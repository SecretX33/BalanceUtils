--[[------------------------------------------------------------+
|   BalanceUtils                                                |
|   --> Increase your DPS by canceling Solar Eclipse            |
|   Author: SecretX (Freezingice @ WoW Brasil)                  |
|   Contact: notyetmidnight@gmail.com                           |
+--------------------------------------------------------------]]

local BalanceUtils = CreateFrame("frame")

-- Configurations
local showCancelMessage                  = true   -- default is true
local cancelMessage                      = "Canceling Solar Eclipse."
local turnAddonOnOnlyInRaidOrParty       = false  -- default is false
local cancelEclipseIfUnderBL             = true   -- default is true
local cancelEclipseOnlyIfUnderBL         = false  -- default is false
local cancelEclipseEvenIfItBreakRotation = false  -- default is false

-- Don't touch anything below
local buDebug           = false    -- BalanceUtils debug messages
local HEROISM_ID        = UnitFactionGroup("player") == "Horde" and 2825 or 32182   -- Horde = "Bloodlust" (2825) / Alliance = "Heroism" (32182)
local HEROISM           = GetSpellInfo(HEROISM_ID) 
local SOLAR_ECLIPSE_ID  = 48517
local SOLAR_ECLIPSE     = GetSpellInfo(SOLAR_ECLIPSE_ID)
local LUNAR_ECLIPSE_ID  = 48518
local LUNAR_ECLIPSE     = GetSpellInfo(LUNAR_ECLIPSE_ID)
local WRATH_ID          = 48461
--local WRATH             = GetSpellInfo(WRATH_ID)
local STARFIRE_ID       = 48465
--local STARFIRE          = GetSpellInfo(STARFIRE_ID)
local MOONKIN_ID        = 24858
local MOONKIN           = GetSpellInfo(MOONKIN_ID)

local gainedLunarTime            = 0       -- When Lunar Eclipse was gained
local lunarCD                    = 0       -- When Lunar Eclipse will be able to proc again
local gainedSolarTime            = 0       -- When Solar Eclipse was gained
local solarCD                    = 0       -- When Solar Eclipse will be able to proc again
local sentMessageTime            = 0       -- Last time the cancelMessage were sent
local advisedPlayerAboutStarfire = 0       -- Last time the addon advised player about Starfire DPS being higher than Wrath DPS

local groupTalentsLib
local addonPrefix = "|cffff9500BalanceUtils:|r %s"

-- Upvalues
local UnitInRaid, UnitAffectingCombat = UnitInRaid, UnitAffectingCombat
local GetSpellLink, UnitAffectingCombat, format = GetSpellLink, UnitAffectingCombat, string.format

BalanceUtils:SetScript("OnEvent", function(self, event, ...)
   self[event](self, ...)
end)

-- Utility functions
local function send(msg)
   print(addonPrefix:format(msg))
   -- DEFAULT_CHAT_FRAME:AddMessage(msg, 1, 1, 1)
end

local function getSpellName(spellID)
   if spellID==nil then return "" end

   local spellName = GetSpellInfo(spellID)
   if spellName~=nil then return spellName else return "" end
end

-- argument "spell" here needs to be spellID
local function getSpellCastTime(spellID)
   if spellID==nil then return 0 end

   -- [API_GetSpellInfo] index 7 is the cast time, in milliseconds
   local castTime = select(7, GetSpellInfo(spellID))
   if castTime~=nil then 
      --if buDebug then send("cast time for spell " .. getSpellName(spell) .. " queued, value is " .. castTime/1000) end
      return castTime/1000
   else 
      if buDebug then send("cast time for spell " .. (getSpellName(spellID) or tostring(spellID) or "Unknown") .. " is nil for some unknown reason") end
      return 0 
   end
end

local function getBuffExpirationTime(unit, spellInfo)
   if(unit==nil or spellInfo==nil) then return 0 end

   -- /run print(select(7,UnitBuff("player",GetSpellInfo(48518)))-GetTime())
   -- 11.402

   -- "API select" pull all the remaining returns from a given function or API starting from that index, the first valid number is 1
   -- [API_UnitBuff] index 7 is the absolute time (client time) when the buff will expire, in seconds

   local now = GetTime()
   local expirationAbsTime = select(7, UnitBuff(unit, spellInfo))

   if expirationAbsTime~=nil then return (expirationAbsTime - now) end
   return 0
end

local function doesUnitHaveThisBuff(unit, spellInfo)
   if(unit==nil or spellInfo==nil) then return false end
   if type(spellInfo)~="string" then send("inside function to check if unit has a buff, expected spellInfo to be a string but it came as " .. tostring(type(spellInfo)) .. ", report this");return false; end

   return UnitBuff(unit, spellInfo)~=nil
end

-- This function guarantee that if the player start the boss with Starfire for whatever reason, it will not cancel his first solar eclipse. Tecnically, the function cancelingSolarWontBreakRotation also do this job, but if player turns on the variable "cancelEclipseEvenIfItBreakRotation" then that function won't prevent this problem from happening aswell, hence why the function below is used.
local function didPlayerGetLunarAtLeastOnce()
   --if buDebug then send("did player get lunar at least once? " .. tostring(gainedLunarTime~=0)) end
   return gainedLunarTime~=0
end

local function isLunarCD()
   return (lunarCD~=0 and (GetTime() < lunarCD))
end

local function isPlayerUnderBL()
   return doesUnitHaveThisBuff("player", HEROISM)
end

local function isPlayerUnderLunar()
   return doesUnitHaveThisBuff("player", LUNAR_ECLIPSE)
end

local function isPlayerUnderSolar()
   return doesUnitHaveThisBuff("player", SOLAR_ECLIPSE)
end

local function willLunarBeOutOfCDWhenWrathCastFinish()
   return ((GetTime() + getSpellCastTime(WRATH_ID)) >= lunarCD)
end

local function getTalentPoints(talentName)
   if talentName==nil or talentName=="" then send("talentName came nil inside function to get how many talent points where spent in a certain talent"); return 0; end
   return groupTalentsLib:UnitHasTalent("player",talentName) or 0
end

local function getSpellDamage(spellID)
   if spellID==nil then send("spellID came nil inside function to get spell damage, report this");return 0; end
   if spellID ~= WRATH_ID and spellID ~= STARFIRE_ID then send(format("addon tried to get damage from spell %s but its not programmed, report this"),(GetSpellLink() or tostring(spellID))); return 0; end

   -- 4 is nature and 7 is arcane
   local baseDmg      = spellID == WRATH_ID and 647 or 1132
   local spellType    = spellID == WRATH_ID and 4 or 7
   local spellPower   = GetSpellBonusDamage(spellType)
   local coefSP       = spellID == WRATH_ID and 0.571 or 1
   local critChance   = math.min(1,math.max(0,GetSpellCritChance(spellType)/100))
   local isShapeshift = doesUnitHaveThisBuff("player", MOONKIN)

   --  Critical chance
   critChance = critChance + (0.02 * getTalentPoints("Nature's Majesty"))
   if spellID == STARFIRE_ID and isPlayerUnderLunar() then
      critChance = math.min(1, critChance + 0.4)
   end

   -- Coef spell power
   if(spellID == WRATH_ID) then coefSP = coefSP + (0.02 * getTalentPoints("Wrath of Cenarius"))
   else coefSP = coefSP + (0.04 * getTalentPoints("Wrath of Cenarius")) end

   -- Damage multiplier
   local moonfury = getTalentPoints("Moonfury")~=3 and (0.03 * getTalentPoints("Moonfury")) or 0.1
   local dmgMulti = 1 * (1 + moonfury) * (1 + (0.02 * getTalentPoints("Earth and Moon"))) * (1 + (isShapeshift and (0.02 * getTalentPoints("Master Shapeshifter")) or 0))
   if spellID == WRATH_ID and isPlayerUnderSolar() then
      dmgMulti = dmgMulti * (1 + 0.4)
   end

   -- Critical multiplier
   local critMulti = 1.5 + (0.1 * getTalentPoints("Vengeance"))
   local headGem = GetItemGem(GetInventoryItemLink("player",1),1)
   if headGem == "Chaotic Skyflare Diamond" or headGem == "Relentless Earthsiege Diamond" then
      critMulti = 1+((1.5*1.03-1) * critMulti)
   end

   local hit = (baseDmg + (spellPower * coefSP)) * dmgMulti
   local crit = hit * critMulti
   --if buDebug then
   --   send("----------------------")
   --   send(select(1,GetSpellInfo(spellID)) ..  " spellPower is " .. spellPower)
   --   send(select(1,GetSpellInfo(spellID)) ..  " critChance is " .. critChance)
   --   send(select(1,GetSpellInfo(spellID)) ..  " coefSP is " .. coefSP)
   --   send(select(1,GetSpellInfo(spellID)) .. " hit is " .. hit)
   --   send(select(1,GetSpellInfo(spellID)) .. " crit is " .. crit)
   --end
   return math.floor(((hit * (1 - critChance)) + (crit * critChance)))
end

local function getSpellDPS(spellID)
   if spellID==nil then send("spellID came nil inside function to get spell dps, report this");return 0; end
   if spellID ~= WRATH_ID and spellID ~= STARFIRE_ID then send(format("addon tried to get DPS from spell %s but its not programmed, report this"),(GetSpellLink() or tostring(spellID))); return 0; end

   return math.floor(getSpellDamage(spellID)/math.max(1, getSpellCastTime(spellID)))
end

-- Bad situation example
-- gainedLunar  = 70 | 85
-- gainedSolar  = 95 | 110
-- now          = 100   < canceled solar
-- lunarCD      = 100
-- gainedLunar2 = 100 | 115
-- lunarCD2     = 130
-- solarCD      = 125

-- Perfect situation example
-- gainedLunar  = 0  | 15
-- gainedSolar  = 15 | 30
-- now          = 15   < calls function below
-- lunarCD      = 30
-- gainedLunar2 = 30 | 45
-- solarCD      = 45
-- lunarCD2     = 60

-- If Lunar Eclipse is CD and willLunarBeOutOfCDWhenWrathCastFinish() returns false then there is no point in calling this function, remember this when using it
local function cancelingSolarWontBreakRotation()
   if not isPlayerUnderSolar() or cancelEclipseEvenIfItBreakRotation then return true end

   local logic = ((solarCD - getSpellCastTime(STARFIRE_ID)) < (GetTime() + 15))
   if buDebug then send("Canceling Solar won't make us waste time casting Starfire without buff = " .. tostring(logic)) end
   return logic
end

local function advisePlayerAboutStarfire()
   if(isPlayerUnderBL() or buDebug) and not isPlayerUnderLunar() and didPlayerGetLunarAtLeastOnce() and isLunarCD() and (getSpellDPS(STARFIRE_ID) > getSpellDPS(WRATH_ID) and (GetTime() > (advisedPlayerAboutStarfire + 3))) then
      send("Please ignore Wrath, Starfire will give you more DPS!")
      advisedPlayerAboutStarfire = GetTime()
   end
end

local function isBalance()
   local playerClass = select(2,UnitClass("player"))
   if playerClass~="DRUID" then return false end

   -- the function GetUnitTalentSpec from GroupTalentsLib can return a number if the player has not yet seen that class/build, so another "just in case" code, but I'm not sure what if this number means the talent tree number (like 1 for balance, 3 for restoration) or just the spec slot (player has just two slots), I guess I'll have to shoot in the dark here. ;)
   -- I just discovered that this function can also return nil if called when player is logging in (probably because the inspect function doesn't work while logging in), so I added the 'nil' as returning true to circumvent this issue
   local spec = groupTalentsLib:GetUnitTalentSpec(UnitName("player"))
   local isBalance = (spec=="Balance" or spec=="1" or spec==1 or spec==nil)
   return isBalance
end

-- Logic functions are under here
local function checkIfShouldCancelSolarEclipse()
   if isPlayerUnderSolar() and didPlayerGetLunarAtLeastOnce() and willLunarBeOutOfCDWhenWrathCastFinish() and cancelingSolarWontBreakRotation() then
      if (not isPlayerUnderBL() and not cancelEclipseOnlyIfUnderBL) or (isPlayerUnderBL() and cancelEclipseIfUnderBL) then
         if buDebug then
            send("Canceling Solar Eclipse at " .. GetTime())
         elseif showCancelMessage and (GetTime() > (sentMessageTime + 2)) then  -- the GetTime here prevent sending the cancel message two times within 2 seconds of each other, a "just in case" check
            sentMessageTime = GetTime()
            send(cancelMessage)
         end
         CancelUnitBuff("player", SOLAR_ECLIPSE);
      end
   end
end

function BalanceUtils:COMBAT_LOG_EVENT_UNFILTERED(timestamp, event, srcGUID, srcName, srcFlags, destGUID, destName, destFlags, spellID, spellName, ...)
   if spellID==nil then return end  -- If spellID is nil then it's not one of our spells
   if srcName ~= UnitName("player") and destName ~= UnitName("player") then return end -- The event if NOT from the player, so that is not relevant

   if event == "SPELL_AURA_APPLIED" then
      if spellID == LUNAR_ECLIPSE_ID then
         if buDebug then send("you just gained " .. (GetSpellLink(spellID) or "Unknown") .. ", very noice!") end
         gainedLunarTime = GetTime()
         whenLunarWillFade = gainedLunarTime + getBuffExpirationTime("player", LUNAR_ECLIPSE)
         lunarCD = gainedLunarTime + 30
      elseif spellID == SOLAR_ECLIPSE_ID then
         if buDebug then send("you just gained " .. (GetSpellLink(spellID) or "Unknown") .. ", darn imagine if it was Lunar instead...") end
         gainedSolarTime = GetTime()
         whenSolarWillFade = gainedSolarTime + getBuffExpirationTime("player", SOLAR_ECLIPSE)
         solarCD = gainedSolarTime + 30
      elseif spellID == HEROISM_ID then
         send(srcName .. " casted " .. (GetSpellLink(spellID) or "Unknown") .. ", go for the neck!")
      end

   elseif spellID == WRATH_ID and srcName == UnitName("player") then
      if (buDebug or isPlayerUnderBL()) and event == "SPELL_CAST_START" then
         --if buDebug then
         --   send("Wrath average damage is " .. getSpellDamage(WRATH_ID) .. ", and Starfire average damage is " .. getSpellDamage(STARFIRE_ID))
         --   send("And Wrath DPS is " .. getSpellDPS(WRATH_ID) .. ", and Starfire average DPS is " .. getSpellDPS(STARFIRE_ID))
         --end
         advisePlayerAboutStarfire()
      end
      if (event == "SPELL_CAST_START" or event == "SPELL_DAMAGE" or event == "SPELL_MISSED") then
         checkIfShouldCancelSolarEclipse()
      end
   end
end

-- Called when player leaves combat
-- Used to zero all variables so the addon logic knows that, when player enters combat again, it's a new fight against a new enemy
function BalanceUtils:PLAYER_REGEN_ENABLED()
   local _, instance = IsInInstance()

   if self.db.enabled and (instance=="raid" or instance=="party" or buDebug) then
      if buDebug then send("Addon variables got zeroed because player leave combat.") end
      gainedLunarTime            = 0
      lunarCD                    = 0
      gainedSolarTime            = 0
      solarCD                    = 0
      sentMessageTime            = 0
      advisedPlayerAboutStarfire = 0
   end
end

local function regForAllEvents()
   if(BalanceUtils==nil) then send("frame is nil inside function that register for all events function, report this"); return; end
   if buDebug then send("addon is now listening to all combatlog events.") end

   BalanceUtils:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
   BalanceUtils:RegisterEvent("PLAYER_REGEN_ENABLED")
   BalanceUtils:RegisterEvent("PLAYER_TALENT_UPDATE")
end

local function unregFromAllEvents()
   if(BalanceUtils==nil) then send("frame is nil inside function that unregister all events function, report this"); return; end
   if buDebug then send("addon is no longer listening to combatlog events.") end

   BalanceUtils:UnregisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
   BalanceUtils:UnregisterEvent("PLAYER_REGEN_ENABLED")
   BalanceUtils:UnregisterEvent("PLAYER_TALENT_UPDATE")
end

-- Checks if addon should be enabled, and enable it if isn't enabled, and disable if it should not be enabled
local function checkIfAddonShouldBeEnabled()
   if(BalanceUtils==nil) then send("frame came nil inside function that check if this addon should be enabled, report this"); return; end
   local _, instance = IsInInstance()

   -- Check if user disabled the addon, if the player is using Balance spec and also if he is a raid or party or he doesn't care about this
   if BalanceUtils.db.enabled and isBalance() and (not turnAddonOnOnlyInRaidOrParty or (turnAddonOnOnlyInRaidOrParty and (instance=="raid" or instance=="party"))) then
      regForAllEvents()
   else
      unregFromAllEvents()
   end
end

function BalanceUtils:PLAYER_TALENT_UPDATE()
   if buDebug then send("you have changed your build to " .. groupTalentsLib:GetUnitTalentSpec(UnitName("player"))) end
   checkIfAddonShouldBeEnabled(self)
end

function BalanceUtils:PLAYER_ENTERING_WORLD()
   checkIfAddonShouldBeEnabled(self)
end

-- Slash commands functions
-- toggle, on, off
local function slashCommandToggleAddon(state)
   if state == "on" or (not BalanceUtils.db.enabled and state==nil) then
      BalanceUtils.db.enabled = true
      checkIfAddonShouldBeEnabled()
      send("|cff00ff00on|r")
   elseif state == "off" or (BalanceUtils.db.enabled and state==nil) then
      BalanceUtils.db.enabled = false
      checkIfAddonShouldBeEnabled()
      send("|cffff0000off|r")
   end
end

-- debug
local function slashCommandDebug()
   if not buDebug then
      buDebug = true
      BalanceUtils.db.debug = true
      send("debug mode turned |cff00ff00on|r")
   else
      buDebug = false
      BalanceUtils.db.debug = false
      send("debug mode turned |cffff0000off|r")
   end
end

local function slashCommand(typed)
   local cmd = string.match(typed,"^(%w+)") -- Gets the first word the user has typed
   if cmd~=nil then cmd = cmd:lower() end           -- And makes it lower case

   if(cmd=="" or cmd==nil or cmd=="toggle") then slashCommandToggleAddon()
   elseif(cmd=="on" or cmd=="enable") then slashCommandToggleAddon("on")
   elseif(cmd=="off" or cmd=="disable") then slashCommandToggleAddon("off")
   elseif(cmd=="debug") then slashCommandDebug()
   end
end
-- End of slash commands function

function BalanceUtils:ADDON_LOADED(addon)
   if addon ~= "BalanceUtils" then return end
   local _,playerClass=UnitClass("player");  -- Get player class

   if playerClass~="DRUID" then  -- If player is not druid, then this addon is not for him/her
      if buDebug then send("you are not a druid, disabling the addon.") end 
      self:UnregisterEvent("ADDON_LOADED")
      return
   end

   groupTalentsLib = LibStub("LibGroupTalents-1.0")  -- Importing LibGroupTalents so I can use it later by using groupTalentsLib variable
   BalanceUtilsDB = BalanceUtilsDB or { enabled = true } -- DB just stores if addon is turned on or off
   self.db = BalanceUtilsDB
   -- Loading variables
   buDebug = self.db.debug or buDebug
   SLASH_BALANCEUTILS1 = "/bu"
   SLASH_BALANCEUTILS2 = "/balanceutils"
   SlashCmdList.BALANCEUTILS = function(cmd) slashCommand(cmd) end
   if buDebug then send("remember that debug mode is |cff00ff00ON|r.") end

   self:RegisterEvent("PLAYER_ENTERING_WORLD")
   self:UnregisterEvent("ADDON_LOADED")
end

BalanceUtils:RegisterEvent("ADDON_LOADED")