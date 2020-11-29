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

local gainedLunarTime   = 0       -- When Lunar Eclipse was gained
local lunarCD           = 0       -- When Lunar Eclipse will be able to proc again
local gainedSolarTime   = 0       -- When Solar Eclipse was gained
local solarCD           = 0       -- When Solar Eclipse will be able to proc again
--local gainedBL          = 0       -- When Bloodlust was gained
--local whenBLWillFade     = 0       -- Expiration time for BL

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

-- argument "spell" here can be spellID, spellName or spellLink
local function getSpellCastTime(spell)
   if spell==nil then return 0 end

   -- [API_GetSpellInfo] index 7 is the cast time, in milliseconds
   local castTime = select(7, GetSpellInfo(spell))
   if castTime~=nil then 
      --if buDebug then send("cast time for spell " .. getSpellName(spell) .. " queued, value is " .. castTime/1000) end
      return castTime/1000
   else 
      if buDebug then send("cast time for spell " .. getSpellName(spell) .. " is nil for some unknown reason") end
      return 0 
   end
end

local function getBuffExpirationTime(unit, buff)
   if(unit==nil or buff==nil) then return 0 end

   -- /run print(select(7,UnitBuff("player",GetSpellInfo(48518)))-GetTime())
   -- 11.402

   -- "API select" pull all the remaining returns from a given function or API starting from that index, the first valid number is 1
   -- [API_UnitBuff] index 7 is the absolute time (client time) when the buff will expire, in seconds

   local now = GetTime()
   local expirationAbsTime = select(7, UnitBuff(unit, buff))

   if expirationAbsTime~=nil then return (expirationAbsTime - now) end
   return 0
end

local function doesUnitHaveThisBuff(unit, buff)
   if(unit==nil or buff==nil) then return false end

   return UnitBuff(unit,buff)~=nil
end

-- This function guarantee that if the player start the boss with Starfire for whatever reason, it will not cancel his first solar eclipse. Tecnically, the function cancelingSolarWontBreakRotation also do this job, but if player turns on the variable "cancelEclipseEvenIfItBreakRotation" then that function won't prevent this problem from happening aswell, hence why the function below is used.
local function didPlayerGetLunarAtLeastOnce()
   --if buDebug then send("did player get lunar at least once? " .. tostring(gainedLunarTime~=0)) end
   return gainedLunarTime~=0
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
   if logic then return true else return false end
end

local function isBalance()
   local playerClass = select(2,UnitClass("player"))
   if playerClass~="DRUID" then return false end

   -- the function GetUnitTalentSpec from GroupTalentsLib can return a number if the player has not yet seen that class/build, so another "just in case" code, but I'm not sure what if this number means the talent tree number (like 1 for balance, 3 for restoration) or just the spec slot (player has just two slots), I guess I'll have to shoot in the dark here. ;)
   -- I just discovered that this function can also return nil if called when player is logging in (probably because the inspect function doesn't work while logging in), so I added the 'nil' as returning true to circumvent this issue
   local spec = groupTalentsLib:GetUnitTalentSpec(UnitName("player"))
   local isBalance = (spec=="Balance" or spec=="1" or spec==1 or spec==nil)
   --if buDebug then send("isBalance() returned " .. tostring(isBalance) .. ", spec is " .. tostring(spec)) end
   return isBalance
end

-- Logic functions are under here
function BalanceUtils:COMBAT_LOG_EVENT_UNFILTERED(timestamp, event, srcGUID, srcName, srcFlags, destGUID, destName, destFlags, spellID, spellName, ...)
   if srcName ~= UnitName("player") and destName ~= UnitName("player") then return end -- The event if NOT from the player, so that is not relevant

   if event == "SPELL_AURA_APPLIED" then
      if spellID == LUNAR_ECLIPSE_ID then
         if buDebug then send("you just gained " .. GetSpellLink(LUNAR_ECLIPSE_ID) .. ", very noice!") end
         gainedLunarTime = GetTime()
         whenLunarWillFade = gainedLunarTime + getBuffExpirationTime("player", LUNAR_ECLIPSE)
         lunarCD = gainedLunarTime + 30
      elseif spellID == SOLAR_ECLIPSE_ID then
         if buDebug then send("you just gained " .. GetSpellLink(SOLAR_ECLIPSE_ID) .. ", darn imagine if it was Lunar instead...") end
         gainedSolarTime = GetTime()
         whenSolarWillFade = gainedSolarTime + getBuffExpirationTime("player", SOLAR_ECLIPSE)
         solarCD = gainedSolarTime + 30
      elseif spellID == HEROISM_ID and buDebug then
         send(srcName .. " casted " .. GetSpellLink(HEROISM_ID) .. ", go for the neck!")
      end

   elseif event == "SPELL_CAST_START" then
      --if buDebug and spellID == WRATH_ID then send("started casting " .. GetSpellLink(WRATH_ID) .. " at " .. GetTime()) end

      if spellID == WRATH_ID and isPlayerUnderSolar() and didPlayerGetLunarAtLeastOnce() and willLunarBeOutOfCDWhenWrathCastFinish() and cancelingSolarWontBreakRotation() then
         if (not isPlayerUnderBL() and not cancelEclipseOnlyIfUnderBL) or (isPlayerUnderBL() and cancelEclipseIfUnderBL) then
            if buDebug then 
               send("Canceling Solar Eclipse at " .. GetTime())
            elseif showCancelMessage then 
               send(cancelMessage)
            end
            CancelUnitBuff("player", SOLAR_ECLIPSE);
         end
      end
   end   
end

-- Called when player leaves combat
-- Used to zero all variables so the addon logic knows that, when player enters combat again, it's a new fight against a new enemy
function BalanceUtils:PLAYER_REGEN_ENABLED()
   local _, instance = IsInInstance()

   if self.db.enabled and (instance=="raid" or instance=="party" or buDebug) then
      if buDebug then send("Addon variables got zeroed because player leave combat.") end
      gainedLunarTime = 0
      lunarCD         = 0
      gainedSolarTime = 0
      solarCD         = 0
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
   SLASH_BALANCEUTILS1 = "/bu"
   SLASH_BALANCEUTILS2 = "/balanceutils"
   SlashCmdList.BALANCEUTILS = function()
      if not self.db.enabled then
         self.db.enabled = true
         checkIfAddonShouldBeEnabled()
         send("|cff00ff00on|r")
      else
         self.db.enabled = false
         checkIfAddonShouldBeEnabled()
         send("|cffff0000off|r")
      end
   end
   self:RegisterEvent("PLAYER_ENTERING_WORLD")
end

BalanceUtils:RegisterEvent("ADDON_LOADED")