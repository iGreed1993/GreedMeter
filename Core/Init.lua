--[[
    GreedMeter - Core / Init
    Global table, module bus, combat state, events, combat log range.
]]

GreedMeter = GreedMeter or {}
local OM = GreedMeter

OM.players = OM.players or {}
OM.inCombat = false
OM.combatStart = 0
OM.segment = "current"
OM.modules = OM.modules or {}
OM.combatLogRange = 200
OM.combatLogRangeApplied = false
OM.heuristicPets = OM.heuristicPets or {}

-- ============================================================
-- Combat Log Range
-- Expands the distance at which combat log events are received
-- so group/raid members farther than the default 40y are tracked.
-- ============================================================

local COMBAT_LOG_RANGE_CVARS = {
    "CombatLogRangeParty",
    "CombatLogRangePartyPet",
    "CombatLogRangeFriendlyPlayers",
    "CombatLogRangeFriendlyPlayersPets",
    "CombatLogRangeHostilePlayers",
    "CombatLogRangeHostilePlayersPets",
    "CombatLogRangeCreature",
}

function OM:ApplyCombatLogRange(range)
    range = tonumber(range) or self.combatLogRange or 200
    if range < 40 then range = 40 end
    if range > 200 then range = 200 end -- hard cap; client may ignore higher
    self.combatLogRange = range

    local rangeStr = tostring(range)
    for _gi = 1, table.getn(COMBAT_LOG_RANGE_CVARS) do local cvar = COMBAT_LOG_RANGE_CVARS[_gi]
        SetCVar(cvar, rangeStr)
    end
    self.combatLogRangeApplied = true
end

function OM:GetCombatLogRange()
    -- Read one representative CVar
    local val = GetCVar("CombatLogRangeFriendlyPlayers")
    return tonumber(val) or self.combatLogRange or 40
end

-- ============================================================
-- Combat State
-- ============================================================

function OM:StartCombat()
    if self.inCombat then return end
    self.inCombat = true
    self.combatStart = GetTime()

    -- Notify modules
    self:Fire("OnCombatStart")
end

function OM:StopCombat()
    if not self.inCombat then return end
    self.inCombat = false

    local duration = GetTime() - self.combatStart
    self:Fire("OnCombatEnd", duration)
end

-- Segment ends after this many seconds with no damage/heal/etc activity.
-- Vanilla REGEN_ENABLED can lag 10–20s with pets/DoTs; the meter should not wait that long.
OM.COMBAT_IDLE_END = 4.0

function OM:CheckCombatIdleEnd()
    if not self.inCombat then return end
    local cur = self.data and self.data.current
    local last = cur and cur.lastActivityTime
    if not last then return end
    if (GetTime() - last) >= (self.COMBAT_IDLE_END or 4.0) then
        self:StopCombat()
    end
end

-- Single reset entry point used by /gdm reset and the UI reset button.
-- Parser:OnReset (fired first) owns clearing combat data; other modules
-- clear their own state. Avoids the previous double-clear in Commands/Frames.
function OM:ResetData()
    if self.SetSetting then
        self:SetSetting("testMode", false)
    end
    if self.UpdateGroupRoster then
        self:UpdateGroupRoster()
    end
    self:Fire("OnReset")
end

-- Group type for Party Reset: "solo" | "party" | "raid"
local function CurrentGroupType()
    local nRaid = GetNumRaidMembers and GetNumRaidMembers() or 0
    if nRaid and nRaid > 0 then
        return "raid"
    end
    local nParty = GetNumPartyMembers and GetNumPartyMembers() or 0
    if nParty and nParty > 0 then
        return "party"
    end
    return "solo"
end

-- Auto-reset on group join and/or leave, depending on settings.
function OM:MaybePartyReset()
    local joinOn = self.GetSetting and self:GetSetting("partyJoinReset") == true
    local leaveOn = self.GetSetting and self:GetSetting("partyLeaveReset") == true
    -- Older combined setting
    if self.GetSetting and self:GetSetting("partyReset") == true then
        joinOn = true
        leaveOn = true
    end
    if not joinOn and not leaveOn then
        self._partyResetGroupType = CurrentGroupType()
        return
    end
    local newType = CurrentGroupType()
    local oldType = self._partyResetGroupType
    self._partyResetGroupType = newType

    -- First observation after load — remember only, do not reset
    if oldType == nil then
        return
    end
    if oldType == newType then
        return
    end

    local isJoin = (oldType == "solo" and (newType == "party" or newType == "raid"))
        or (oldType == "party" and newType == "raid")
    local isLeave = (newType == "solo" and (oldType == "party" or oldType == "raid"))
        or (oldType == "raid" and newType == "party")
    local shouldReset = (isJoin and joinOn) or (isLeave and leaveOn)
    if not shouldReset then
        return
    end

    local function doIt()
        if OM.ResetData then
            OM:ResetData()
        else
            OM:Fire("OnReset")
        end
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00GreedMeter:|r Group change reset — data cleared.")
    end

    if self:GetSetting("confirmReset") then
        StaticPopupDialogs["GREEDMETER_CONFIRM_PARTY_RESET"] = {
            text = "Party/Raid changed.\nReset all GreedMeter data?",
            button1 = "Yes",
            button2 = "No",
            OnAccept = function()
                doIt()
            end,
            timeout = 0,
            whileDead = 1,
            hideOnEscape = 1,
            exclusive = 1,
        }
        StaticPopup_Show("GREEDMETER_CONFIRM_PARTY_RESET")
    else
        doIt()
    end
end

-- ============================================================
-- Module system (simple event bus)
-- ============================================================

function OM:RegisterModule(name, module)
    self.modules[name] = module
    if module.OnLoad then
        module:OnLoad()
    end
end

-- Lua 5.0 compatible: no "..." expression (that is Lua 5.1+)
function OM:Fire(event, a1, a2, a3, a4, a5)
    -- Parser first so duration/lastActivity are finalized before UI refresh
    local parser = self.modules and self.modules.Parser
    if parser and parser[event] then
        parser[event](parser, a1, a2, a3, a4, a5)
    end
    local name, mod
    for name, mod in pairs(self.modules) do
        if name ~= "Parser" and mod[event] then
            mod[event](mod, a1, a2, a3, a4, a5)
        end
    end
end

-- ============================================================
-- Event Frame
-- ============================================================

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PARTY_MEMBERS_CHANGED")
frame:RegisterEvent("RAID_ROSTER_UPDATE")
frame:RegisterEvent("PLAYER_REGEN_DISABLED")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
frame:RegisterEvent("UNIT_PET")
frame:RegisterEvent("PET_BAR_UPDATE") -- extra pet signal

-- Soft-end segment after idle (does not wait for slow REGEN_ENABLED)
local idleElapsed = 0
frame:SetScript("OnUpdate", function()
    idleElapsed = idleElapsed + arg1
    if idleElapsed < 0.25 then return end
    idleElapsed = 0
    if OM.CheckCombatIdleEnd then
        OM:CheckCombatIdleEnd()
    end
end)

frame:SetScript("OnEvent", function()
    local event = event
    local arg1 = arg1

    if event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
        OM:InitDB()
        local range = (OM.GetSetting and OM:GetSetting("combatLogRangeSetting")) or OM.combatLogRange or 200
        OM:ApplyCombatLogRange(range)
        OM:UpdateGroupRoster()
        OM._partyResetGroupType = CurrentGroupType()
        OM:Fire("OnLoad")
        if OM.ShowSuperWoWPromptIfNeeded then
            OM:ShowSuperWoWPromptIfNeeded()
        end
    elseif event == "PARTY_MEMBERS_CHANGED" or event == "RAID_ROSTER_UPDATE" then
        OM:UpdateGroupRoster()
        OM:Fire("OnRosterUpdate")
        if OM.MaybePartyReset then
            OM:MaybePartyReset()
        end
    elseif event == "UNIT_PET" or event == "PET_BAR_UPDATE" then
        OM:UpdateGroupRoster()
        OM:Fire("OnRosterUpdate")
    elseif event == "PLAYER_REGEN_DISABLED" then
        OM:StartCombat()
    elseif event == "PLAYER_REGEN_ENABLED" then
        -- Small delay so combat does not end on brief drops
        -- For now keep it simple; group combat timer can come later
        OM:StopCombat()
    end
end)
