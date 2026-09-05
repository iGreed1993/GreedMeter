--[[
    GreedMeter - Parser / Backend_Chat
    CHAT_MSG_* and pattern-based combat log parsing.
    Uses shared Parser API from Parser/API.lua via GreedMeter.ParserNS.
]]

local OM = GreedMeter
local NS = GreedMeter.ParserNS
local Parser = NS.Parser
local H = NS.H
local ST = NS.ST

-- Locals mirrored from API for readable call sites
local ModeEnabled = NS.ModeEnabled
local NormalizeName = NS.NormalizeName
local EnsurePlayer = NS.EnsurePlayer
local ResolveSource = NS.ResolveSource
local IsTracked = NS.IsTracked
local SuperWoWAvailable = NS.SuperWoWAvailable
local StripAndCacheGuids = NS.StripAndCacheGuids
local RefreshGuidCacheFromUnits = NS.RefreshGuidCacheFromUnits
local NoteActivity = NS.NoteActivity
local guidToName = NS.guidToName
local SpellInSet = NS.SpellInSet
local SpellLookup = NS.SpellLookup
local PushCapped = NS.PushCapped
local ForEachGroupUnit = NS.ForEachGroupUnit
local FindUnitByName = NS.FindUnitByName
local SplitOverheal = NS.SplitOverheal
local IsUniqueEnemyName = NS.IsUniqueEnemyName
local MarkDuplicateName = NS.MarkDuplicateName
local NoteEnemyDeath = NS.NoteEnemyDeath
local NoteEnemyHit = NS.NoteEnemyHit
local UnitLooksLikeBoss = NS.UnitLooksLikeBoss
local GetGroupAverageMaxHP = NS.GetGroupAverageMaxHP
local NoteLastHit = NS.NoteLastHit
local NoteSpellOutcome = NS.NoteSpellOutcome
local EmptyOutcomeBucket = NS.EmptyOutcomeBucket
local IsAbsorbShield = NS.IsAbsorbShield
local NoteRecentAbsorbCaster = NS.NoteRecentAbsorbCaster
local GetRecentAbsorbCaster = NS.GetRecentAbsorbCaster
local SetAbsorbAura = NS.SetAbsorbAura
local ClearAbsorbAura = NS.ClearAbsorbAura
local GetAbsorbApplicator = NS.GetAbsorbApplicator
local RECENT_CASTER_TIMEOUT = NS.RECENT_CASTER_TIMEOUT or 8

local playerName = UnitName("player")
if ST then ST.playerName = playerName end

local Chat = {}
NS.Backends.Chat = Chat

-- Pattern sanitization (locale-independent)
-- Converts global strings like COMBATHITSELFOTHER into matchable patterns
-- ============================================================

local sanitize_cache = {}
local function sanitize(pattern)
    if not pattern then return nil end
    if sanitize_cache[pattern] then
        return sanitize_cache[pattern]
    end

    local ret = pattern
    -- Escape magic characters
    ret = string.gsub(ret, "([%+%-%*%(%)%?%[%]%^])", "%%%1")
    -- Remove capture indexes (%1$s → %s)
    ret = string.gsub(ret, "%%%d%$", "%%")
    -- Convert %s / %d / %c into captures
    ret = string.gsub(ret, "%%s", "(.+)")
    ret = string.gsub(ret, "%%d", "(%%d+)")
    ret = string.gsub(ret, "%%c", "(.)")
    -- Prefer non-greedy for name before number
    ret = string.gsub(ret, "%(.%+%)%(%%d%+%)", "(.-)(%d+)")

    sanitize_cache[pattern] = ret
    return ret
end

-- ============================================================
-- Combat log pattern tables
-- ============================================================

-- Defaults for "You" source / target
local defaults = {
    source = function() return playerName or UnitName("player") end,
    target = function() return playerName or UnitName("player") end,
    attack = "Auto Attack",
    school = nil,
}

-- Each entry: pattern global → function that returns source, spell, target, amount, school, type
-- type = "damage" | "heal" | "taken"

local combatlog_parser = {}

-- ---------- Melee hits (self) ----------
combatlog_parser[COMBATHITSELFOTHER] = function(d, target, value)
    -- You hit %s for %d.
    return d.source(), d.attack, target, value, nil, "damage"
end
combatlog_parser[COMBATHITCRITSELFOTHER] = function(d, target, value)
    -- You crit %s for %d.
    return d.source(), d.attack, target, value, nil, "damage"
end
combatlog_parser[COMBATHITSCHOOLSELFOTHER] = function(d, target, value, school)
    -- You hit %s for %d %s damage.
    return d.source(), d.attack, target, value, school, "damage"
end
combatlog_parser[COMBATHITCRITSCHOOLSELFOTHER] = function(d, target, value, school)
    -- You crit %s for %d %s damage.
    return d.source(), d.attack, target, value, school, "damage"
end

-- ---------- Melee hits (other → self) ----------
combatlog_parser[COMBATHITOTHERSELF] = function(d, source, value)
    -- %s hits you for %d.
    return source, d.attack, d.target(), value, nil, "taken"
end
combatlog_parser[COMBATHITCRITOTHERSELF] = function(d, source, value)
    -- %s crits you for %d.
    return source, d.attack, d.target(), value, nil, "taken"
end
combatlog_parser[COMBATHITSCHOOLOTHERSELF] = function(d, source, value, school)
    -- %s hits you for %d %s damage.
    return source, d.attack, d.target(), value, school, "taken"
end
combatlog_parser[COMBATHITCRITSCHOOLOTHERSELF] = function(d, source, value, school)
    -- %s crits you for %d %s damage.
    return source, d.attack, d.target(), value, school, "taken"
end

-- ---------- Melee hits (other → other) ----------
combatlog_parser[COMBATHITOTHEROTHER] = function(d, source, target, value)
    -- %s hits %s for %d.
    return source, d.attack, target, value, nil, "damage"
end
combatlog_parser[COMBATHITCRITOTHEROTHER] = function(d, source, target, value)
    -- %s crits %s for %d.
    return source, d.attack, target, value, nil, "damage"
end
combatlog_parser[COMBATHITSCHOOLOTHEROTHER] = function(d, source, target, value, school)
    -- %s hits %s for %d %s damage.
    return source, d.attack, target, value, school, "damage"
end
combatlog_parser[COMBATHITCRITSCHOOLOTHEROTHER] = function(d, source, target, value, school)
    -- %s crits %s for %d %s damage.
    return source, d.attack, target, value, school, "damage"
end

-- ---------- Spell damage (self) ----------
combatlog_parser[SPELLLOGSELFOTHER] = function(d, spell, target, value)
    -- Your %s hits %s for %d.
    return d.source(), spell, target, value, nil, "damage"
end
combatlog_parser[SPELLLOGCRITSELFOTHER] = function(d, spell, target, value)
    -- Your %s crits %s for %d.
    return d.source(), spell, target, value, nil, "damage"
end
combatlog_parser[SPELLLOGSCHOOLSELFOTHER] = function(d, spell, target, value, school)
    -- Your %s hits %s for %d %s damage.
    return d.source(), spell, target, value, school, "damage"
end
combatlog_parser[SPELLLOGCRITSCHOOLSELFOTHER] = function(d, spell, target, value, school)
    -- Your %s crits %s for %d %s damage.
    return d.source(), spell, target, value, school, "damage"
end
combatlog_parser[SPELLLOGSELFSELF] = function(d, spell, value)
    -- Your %s hits you for %d.
    return d.source(), spell, d.target(), value, nil, "damage"
end
combatlog_parser[SPELLLOGCRITSELFSELF] = function(d, spell, value)
    -- Your %s crits you for %d.
    return d.source(), spell, d.target(), value, nil, "damage"
end
combatlog_parser[SPELLLOGSCHOOLSELFSELF] = function(d, spell, value, school)
    -- Your %s hits you for %d %s damage.
    return d.source(), spell, d.target(), value, school, "damage"
end
combatlog_parser[SPELLLOGCRITSCHOOLSELFSELF] = function(d, spell, value, school)
    -- Your %s crits you for %d %s damage.
    return d.source(), spell, d.target(), value, school, "damage"
end

-- ---------- Spell damage (other → self) ----------
combatlog_parser[SPELLLOGOTHERSELF] = function(d, source, spell, value)
    -- %s's %s hits you for %d.
    return source, spell, d.target(), value, nil, "taken"
end
combatlog_parser[SPELLLOGCRITOTHERSELF] = function(d, source, spell, value)
    -- %s's %s crits you for %d.
    return source, spell, d.target(), value, nil, "taken"
end
combatlog_parser[SPELLLOGSCHOOLOTHERSELF] = function(d, source, spell, value, school)
    -- %s's %s hits you for %d %s damage.
    return source, spell, d.target(), value, school, "taken"
end
combatlog_parser[SPELLLOGCRITSCHOOLOTHERSELF] = function(d, source, spell, value, school)
    -- %s's %s crits you for %d %s damage.
    return source, spell, d.target(), value, school, "taken"
end

-- ---------- Spell damage (other → other) ----------
combatlog_parser[SPELLLOGOTHEROTHER] = function(d, source, spell, target, value)
    -- %s's %s hits %s for %d.
    return source, spell, target, value, nil, "damage"
end
combatlog_parser[SPELLLOGCRITOTHEROTHER] = function(d, source, spell, target, value)
    -- %s's %s crits %s for %d.
    return source, spell, target, value, nil, "damage"
end
combatlog_parser[SPELLLOGSCHOOLOTHEROTHER] = function(d, source, spell, target, value, school)
    -- %s's %s hits %s for %d %s damage.
    return source, spell, target, value, school, "damage"
end
combatlog_parser[SPELLLOGCRITSCHOOLOTHEROTHER] = function(d, source, spell, target, value, school)
    -- %s's %s crits %s for %d %s damage.
    return source, spell, target, value, school, "damage"
end

-- ---------- Periodic damage ----------
combatlog_parser[PERIODICAURADAMAGESELFOTHER] = function(d, target, value, school, spell)
    -- %s suffers %d %s damage from your %s.
    return d.source(), spell, target, value, school, "periodic"
end
combatlog_parser[PERIODICAURADAMAGEOTHEROTHER] = function(d, target, value, school, source, spell)
    -- %s suffers %d %s damage from %s's %s.
    return source, spell, target, value, school, "periodic"
end
combatlog_parser[PERIODICAURADAMAGESELFSELF] = function(d, value, school, spell)
    -- You suffer %d %s damage from your %s.
    return d.source(), spell, d.target(), value, school, "periodic"
end
combatlog_parser[PERIODICAURADAMAGEOTHERSELF] = function(d, value, school, source, spell)
    -- You suffer %d %s damage from %s's %s.
    return source, spell, d.target(), value, school, "periodic_taken"
end

-- ---------- Damage shields / reflection (Thorns, Retribution, etc.) ----------
-- Source here is the buffed unit. Re-attributed to the applicator in ParseMessage.
-- Typical globals:
--   DAMAGESHIELDSELFOTHER  = "You reflect %d %s damage to %s."
--   DAMAGESHIELDOTHERSELF  = "%s reflects %d %s damage to you."
--   DAMAGESHIELDOTHEROTHER = "%s reflects %d %s damage to %s."
combatlog_parser[DAMAGESHIELDSELFOTHER] = function(d, a1, a2, a3)
    -- Captures: value, school, target  OR  value, target (no school)
    if a3 then
        return d.source(), "Reflect", a3, a1, a2, "reflect"
    end
    return d.source(), "Reflect", a2, a1, nil, "reflect"
end
combatlog_parser[DAMAGESHIELDOTHERSELF] = function(d, a1, a2, a3)
    -- Captures: source, value, school  OR  source, value
    if a3 then
        return a1, "Reflect", d.target(), a2, a3, "reflect_taken"
    end
    return a1, "Reflect", d.target(), a2, nil, "reflect_taken"
end
combatlog_parser[DAMAGESHIELDOTHEROTHER] = function(d, a1, a2, a3, a4)
    -- Captures: source, value, school, target  OR  source, value, target
    if a4 then
        return a1, "Reflect", a4, a2, a3, "reflect"
    end
    return a1, "Reflect", a3, a2, nil, "reflect"
end

-- ---------- Healing (direct) ----------
combatlog_parser[HEALEDSELFSELF] = function(d, spell, value)
    -- Your %s heals you for %d.
    return d.source(), spell, d.target(), value, nil, "heal"
end
combatlog_parser[HEALEDCRITSELFSELF] = function(d, spell, value)
    -- Your %s critically heals you for %d.
    return d.source(), spell, d.target(), value, nil, "heal"
end
combatlog_parser[HEALEDSELFOTHER] = function(d, spell, target, value)
    -- Your %s heals %s for %d.
    return d.source(), spell, target, value, nil, "heal"
end
combatlog_parser[HEALEDCRITSELFOTHER] = function(d, spell, target, value)
    -- Your %s critically heals %s for %d.
    return d.source(), spell, target, value, nil, "heal"
end
combatlog_parser[HEALEDOTHERSELF] = function(d, source, spell, value)
    -- %s's %s heals you for %d.
    return source, spell, d.target(), value, nil, "heal"
end
combatlog_parser[HEALEDCRITOTHERSELF] = function(d, source, spell, value)
    -- %s's %s critically heals you for %d.
    return source, spell, d.target(), value, nil, "heal"
end
combatlog_parser[HEALEDOTHEROTHER] = function(d, source, spell, target, value)
    -- %s's %s heals %s for %d.
    return source, spell, target, value, nil, "heal"
end
combatlog_parser[HEALEDCRITOTHEROTHER] = function(d, source, spell, target, value)
    -- %s's %s critically heals %s for %d.
    return source, spell, target, value, nil, "heal"
end

-- ---------- Periodic healing ----------
combatlog_parser[PERIODICAURAHEALSELFOTHER] = function(d, target, value, spell)
    -- %s gains %d health from your %s.
    return d.source(), spell, target, value, nil, "heal"
end
combatlog_parser[PERIODICAURAHEALOTHEROTHER] = function(d, target, value, source, spell)
    -- %s gains %d health from %s's %s.
    return source, spell, target, value, nil, "heal"
end
combatlog_parser[PERIODICAURAHEALSELFSELF] = function(d, value, spell)
    -- You gain %d health from your %s.
    return d.source(), spell, d.target(), value, nil, "heal"
end
combatlog_parser[PERIODICAURAHEALOTHERSELF] = function(d, value, source, spell)
    -- You gain %d health from %s's %s.
    return source, spell, d.target(), value, nil, "heal"
end

-- ============================================================
-- Event → pattern list mapping
-- ============================================================

local combatlog_strings = {
    -- Melee
    ["Hit Damage (self vs. other)"] = {
        COMBATHITSELFOTHER, COMBATHITSCHOOLSELFOTHER,
        COMBATHITCRITSELFOTHER, COMBATHITCRITSCHOOLSELFOTHER,
    },
    ["Hit Damage (other vs. self)"] = {
        COMBATHITOTHERSELF, COMBATHITCRITOTHERSELF,
        COMBATHITSCHOOLOTHERSELF, COMBATHITCRITSCHOOLOTHERSELF,
    },
    ["Hit Damage (other vs. other)"] = {
        COMBATHITOTHEROTHER, COMBATHITCRITOTHEROTHER,
        COMBATHITSCHOOLOTHEROTHER, COMBATHITCRITSCHOOLOTHEROTHER,
    },
    -- Spells
    ["Spell Damage (self)"] = {
        SPELLLOGSELFOTHER, SPELLLOGCRITSELFOTHER,
        SPELLLOGSCHOOLSELFOTHER, SPELLLOGCRITSCHOOLSELFOTHER,
        SPELLLOGSELFSELF, SPELLLOGCRITSELFSELF,
        SPELLLOGSCHOOLSELFSELF, SPELLLOGCRITSCHOOLSELFSELF,
    },
    ["Spell Damage (other vs. self)"] = {
        SPELLLOGOTHERSELF, SPELLLOGCRITOTHERSELF,
        SPELLLOGSCHOOLOTHERSELF, SPELLLOGCRITSCHOOLOTHERSELF,
    },
    ["Spell Damage (other vs. other)"] = {
        SPELLLOGOTHEROTHER, SPELLLOGCRITOTHEROTHER,
        SPELLLOGSCHOOLOTHEROTHER, SPELLLOGCRITSCHOOLOTHEROTHER,
    },
    -- Periodic / DoTs
    ["Periodic Damage"] = {
        PERIODICAURADAMAGESELFOTHER, PERIODICAURADAMAGEOTHEROTHER,
        PERIODICAURADAMAGESELFSELF, PERIODICAURADAMAGEOTHERSELF,
    },
    -- Shields / Reflect
    ["Shield Damage"] = {
        DAMAGESHIELDSELFOTHER, DAMAGESHIELDOTHERSELF, DAMAGESHIELDOTHEROTHER,
    },
    -- Healing
    ["Heal (self)"] = {
        HEALEDSELFSELF, HEALEDCRITSELFSELF,
        HEALEDSELFOTHER, HEALEDCRITSELFOTHER,
    },
    ["Heal (other)"] = {
        HEALEDOTHERSELF, HEALEDCRITOTHERSELF,
        HEALEDOTHEROTHER, HEALEDCRITOTHEROTHER,
    },
    ["Periodic Heal"] = {
        PERIODICAURAHEALSELFOTHER, PERIODICAURAHEALOTHEROTHER,
        PERIODICAURAHEALSELFSELF, PERIODICAURAHEALOTHERSELF,
    },
}

local combatlog_events = {
    -- Melee damage
    ["CHAT_MSG_COMBAT_SELF_HITS"]              = combatlog_strings["Hit Damage (self vs. other)"],
    ["CHAT_MSG_COMBAT_CREATURE_VS_SELF_HITS"]  = combatlog_strings["Hit Damage (other vs. self)"],
    ["CHAT_MSG_COMBAT_PARTY_HITS"]             = combatlog_strings["Hit Damage (other vs. other)"],
    ["CHAT_MSG_COMBAT_FRIENDLYPLAYER_HITS"]    = combatlog_strings["Hit Damage (other vs. other)"],
    ["CHAT_MSG_COMBAT_HOSTILEPLAYER_HITS"]     = combatlog_strings["Hit Damage (other vs. other)"],
    ["CHAT_MSG_COMBAT_CREATURE_VS_CREATURE_HITS"] = combatlog_strings["Hit Damage (other vs. other)"],
    ["CHAT_MSG_COMBAT_CREATURE_VS_PARTY_HITS"] = combatlog_strings["Hit Damage (other vs. other)"],
    ["CHAT_MSG_COMBAT_PET_HITS"]               = combatlog_strings["Hit Damage (other vs. other)"],

    -- Spell damage
    ["CHAT_MSG_SPELL_SELF_DAMAGE"]             = combatlog_strings["Spell Damage (self)"],
    ["CHAT_MSG_SPELL_CREATURE_VS_SELF_DAMAGE"] = combatlog_strings["Spell Damage (other vs. self)"],
    ["CHAT_MSG_SPELL_PARTY_DAMAGE"]            = combatlog_strings["Spell Damage (other vs. other)"],
    ["CHAT_MSG_SPELL_FRIENDLYPLAYER_DAMAGE"]   = combatlog_strings["Spell Damage (other vs. other)"],
    ["CHAT_MSG_SPELL_HOSTILEPLAYER_DAMAGE"]    = combatlog_strings["Spell Damage (other vs. other)"],
    ["CHAT_MSG_SPELL_CREATURE_VS_CREATURE_DAMAGE"] = combatlog_strings["Spell Damage (other vs. other)"],
    ["CHAT_MSG_SPELL_CREATURE_VS_PARTY_DAMAGE"]= combatlog_strings["Spell Damage (other vs. other)"],
    ["CHAT_MSG_SPELL_PET_DAMAGE"]              = combatlog_strings["Spell Damage (other vs. other)"],

    -- Damage shields
    ["CHAT_MSG_SPELL_DAMAGESHIELDS_ON_SELF"]   = combatlog_strings["Shield Damage"],
    ["CHAT_MSG_SPELL_DAMAGESHIELDS_ON_OTHERS"] = combatlog_strings["Shield Damage"],

    -- Periodic damage
    ["CHAT_MSG_SPELL_PERIODIC_SELF_DAMAGE"]    = combatlog_strings["Periodic Damage"],
    ["CHAT_MSG_SPELL_PERIODIC_PARTY_DAMAGE"]   = combatlog_strings["Periodic Damage"],
    ["CHAT_MSG_SPELL_PERIODIC_FRIENDLYPLAYER_DAMAGE"] = combatlog_strings["Periodic Damage"],
    ["CHAT_MSG_SPELL_PERIODIC_HOSTILEPLAYER_DAMAGE"]  = combatlog_strings["Periodic Damage"],
    ["CHAT_MSG_SPELL_PERIODIC_CREATURE_DAMAGE"]= combatlog_strings["Periodic Damage"],

    -- Healing
    ["CHAT_MSG_SPELL_SELF_BUFF"]               = combatlog_strings["Heal (self)"],
    ["CHAT_MSG_SPELL_PARTY_BUFF"]              = combatlog_strings["Heal (other)"],
    ["CHAT_MSG_SPELL_FRIENDLYPLAYER_BUFF"]     = combatlog_strings["Heal (other)"],
    ["CHAT_MSG_SPELL_HOSTILEPLAYER_BUFF"]      = combatlog_strings["Heal (other)"],

    -- Periodic healing
    ["CHAT_MSG_SPELL_PERIODIC_SELF_BUFFS"]     = combatlog_strings["Periodic Heal"],
    ["CHAT_MSG_SPELL_PERIODIC_PARTY_BUFFS"]    = combatlog_strings["Periodic Heal"],
    ["CHAT_MSG_SPELL_PERIODIC_FRIENDLYPLAYER_BUFFS"] = combatlog_strings["Periodic Heal"],
    ["CHAT_MSG_SPELL_PERIODIC_HOSTILEPLAYER_BUFFS"]  = combatlog_strings["Periodic Heal"],
}

-- Flat fallback pattern list when event name is unknown (SuperWoW RAW arg1 quirks)
local FALLBACK_COMBAT_PATTERNS = {}
do
    local seen = {}
    local groups = {
        "Hit Damage (self vs. other)",
        "Hit Damage (other vs. self)",
        "Hit Damage (other vs. other)",
        "Spell Damage (self)",
        "Spell Damage (other vs. self)",
        "Spell Damage (other vs. other)",
        "Periodic Damage",
        "Heal (self)",
        "Heal (other)",
        "Periodic Heal",
        "Shield Damage",
    }
    local gi, gname, pi, pat
    for gi = 1, table.getn(groups) do
        gname = groups[gi]
        local list = combatlog_strings[gname]
        if list then
            for pi = 1, table.getn(list) do
                pat = list[pi]
                if pat and not seen[pat] then
                    seen[pat] = true
                    table.insert(FALLBACK_COMBAT_PATTERNS, pat)
                end
            end
        end
    end
end

-- ============================================================
-- Aura gain / fade parsing (reflection tracking)
-- ============================================================

-- Among group priests, pick a likely PW:S caster.
-- 1 priest → that priest.
-- Multiple → top healer by current healing if they lead the next priest by ≥15% share.
-- Otherwise nil (caller falls back to the buffed unit).
local function ResolvePriestShieldApplicator()
    local priests = {}
    local name, data
    for name, data in pairs(OM.players or {}) do
        if data and data.class == "PRIEST" then
            table.insert(priests, name)
        end
    end
    local n = table.getn(priests)
    if n == 0 then return nil end
    if n == 1 then return priests[1] end

    local seg = OM.data and OM.data.current
    local heals = {}
    local total = 0
    local i
    for i = 1, n do
        local pName = priests[i]
        local h = 0
        if seg and seg.players and seg.players[pName] then
            h = seg.players[pName].healing or 0
        end
        heals[pName] = h
        total = total + h
    end
    if total <= 0 then return nil end

    table.sort(priests, function(a, b)
        local ha = heals[a] or 0
        local hb = heals[b] or 0
        if ha == hb then
            return tostring(a or "") < tostring(b or "")
        end
        return ha > hb
    end)
    local top = priests[1]
    local second = priests[2]
    if not top then return nil end
    if not second then return top end
    local topH = heals[top] or 0
    local secondH = heals[second] or 0
    local topShare = topH / total
    local secondShare = secondH / total
    if (topShare - secondShare) >= 0.15 then
        return top
    end
    return nil
end

local function HandleAuraGain(target, spell)
    target = NormalizeName(target)
    if not target or not spell then return end

    -- Absorb shields only (reflection caster assignment removed)
    if IsAbsorbShield(spell) then
        local applicator = GetRecentAbsorbCaster(spell)
        -- Prefer a recent cast aimed at this specific target when available
        if ST.recentShieldByTarget and ST.recentShieldByTarget[target] then
            local entry = ST.recentShieldByTarget[target]
            if entry and entry.caster and (GetTime() - (entry.time or 0)) <= RECENT_CASTER_TIMEOUT then
                applicator = entry.caster
            end
        end
        if not applicator then
            if spell == "Power Word: Shield" or string.find(spell, "Power Word: Shield", 1, true) then
                applicator = ResolvePriestShieldApplicator()
            elseif OM.players[target] then
                local class = OM.players[target].class
                if (spell == "Ice Barrier" or spell == "Mana Shield" or spell == "Frost Ward" or spell == "Fire Ward") and class == "MAGE" then
                    applicator = target
                elseif spell == "Sacrifice" and class == "WARLOCK" then
                    applicator = target
                end
            end
        end
        -- Multiple close priests / unknown → credit the buffed unit
        applicator = applicator or target
        SetAbsorbAura(target, spell, applicator)
        if applicator then
            NoteRecentAbsorbCaster(spell, applicator)
        end
    end
end

local function HandleAuraFade(target, spell)
    target = NormalizeName(target)
    if not target or not spell then return end
    if IsAbsorbShield(spell) then
        ClearAbsorbAura(target, spell)
    end
end

local function ParseAuraMessage(event, message)
    if not message or message == "" then return end

    -- Self gain
    if AURAADDEDSELFHELPFUL then
        local regex = sanitize(AURAADDEDSELFHELPFUL)
        if regex then
            local _, _, s = string.find(message, regex)
            if s and IsAbsorbShield(s) then
                HandleAuraGain(playerName, s)
                return
            end
        end
    end

    -- Other gain
    if AURAADDEDOTHERHELPFUL then
        local regex = sanitize(AURAADDEDOTHERHELPFUL)
        if regex then
            local _, _, target, s = string.find(message, regex)
            if target and s and IsAbsorbShield(s) then
                HandleAuraGain(target, s)
                return
            end
        end
    end

    -- Fallback plain-text gain
    local _, _, s = string.find(message, "^You gain ([%.%w%s%'%-]+)%.?$")
    if s and IsAbsorbShield(s) then
        HandleAuraGain(playerName, s)
        return
    end

    local _, _, target, s2 = string.find(message, "^(.+) gains ([%.%w%s%'%-]+)%.?$")
    if target and s2 and IsAbsorbShield(s2) then
        HandleAuraGain(target, s2)
        return
    end

    -- Fade via globals
    if AURAREMOVEDSELF then
        local regex = sanitize(AURAREMOVEDSELF)
        if regex then
            local _, _, s = string.find(message, regex)
            if s and IsAbsorbShield(s) then
                HandleAuraFade(playerName, s)
                return
            end
        end
    end

    if AURAREMOVEDOTHER then
        local regex = sanitize(AURAREMOVEDOTHER)
        if regex then
            local _, _, s, target = string.find(message, regex)
            if s and target and IsAbsorbShield(s) then
                HandleAuraFade(target, s)
                return
            end
        end
    end

    -- Fallback fade
    local _, _, s3 = string.find(message, "^([%.%w%s%'%-]+) fades from you%.?$")
    if s3 and IsAbsorbShield(s3) then
        HandleAuraFade(playerName, s3)
        return
    end

    local _, _, s4, target2 = string.find(message, "^([%.%w%s%'%-]+) fades from (.+)%.?$")
    if s4 and target2 and IsAbsorbShield(s4) then
        HandleAuraFade(target2, s4)
        return
    end
end

-- ============================================================
-- Interrupt & Dispel tracking
-- ============================================================

-- True interrupts only (not stuns/CCs — those go in the CC mode later)
local INTERRUPT_SPELLS = {
    ["Kick"] = true,
    ["Pummel"] = true,
    ["Shield Bash"] = true,
    ["Counterspell"] = true,
    ["Earth Shock"] = true,
    ["Spell Lock"] = true,
    ["Silence"] = true,
}

-- Dispel / cleanse abilities
local DISPEL_SPELLS = {
    ["Dispel Magic"] = true,
    ["Cleanse"] = true,
    ["Purify"] = true,
    ["Remove Curse"] = true,
    ["Remove Lesser Curse"] = true,
    ["Cure Disease"] = true,
    ["Abolish Disease"] = true,
    ["Cure Poison"] = true,
    ["Abolish Poison"] = true,
    ["Devour Magic"] = true,
    ["Purge"] = true,
    ["Poison Cleansing Totem"] = true,
    ["Disease Cleansing Totem"] = true,
    ["Powerful Anti-Venom"] = true,
    ["Restoration"] = true,          -- enchanted item / some effects
    ["Purification"] = true,
    ["Purification Potion"] = true,
    ["Restorative Potion"] = true,
}

-- Periodic / multi-tick cleanses. Credit only combat-log lines that name the
-- ability as the remover. Do not pair their cast with nearby fade messages.
local PERIODIC_DISPEL_SPELLS = {
    ["Abolish Disease"] = true,
    ["Abolish Poison"] = true,
    ["Poison Cleansing Totem"] = true,
    ["Disease Cleansing Totem"] = true,
}

local function IsPeriodicDispelSpell(spell)
    return SpellInSet(PERIODIC_DISPEL_SPELLS, spell)
end

local function IsInterruptSpell(spell)
    return SpellInSet(INTERRUPT_SPELLS, spell)
end
-- Exposed for AddDamage (defined earlier in the file)
Parser.IsInterruptAbility = IsInterruptSpell

local function IsDispelSpell(spell)
    return SpellInSet(DISPEL_SPELLS, spell)
end

-- Dispel matching: combat log order is unreliable. Buffer casts and fades
-- and pair them so natural expirations are not counted as dispels.
-- Pair only fades of auras previously applied as harmful. Named-target casts
-- must match that target. Direct "X removes Y from Z" lines win.
-- PERIODIC_DISPEL_SPELLS never use cast↔fade pairing.
local PENDING_DISPEL_WINDOW = 1.25  -- others' cast↔fade lines can be farther apart than self "You remove"
local HARMFUL_AURA_TTL = 180  -- remember afflictions this long for fade matching
local recentDispelFades = {}  -- { { spell, target, time }, ... }
local pendingDispelCasts = {} -- { { caster, target, time, spell }, ... }
local lastDispelCastKey = nil -- "caster|spell" for de-dupe
local lastDispelCastTime = 0
local directDispelSuppressUntil = 0 -- ignore fade pairing briefly after a direct remove
-- ST.recentHarmfulAuras[targetName][spellName] = lastApplyTime
ST.recentHarmfulAuras = {}

-- Friendly/beneficial auras that should never be credited via cast↔fade pairing
local FRIENDLY_AURAS = {
    ["Power Word: Fortitude"] = true,
    ["Prayer of Fortitude"] = true,
    ["Mark of the Wild"] = true,
    ["Gift of the Wild"] = true,
    ["Arcane Intellect"] = true,
    ["Arcane Brilliance"] = true,
    ["Divine Spirit"] = true,
    ["Prayer of Spirit"] = true,
    ["Shadow Protection"] = true,
    ["Prayer of Shadow Protection"] = true,
    ["Thorns"] = true,
    ["Blessing of Kings"] = true,
    ["Blessing of Might"] = true,
    ["Blessing of Wisdom"] = true,
    ["Blessing of Salvation"] = true,
    ["Blessing of Light"] = true,
    ["Blessing of Sanctuary"] = true,
    ["Blessing of Protection"] = true,
    ["Blessing of Freedom"] = true,
    ["Blessing of Sacrifice"] = true,
    ["Greater Blessing of Kings"] = true,
    ["Greater Blessing of Might"] = true,
    ["Greater Blessing of Wisdom"] = true,
    ["Greater Blessing of Salvation"] = true,
    ["Greater Blessing of Light"] = true,
    ["Greater Blessing of Sanctuary"] = true,
    ["Battle Shout"] = true,
    ["Trueshot Aura"] = true,
    ["Power Word: Shield"] = true,
    ["Ice Barrier"] = true,
    ["Mana Shield"] = true,
    ["Divine Shield"] = true,
    ["Blessing of Protection"] = true,
    ["Hand of Protection"] = true,
    ["Abolish Disease"] = true,
    ["Abolish Poison"] = true,
    ["Renew"] = true,
    ["Rejuvenation"] = true,
    ["Regrowth"] = true,
    ["Hot Streak"] = true,
    ["Focus"] = true,
    ["Inner Fire"] = true,
    ["Dampen Magic"] = true,
    ["Amplify Magic"] = true,
    ["Detect Invisibility"] = true,
    ["Detect Lesser Invisibility"] = true,
    ["Unending Breath"] = true,
    ["Water Breathing"] = true,
    ["Water Walking"] = true,
    ["Levitate"] = true,
    ["Blood Pact"] = true,
    ["Soulstone Resurrection"] = true,
    ["Fear Ward"] = true,
}

local function IsFriendlyAura(spell)
    if not spell then return false end
    if FRIENDLY_AURAS[spell] then return true end
    local lower = string.lower(spell)
    -- Broad beneficial patterns
    if string.find(lower, "blessing of", 1, true) then return true end
    if string.find(lower, "greater blessing", 1, true) then return true end
    if string.find(lower, "prayer of", 1, true) then return true end
    if string.find(lower, "gift of", 1, true) then return true end
    if string.find(lower, "mark of the wild", 1, true) then return true end
    if string.find(lower, "arcane intellect", 1, true) then return true end
    if string.find(lower, "arcane brilliance", 1, true) then return true end
    if string.find(lower, "power word:", 1, true) then return true end
    if string.find(lower, "fortitude", 1, true) then return true end
    return false
end

local function NoteHarmfulAura(target, spell)
    target = NormalizeName(target)
    if not target or not spell or spell == "" then return end
    if IsFriendlyAura(spell) then return end
    if not ST.recentHarmfulAuras[target] then
        ST.recentHarmfulAuras[target] = {}
    end
    ST.recentHarmfulAuras[target][spell] = GetTime()
end

local function ClearHarmfulAura(target, spell)
    target = NormalizeName(target)
    if not target or not ST.recentHarmfulAuras[target] then return end
    if spell then
        ST.recentHarmfulAuras[target][spell] = nil
    else
        ST.recentHarmfulAuras[target] = nil
    end
end

-- True if this unit was afflicted by this spell recently (and it was not friendly).
local function IsTrackedHarmfulAura(target, spell)
    target = NormalizeName(target)
    if not target or not spell or spell == "" then return false end
    if IsFriendlyAura(spell) then return false end
    local byTarget = ST.recentHarmfulAuras[target]
    if not byTarget then return false end
    local t = byTarget[spell]
    if not t then
        -- Partial match for rank suffixes ("Corruption" vs "Corruption Rank 5" rarely differs)
        local k, applyT
        for k, applyT in pairs(byTarget) do
            if k == spell or string.find(spell, k, 1, true) or string.find(k, spell, 1, true) then
                t = applyT
                break
            end
        end
    end
    if not t then return false end
    if (GetTime() - t) > HARMFUL_AURA_TTL then
        byTarget[spell] = nil
        return false
    end
    return true
end

local function PruneHarmfulAuras(now)
    now = now or GetTime()
    local target, spells
    for target, spells in pairs(ST.recentHarmfulAuras) do
        local spell, t
        local empty = true
        for spell, t in pairs(spells) do
            if (now - (t or 0)) > HARMFUL_AURA_TTL then
                spells[spell] = nil
            else
                empty = false
            end
        end
        if empty then
            ST.recentHarmfulAuras[target] = nil
        end
    end
end

local function PruneDispelBuffers(now)
    now = now or GetTime()
    local i
    for i = table.getn(recentDispelFades), 1, -1 do
        if (now - (recentDispelFades[i].time or 0)) > PENDING_DISPEL_WINDOW then
            table.remove(recentDispelFades, i)
        end
    end
    for i = table.getn(pendingDispelCasts), 1, -1 do
        if (now - (pendingDispelCasts[i].time or 0)) > PENDING_DISPEL_WINDOW then
            table.remove(pendingDispelCasts, i)
        end
    end
    PruneHarmfulAuras(now)
end

local function ClearDispelBuffers()
    recentDispelFades = {}
    pendingDispelCasts = {}
    lastDispelCastKey = nil
    lastDispelCastTime = 0
end

-- After a definitive "X removes Y from Z", ignore nearby fades so they don't double-count
local function SuppressFadePairing()
    ClearDispelBuffers()
    directDispelSuppressUntil = GetTime() + PENDING_DISPEL_WINDOW
end

-- Score a fade/cast pair; lower is better. nil = reject.
-- If the cast named a target, the fade MUST be on that target.
local function DispelPairScore(castTime, castTarget, fadeTime, fadeTarget)
    local dist = castTime - fadeTime
    if dist < 0 then dist = -dist end
    if dist > PENDING_DISPEL_WINDOW then return nil end
    local ct = castTarget and NormalizeName(castTarget) or nil
    local ft = fadeTarget and NormalizeName(fadeTarget) or nil
    if ct and ft then
        if ct ~= ft then
            return nil  -- hard reject: different unit
        end
        return dist  -- same target is required; no bonus needed
    end
    -- Cast had no target (e.g. "You cast Dispel Magic.") — allow any unit,
    -- but penalize so same-target pairs still win when both exist.
    if not ct then
        return dist + 0.15
    end
    -- Fade had no target (should be rare) — weak candidate
    return dist + 0.20
end

local function NoteDispelCast(caster, target, spellName)
    -- Periodic cleanses (Abolish Disease/Poison, cleansing totems) must never
    -- use cast↔fade pairing. Only explicit "SPELL removes EFFECT" lines count.
    if IsPeriodicDispelSpell(spellName) then
        return
    end

    caster = ResolveSource(caster)
    if not caster then return end
    if not IsTracked(caster) and not OM.players[caster] then return end
    target = target and NormalizeName(target) or nil
    local now = GetTime()

    -- Combat log sometimes double-prints the same cast with nothing in between
    local key = tostring(caster) .. "|" .. tostring(spellName or "")
    if lastDispelCastKey == key and (now - lastDispelCastTime) < PENDING_DISPEL_WINDOW then
        return
    end
    lastDispelCastKey = key
    lastDispelCastTime = now

    PruneDispelBuffers(now)

    -- Match the closest buffered fade (may have arrived before the cast line).
    -- Prefer known-harmful fades; also accept same-target pairs so group
    -- dispels work when the original affliction line was never seen.
    local bestIdx, bestScore = nil, nil
    local i, fade
    for i = 1, table.getn(recentDispelFades) do local fade = recentDispelFades[i]
        if fade.spell and not IsFriendlyAura(fade.spell) then
            local ft = fade.target or target
            local known = fade.knownHarmful or IsTrackedHarmfulAura(ft, fade.spell)
            local score = DispelPairScore(now, target, fade.time, fade.target)
            if score then
                local ct = target and NormalizeName(target) or nil
                local ftn = ft and NormalizeName(ft) or nil
                local targetMatched = ct and ftn and ct == ftn
                if known or targetMatched then
                    if not bestScore or score < bestScore then
                        bestScore = score
                        bestIdx = i
                    end
                end
            end
        end
    end
    if bestIdx then
        local fade = recentDispelFades[bestIdx]
        table.remove(recentDispelFades, bestIdx)
        ClearHarmfulAura(fade.target or target, fade.spell)
        Parser:AddDispel(caster, fade.spell or "Unknown", fade.target or target)
        return
    end

    table.insert(pendingDispelCasts, {
        caster = caster,
        target = target,
        time = now,
        spell = spellName,
    })
end

local function TryCreditPendingDispel(fadedSpell, target)
    -- Direct removes already credited — ignore nearby fades
    if GetTime() < (directDispelSuppressUntil or 0) then
        return false
    end

    fadedSpell = fadedSpell or "Unknown"
    -- Never credit friendly/beneficial auras via fade pairing
    if IsFriendlyAura(fadedSpell) then
        return false
    end

    target = target and NormalizeName(target) or nil
    local now = GetTime()
    PruneDispelBuffers(now)

    local knownHarmful = IsTrackedHarmfulAura(target, fadedSpell)

    -- Match a pending cast first. Group members often only generate
    -- "Name casts Dispel on X" + "Spell fades from X" (no "Name removes …").
    -- Self usually gets the direct remove line; others rely on this path.
    local bestIdx, bestScore = nil, nil
    local i, cast
    for i = 1, table.getn(pendingDispelCasts) do local cast = pendingDispelCasts[i]
        local score = DispelPairScore(cast.time, cast.target, now, target)
        if score then
            -- If the cast named a target and it matches this fade, trust it
            -- even when the original "afflicted by" line was never seen.
            local ct = cast.target and NormalizeName(cast.target) or nil
            local ft = target and NormalizeName(target) or nil
            local targetMatched = ct and ft and ct == ft
            if targetMatched or knownHarmful then
                if not bestScore or score < bestScore then
                    bestScore = score
                    bestIdx = i
                end
            end
        end
    end
    if bestIdx then
        local cast = pendingDispelCasts[bestIdx]
        table.remove(pendingDispelCasts, bestIdx)
        ClearHarmfulAura(target, fadedSpell)
        Parser:AddDispel(cast.caster, fadedSpell, target or cast.target)
        return true
    end

    -- Buffer fades for a slightly later cast. Prefer known harmful, but also
    -- keep non-friendly fades briefly so other players' casts can still pair.
    table.insert(recentDispelFades, {
        spell = fadedSpell,
        target = target,
        time = now,
        knownHarmful = knownHarmful and true or false,
    })
    return false
end

--[[
  Interrupt combat log forms (English, common variants):
    "You interrupt Mob's Fireball."
    "You interrupt Mob's Fireball with Kick."
    "Bob interrupts Mob's Frostbolt."
    "Bob's Kick interrupts Mob's Heal."
    "Your Counterspell interrupts Mob's Pyroblast."

  Dispel combat log forms:
    "You remove Curse of Weakness from Bob."
    "You purify Bob."
    "Bob's Cleanse removes Disease from You."
    "Your Dispel Magic removes Power Word: Shield from Mob."
    "Bob removes Shadow Word: Pain from You."
    "You cast Dispel Magic on Mob."
]]

local function ParseInterruptMessage(message)
    if not message then return end

    -- "You interrupt TARGET's SPELL."
    local _, _, target, interrupted = string.find(message, "^You interrupt (.+)'s (.+)%.?$")
    if target and interrupted then
        -- Strip optional " with Kick" suffix if present inside interrupted
        local clean = interrupted
        local _, _, spellOnly, withSpell = string.find(interrupted, "^(.+) with (.+)$")
        if spellOnly then
            clean = spellOnly
        end
        Parser:AddInterrupt(playerName, clean)
        return true
    end

    -- "Your SPELL interrupts TARGET's INTERRUPTED."
    local _, _, sourceSpell, target2, interrupted2 = string.find(message, "^Your (.+) interrupts (.+)'s (.+)%.?$")
    if sourceSpell and target2 and interrupted2 then
        Parser:AddInterrupt(playerName, interrupted2)
        return true
    end

    -- "SOURCE interrupts TARGET's SPELL."
    local _, _, source, target3, interrupted3 = string.find(message, "^(.+) interrupts (.+)'s (.+)%.?$")
    if source and target3 and interrupted3 then
        -- Avoid matching "Your X interrupts..." again
        if source ~= "Your" and not string.find(source, "^Your ") then
            Parser:AddInterrupt(source, interrupted3)
            return true
        end
    end

    -- "SOURCE's SPELL interrupts TARGET's INTERRUPTED."
    local _, _, source2, sourceSpell2, target4, interrupted4 =
        string.find(message, "^(.+)'s (.+) interrupts (.+)'s (.+)%.?$")
    if source2 and sourceSpell2 and target4 and interrupted4 then
        if IsInterruptSpell(sourceSpell2) or true then
            Parser:AddInterrupt(source2, interrupted4)
            return true
        end
    end

    return false
end

local function ParseDispelMessage(message)
    if not message then return false end

    -- Cast forms (with optional target): fade may appear before or after these.
    -- "You cast SPELL on TARGET." / "You cast SPELL."
    local _, _, castSpell, castTarget = string.find(message, "^You cast (.+) on (.+)%.?$")
    if castSpell and IsDispelSpell(castSpell) then
        NoteDispelCast(playerName, castTarget, castSpell)
        return true
    end
    local _, _, castSpellOnly = string.find(message, "^You cast (.+)%.?$")
    if castSpellOnly and IsDispelSpell(castSpellOnly) then
        NoteDispelCast(playerName, nil, castSpellOnly)
        return true
    end
    -- "You perform SPELL on TARGET." (some clients use perform for cleanses)
    local _, _, perfSpell, perfTarget = string.find(message, "^You perform (.+) on (.+)%.?$")
    if perfSpell and IsDispelSpell(perfSpell) then
        NoteDispelCast(playerName, perfTarget, perfSpell)
        return true
    end
    -- "SOURCE performs SPELL on TARGET."
    local _, _, perfSrc, perfSpell2, perfTarget2 = string.find(message, "^(.+) performs (.+) on (.+)%.?$")
    if perfSrc and perfSpell2 and IsDispelSpell(perfSpell2) then
        if perfSrc ~= "You" and not string.find(perfSrc, "^Your ") then
            NoteDispelCast(perfSrc, perfTarget2, perfSpell2)
            return true
        end
    end

    -- "SOURCE casts SPELL on TARGET." / "SOURCE casts SPELL."
    local _, _, castSrc, castSpell2, castTarget2 = string.find(message, "^(.+) casts (.+) on (.+)%.?$")
    if castSrc and castSpell2 and IsDispelSpell(castSpell2) then
        if castSrc ~= "You" and not string.find(castSrc, "^Your ") then
            NoteDispelCast(castSrc, castTarget2, castSpell2)
            return true
        end
    end
    local _, _, castSrc2, castSpell3 = string.find(message, "^(.+) casts (.+)%.?$")
    if castSrc2 and castSpell3 and IsDispelSpell(castSpell3) then
        if castSrc2 ~= "You" and not string.find(castSrc2, "^Your ") then
            NoteDispelCast(castSrc2, nil, castSpell3)
            return true
        end
    end
    local _, _, yourSpell = string.find(message, "^Your (.+) is cast%.?$")
    if yourSpell and IsDispelSpell(yourSpell) then
        NoteDispelCast(playerName, nil, yourSpell)
        return true
    end

    -- Direct remove forms still work as a fallback (credit immediately)
    -- "You remove SPELL from TARGET."
    local _, _, removed, target = string.find(message, "^You remove (.+) from (.+)%.?$")
    if removed and target then
        Parser:AddDispel(playerName, removed, target)
        if ClearHarmfulAura then ClearHarmfulAura(target, removed) end
        SuppressFadePairing()
        return true
    end

    -- "You purify TARGET." / "You cleanse TARGET."
    local _, _, action, target2 = string.find(message, "^You (%w+) (.+)%.?$")
    if action and target2 then
        local al = string.lower(action)
        if al == "purify" or al == "cleanse" or al == "cure" or al == "purge" then
            NoteDispelCast(playerName, target2, action)
            return true
        end
    end

    -- "SOURCE's SPELL removes REMOVED from TARGET."
    local _, _, source, sourceSpell, removed2, target3 =
        string.find(message, "^(.+)'s (.+) removes (.+) from (.+)%.?$")
    if source and sourceSpell and removed2 and target3 then
        if IsDispelSpell(sourceSpell) then
            Parser:AddDispel(source, removed2, target3)
            if ClearHarmfulAura then ClearHarmfulAura(target3, removed2) end
            SuppressFadePairing()
            return true
        end
    end

    -- "SOURCE removes REMOVED from TARGET."
    local _, _, source2, removed3, target4 = string.find(message, "^(.+) removes (.+) from (.+)%.?$")
    if source2 and removed3 and target4 then
        if source2 ~= "You" and not string.find(source2, "^Your ") then
            Parser:AddDispel(source2, removed3, target4)
            if ClearHarmfulAura then ClearHarmfulAura(target4, removed3) end
            SuppressFadePairing()
            return true
        end
    end

    return false
end

local function ParseInterruptOrDispel(event, message)
    if not message or message == "" then return false end

    local lower = string.lower(message)
    -- Interrupts always from chat (nampower has no interrupt event)
    if string.find(lower, "interrupt", 1, true) then
        if ParseInterruptMessage(message) then return true end
    end

    -- When Nampower owns dispels, skip chat dispel/fade pairing
    local NS = GreedMeter.ParserNS
    if NS and NS.useNampowerDispel then
        return false
    end

    -- Dispel casts + direct remove lines
    if string.find(lower, "cast", 1, true)
    or string.find(lower, "perform", 1, true)
    or string.find(lower, "remove", 1, true)
    or string.find(lower, "purify", 1, true)
    or string.find(lower, "cleanse", 1, true)
    or string.find(lower, "cure", 1, true)
    or string.find(lower, "dispel", 1, true)
    or string.find(lower, "purge", 1, true)
    or string.find(lower, "devour", 1, true)
    or string.find(lower, "abolish", 1, true)
    or string.find(lower, "totem", 1, true) then
        if ParseDispelMessage(message) then return true end
    end
    -- Fade lines: credit pending dispel if armed
    if string.find(lower, "fades from", 1, true) then
        local _, _, faded, tgt = string.find(message, "^(.+) fades from (.+)%.?$")
        if faded and tgt then
            if tgt == "you" or tgt == "You" then tgt = playerName end
            if TryCreditPendingDispel(faded, tgt) then
                return true
            end
        end
        local _, _, faded2 = string.find(message, "^(.+) fades from you%.?$")
        if faded2 then
            if TryCreditPendingDispel(faded2, playerName) then
                return true
            end
        end
    end
    return false
end

-- ============================================================
-- Hard CC tracking
-- Stuns, fears, saps, polymorph, sleeps, etc.
-- NO roots, slows, or snares.
-- Duration values are base estimates (talents/DR not modeled).
-- ============================================================

local HARD_CC_SPELLS = {
    -- Rogue
    ["Sap"]              = 45,  -- rank-dependent; use high rank estimate
    ["Cheap Shot"]       = 4,
    ["Kidney Shot"]      = 4,   -- combo-point dependent; ~4s average
    ["Gouge"]            = 4,
    ["Blind"]            = 10,

    -- Warrior
    ["Concussion Blow"]  = 5,
    ["Charge Stun"]      = 1,
    ["Intercept Stun"]   = 1,
    ["Intimidating Shout"] = 8,

    -- Mage
    ["Polymorph"]        = 50,  -- rank-dependent; sheep
    ["Polymorph: Pig"]   = 50,
    ["Polymorph: Turtle"]= 50,
    ["Impact"]           = 2,

    -- Warlock
    ["Fear"]             = 20,
    ["Howl of Terror"]   = 15,
    ["Seduction"]        = 15,
    ["Death Coil"]       = 3,   -- horror
    ["Pyroclasm"]        = 3,

    -- Priest
    ["Psychic Scream"]   = 8,
    ["Blackout"]         = 3,

    -- Druid
    ["Bash"]             = 3,
    ["Pounce"]           = 3,
    ["Hibernate"]        = 40,

    -- Paladin
    ["Hammer of Justice"]= 6,
    ["Repentance"]       = 6,

    -- Hunter
    ["Scatter Shot"]     = 4,
    ["Intimidation"]     = 3,
    ["Wyvern Sting"]     = 12,  -- sleep
    ["Freezing Trap Effect"] = 20,
    ["Freezing Trap"]    = 20,
    ["Scare Beast"]      = 20,

    -- Other / racial / items
    ["War Stomp"]        = 2,
    ["Tidal Charm"]      = 3,
    ["Reckless Charge"]  = 30,
    ["Shackle Undead"]   = 50,
}

local function GetHardCCDuration(spell)
    return SpellLookup(HARD_CC_SPELLS, spell)
end

local function IsHardCCSpell(spell)
    return GetHardCCDuration(spell) ~= nil
end

--[[
  Common affliction / apply forms:
    "You afflict Mob with Cheap Shot."
    "Bob afflicts Mob with Polymorph."
    "Mob is afflicted by Sap."
    "Your Polymorph was resisted by Mob."  -- ignore resists
]]

local function ParseCCMessage(message)
    if not message then return false end
    local lower = string.lower(message)

    local function CleanCCSpell(spell)
        if not spell then return nil end
        spell = string.gsub(spell, "^%s+", "")
        spell = string.gsub(spell, "%s+$", "")
        -- "Hammer of Justice on Dummy" style bleed into the spell capture
        local _, _, beforeOn = string.find(spell, "^(.+) on .+$")
        if beforeOn then spell = beforeOn end
        if string.len(spell) < 3 then return nil end
        local sl = string.lower(spell)
        if sl == "on" or sl == "with" or sl == "by" or sl == "from" then return nil end
        return spell
    end
    -- Ignore resists / immunes / misses
    if string.find(lower, "resist", 1, true)
    or string.find(lower, "immune", 1, true)
    or string.find(lower, "miss", 1, true)
    or string.find(lower, "dodge", 1, true)
    or string.find(lower, "parry", 1, true)
    or string.find(lower, "block", 1, true)
    or string.find(lower, "evade", 1, true)
    or string.find(lower, "absorb", 1, true)
    or string.find(lower, "fail", 1, true) then
        return false
    end

    -- Self form: "You are afflicted by SPELL."
    local _, _, selfSpell = string.find(message, "^You are afflicted by (.+)%.?$")
    if selfSpell then
        if NoteHarmfulAura then NoteHarmfulAura(playerName, selfSpell) end
        selfSpell = CleanCCSpell(selfSpell)
        local dur = selfSpell and GetHardCCDuration(selfSpell) or nil
        if dur then
            Parser:AddEnemyCC(selfSpell, playerName, dur)
            return true
        end
        return false
    end

    -- Primary form (no caster): "TARGET is afflicted by SPELL."
    local _, _, target, spell = string.find(message, "^(.+) is afflicted by (.+)%.?$")
    if target and spell then
        if target == "you" or target == "You" then
            target = playerName
        end
        -- Always record harmful applications for dispel fade pairing
        if NoteHarmfulAura then
            NoteHarmfulAura(target, spell)
        end
        spell = CleanCCSpell(spell)
        local dur = spell and GetHardCCDuration(spell) or nil
        if dur then
            Parser:AddEnemyCC(spell, target, dur)
            return true
        end
        return false
    end

    -- "You afflict TARGET with SPELL."
    local _, _, target2, spell2 = string.find(message, "^You afflict (.+) with (.+)%.?$")
    if target2 and spell2 then
        if NoteHarmfulAura then NoteHarmfulAura(target2, spell2) end
        spell2 = CleanCCSpell(spell2)
        local dur = spell2 and GetHardCCDuration(spell2) or nil
        if dur then
            Parser:AddEnemyCC(spell2, target2, dur)
            return true
        end
        return false
    end

    -- "SOURCE afflicts TARGET with SPELL."
    local _, _, source, target3, spell3 = string.find(message, "^(.+) afflicts (.+) with (.+)%.?$")
    if source and target3 and spell3 then
        if source ~= "Your" and not string.find(source, "^Your ") then
            if NoteHarmfulAura then NoteHarmfulAura(target3, spell3) end
            spell3 = CleanCCSpell(spell3)
        local dur = spell3 and GetHardCCDuration(spell3) or nil
            if dur then
                Parser:AddEnemyCC(spell3, target3, dur)
                return true
            end
        end
        return false
    end

    -- "Your SPELL afflicts TARGET."
    local _, _, spell4, target4 = string.find(message, "^Your (.+) afflicts (.+)%.?$")
    if spell4 and target4 then
        spell4 = CleanCCSpell(spell4)
        local dur = spell4 and GetHardCCDuration(spell4) or nil
        if dur then
            Parser:AddEnemyCC(spell4, target4, dur)
            return true
        end
    end

    return false
end

local function ParseCCFadeMessage(message)
    if not message then return false end

    -- "SPELL fades from TARGET."
    local _, _, spell, target = string.find(message, "^(.+) fades from (.+)%.?$")
    if spell and target then
        if target == "you" or target == "You" then
            target = playerName
        end
        if IsHardCCSpell(spell) then
            Parser:FinishCC(target, spell)
            return true
        end
        -- Substring match against known hard CCs
        for name, _ in pairs(HARD_CC_SPELLS) do
            if string.find(spell, name, 1, true) then
                Parser:FinishCC(target, name)
                return true
            end
        end
    end

    -- "SPELL fades from you."
    local _, _, spell2 = string.find(message, "^(.+) fades from you%.?$")
    if spell2 then
        if IsHardCCSpell(spell2) then
            Parser:FinishCC(playerName, spell2)
            return true
        end
        for name, _ in pairs(HARD_CC_SPELLS) do
            if string.find(spell2, name, 1, true) then
                Parser:FinishCC(playerName, name)
                return true
            end
        end
    end

    return false
end

local function ParseHardCC(event, message)
    if not message or message == "" then return false end
    local lower = string.lower(message)

    -- Fades / breaks first
    if string.find(lower, "fades from", 1, true) then
        if ParseCCFadeMessage(message) then
            return true
        end
    end

    if string.find(lower, "afflict", 1, true)
    or string.find(lower, "stun", 1, true)
    or string.find(lower, "polymorph", 1, true)
    or string.find(lower, "fear", 1, true)
    or string.find(lower, "sap", 1, true)
    or string.find(lower, "seduction", 1, true)
    or string.find(lower, "hibernate", 1, true)
    or string.find(lower, "shackle", 1, true)
    or string.find(lower, "repentance", 1, true)
    or string.find(lower, "blind", 1, true)
    or string.find(lower, "scatter", 1, true)
    or string.find(lower, "wyvern", 1, true)
    or string.find(lower, "freezing trap", 1, true) then
        return ParseCCMessage(message)
    end
    return false
end

-- ============================================================
-- Periodic (HoT) heal plain-text parser
-- Combat log: "You gain N health from Caster's Spell."
-- Always credit the *caster*, never the unit that gained the HP.
-- ============================================================

local function ParsePeriodicHealMessage(message)
    if not message then return false end
    local lower = string.lower(message)
    if not string.find(lower, "health from", 1, true) and not string.find(lower, "hit points from", 1, true) then
        return false
    end

    -- "You gain N health from your Spell."
    local _, _, amt, spell = string.find(message, "^You gain (%d+) health from your (.+)%.?$")
    if amt and spell then
        Parser:AddHealing(playerName, tonumber(amt), spell, false, playerName)
        return true
    end
    -- "You gain N health from Caster's Spell."
    local _, _, amt2, caster, spell2 = string.find(message, "^You gain (%d+) health from (.+)'s (.+)%.?$")
    if amt2 and caster and spell2 then
        Parser:AddHealing(caster, tonumber(amt2), spell2, false, playerName)
        return true
    end
    -- "Target gains N health from your Spell."
    local _, _, target, amt3, spell3 = string.find(message, "^(.+) gains (%d+) health from your (.+)%.?$")
    if target and amt3 and spell3 then
        if target ~= "You" and not string.find(target, "^Your ") then
            Parser:AddHealing(playerName, tonumber(amt3), spell3, false, target)
            return true
        end
    end
    -- "Target gains N health from Caster's Spell."
    local _, _, target2, amt4, caster2, spell4 = string.find(message, "^(.+) gains (%d+) health from (.+)'s (.+)%.?$")
    if target2 and amt4 and caster2 and spell4 then
        if target2 ~= "You" and not string.find(target2, "^Your ") then
            Parser:AddHealing(caster2, tonumber(amt4), spell4, false, target2)
            return true
        end
    end
    -- Variant: "hit points" instead of "health"
    local _, _, amt5, caster3, spell5 = string.find(message, "^You gain (%d+) hit points from (.+)'s (.+)%.?$")
    if amt5 and caster3 and spell5 then
        Parser:AddHealing(caster3, tonumber(amt5), spell5, false, playerName)
        return true
    end
    local _, _, target3, amt6, caster4, spell6 = string.find(message, "^(.+) gains (%d+) hit points from (.+)'s (.+)%.?$")
    if target3 and amt6 and caster4 and spell6 then
        if target3 ~= "You" and not string.find(target3, "^Your ") then
            Parser:AddHealing(caster4, tonumber(amt6), spell6, false, target3)
            return true
        end
    end
    return false
end

-- ============================================================
-- Absorb-shield cast tracking
-- "Alice casts Power Word: Shield on Bob." → remember Alice for Bob's absorbs
-- ============================================================

local function ParseShieldCastMessage(message)
    if not message then return false end
    local lower = string.lower(message)
    if not string.find(lower, "cast", 1, true) then return false end

    -- "You cast SPELL on TARGET."
    local _, _, spell, target = string.find(message, "^You cast (.+) on (.+)%.?$")
    if spell and target and IsAbsorbShield(spell) then
        NoteRecentAbsorbCaster(spell, playerName, target)
        SetAbsorbAura(target, spell, playerName)
        return true
    end
    -- "SOURCE casts SPELL on TARGET."
    local _, _, source, spell2, target2 = string.find(message, "^(.+) casts (.+) on (.+)%.?$")
    if source and spell2 and target2 and IsAbsorbShield(spell2) then
        if source ~= "You" and not string.find(source, "^Your ") then
            NoteRecentAbsorbCaster(spell2, source, target2)
            SetAbsorbAura(target2, spell2, source)
            return true
        end
    end
    return false
end

-- ============================================================
-- Absorb message parsing
-- Credits absorbed damage as healing to the shield provider.
-- ============================================================

-- De-dupe absorb credits: the same absorb often arrives twice
-- (hit line "(N absorbed)" trailer + standalone "X absorbs N damage",
-- or RAW_COMBATLOG + CHAT_MSG). Collapse duplicates within a short window.
ST.recentAbsorbCredits = {} -- [ "unit|amount" ] = GetTime()
local ABSORB_DEDUPE_WINDOW = 0.2

local function CreditAbsorb(buffedUnit, amount, shieldName)
    amount = tonumber(amount)
    if not amount or amount <= 0 then return end
    buffedUnit = NormalizeName(buffedUnit) or buffedUnit

    local now = GetTime()
    local dedupeKey = tostring(buffedUnit) .. "|" .. tostring(amount)
    local last = ST.recentAbsorbCredits[dedupeKey]
    if last and (now - last) < ABSORB_DEDUPE_WINDOW then
        return
    end
    ST.recentAbsorbCredits[dedupeKey] = now
    -- Occasional prune
    if math.mod(math.floor(now * 5), 25) == 0 then
        local k, ts
        for k, ts in pairs(ST.recentAbsorbCredits) do
            if (now - ts) > 1 then
                ST.recentAbsorbCredits[k] = nil
            end
        end
    end

    local applicator, spell = GetAbsorbApplicator(buffedUnit)

    -- Prefer recent cast aimed at this unit (name + caster)
    if ST.recentShieldByTarget and ST.recentShieldByTarget[buffedUnit] then
        local entry = ST.recentShieldByTarget[buffedUnit]
        if entry and (GetTime() - (entry.time or 0)) <= RECENT_CASTER_TIMEOUT then
            if entry.caster and not applicator then
                applicator = entry.caster
            end
            if entry.spell and (not spell or spell == "") then
                spell = entry.spell
            end
        end
    end

    -- Resolve display name: never leave PW:S / Ice Barrier etc. as generic "Absorb"
    local label = shieldName
    if not label or label == "" or label == "Absorb" then
        label = spell
    end
    if (not label or label == "" or label == "Absorb") and ST.absorbAuras[buffedUnit] then
        -- Prefer Power Word: Shield when present, else any active shield on the unit
        if ST.absorbAuras[buffedUnit]["Power Word: Shield"] then
            label = "Power Word: Shield"
            if not applicator then
                applicator = ST.absorbAuras[buffedUnit]["Power Word: Shield"]
            end
        else
            local s, app
            for s, app in pairs(ST.absorbAuras[buffedUnit]) do
                label = s
                if not applicator then applicator = app end
                break
            end
        end
    end
    if not label or label == "" then
        label = "Absorb"
    end

    if not applicator then
        -- Power Word: Shield: single priest / clear healing-lead priest
        if label == "Power Word: Shield"
        or (spell and string.find(spell, "Power Word: Shield", 1, true))
        or (shieldName and string.find(shieldName, "Power Word: Shield", 1, true))
        or label == "Absorb" then
            local priest = ResolvePriestShieldApplicator()
            if priest then
                applicator = priest
                if label == "Absorb" then
                    label = "Power Word: Shield"
                end
            end
        end
    end

    if not applicator and OM.players[buffedUnit] then
        local class = OM.players[buffedUnit].class
        -- Self-cast class shields when still unknown
        if class == "PRIEST" or class == "MAGE" or class == "WARLOCK" then
            applicator = buffedUnit
        end
    end

    local credit = applicator or buffedUnit
    Parser:AddHealing(credit, amount, label, true)
end

-- Extract "(N absorbed)" trailer; return clean message + absorb amount
local function ExtractAbsorbTrailer(message)
    if not message then return message, nil end
    local absorbAmount = nil

    -- Use global ABSORB_TRAILER if available (e.g. " (%d+ absorbed)")
    if ABSORB_TRAILER then
        local regex = sanitize(ABSORB_TRAILER)
        if regex then
            local _, _, amt = string.find(message, regex)
            if amt then
                absorbAmount = tonumber(amt)
                message = string.gsub(message, regex, "")
            end
        end
    end

    -- Fallback English patterns
    if not absorbAmount then
        local _, _, amt = string.find(message, "%((%d+) absorbed%)")
        if amt then
            absorbAmount = tonumber(amt)
            message = string.gsub(message, "%s*%((%d+) absorbed%)", "")
        end
    end
    if not absorbAmount then
        local _, _, amt = string.find(message, "%((%d+) Absorbed%)")
        if amt then
            absorbAmount = tonumber(amt)
            message = string.gsub(message, "%s*%((%d+) Absorbed%)", "")
        end
    end

    return message, absorbAmount
end

local function ExtractBlockTrailer(message)
    if not message then return message, nil end
    local amt
    local _, _, a = string.find(message, "%((%d+) blocked%)")
    if a then
        amt = tonumber(a)
        message = string.gsub(message, "%s*%(%d+ blocked%)", "")
        return message, amt
    end
    _, _, a = string.find(message, "%((%d+) Blocked%)")
    if a then
        amt = tonumber(a)
        message = string.gsub(message, "%s*%(%d+ [Bb]locked%)", "")
        return message, amt
    end
    return message, nil
end

local function ExtractResistTrailer(message)
    if not message then return message, nil end
    local resistAmount = nil
    local _, _, amt = string.find(message, "%((%d+) resisted%)")
    if amt then
        resistAmount = tonumber(amt)
        message = string.gsub(message, "%s*%((%d+) resisted%)", "")
    else
        local _, _, amt2 = string.find(message, "%((%d+) Resisted%)")
        if amt2 then
            resistAmount = tonumber(amt2)
            message = string.gsub(message, "%s*%((%d+) Resisted%)", "")
        end
    end
    return message, resistAmount
end

-- Plain-text reflection fallback (when global DAMAGESHIELD patterns miss)
-- Credits the unit wearing the buff; no caster reassignment.
local function ParseReflectMessage(message)
    if not message then return false end
    local lower = string.lower(message)
    if not string.find(lower, "reflect", 1, true) then
        return false
    end

    local absorbAmt = nil
    message, absorbAmt = ExtractAbsorbTrailer(message)

    -- "You reflect AMOUNT [school] damage to TARGET."
    local _, _, amount, target = string.find(message, "^You reflect (%d+) [%w%s]*damage to (.+)%.?$")
    if not amount then
        _, _, amount, target = string.find(message, "^You reflect (%d+) damage to (.+)%.?$")
    end
    if amount and target then
        amount = tonumber(amount)
        if amount and amount > 0 then
            Parser:AddDamage(playerName, amount, "Reflect", target)
        end
        if absorbAmt and absorbAmt > 0 then
            CreditAbsorb(target, absorbAmt, "Absorb")
        end
        return true
    end

    -- "SOURCE reflects AMOUNT damage to you."
    local _, _, source, amount2 = string.find(message, "^(.+) reflects (%d+) [%w%s]*damage to you%.?$")
    if not source then
        _, _, source, amount2 = string.find(message, "^(.+) reflects (%d+) damage to you%.?$")
    end
    if source and amount2 then
        amount2 = tonumber(amount2)
        if amount2 and amount2 > 0 then
            Parser:AddDamageTaken(playerName, amount2, source)
        end
        if absorbAmt and absorbAmt > 0 then
            CreditAbsorb(playerName, absorbAmt, "Absorb")
        end
        return true
    end

    -- "SOURCE reflects AMOUNT damage to TARGET."
    local _, _, source2, amount3, target2 = string.find(message, "^(.+) reflects (%d+) [%w%s]*damage to (.+)%.?$")
    if not source2 then
        _, _, source2, amount3, target2 = string.find(message, "^(.+) reflects (%d+) damage to (.+)%.?$")
    end
    if source2 and amount3 and target2 then
        amount3 = tonumber(amount3)
        if amount3 and amount3 > 0 then
            Parser:AddDamage(source2, amount3, "Reflect", target2)
            if OM.players[NormalizeName(target2)] then
                Parser:AddDamageTaken(target2, amount3, source2)
            end
        end
        if absorbAmt and absorbAmt > 0 then
            CreditAbsorb(target2, absorbAmt, "Absorb")
        end
        return true
    end

    return false
end


local function ParseAbsorbMessage(message)
    if not message then return false end
    local lower = string.lower(message)
    if not string.find(lower, "absorb", 1, true) then
        return false
    end

    -- "You absorb AMOUNT damage." / "You absorb AMOUNT SCHOOL damage."
    local _, _, amount = string.find(message, "^You absorb (%d+)")
    if amount then
        CreditAbsorb(playerName, amount, "Absorb")
        return true
    end

    -- "TARGET absorbs AMOUNT damage." / "TARGET absorbs AMOUNT SCHOOL damage."
    local _, _, target, amount2 = string.find(message, "^(.+) absorbs (%d+)")
    if target and amount2 then
        if target ~= "You" and not string.find(target, "^Your ") then
            CreditAbsorb(target, amount2, "Absorb")
            return true
        end
    end

    -- "Your SPELL is absorbed by TARGET."
    local _, _, spell, target2 = string.find(message, "^Your (.+) is absorbed by (.+)%.?$")
    if spell and target2 then
        -- Outgoing spell fully absorbed — no healing credit; damage was prevented on enemy
        return true
    end

    -- "SOURCE's SPELL is absorbed by TARGET."
    local _, _, source, spell2, target3 = string.find(message, "^(.+)'s (.+) is absorbed by (.+)%.?$")
    if source and spell2 and target3 then
        return true
    end

    -- "SPELL is absorbed by TARGET." (melee etc.)
    local _, _, spell3, target4 = string.find(message, "^(.+) is absorbed by (.+)%.?$")
    if spell3 and target4 then
        -- Full absorb on the target — amount often unknown from this form alone
        return true
    end

    return false
end

-- ============================================================
-- Main parse loop
-- ============================================================

local function ParseEnemyDeath(message)
    if not message then return false end
    local name = nil
    -- "You die."
    if string.find(message, "^You die%.?$") or string.find(message, "^You have died%.?$") then
        name = UnitName("player")
    else
        -- "Bob dies." / "Defias Pillager dies."
        local _, _, n = string.find(message, "^(.+) dies%.?$")
        name = n
    end
    if not name and UNITDIESOTHER then
        local regex = sanitize(UNITDIESOTHER)
        if regex then
            local _, _, n = string.find(message, regex)
            name = n
        end
    end
    if not name then return false end

    name = NormalizeName(name)
    if OM.players[name] or name == UnitName("player") then
        Parser:AddDeath(name, ST.lastHitOn[name])
        return true
    end
    -- Hostile / other NPC death for boss detection
    if name ~= "You" and name ~= "you" then
        NoteEnemyDeath(name)
        return true
    end
    return false
end

local function ParseResistMessage(message)
    if not message then return false end
    local lower = string.lower(message)
    if not string.find(lower, "resist", 1, true) then return false end
    if string.find(message, "%(%d+ resisted%)") or string.find(message, "%(%d+ Resisted%)") then
        return false
    end
    local src, spell, target
    _, _, spell, target = string.find(message, "^Your (.+) was resisted by (.+)%.?$")
    if spell and target then
        Parser:AddResist(H.getPlayerName(), spell, target)
        return true
    end
    _, _, src, spell, target = string.find(message, "^(.+)'s (.+) was resisted by (.+)%.?$")
    if src and spell and target then
        Parser:AddResist(src, spell, target)
        return true
    end
    return false
end

local function ParseMissMessage(message)
    if not message then return false end
    local lower = string.lower(message)
    local isMiss = string.find(lower, "miss", 1, true)
        or string.find(lower, "dodge", 1, true)
        or string.find(lower, "parry", 1, true)
        or string.find(lower, "block", 1, true)
        or string.find(lower, "glance", 1, true)
    if not isMiss then return false end
    if string.find(lower, "heal", 1, true) then return false end

    local me = (H and H.getPlayerName and H.getPlayerName()) or (ST and ST.playerName) or UnitName("player")

    -- FIRST: "You attack. TARGET dodges/parries/blocks."
    -- Must run before any other pattern — earlier rules can false-match on "parry".
    if string.find(lower, "you attack", 1, true) then
        local avoid, key = nil, nil
        if string.find(lower, "parries", 1, true) then
            avoid, key = "parry", "parries"
        elseif string.find(lower, "dodges", 1, true) then
            avoid, key = "dodge", "dodges"
        elseif string.find(lower, "blocks", 1, true) and not string.find(lower, "blocked", 1, true) then
            -- "blocks." at end of swing avoid (not "was blocked by")
            local tail = string.sub(lower, -12)
            if string.find(tail, "blocks", 1, true) then
                avoid, key = "block", "blocks"
            end
        end
        if avoid and key then
            local kp = string.find(lower, key, 1, true)
            -- name sits between "you attack." and the avoid word
            local ap = string.find(lower, "you attack", 1, true)
            local after = ap + string.len("you attack")
            -- skip optional '.' and spaces
            while after <= string.len(message) do
                local ch = string.sub(message, after, after)
                if ch == "." or ch == " " then
                    after = after + 1
                else
                    break
                end
            end
            local tname = string.sub(message, after, kp - 1)
            tname = string.gsub(tname, "^%s+", "")
            tname = string.gsub(tname, "%s+$", "")
            if tname and tname ~= "" then
                Parser:AddMiss(me, "Auto Attack", tname, avoid)
                return true
            end
        end
    end

    local src, spell, target, amt

    -- Incoming avoids / enemy misses on us (damage-taken detail)
    -- "SOURCE misses you."
    _, _, src = string.find(message, "^(.+) misses you%.?$")
    if src and src ~= "You" then
        Parser:AddMiss(src, "Auto Attack", H.getPlayerName())
        Parser:AddTakenAvoid(H.getPlayerName(), "Auto Attack", src, "miss")
        return true
    end
    _, _, src = string.find(message, "^(.+) missed you%.?$")
    if src and src ~= "You" then
        Parser:AddMiss(src, "Auto Attack", H.getPlayerName())
        Parser:AddTakenAvoid(H.getPlayerName(), "Auto Attack", src, "miss")
        return true
    end
    -- "SOURCE's SPELL misses/missed you."
    _, _, src, spell = string.find(message, "^(.+)'s (.+) misses you%.?$")
    if src and spell then
        Parser:AddMiss(src, spell, H.getPlayerName())
        Parser:AddTakenAvoid(H.getPlayerName(), spell, src, "miss")
        return true
    end
    _, _, src, spell = string.find(message, "^(.+)'s (.+) missed you%.?$")
    if src and spell then
        -- Incoming only — do not AddMiss for the mob (and never for us)
        Parser:AddTakenAvoid(H.getPlayerName(), spell, src, "miss")
        return true
    end
    -- "SOURCE attacks. You dodge/parry/block."
    _, _, src = string.find(message, "^(.+) attacks%. You dodge%.?$")
    if src then
        Parser:AddTakenAvoid(H.getPlayerName(), "Auto Attack", src, "dodge")
        return true
    end
    _, _, src = string.find(message, "^(.+) attacks%. You parry%.?$")
    if src then
        Parser:AddTakenAvoid(H.getPlayerName(), "Auto Attack", src, "parry")
        return true
    end
    _, _, src = string.find(message, "^(.+) attacks%. You block%.?$")
    if src then
        Parser:AddTakenAvoid(H.getPlayerName(), "Auto Attack", src, "block")
        return true
    end
    -- "SOURCE's SPELL was dodged/parried/blocked." (OTHERSELF — local player is the defender)
    _, _, src, spell = string.find(message, "^(.+)'s (.+) was dodged%.?$")
    if src and spell then
        Parser:AddTakenAvoid(H.getPlayerName(), spell, src, "dodge")
        return true
    end
    _, _, src, spell = string.find(message, "^(.+)'s (.+) was parried%.?$")
    if src and spell then
        Parser:AddTakenAvoid(H.getPlayerName(), spell, src, "parry")
        return true
    end
    _, _, src, spell = string.find(message, "^(.+)'s (.+) was blocked%.?$")
    if src and spell then
        Parser:AddTakenAvoid(H.getPlayerName(), spell, src, "block")
        return true
    end

    -- "You miss TARGET."
    _, _, target = string.find(message, "^You miss (.+)%.?$")
    if target then
        Parser:AddMiss(H.getPlayerName(), "Auto Attack", target)
        return true
    end
    -- "Your SPELL misses/missed TARGET." (SPELLMISSSELFOTHER uses "missed")
    _, _, spell, target = string.find(message, "^Your (.+) misses (.+)%.?$")
    if spell and target then
        Parser:AddMiss(H.getPlayerName(), spell, target)
        return true
    end
    _, _, spell, target = string.find(message, "^Your (.+) missed (.+)%.?$")
    if spell and target then
        Parser:AddMiss(H.getPlayerName(), spell, target)
        return true
    end
    -- "SOURCE misses TARGET." / MISSEDSELFOTHER style
    _, _, src, target = string.find(message, "^(.+) misses (.+)%.?$")
    if src and target and src ~= "You" then
        Parser:AddMiss(src, "Auto Attack", target)
        return true
    end
    _, _, src, target = string.find(message, "^(.+) missed (.+)%.?$")
    if src and target and src ~= "You" then
        -- Prefer spell form below when "X's Spell missed Y"
        if not string.find(src, "'s ", 1, true) then
            Parser:AddMiss(src, "Auto Attack", target)
            return true
        end
    end
    -- "SOURCE's SPELL misses/missed TARGET."
    _, _, src, spell, target = string.find(message, "^(.+)'s (.+) misses (.+)%.?$")
    if src and spell and target then
        Parser:AddMiss(src, spell, target)
        return true
    end
    _, _, src, spell, target = string.find(message, "^(.+)'s (.+) missed (.+)%.?$")
    if src and spell and target then
        Parser:AddMiss(src, spell, target)
        return true
    end

    -- (You-attack avoids handled at top of ParseMissMessage)

    -- Party outbound: "SOURCE attacks. TARGET dodges/parries/blocks." (TARGET not You)
    if string.find(message, " attacks.", 1, true) and not string.find(message, "You dodge", 1, true)
        and not string.find(message, "You parry", 1, true)
        and not string.find(message, "You block", 1, true) then
        local src, tname
        if string.find(lower, "dodges", 1, true) then
            _, _, src, tname = string.find(message, "^(.+) attacks%. (.+) dodges")
            if src and tname and tname ~= "You" then
                tname = string.gsub(tname, "%.$", "")
                Parser:AddMiss(src, "Auto Attack", tname, "dodge")
                return true
            end
        end
        if string.find(lower, "parries", 1, true) then
            _, _, src, tname = string.find(message, "^(.+) attacks%. (.+) parries")
            if src and tname and tname ~= "You" then
                tname = string.gsub(tname, "%.$", "")
                Parser:AddMiss(src, "Auto Attack", tname, "parry")
                return true
            end
        end
        if string.find(lower, "blocks", 1, true) then
            _, _, src, tname = string.find(message, "^(.+) attacks%. (.+) blocks")
            if src and tname and tname ~= "You" then
                tname = string.gsub(tname, "%.$", "")
                Parser:AddMiss(src, "Auto Attack", tname, "block")
                return true
            end
        end
    end
    -- Spells: "Your SPELL was dodged/parried/blocked by TARGET."
    _, _, spell, target = string.find(message, "^Your (.+) was dodged by (.+)%.?$")
    if spell and target then
        Parser:AddMiss(H.getPlayerName(), spell, target, "dodge")
        return true
    end
    _, _, spell, target = string.find(message, "^Your (.+) was parried by (.+)%.?$")
    if spell and target then
        Parser:AddMiss(H.getPlayerName(), spell, target, "parry")
        return true
    end
    _, _, spell, target = string.find(message, "^Your (.+) was blocked by (.+)%.?$")
    if spell and target then
        Parser:AddMiss(H.getPlayerName(), spell, target, "block")
        return true
    end
    _, _, src, spell, target = string.find(message, "^(.+)'s (.+) was dodged by (.+)%.?$")
    if src and spell and target then
        Parser:AddMiss(src, spell, target, "dodge")
        return true
    end
    _, _, src, spell, target = string.find(message, "^(.+)'s (.+) was parried by (.+)%.?$")
    if src and spell and target then
        Parser:AddMiss(src, spell, target, "parry")
        return true
    end
    _, _, src, spell, target = string.find(message, "^(.+)'s (.+) was blocked by (.+)%.?$")
    if src and spell and target then
        Parser:AddMiss(src, spell, target, "block")
        return true
    end

    _, _, target, amt = string.find(message, "^You glance (.+) for (%d+)")
    if target and amt then
        Parser:AddDamage(H.getPlayerName(), tonumber(amt), "Auto Attack", H.NormalizeName(target), "glance")
        return true
    end
    _, _, src, target, amt = string.find(message, "^(.+) glances (.+) for (%d+)")
    if src and target and amt and src ~= "You" then
        Parser:AddDamage(src, tonumber(amt), "Auto Attack", H.NormalizeName(target), "glance")
        return true
    end
    return false
end

-- Bind helpers into H so ParseMessage only needs H/OM/Parser upvalues
H.NormalizeName = NormalizeName
H.ResolveSource = ResolveSource
H.NoteEnemyHit = NoteEnemyHit
H.CreditAbsorb = CreditAbsorb
H.ExtractAbsorbTrailer = ExtractAbsorbTrailer
H.ExtractBlockTrailer = ExtractBlockTrailer
H.ExtractResistTrailer = ExtractResistTrailer
H.ParseAbsorbMessage = ParseAbsorbMessage
H.ParseAuraMessage = ParseAuraMessage
H.ParseEnemyDeath = ParseEnemyDeath
H.ParseHardCC = ParseHardCC
H.ParseInterruptOrDispel = ParseInterruptOrDispel
H.ParseMissMessage = ParseMissMessage
H.ParsePeriodicHealMessage = ParsePeriodicHealMessage
H.ParseReflectMessage = ParseReflectMessage
H.ParseResistMessage = ParseResistMessage
H.ParseShieldCastMessage = ParseShieldCastMessage
H.sanitize = sanitize
H.combatlog_events = combatlog_events
H.combatlog_parser = combatlog_parser
H.defaults = defaults
H.FALLBACK_COMBAT_PATTERNS = FALLBACK_COMBAT_PATTERNS
H.OM = OM
H.Parser = Parser
H.getPlayerName = function() return ST.playerName or UnitName("player") end

local function ParseMessage(event, message)
    if not message or message == "" then return end
    if OM.NoteTotemCast then
        local _, _, youSpell = string.find(message, "^You cast (.+)%.?$")
        if youSpell and string.find(youSpell, "Totem") and not string.find(youSpell, " on ") then
            OM:NoteTotemCast(UnitName("player"), youSpell)
        else
            local _, _, src, spell = string.find(message, "^(.+) casts (.+)%.?$")
            if src and spell and string.find(spell, "Totem") and not string.find(spell, " on ") then
                if src ~= "You" and not string.find(src, "^Your ") and (OM.players and OM.players[src]) then
                    OM:NoteTotemCast(src, spell)
                end
            end
        end
    end

    -- When Nampower owns damage/heal/miss, skip chat paths that would double-count.
    -- Interrupt / dispel / CC chat parsers still run below.
    local skipCombatChat = GreedMeter.ParserNS and GreedMeter.ParserNS.useNampowerCombat

    -- Hard path for swing avoids (must not depend on later pattern order)
    if not skipCombatChat then
        local lowerEarly = string.lower(message)
        if string.find(lowerEarly, "you attack", 1, true) then
            local avoidWord = nil
            local avoidType = nil
            if string.find(lowerEarly, "parries", 1, true) then
                avoidWord, avoidType = "parries", "parry"
            elseif string.find(lowerEarly, "dodges", 1, true) then
                avoidWord, avoidType = "dodges", "dodge"
            elseif string.find(lowerEarly, "blocks", 1, true) then
                -- only trailing "blocks." swing form
                if string.find(lowerEarly, "blocks", 1, true) and not string.find(lowerEarly, "blocked", 1, true) then
                    avoidWord, avoidType = "blocks", "block"
                end
            end
            if avoidWord and avoidType then
                local me = (H.getPlayerName and H.getPlayerName()) or (ST and ST.playerName) or UnitName("player")
                local kp = string.find(lowerEarly, avoidWord, 1, true)
                local ap = string.find(lowerEarly, "you attack", 1, true)
                local after = ap + 10 -- len("you attack")
                while after <= string.len(message) do
                    local ch = string.sub(message, after, after)
                    if ch == "." or ch == " " or ch == ":" then
                        after = after + 1
                    else
                        break
                    end
                end
                if kp and kp > after then
                    local tname = string.sub(message, after, kp - 1)
                    tname = string.gsub(tname, "^%s+", "")
                    tname = string.gsub(tname, "%s+$", "")
                    if tname ~= "" then
                        Parser:AddMiss(me, "Auto Attack", tname, avoidType)
                        return
                    end
                end
            end
        end
    end

    -- Full resists (before miss path)
    if not skipCombatChat then
    if string.find(message, "resist", 1, true) or string.find(message, "Resist", 1, true) then
        if H.ParseResistMessage(message) then
            return
        end
    end

    -- Misses / dodges / glancing (before generic ignore paths)
    if string.find(message, "miss", 1, true)
    or string.find(message, "Miss", 1, true)
    or string.find(message, "dodge", 1, true)
    or string.find(message, "Dodge", 1, true)
    or string.find(message, "dodges", 1, true)
    or string.find(message, "parry", 1, true)
    or string.find(message, "Parry", 1, true)
    or string.find(message, "parries", 1, true)
    or string.find(message, "block", 1, true)
    or string.find(message, "blocks", 1, true)
    or string.find(message, "glance", 1, true)
    or string.find(message, "Glance", 1, true) then
        if H.ParseMissMessage(message) then
            return
        end
    end
    end -- not skipCombatChat (resist/miss)

    -- Hostile deaths (unique-name boss detection)
    if event == "CHAT_MSG_COMBAT_HOSTILE_DEATH"
    or event == "CHAT_MSG_COMBAT_FRIENDLY_DEATH"
    or string.find(message, " dies", 1, true)
    or string.find(message, "You die", 1, true)
    or string.find(message, "you die", 1, true) then
        if H.ParseEnemyDeath(message) then
            return
        end
    end

    -- Cheap substring gates before heavier parsers (plain find is case-sensitive;
    -- combat log verbs are consistently cased in English 1.12 clients).
    -- Interrupts / dispels / fades
    if string.find(message, "interrupt", 1, true)
    or string.find(message, "Interrupt", 1, true)
    or string.find(message, "cast", 1, true)
    or string.find(message, "perform", 1, true)
    or string.find(message, "remove", 1, true)
    or string.find(message, "fades from", 1, true)
    or string.find(message, "Purify", 1, true)
    or string.find(message, "Cleanse", 1, true)
    or string.find(message, "Dispel", 1, true)
    or string.find(message, "Purge", 1, true)
    or string.find(message, "Cure", 1, true)
    or string.find(message, "Abolish", 1, true)
    or string.find(message, "Devour", 1, true)
    or string.find(message, "Remove Curse", 1, true) then
        if H.ParseInterruptOrDispel(event, message) then
            return
        end
    end

    -- Hard CC applications / fades (chat fallback when Nampower CC path is off)
    if not (GreedMeter.ParserNS and GreedMeter.ParserNS.useNampowerCC) then
    if string.find(message, "afflicted by", 1, true)
    or string.find(message, "fades from", 1, true)
    or string.find(message, "is afflicted", 1, true) then
        if H.ParseHardCC(event, message) then
            return
        end
    end
    end

    -- Nampower owns damage/heal/miss/absorb; stop most chat combat parsing here.
    -- Reflection (Thorns, Lightning Shield, Fire Shield, etc.) has no reliable
    -- Nampower structured event — keep chat reflect lines even when Nampower is on.
    if skipCombatChat then
        if string.find(message, "reflect", 1, true) or string.find(message, "Reflect", 1, true) then
            if H.ParseReflectMessage and H.ParseReflectMessage(message) then
                return
            end
        end
        return
    end

    -- HoT ticks: always credit the caster named in "from X's Spell"
    if string.find(message, "health from", 1, true)
    or string.find(message, "hit points from", 1, true) then
        if H.ParsePeriodicHealMessage(message) then
            return
        end
    end

    -- Track absorb-shield casts for later absorb credit
    if string.find(message, "cast", 1, true) and (
        string.find(message, "Power Word: Shield", 1, true)
        or string.find(message, "Ice Barrier", 1, true)
        or string.find(message, "Mana Shield", 1, true)
        or string.find(message, "Sacrifice", 1, true)
        or string.find(message, "Ward", 1, true)
    ) then
        if H.ParseShieldCastMessage(message) then
            return
        end
    end

    -- Non-damaging threat abilities: "X casts/performs Sunder Armor on Y"
    if string.find(message, "Sunder Armor", 1, true)
        or string.find(message, "Demoralizing Shout", 1, true)
        or string.find(message, "Demoralizing Roar", 1, true)
        or string.find(message, "Faerie Fire", 1, true)
        or string.find(message, "Hamstring", 1, true)
        or string.find(message, "Growl", 1, true)
        or string.find(message, "Intimidation", 1, true)
        or string.find(message, "Torment", 1, true)
        or string.find(message, "Suffering", 1, true) then
        local src, spell
        local _
        _, _, spell = string.find(message, "^You perform (.+) on ")
        if spell then
            H.Parser:AddThreatCast(H.getPlayerName(), spell)
        else
            _, _, spell = string.find(message, "^You cast (.+) on ")
            if spell then
                H.Parser:AddThreatCast(H.getPlayerName(), spell)
            else
                _, _, spell = string.find(message, "^You cast (.+)%.?$")
                if spell then
                    H.Parser:AddThreatCast(H.getPlayerName(), spell)
                else
                    _, _, src, spell = string.find(message, "^(.+) performs (.+) on ")
                    if src and spell then
                        H.Parser:AddThreatCast(src, spell)
                    else
                        _, _, src, spell = string.find(message, "^(.+) casts (.+) on ")
                        if src and spell then
                            H.Parser:AddThreatCast(src, spell)
                        else
                            _, _, src, spell = string.find(message, "^(.+) casts (.+)%.?$")
                            if src and spell then
                                H.Parser:AddThreatCast(src, spell)
                            end
                        end
                    end
                end
            end
        end
        -- do not return — message may still carry other useful patterns
    end

    -- Plain-text reflection
    if string.find(message, "reflect", 1, true) or string.find(message, "Reflect", 1, true) then
        if H.ParseReflectMessage(message) then
            return
        end
    end

    -- Standalone absorb messages
    if string.find(message, "absorb", 1, true) or string.find(message, "Absorb", 1, true) then
        if H.ParseAbsorbMessage(message) then
            return
        end
    end

    -- Aura gain/fade events (reflection + absorb shield tracking)
    if event == "CHAT_MSG_SPELL_AURA_GONE_SELF"
    or event == "CHAT_MSG_SPELL_AURA_GONE_OTHER"
    or event == "CHAT_MSG_SPELL_PERIODIC_SELF_BUFFS"
    or event == "CHAT_MSG_SPELL_PERIODIC_PARTY_BUFFS"
    or event == "CHAT_MSG_SPELL_PERIODIC_FRIENDLYPLAYER_BUFFS"
    or event == "CHAT_MSG_SPELL_SELF_BUFF"
    or event == "CHAT_MSG_SPELL_PARTY_BUFF"
    or event == "CHAT_MSG_SPELL_FRIENDLYPLAYER_BUFF" then
        H.ParseAuraMessage(event, message)
        -- Continue: some of these events also carry heal patterns
    end

    -- Strip absorb / partial-resist / glancing trailers so patterns match
    local absorbFromTrailer = nil
    local resistFromTrailer = nil
    local blockFromTrailer = nil
    local glanceFromTrailer = false
    if string.find(message, "%([Gg]lancing%)") then
        glanceFromTrailer = true
        message = string.gsub(message, "%s*%([Gg]lancing%)", "")
    end
    local crushFromTrailer = false
    if string.find(message, "%([Cc]rushing%)") then
        crushFromTrailer = true
        message = string.gsub(message, "%s*%([Cc]rushing%)", "")
    end
    message, absorbFromTrailer = H.ExtractAbsorbTrailer(message)
    message, resistFromTrailer = H.ExtractResistTrailer(message)
    message, blockFromTrailer = H.ExtractBlockTrailer(message)

    local patterns = H.combatlog_events[event]
    if not patterns then
        -- Unknown / SuperWoW event name: still try the full combat pattern set
        patterns = H.FALLBACK_COMBAT_PATTERNS
    end
    if not patterns or table.getn(patterns) == 0 then
        if absorbFromTrailer and absorbFromTrailer > 0 then
            local absorbTarget = H.getPlayerName()
            if event and string.find(event, "SELF", 1, true) then
                absorbTarget = H.getPlayerName()
            end
            H.CreditAbsorb(absorbTarget, absorbFromTrailer, "Absorb")
        end
        return
    end

    for _gi = 1, table.getn(patterns) do local pattern = patterns[_gi]
        local handler = H.combatlog_parser[pattern]
        if handler then
            local regex = H.sanitize(pattern)
            if regex then
                local found = string.find(message, regex)
                if found then
                    local _, _, c1, c2, c3, c4, c5 = string.find(message, regex)
                    local source, spell, target, amount, school, dtype =
                        handler(H.defaults, c1, c2, c3, c4, c5)

                    amount = tonumber(amount)

                    -- Reject false matches from mis-ordered GlobalString captures
                    -- (these produced target names like "hit", "crits", "from", "missed").
                    if (dtype == "damage" or dtype == "taken" or dtype == "heal"
                        or dtype == "reflect" or dtype == "reflect_taken"
                        or dtype == "periodic" or dtype == "periodic_taken")
                        and (not amount or amount <= 0) then
                        -- try next pattern
                    else

                    -- Absorb trailer: the unit who actually took the hit absorbed part of it.
                    -- For normal damage/taken → target (or self).
                    -- For reflection → the unit the damage was reflected *onto*.
                    if absorbFromTrailer and absorbFromTrailer > 0 then
                        local absTarget = nil
                        if dtype == "reflect" then
                            absTarget = target -- reflected damage absorbed by the attacker
                        elseif dtype == "reflect_taken" then
                            absTarget = target or H.getPlayerName() -- local player absorbed their reflection
                        elseif dtype == "taken" then
                            absTarget = target or H.getPlayerName()
                        elseif dtype == "damage" then
                            absTarget = target
                        end
                        if absTarget then
                            H.CreditAbsorb(absTarget, absorbFromTrailer, "Absorb")
                        end
                    end

                    -- Pattern globals are English format strings ("You crit %s for %d."),
                    -- not the identifier COMBATHITCRIT*. Match case-insensitively, and
                    -- also fall back to the live message text.
                    local hitType = "hit"
                    local patLower = string.lower(tostring(pattern or ""))
                    local msgLower = string.lower(tostring(message or ""))
                    if string.find(patLower, "crit", 1, true)
                        or string.find(msgLower, " crits ", 1, true)
                        or string.find(msgLower, " crit ", 1, true)
                        or string.find(msgLower, "^you crit ", 1, true)
                        or string.find(msgLower, " you crit ", 1, true) then
                        hitType = "crit"
                    elseif string.find(patLower, "glancing", 1, true)
                        or glanceFromTrailer then
                        hitType = "glance"
                    elseif crushFromTrailer then
                        hitType = "crush"
                    end

                    if amount and amount > 0 and source then
                        if dtype == "damage" then
                            local resolvedSource = H.ResolveSource(source)
                            local tname = target and H.NormalizeName(target) or nil
                            -- Self-inflicted (Bloodrage, Life Tap, etc.): taken only, not damage done
                            local selfHarm = false
                            if resolvedSource and tname and resolvedSource == tname then
                                selfHarm = true
                            end
                            if not selfHarm then
                                local partial = (resistFromTrailer and resistFromTrailer > 0) and true or false
                                -- Partial block still deals damage; count the hit and a block
                                if blockFromTrailer and blockFromTrailer > 0 and hitType == "hit" then
                                    -- keep as hit for damage totals; also note block
                                    H.Parser:AddDamage(source, amount, spell, tname, hitType, partial)
                                    H.Parser:AddBlock(source, spell or "Auto Attack", tname)
                                else
                                    H.Parser:AddDamage(source, amount, spell, tname, hitType, partial)
                                end
                            end
                            if tname and H.OM.players[tname] then
                                local takenFrom = selfHarm and (spell or "Self") or source
                                local takenSpell = selfHarm and (spell or "Self") or (spell or "Auto Attack")
                                local partial = (resistFromTrailer and resistFromTrailer > 0) and true or false
                                H.Parser:AddDamageTaken(tname, amount, takenFrom, takenSpell, hitType, partial)
                            elseif tname and not selfHarm then
                                H.NoteEnemyHit(tname, amount)
                            end
                        elseif dtype == "heal" then
                            H.Parser:AddHealing(source, amount, spell, false, target, hitType)
                        elseif dtype == "taken" then
                            local partial = (resistFromTrailer and resistFromTrailer > 0) and true or false
                            H.Parser:AddDamageTaken(target or H.getPlayerName(), amount, source, spell or "Auto Attack", hitType, partial, false)
                        elseif dtype == "periodic" then
                            local partial = (resistFromTrailer and resistFromTrailer > 0) and true or false
                            local tname = H.NormalizeName(target)
                            local selfHarm = false
                            local resolvedSource = H.ResolveSource and H.ResolveSource(source) or source
                            if resolvedSource and tname and resolvedSource == tname then
                                selfHarm = true
                            end
                            if not selfHarm then
                                H.Parser:AddDamage(source, amount, spell, tname, hitType, partial, true)
                            end
                            if tname and H.OM.players[tname] then
                                local takenFrom = selfHarm and (spell or "Self") or source
                                H.Parser:AddDamageTaken(tname, amount, takenFrom, spell or "Auto Attack", hitType, partial, true)
                            elseif tname and not selfHarm then
                                H.NoteEnemyHit(tname, amount)
                            end
                        elseif dtype == "periodic_taken" then
                            local partial = (resistFromTrailer and resistFromTrailer > 0) and true or false
                            H.Parser:AddDamageTaken(target or H.getPlayerName(), amount, source, spell or "Auto Attack", hitType, partial, true)
                        elseif dtype == "reflect" then
                            -- Credit the unit wearing the reflection buff (no caster reassignment)
                            local spellName = spell or "Reflect"
                            H.Parser:AddDamage(source, amount, spellName, target)
                            if target and H.OM.players[H.NormalizeName(target)] then
                                H.Parser:AddDamageTaken(target, amount, source, spellName, hitType, false)
                            end
                        elseif dtype == "reflect_taken" then
                            H.Parser:AddDamageTaken(target or H.getPlayerName(), amount, source, spell or "Reflect", hitType, false)
                        end
                    end
                    return
                    end -- valid amount
                end
            end
        end
    end

    -- Pattern miss but trailer present
    if absorbFromTrailer and absorbFromTrailer > 0 then
        H.CreditAbsorb(H.getPlayerName(), absorbFromTrailer, "Absorb")
    end
end

-- ============================================================
-- Event frame
-- ============================================================


-- ============================================================
-- Chat backend enable (register CHAT_MSG events + optional RAW)
-- ============================================================

-- Export chat-defined helpers for lifecycle / other modules
if ClearDispelBuffers then
    NS.ClearDispelBuffers = ClearDispelBuffers
end
if IsInterruptSpell then
    Parser.IsInterruptAbility = IsInterruptSpell
end
if NoteBreakableCCDamage then
    Parser.NoteBreakableCCDamage = NoteBreakableCCDamage
end
-- H already assigned Parse* inside body; re-point shared H
if NS.H then
    local i
    -- copy parse-related H fields set on local H
end
H = NS.H or H
NS.H = H

function Chat.Enable(parseFrame, opts)
    opts = opts or {}
    local useRaw = opts.useRaw
    if not parseFrame then
        parseFrame = CreateFrame("Frame", "GreedMeterChatParseFrame")
    end
    Chat.frame = parseFrame

    playerName = UnitName("player")
    if ST then ST.playerName = playerName end

    -- Short window de-dupe so RAW + CHAT of the same line do not double-count
    local recentLine = {}
    local function ParseDeduped(evName, msg)
        if not msg or msg == "" then return end
        local now = GetTime()
        local last = recentLine[msg]
        if last and (now - last) < 0.15 then
            return
        end
        recentLine[msg] = now
        if math.mod(math.floor(now), 3) == 0 and math.mod(math.floor(now * 10), 10) == 0 then
            local k, ts
            for k, ts in pairs(recentLine) do
                if (now - ts) > 1 then
                    recentLine[k] = nil
                end
            end
        end
        ParseMessage(evName, msg)
    end

    parseFrame:SetScript("OnEvent", function()
        if event == "RAW_COMBATLOG" then
            if arg2 then
                local cleaned = StripAndCacheGuids(arg2)
                ParseDeduped(arg1 or event, cleaned)
            end
            return
        end
        ParseDeduped(event, arg1)
    end)

    local combatlog_events = H.combatlog_events
    if combatlog_events then
        local ev
        for ev, _ in pairs(combatlog_events) do
            parseFrame:RegisterEvent(ev)
        end
    end

    local extraEvents = {
        "CHAT_MSG_SPELL_AURA_GONE_SELF",
        "CHAT_MSG_SPELL_AURA_GONE_OTHER",
        "CHAT_MSG_SPELL_PERIODIC_SELF_BUFFS",
        "CHAT_MSG_SPELL_PERIODIC_PARTY_BUFFS",
        "CHAT_MSG_SPELL_PERIODIC_FRIENDLYPLAYER_BUFFS",
        "CHAT_MSG_SPELL_PERIODIC_HOSTILEPLAYER_BUFFS",
        "CHAT_MSG_SPELL_PERIODIC_CREATURE_BUFFS",
        "CHAT_MSG_COMBAT_HOSTILE_DEATH",
        "CHAT_MSG_COMBAT_FRIENDLY_DEATH",
        "CHAT_MSG_COMBAT_SELF_MISSES",
        "CHAT_MSG_COMBAT_PARTY_MISSES",
        "CHAT_MSG_COMBAT_FRIENDLYPLAYER_MISSES",
        "CHAT_MSG_COMBAT_HOSTILEPLAYER_MISSES",
        "CHAT_MSG_COMBAT_CREATURE_VS_SELF_MISSES",
        "CHAT_MSG_COMBAT_CREATURE_VS_PARTY_MISSES",
        "CHAT_MSG_COMBAT_CREATURE_VS_CREATURE_MISSES",
        "CHAT_MSG_COMBAT_PET_MISSES",
        "CHAT_MSG_SPELL_SELF_DAMAGE",
        "CHAT_MSG_SPELL_PARTY_DAMAGE",
        "CHAT_MSG_SPELL_FRIENDLYPLAYER_DAMAGE",
        "CHAT_MSG_SPELL_HOSTILEPLAYER_DAMAGE",
        "CHAT_MSG_SPELL_PET_DAMAGE",
    }
    local i
    for i = 1, table.getn(extraEvents) do
        parseFrame:RegisterEvent(extraEvents[i])
    end

    if useRaw then
        parseFrame:RegisterEvent("RAW_COMBATLOG")
    end

    return parseFrame
end
