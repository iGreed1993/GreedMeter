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
    for _, cvar in ipairs(COMBAT_LOG_RANGE_CVARS) do
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

frame:SetScript("OnEvent", function()
    local event = event
    local arg1 = arg1

    if event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
        OM:InitDB()
        local range = (OM.GetSetting and OM:GetSetting("combatLogRangeSetting")) or OM.combatLogRange or 200
        OM:ApplyCombatLogRange(range)
        OM:UpdateGroupRoster()
        OM:Fire("OnLoad")
        if OM.ShowSuperWoWPromptIfNeeded then
            OM:ShowSuperWoWPromptIfNeeded()
        end
    elseif event == "PARTY_MEMBERS_CHANGED" or event == "RAID_ROSTER_UPDATE" or event == "UNIT_PET" or event == "PET_BAR_UPDATE" then
        OM:UpdateGroupRoster()
        OM:Fire("OnRosterUpdate")
    elseif event == "PLAYER_REGEN_DISABLED" then
        OM:StartCombat()
    elseif event == "PLAYER_REGEN_ENABLED" then
        -- Small delay so we don't end combat on brief drops
        -- For now keep it simple; group combat timer can come later
        OM:StopCombat()
    end
end)
