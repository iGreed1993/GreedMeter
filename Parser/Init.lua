--[[
    GreedMeter - Parser / Init
    Shared namespace for parser files (Lua 5.0 has no cross-file locals).

    Combat-event backend priority:
      1. Nampower  — structured damage / heal / miss / dispel / CC events
      2. SuperWoW  — RAW_COMBATLOG (when Nampower absent)
      3. Stock chat — CHAT_MSG_* text parsing

    Interrupts always use chat (nampower has no reliable interrupt event).

    SuperWoW GUID / pet helpers stay enabled whenever SuperWoW is present.
    Threat is independent of the combat-event backend.
]]

local OM = GreedMeter
GreedMeter.ParserNS = GreedMeter.ParserNS or {}
local NS = GreedMeter.ParserNS

NS.Parser = NS.Parser or {}
NS.Backends = NS.Backends or {}

-- "nampower" | "superwow" | "chat"
NS.combatBackend = "chat"
NS.useNampowerCombat = false   -- damage / heal / miss / absorb
NS.useNampowerDispel = false   -- SPELL_DISPEL_BY_*
NS.useNampowerCC = false       -- AURA_CAST + DEBUFF_* hard CC
NS.superwowHelpers = false
