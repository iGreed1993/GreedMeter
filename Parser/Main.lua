--[[
    GreedMeter - Parser / Main
    Combat log parsing, metrics, attribution, history.
    Locale-independent via global combat text patterns.
]]

local OM = GreedMeter
local Parser = {}
GreedMeter.ParserNS = GreedMeter.ParserNS or {}
GreedMeter.ParserNS.Parser = Parser

-- ============================================================
-- Data storage (per segment)
-- ============================================================

OM.data = {
    current = { players = {}, ccTargets = {}, startTime = 0, endTime = 0, label = "Current" },
    overall = { players = {}, ccTargets = {}, startTime = 0, endTime = 0, label = "Overall" },
    -- Last 2 fights of any kind (newest first)
    recentFights = {},
    -- Last 3 boss fights (newest first)
    bossFights = {},
}

local MAX_RECENT_FIGHTS = 3
local MAX_BOSS_FIGHTS = 5

-- Soft caps on per-player detail lists so overall / long sessions stay bounded.
-- Counts remain accurate; only the stored event history is trimmed (oldest first).
local MAX_DETAIL_LIST = 80   -- dispels / interrupts / ccBreaks / per-enemy CC applications
local MAX_DEATHS_LIST = 40

-- Per-fight enemy tracking for naming + boss detection
local fightEnemies = {}        -- [name] = damage dealt to them by group
local fightEnemyDeaths = {}    -- [name] = how many times this name died this fight
local fightDuplicateNames = {} -- [name] = true if name is not unique (pack trash)
local fightIsBoss = false
local fightBossName = nil

-- ============================================================
-- Helpers
-- ============================================================

local playerName = nil

-- Optional mode gates (Advanced Customization "Enabled" checkboxes).
-- When a mode is disabled we skip storing its metrics to save CPU/memory.
local function ModeEnabled(mode)
    local UI = GreedMeter and GreedMeter.UI
    if UI and UI.IsModeEnabled then
        return UI.IsModeEnabled(mode)
    end
    return true
end


-- Resolve "You" and SuperWoW-style pet ownership names
local function NormalizeName(name)
    if not name then return nil end
    if name == "You" or name == "you" then
        return playerName or UnitName("player")
    end
    -- SuperWoW style: "PetName (OwnerName)"
    local _, _, pet, owner = string.find(name, "^(.+) %((.+)%)$")
    if pet and owner then
        return owner
    end
    return name
end

-- Exact match first, then substring (handles rank suffixes / variants).
-- Used by absorb / interrupt / dispel / CC spell tables.
local function SpellLookup(set, spell)
    if not spell or not set then return nil end
    local v = set[spell]
    if v ~= nil then return v end
    local name, val
    for name, val in pairs(set) do
        if string.find(spell, name, 1, true) then
            return val
        end
    end
    return nil
end

local function SpellInSet(set, spell)
    return SpellLookup(set, spell) ~= nil
end

-- Iterate player + party + raid unit tokens once.
local function ForEachGroupUnit(fn)
    if not fn then return end
    fn("player")
    local i
    for i = 1, 4 do
        fn("party" .. i)
    end
    if GetNumRaidMembers() > 0 then
        for i = 1, 40 do
            fn("raid" .. i)
        end
    end
end

-- ============================================================
-- SuperWoW helpers (preferred path when available)
-- ============================================================
local guidToName = {}
local nameToGuid = {}

local function SuperWoWAvailable()
    if OM and OM.HasSuperWoW then
        return OM:HasSuperWoW()
    end
    return (SUPERWOW_VERSION or SUPERWOW_STRING or SuperWoW) and true or false
end

local function CacheGuid(name, guid)
    if not name or name == "" or not guid or guid == "" then return end
    name = NormalizeName(name) or name
    guidToName[guid] = name
    nameToGuid[name] = guid
end


-- Strip SuperWoW GUID tokens from a combat log line while caching them
-- Handles forms like: 0xF130..., player-..., and trailing GUID chunks
local function StripAndCacheGuids(msg)
    if not msg then return msg end
    local cleaned = msg
    -- Cache "Name 0xGUID" pairs before stripping (only 0x-prefixed GUIDs)
    local pos = 1
    while true do
        local s, e, name, guid = string.find(cleaned, "([%w'-]+)%s+(0[xX]%x+)", pos)
        if not s then break end
        if string.len(guid) >= 10 then
            CacheGuid(name, guid)
        end
        pos = e + 1
    end
    -- Remove only 0x-prefixed GUID tokens — never bare numbers (those are damage amounts)
    cleaned = string.gsub(cleaned, "%s*0[xX]%x%x%x%x%x%x%x%x+", "")
    return cleaned
end

local function RefreshGuidCacheFromUnits()
    if not SuperWoWAvailable() then return end
    local function scan(unit)
        if not UnitExists(unit) then return end
        local name = UnitName(unit)
        local guid = nil
        if type(UnitGUID) == "function" then
            guid = UnitGUID(unit)
        else
            -- SuperWoW: UnitExists returns GUID as 2nd value
            local ok, g = UnitExists(unit)
            if ok and g and type(g) == "string" and string.len(g) > 4 then
                guid = g
            end
        end
        if name and guid then
            CacheGuid(name, guid)
        end
        -- Pet
        local petUnit = unit
        if unit == "player" then
            petUnit = "pet"
        else
            local _, _, idx = string.find(unit, "^raid(%d+)$")
            if idx then
                petUnit = "raidpet" .. idx
            else
                local _, _, pidx = string.find(unit, "^party(%d+)$")
                if pidx then
                    petUnit = "partypet" .. pidx
                else
                    petUnit = nil
                end
            end
        end
        if petUnit and UnitExists(petUnit) then
            local pname = UnitName(petUnit)
            local pguid = nil
            if type(UnitGUID) == "function" then
                pguid = UnitGUID(petUnit)
            end
            if pname and pguid then
                CacheGuid(pname, pguid)
            end
            -- Ownership: map pet name to owner for ResolveSource
            if pname and name then
                OM.heuristicPets = OM.heuristicPets or {}
                OM.heuristicPets[pname] = name
            end
        end
    end
    scan("player")
    local i
    for i = 1, 4 do scan("party" .. i) end
    for i = 1, 40 do scan("raid" .. i) end
end

local function EnsurePlayer(segment, name)
    if not name or name == "" then return nil end
    local p = segment.players[name]
    if p then
        -- Refresh class from roster when known
        if OM.players and OM.players[name] and OM.players[name].class then
            p.class = OM.players[name].class
        end
        return p
    end
    local class = nil
    if OM.players and OM.players[name] then
        class = OM.players[name].class
    end
    p = {
        damage = 0,
        healing = 0,
        overhealing = 0,
        rawHealing = 0,
        absorbs = 0,
        damageTaken = 0,
        dispels = { count = 0, list = {} },
        interrupts = { count = 0, list = {} },
        ccBreaks = { count = 0, list = {} },
        deaths = { count = 0, list = {} },
        damageTakenBy = {},
        damageTo = {},
        healingTo = {},
        damageSpells = {},
        healSpells = {},
        damageSpellDetails = {},
        healSpellDetails = {},
        threatCasts = {},  -- non-damaging threat apps (Sunder, Demo Shout, ...)
        class = class,
    }
    segment.players[name] = p
    return p
end

-- Find a unit token for a player name (needed for health deficit / overheal)
local function FindUnitByName(name)
    if not name then return nil end
    if UnitName("player") == name then return "player" end
    for i = 1, 4 do
        local u = "party"..i
        if UnitExists(u) and UnitName(u) == name then return u end
    end
    if GetNumRaidMembers() > 0 then
        for i = 1, 40 do
            local u = "raid"..i
            if UnitExists(u) and UnitName(u) == name then return u end
        end
    end
    if UnitExists("target") and UnitName("target") == name then return "target" end
    if UnitExists("targettarget") and UnitName("targettarget") == name then return "targettarget" end
    return nil
end

-- Compute effective heal vs overheal using the target's current deficit
local function SplitOverheal(targetName, amount)
    amount = tonumber(amount) or 0
    if amount <= 0 then return 0, 0 end

    targetName = NormalizeName(targetName)
    local unit = FindUnitByName(targetName)
    if not unit then
        -- Unknown unit: count full amount as effective (avoid under-counting)
        return amount, 0
    end

    local maxhp = UnitHealthMax(unit)
    local curhp = UnitHealth(unit)
    if not maxhp or maxhp <= 0 then
        return amount, 0
    end

    local deficit = maxhp - curhp
    if deficit < 0 then deficit = 0 end

    local effective = amount
    local over = 0
    if amount > deficit then
        effective = deficit
        over = amount - deficit
    end
    return effective, over
end

local function ResolveSource(name)
    name = NormalizeName(name)
    if not name then return nil end

    -- Already a group player
    if OM.players[name] then
        return name
    end

    -- Pet → owner (roster, heuristic, or orphan assignment)
    local owner = OM:ResolvePetOwner(name)
    if owner then
        return owner
    end

    return name
end

local function IsTracked(name)
    if not name then return false end
    if OM.players[name] then return true end
    -- Known pet names only (unit-token / roster). Never invent ownership here.
    if OM:GetPetOwner(name) then return true end
    return false
end

-- ============================================================
-- Absorb shield tracking
-- Credits absorbed damage as healing to the shield provider when known.
-- ============================================================

local ABSORB_SHIELDS = {
    ["Power Word: Shield"] = true,
    ["Ice Barrier"] = true,
    ["Mana Shield"] = true,
    ["Sacrifice"] = true,
    ["Frost Ward"] = true,
    ["Fire Ward"] = true,
}

-- absorbAuras[targetName] = { [shieldName] = applicatorName }
local absorbAuras = {}
-- recentAbsorbCaster[spellName] = { name = "Caster", time = GetTime() }
local recentAbsorbCaster = {}
-- recentShieldByTarget[targetName] = { caster = "Caster", spell = "...", time = GetTime() }
local recentShieldByTarget = {}
local RECENT_CASTER_TIMEOUT = 8

local function IsAbsorbShield(spell)
    return SpellInSet(ABSORB_SHIELDS, spell)
end

local function NoteRecentAbsorbCaster(spell, caster, target)
    if not spell or not caster or not IsAbsorbShield(spell) then return end
    caster = NormalizeName(caster)
    recentAbsorbCaster[spell] = {
        name = caster,
        time = GetTime(),
    }
    target = NormalizeName(target)
    if target then
        recentShieldByTarget[target] = {
            caster = caster,
            spell = spell,
            time = GetTime(),
        }
    end
end

local function GetRecentAbsorbCaster(spell)
    if not spell then return nil end
    local entry = recentAbsorbCaster[spell]
    if not entry then
        for s, e in pairs(recentAbsorbCaster) do
            if string.find(spell, s, 1, true) or string.find(s, spell, 1, true) then
                entry = e
                break
            end
        end
    end
    if entry and (GetTime() - entry.time) <= RECENT_CASTER_TIMEOUT then
        return entry.name
    end
    return nil
end

local function SetAbsorbAura(target, spell, applicator)
    target = NormalizeName(target)
    applicator = NormalizeName(applicator)
    if not target or not spell or not applicator then return end
    if not absorbAuras[target] then
        absorbAuras[target] = {}
    end
    absorbAuras[target][spell] = applicator
end

local function ClearAbsorbAura(target, spell)
    target = NormalizeName(target)
    if not target or not absorbAuras[target] then return end
    if spell then
        for name, _ in pairs(absorbAuras[target]) do
            if name == spell or string.find(name, spell, 1, true) or string.find(spell, name, 1, true) then
                absorbAuras[target][name] = nil
            end
        end
        local empty = true
        for _ in pairs(absorbAuras[target]) do empty = false break end
        if empty then absorbAuras[target] = nil end
    else
        absorbAuras[target] = nil
    end
end

local function GetAbsorbApplicator(buffedUnit)
    buffedUnit = NormalizeName(buffedUnit)
    if not buffedUnit or not absorbAuras[buffedUnit] then return nil, nil end
    for spell, applicator in pairs(absorbAuras[buffedUnit]) do
        if applicator then
            return applicator, spell
        end
    end
    return nil, nil
end

-- ============================================================
-- Recording API
-- ============================================================

-- True when in a dungeon/raid instance (IsInInstance on most 1.12 private servers)
local function PlayerInInstance()
    if type(IsInInstance) == "function" then
        local inInstance = IsInInstance()
        return inInstance and true or false
    end
    return false
end

-- Average max HP of group members (party/raid). Falls back to the player alone.
local function GetGroupAverageMaxHP()
    local total, count = 0, 0
    ForEachGroupUnit(function(unit)
        if UnitExists(unit) and UnitIsConnected(unit) then
            local hp = UnitHealthMax(unit)
            if hp and hp > 0 then
                total = total + hp
                count = count + 1
            end
        end
    end)
    if count == 0 then
        return UnitHealthMax("player") or 1
    end
    return total / count
end

-- Average player level in the group (for level-gated elite checks)
local function GetGroupAverageLevel()
    local total, count = 0, 0
    ForEachGroupUnit(function(unit)
        if UnitExists(unit) and UnitIsConnected(unit) then
            local lvl = UnitLevel(unit)
            if lvl and lvl > 0 then
                total = total + lvl
                count = count + 1
            end
        end
    end)
    if count == 0 then return UnitLevel("player") or 1 end
    return total / count
end

local function IsUniqueEnemyName(name)
    if not name then return false end
    if fightDuplicateNames[name] then return false end
    local deaths = fightEnemyDeaths[name] or 0
    -- 2+ deaths of the same name = pack trash, not a unique boss
    if deaths >= 2 then return false end
    return true
end

local function MarkDuplicateName(name)
    if not name then return end
    fightDuplicateNames[name] = true
    -- If we had flagged this name as the boss, clear it
    if fightBossName == name then
        fightIsBoss = false
        fightBossName = nil
        -- Try to recover another unique boss candidate from enemies hit
        -- (left for combat-end / next elite hit)
    end
end

local function NoteEnemyDeath(name)
    name = NormalizeName(name)
    if not name or OM.players[name] then return end
    fightEnemyDeaths[name] = (fightEnemyDeaths[name] or 0) + 1
    if fightEnemyDeaths[name] >= 2 then
        MarkDuplicateName(name)
    end
end

local function UnitLooksLikeBoss(unit)
    if not unit or not UnitExists(unit) then return false end
    if UnitIsFriend("player", unit) then return false end

    local unitName = UnitName(unit)
    -- Pack trash shares names; bosses are unique within the fight
    if unitName and not IsUniqueEnemyName(unitName) then
        return false
    end

    local classification = UnitClassification(unit)
    local level = UnitLevel(unit)

    -- Raid / outdoor world bosses
    if classification == "worldboss" then return true end
    -- Skull (??) — typical when the boss is well above the group
    if level == -1 then return true end

    -- Leveling dungeon bosses: elite/rareelite with a real level, inside an instance
    if classification == "elite" or classification == "rareelite" then
        if PlayerInInstance() then
            local enemyHP = UnitHealthMax(unit) or 0
            local avgHP = GetGroupAverageMaxHP()
            if avgHP < 1 then avgHP = 1 end
            local avgLevel = GetGroupAverageLevel()

            -- Tanky elite relative to the group's average HP
            if enemyHP >= avgHP * 6 then
                return true
            end
            -- Near group level + meaningful HP pool (covers early dungeon bosses)
            if level > 0 and level >= (avgLevel - 3) and enemyHP >= avgHP * 3 then
                return true
            end
            -- Rare elites in instances are almost always notable (if unique)
            if classification == "rareelite" then
                return true
            end
        end
    end

    return false
end

local function NoteEnemyHit(enemyName, amount)
    enemyName = NormalizeName(enemyName)
    if not enemyName or OM.players[enemyName] then return end
    amount = tonumber(amount) or 0
    fightEnemies[enemyName] = (fightEnemies[enemyName] or 0) + amount

    -- Never promote non-unique names to boss
    if not IsUniqueEnemyName(enemyName) then
        return
    end

    local units = { "target", "targettarget", "pettarget", "mouseover" }
    for _, u in ipairs(units) do
        if UnitExists(u) and UnitName(u) == enemyName and UnitLooksLikeBoss(u) then
            fightIsBoss = true
            fightBossName = enemyName
            break
        end
    end
end

local function DeepCopyPlayerData(data)
    local p = {
        damage = data.damage or 0,
        healing = data.healing or 0,
        overhealing = data.overhealing or 0,
        rawHealing = data.rawHealing or 0,
        absorbs = data.absorbs or 0,
        damageTaken = data.damageTaken or 0,
        dispels = { count = 0, list = {} },
        interrupts = { count = 0, list = {} },
        ccBreaks = { count = 0, list = {} },
        deaths = { count = 0, list = {} },
        damageTakenBy = {},
        damageTo = {},
        healingTo = {},
        damageSpells = {},
        healSpells = {},
        damageSpellDetails = {},
        healSpellDetails = {},
        class = data.class,
        dpsSum = data.dpsSum or 0,
        dpsSamples = data.dpsSamples or 0,
        hpsSum = data.hpsSum or 0,
        hpsSamples = data.hpsSamples or 0,
    }
    if data.damageTo then
        for k, v in pairs(data.damageTo) do
            p.damageTo[k] = v
        end
    end
    if data.healingTo then
        for k, v in pairs(data.healingTo) do
            p.healingTo[k] = v
        end
    end
    if data.dispels then
        p.dispels.count = data.dispels.count or 0
        p.dispels.targets = {}
        if data.dispels.list then
            for i, v in ipairs(data.dispels.list) do
                p.dispels.list[i] = v
            end
        end
        if data.dispels.targets then
            for k, v in pairs(data.dispels.targets) do
                p.dispels.targets[k] = v
            end
        end
    end
    if data.interrupts then
        p.interrupts.count = data.interrupts.count or 0
        if data.interrupts.list then
            for i, v in ipairs(data.interrupts.list) do
                p.interrupts.list[i] = v
            end
        end
    end
    if data.ccBreaks then
        p.ccBreaks.count = data.ccBreaks.count or 0
        if data.ccBreaks.list then
            for i, v in ipairs(data.ccBreaks.list) do
                if type(v) == "table" then
                    p.ccBreaks.list[i] = { spell = v.spell, target = v.target }
                else
                    p.ccBreaks.list[i] = v
                end
            end
        end
    end
    if data.deaths then
        p.deaths.count = data.deaths.count or 0
        if data.deaths.list then
            for i, v in ipairs(data.deaths.list) do
                if type(v) == "table" then
                    p.deaths.list[i] = { killer = v.killer, spell = v.spell, amount = v.amount }
                else
                    p.deaths.list[i] = v
                end
            end
        end
    end
    if data.damageTakenBy then
        for k, v in pairs(data.damageTakenBy) do
            p.damageTakenBy[k] = v
        end
    end
    if data.damageSpells then
        for k, v in pairs(data.damageSpells) do
            p.damageSpells[k] = v
        end
    end
    if data.threatCasts then
        p.threatCasts = {}
        for k, v in pairs(data.threatCasts) do
            p.threatCasts[k] = v
        end
    end
    if data.healSpells then
        for k, v in pairs(data.healSpells) do
            p.healSpells[k] = v
        end
    end
    if data.damageSpellDetails then
        local spell, d
        for spell, d in pairs(data.damageSpellDetails) do
            if type(d) == "table" then
                local copy = {
                    hits = d.hits or 0, crits = d.crits or 0,
                    misses = d.misses or 0, glances = d.glances or 0,
                    resists = d.resists or 0, partials = d.partials or 0,
                    total = d.total or 0, count = d.count or 0,
                    min = d.min, max = d.max, byTarget = {},
                }
                if d.byTarget then
                    local tn, td
                    for tn, td in pairs(d.byTarget) do
                        if type(td) == "table" then
                            copy.byTarget[tn] = {
                                hits = td.hits or 0, crits = td.crits or 0,
                                misses = td.misses or 0, glances = td.glances or 0,
                                resists = td.resists or 0, partials = td.partials or 0,
                                total = td.total or 0, count = td.count or 0,
                                min = td.min, max = td.max,
                            }
                        end
                    end
                end
                p.damageSpellDetails[spell] = copy
            end
        end
    end
    if data.healSpellDetails then
        local spell, d
        for spell, d in pairs(data.healSpellDetails) do
            if type(d) == "table" then
                local copy = {
                    hits = d.hits or 0, crits = d.crits or 0,
                    misses = d.misses or 0, glances = d.glances or 0,
                    resists = d.resists or 0, partials = d.partials or 0,
                    total = d.total or 0, count = d.count or 0,
                    min = d.min, max = d.max, byTarget = {},
                }
                if d.byTarget then
                    local tn, td
                    for tn, td in pairs(d.byTarget) do
                        if type(td) == "table" then
                            copy.byTarget[tn] = {
                                hits = td.hits or 0, crits = td.crits or 0,
                                misses = td.misses or 0, glances = td.glances or 0,
                                resists = td.resists or 0, partials = td.partials or 0,
                                total = td.total or 0, count = td.count or 0,
                                min = td.min, max = td.max,
                            }
                        end
                    end
                end
                p.healSpellDetails[spell] = copy
            end
        end
    end
    return p
end

local function SnapshotSegment(seg)
    local players = {}
    if seg and seg.players then
        for name, data in pairs(seg.players) do
            players[name] = DeepCopyPlayerData(data)
        end
    end
    local ccTargets = {}
    if seg and seg.ccTargets then
        for enemy, data in pairs(seg.ccTargets) do
            local entry = { count = data.count or 0, duration = data.duration or 0, list = {} }
            if data.list then
                local i, v
                for i, v in ipairs(data.list) do
                    if type(v) == "table" then
                        entry.list[i] = { spell = v.spell, duration = v.duration }
                    end
                end
            end
            ccTargets[enemy] = entry
        end
    end
    return {
        players = players,
        ccTargets = ccTargets,
        startTime = seg and seg.startTime or 0,
        endTime = seg and seg.endTime or 0,
        label = seg and seg.label or "Fight",
        isBoss = seg and seg.isBoss or false,
        duration = seg and seg.duration or 0,
    }
end

local function PickFightLabel()
    if fightBossName then
        return fightBossName
    end
    local bestName, bestDmg = nil, -1
    for name, dmg in pairs(fightEnemies) do
        if dmg > bestDmg then
            bestDmg = dmg
            bestName = name
        end
    end
    if bestName then return bestName end
    return "Fight"
end

local function PushFront(list, entry, maxCount)
    table.insert(list, 1, entry)
    while table.getn(list) > maxCount do
        table.remove(list)
    end
end

-- Append then drop oldest when over the soft cap (chronological history).
local function PushCapped(list, entry, maxCount)
    table.insert(list, entry)
    while table.getn(list) > maxCount do
        table.remove(list, 1)
    end
end

-- Last damage dealt TO a unit (for CC break attribution + death killing blow)
-- lastHitOn[target] = { source, spell, amount, time }
local lastHitOn = {}

local function NoteLastHit(target, source, spell, amount)
    target = NormalizeName(target)
    source = NormalizeName(source)
    if not target then return end
    lastHitOn[target] = {
        source = source or "Unknown",
        spell = spell or "Melee",
        amount = amount or 0,
        time = GetTime(),
    }
end

-- Stamp last combat activity on the current segment (for trailing-idle duration trim)
local function NoteActivity()
    if OM.data and OM.data.current then
        OM.data.current.lastActivityTime = GetTime()
    end
end

-- Abilities that generate threat with little or no damage component.
-- Counted from cast/perform combat-log lines for estimate use.
local THREAT_CAST_ABILITIES = {
    ["Sunder Armor"] = true,
    ["Demoralizing Shout"] = true,
    ["Demoralizing Roar"] = true,
    ["Faerie Fire"] = true,
    ["Faerie Fire (Feral)"] = true,
    ["Hamstring"] = true,
    -- Pet / minion high-threat abilities (1.12)
    ["Growl"] = true,          -- hunter pet
    ["Intimidation"] = true,   -- hunter BM talent (threat on pet)
    ["Torment"] = true,        -- voidwalker
    ["Suffering"] = true,      -- voidwalker AoE threat
}

local function IsThreatCastAbility(spell)
    if not spell then return false end
    if THREAT_CAST_ABILITIES[spell] then return true end
    local k
    for k in pairs(THREAT_CAST_ABILITIES) do
        if string.find(spell, k, 1, true) then
            return true
        end
    end
    return false
end

function Parser:AddThreatCast(source, spell)
    if not source or not spell then return end
    if not IsThreatCastAbility(spell) then return end
    source = ResolveSource(source)
    if not source then return end
    if not IsTracked(source) and not (OM.players and OM.players[source]) then return end

    local function apply(seg)
        if not seg then return end
        local p = EnsurePlayer(seg, source)
        if not p then return end
        if not p.threatCasts then p.threatCasts = {} end
        p.threatCasts[spell] = (p.threatCasts[spell] or 0) + 1
    end
    apply(OM.data and OM.data.current)
    apply(OM.data and OM.data.overall)
end

local function EmptyOutcomeBucket()
    return {
        hits = 0, crits = 0, misses = 0, glances = 0,
        resists = 0, partials = 0,
        total = 0, count = 0, min = nil, max = nil,
    }
end

local function ApplyOutcomeToBucket(s, amount, hitType, partialFlag)
    if not s then return end
    if hitType == "miss" then
        s.misses = (s.misses or 0) + 1
        return
    elseif hitType == "resist" then
        s.resists = (s.resists or 0) + 1
        return
    elseif hitType == "crit" then
        s.crits = (s.crits or 0) + 1
    elseif hitType == "glance" then
        s.glances = (s.glances or 0) + 1
    else
        s.hits = (s.hits or 0) + 1
    end
    if partialFlag then
        s.partials = (s.partials or 0) + 1
    end
    amount = tonumber(amount) or 0
    if amount > 0 then
        s.total = (s.total or 0) + amount
        s.count = (s.count or 0) + 1
        if s.min == nil or amount < s.min then s.min = amount end
        if s.max == nil or amount > s.max then s.max = amount end
    end
end

local function NoteSpellOutcome(p, spell, amount, hitType, isHeal, target, partialFlag)
    if not p or not spell or spell == "" then return end
    hitType = hitType or "hit"
    local bagName = isHeal and "healSpellDetails" or "damageSpellDetails"
    if not p[bagName] then p[bagName] = {} end
    local s = p[bagName][spell]
    if not s then
        s = EmptyOutcomeBucket()
        s.byTarget = {}
        p[bagName][spell] = s
    end
    if not s.byTarget then s.byTarget = {} end
    ApplyOutcomeToBucket(s, amount, hitType, partialFlag)
    if target and target ~= "" then
        local ts = s.byTarget[target]
        if not ts then
            ts = EmptyOutcomeBucket()
            s.byTarget[target] = ts
        end
        ApplyOutcomeToBucket(ts, amount, hitType, partialFlag)
    end
end

function Parser:AddDamage(source, amount, spell, target, hitType, partialFlag)
    -- Detect pet contribution before ResolveSource merges onto owner.
    -- Only mark as pet when ownership is already known from unit tokens /
    -- SuperWoW "Pet (Owner)" form — never invent a pet for random names.
    local isPet = false
    if source then
        if string.find(source, " %(.+%)$") then
            isPet = true
        else
            local raw = source
            if raw ~= "You" and raw ~= "you" then
                if OM.GetPetOwner and OM:GetPetOwner(raw) then
                    isPet = true
                elseif OM.heuristicPets and OM.heuristicPets[raw] then
                    isPet = true
                end
            end
        end
    end

    source = ResolveSource(source)
    if not source or not amount or amount <= 0 then return end
    -- Only record damage from tracked group members (pets resolve to owners above)
    if not OM.players[source] then
        return
    end

    if isPet then
        if OM.GetSetting and OM:GetSetting("mergePetDamage") then
            spell = "Pet: Damage"
        else
            if not spell or spell == "" then
                spell = "Auto Attack"
            end
            if string.sub(spell, 1, 5) ~= "Pet: " then
                spell = "Pet: " .. spell
            end
        end
    end

    target = NormalizeName(target)

    if ModeEnabled("damage") then
        local p = EnsurePlayer(OM.data.current, source)
        if p then
            p.damage = p.damage + amount
            if spell then
                p.damageSpells[spell] = (p.damageSpells[spell] or 0) + amount
                NoteSpellOutcome(p, spell, amount, hitType or "hit", false, target, partialFlag)
            end
            if target then
                p.damageTo[target] = (p.damageTo[target] or 0) + amount
                NoteLastHit(target, source, spell, amount)
            end
        end

        local o = EnsurePlayer(OM.data.overall, source)
        if o then
            o.damage = o.damage + amount
            if spell then
                o.damageSpells[spell] = (o.damageSpells[spell] or 0) + amount
                NoteSpellOutcome(o, spell, amount, hitType or "hit", false, target, partialFlag)
            end
            if target then
                o.damageTo[target] = (o.damageTo[target] or 0) + amount
            end
        end
    elseif target then
        -- Still track last-hit for death tooltips even when damage mode is off
        NoteLastHit(target, source, spell, amount)
    end
    -- Interrupt abilities: combat log rarely reports "interrupted X"; count uses instead
    if ModeEnabled("interrupts") and spell and Parser.IsInterruptAbility and Parser.IsInterruptAbility(spell) then
        Parser:AddInterrupt(source, spell)
    end
    -- Breakable CC: first damage to a CC'd target credits the breaker
    if ModeEnabled("ccbreak") and target and Parser.NoteBreakableCCDamage then
        Parser.NoteBreakableCCDamage(target, source, spell)
    end
    NoteActivity()
end

-- amount = full heal from the log
-- healing field stores EFFECTIVE healing (amount - overheal)
-- overhealing tracked separately for later tooltip %
function Parser:AddMiss(source, spell, target)
    source = ResolveSource(source)
    if not source then return end
    if not OM.players[source] and not IsTracked(source) then return end
    spell = spell or "Auto Attack"
    target = NormalizeName(target)
    local function apply(seg)
        if not seg then return end
        local p = EnsurePlayer(seg, source)
        if p then
            NoteSpellOutcome(p, spell, 0, "miss", false, target, false)
        end
    end
    apply(OM.data and OM.data.current)
    apply(OM.data and OM.data.overall)
end

function Parser:AddResist(source, spell, target)
    source = ResolveSource(source)
    if not source then return end
    if not OM.players[source] and not IsTracked(source) then return end
    spell = spell or "Unknown"
    target = NormalizeName(target)
    local function apply(seg)
        if not seg then return end
        local p = EnsurePlayer(seg, source)
        if p then
            NoteSpellOutcome(p, spell, 0, "resist", false, target, false)
        end
    end
    apply(OM.data and OM.data.current)
    apply(OM.data and OM.data.overall)
end

function Parser:AddHealing(source, amount, spell, isAbsorb, target, hitType)
    if not ModeEnabled("healing") then return end
    source = ResolveSource(source)
    if not source or not amount or amount <= 0 then return end
    if not IsTracked(source) and not OM.players[source] then return end

    local effective, over = amount, 0

    if isAbsorb then
        -- Absorbs are always fully "effective" (damage prevented)
        effective, over = amount, 0
    else
        effective, over = SplitOverheal(target, amount)
    end

    local healTarget = NormalizeName(target)

    local function apply(seg)
        local p = EnsurePlayer(seg, source)
        if not p then return end
        p.rawHealing = (p.rawHealing or 0) + amount
        p.overhealing = (p.overhealing or 0) + over
        local credited = isAbsorb and amount or effective
        if isAbsorb then
            p.absorbs = (p.absorbs or 0) + amount
            p.healing = (p.healing or 0) + amount -- absorbs add to effective total
        else
            p.healing = (p.healing or 0) + effective
        end
        if spell then
            p.healSpells[spell] = (p.healSpells[spell] or 0) + credited
            NoteSpellOutcome(p, spell, credited, hitType or "hit", true, healTarget, false)
        end
        if healTarget and credited > 0 then
            p.healingTo[healTarget] = (p.healingTo[healTarget] or 0) + credited
        end
    end

    apply(OM.data.current)
    apply(OM.data.overall)
    NoteActivity()
end

function Parser:AddDamageTaken(target, amount, source, spell)
    if not ModeEnabled("taken") then return end
    target = NormalizeName(target)
    if not target or not amount or amount <= 0 then return end
    if not OM.players[target] then return end -- only track damage taken by our group

    source = NormalizeName(source) or "Unknown"
    NoteLastHit(target, source, spell, amount)

    local p = EnsurePlayer(OM.data.current, target)
    if p then
        p.damageTaken = p.damageTaken + amount
        p.damageTakenBy[source] = (p.damageTakenBy[source] or 0) + amount
    end

    local o = EnsurePlayer(OM.data.overall, target)
    if o then
        o.damageTaken = o.damageTaken + amount
        o.damageTakenBy[source] = (o.damageTakenBy[source] or 0) + amount
    end
end

function Parser:AddDispel(source, what, target)
    if not ModeEnabled("dispels") then return end
    source = ResolveSource(source)
    if not source then return end
    -- Prefer group members; still allow if we somehow see it
    if not IsTracked(source) and not OM.players[source] then return end
    what = what or "Unknown"
    target = NormalizeName(target)

    local function apply(seg)
        local p = EnsurePlayer(seg, source)
        if not p then return end
        p.dispels.count = p.dispels.count + 1
        PushCapped(p.dispels.list, what, MAX_DETAIL_LIST)
        if not p.dispels.targets then
            p.dispels.targets = {}
        end
        if target and target ~= "" then
            p.dispels.targets[target] = (p.dispels.targets[target] or 0) + 1
        end
    end
    apply(OM.data.current)
    apply(OM.data.overall)
end

function Parser:AddInterrupt(source, what)
    if not ModeEnabled("interrupts") then return end
    source = ResolveSource(source)
    if not source then return end
    if not IsTracked(source) and not OM.players[source] then return end
    local p = EnsurePlayer(OM.data.current, source)
    if p then
        p.interrupts.count = p.interrupts.count + 1
        PushCapped(p.interrupts.list, what or "Unknown", MAX_DETAIL_LIST)
    end
    local o = EnsurePlayer(OM.data.overall, source)
    if o then
        o.interrupts.count = o.interrupts.count + 1
        PushCapped(o.interrupts.list, what or "Unknown", MAX_DETAIL_LIST)
    end
end

-- ============================================================
-- CC tracking (enemy-centric) + breakable CC breaks (player-centric)
-- Combat log usually says "Enemy is afflicted by Sap" with no caster.
-- We list enemies that were CC'd and estimate full duration.
-- Breakable CCs (Sap/Gouge/Blind/Poly/Frost Trap): first damage to the
-- target after the CC is applied credits the breaker.
-- ============================================================

-- Breakable (damage-breakable) hard CCs
local BREAKABLE_CC = {
    ["Sap"] = true,
    ["Gouge"] = true,
    ["Blind"] = true,
    ["Polymorph"] = true,
    ["Polymorph: Pig"] = true,
    ["Polymorph: Turtle"] = true,
    ["Freezing Trap Effect"] = true,
    ["Freezing Trap"] = true,
    ["Hibernate"] = true,
    ["Shackle Undead"] = true,
    ["Wyvern Sting"] = true,
    ["Seduction"] = true,
    ["Scare Beast"] = true,
}

-- activeBreakable[target] = { spell = "...", time = GetTime() }
local activeBreakable = {}

local function IsBreakableCC(spell)
    return SpellInSet(BREAKABLE_CC, spell)
end

local function EnsureCCTargets(seg)
    if not seg.ccTargets then
        seg.ccTargets = {}
    end
    return seg.ccTargets
end

local function EnsureCCTargetEntry(seg, enemy)
    local t = EnsureCCTargets(seg)
    if not t[enemy] then
        t[enemy] = { count = 0, duration = 0, list = {} }
    end
    return t[enemy]
end

-- Record that an enemy was CC'd (no caster required). Duration = estimate.
function Parser:AddEnemyCC(spell, target, maxDuration)
    if not ModeEnabled("cc") then return end
    target = NormalizeName(target)
    if not target or target == "" then return end
    -- Don't track our own group as CC targets in this mode
    if OM.players and OM.players[target] then return end

    spell = spell or "Unknown"
    maxDuration = tonumber(maxDuration) or 0
    if maxDuration < 0 then maxDuration = 0 end

    local function apply(seg)
        local e = EnsureCCTargetEntry(seg, target)
        e.count = e.count + 1
        e.duration = (e.duration or 0) + maxDuration
        PushCapped(e.list, { spell = spell, duration = maxDuration }, MAX_DETAIL_LIST)
    end
    apply(OM.data.current)
    apply(OM.data.overall)

    if IsBreakableCC(spell) then
        activeBreakable[target] = { spell = spell, time = GetTime() }
    end
end

-- First damage to a breakable-CC'd target → credit the breaker
local function NoteBreakableCCDamage(target, source, spell)
    target = NormalizeName(target)
    if not target then return end
    local entry = activeBreakable[target]
    if not entry then return end
    -- Ignore tiny window noise right as CC is applied
    if entry.time and (GetTime() - entry.time) < 0.15 then return end
    activeBreakable[target] = nil
    Parser:AddCCBreak(source, entry.spell, target)
end
Parser.NoteBreakableCCDamage = NoteBreakableCCDamage

function Parser:FinishCC(target, spell)
    target = NormalizeName(target)
    if target then
        activeBreakable[target] = nil
    end
end

function Parser:FlushActiveCCs()
    activeBreakable = {}
end

function Parser:AddCCBreak(breaker, ccSpell, target)
    if not ModeEnabled("ccbreak") then return end
    breaker = ResolveSource(breaker)
    if not breaker then return end
    if not IsTracked(breaker) and not OM.players[breaker] then return end
    ccSpell = ccSpell or "CC"
    target = NormalizeName(target) or "?"

    local p = EnsurePlayer(OM.data.current, breaker)
    if p then
        p.ccBreaks.count = p.ccBreaks.count + 1
        PushCapped(p.ccBreaks.list, { spell = ccSpell, target = target }, MAX_DETAIL_LIST)
    end
    local o = EnsurePlayer(OM.data.overall, breaker)
    if o then
        o.ccBreaks.count = o.ccBreaks.count + 1
        PushCapped(o.ccBreaks.list, { spell = ccSpell, target = target }, MAX_DETAIL_LIST)
    end
end


function Parser:AddDeath(name, lastHit)
    if not ModeEnabled("deaths") then return end
    name = NormalizeName(name)
    if not name then return end
    if not OM.players[name] and name ~= (playerName or UnitName("player")) then
        return
    end

    local killer, spell, amount = "?", "?", 0
    if type(lastHit) == "table" then
        killer = lastHit.source or lastHit.killer or "?"
        spell = lastHit.spell or "?"
        amount = tonumber(lastHit.amount) or 0
    end

    local function apply(seg)
        local p = EnsurePlayer(seg, name)
        if not p then return end
        p.deaths.count = (p.deaths.count or 0) + 1
        if not p.deaths.list then p.deaths.list = {} end
        PushCapped(p.deaths.list, {
            killer = killer,
            spell = spell,
            amount = amount,
        }, MAX_DEATHS_LIST)
    end
    apply(OM.data.current)
    apply(OM.data.overall)
end

-- ============================================================
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
    return d.source(), spell, target, value, school, "damage"
end
combatlog_parser[PERIODICAURADAMAGEOTHEROTHER] = function(d, target, value, school, source, spell)
    -- %s suffers %d %s damage from %s's %s.
    return source, spell, target, value, school, "damage"
end
combatlog_parser[PERIODICAURADAMAGESELFSELF] = function(d, value, school, spell)
    -- You suffer %d %s damage from your %s.
    return d.source(), spell, d.target(), value, school, "damage"
end
combatlog_parser[PERIODICAURADAMAGEOTHERSELF] = function(d, value, school, source, spell)
    -- You suffer %d %s damage from %s's %s.
    return source, spell, d.target(), value, school, "taken"
end

-- ---------- Damage shields / reflection (Thorns, Retribution, etc.) ----------
-- Source here is the buffed unit. We re-attribute to the applicator in ParseMessage.
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
        if heals[a] == heals[b] then return a < b end
        return heals[a] > heals[b]
    end)
    local top = priests[1]
    local second = priests[2]
    local topShare = heals[top] / total
    local secondShare = heals[second] / total
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
        if recentShieldByTarget and recentShieldByTarget[target] then
            local entry = recentShieldByTarget[target]
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

-- Periodic / multi-tick cleanses. These apply a lasting effect that can remove
-- multiple diseases/poisons over time. For them we ONLY credit direct combat-log
-- lines that explicitly name the ability as the remover (e.g. "X's Abolish Disease
-- removes Y from Z"). We never pair their cast with nearby "effect fades" messages,
-- because the removals can happen long after the cast and the fades are unreliable
-- for attribution.
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

-- Dispel matching: combat log order is unreliable. The fade line can appear
-- before or after "X casts Purify". Keep short buffers of both and pair them
-- carefully so natural expirations are not counted as dispels.
--
-- Rules for cast↔fade pairing:
--   1. Only pair fades of auras we previously saw applied as harmful
--      ("X is afflicted by SPELL"). Friendly buffs / unknown fades are ignored.
--   2. If the cast names a target, the fade must be on that same target.
--   3. Direct "X removes Y from Z" lines always win and suppress nearby pairing.
--
-- Exception: PERIODIC_DISPEL_SPELLS (Abolish Disease/Poison, cleansing totems)
-- never enter the cast↔fade pairing path. Their removals are only credited when
-- the combat log explicitly names the ability as the remover.
local PENDING_DISPEL_WINDOW = 1.25  -- others' cast↔fade lines can be farther apart than self "You remove"
local HARMFUL_AURA_TTL = 180  -- remember afflictions this long for fade matching
local recentDispelFades = {}  -- { { spell, target, time }, ... }
local pendingDispelCasts = {} -- { { caster, target, time, spell }, ... }
local lastDispelCastKey = nil -- "caster|spell" for de-dupe
local lastDispelCastTime = 0
local directDispelSuppressUntil = 0 -- ignore fade pairing briefly after a direct remove
-- recentHarmfulAuras[targetName][spellName] = lastApplyTime
local recentHarmfulAuras = {}

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
    if not recentHarmfulAuras[target] then
        recentHarmfulAuras[target] = {}
    end
    recentHarmfulAuras[target][spell] = GetTime()
end

local function ClearHarmfulAura(target, spell)
    target = NormalizeName(target)
    if not target or not recentHarmfulAuras[target] then return end
    if spell then
        recentHarmfulAuras[target][spell] = nil
    else
        recentHarmfulAuras[target] = nil
    end
end

-- True if we saw this unit afflicted by this spell recently (and it was not friendly).
local function IsTrackedHarmfulAura(target, spell)
    target = NormalizeName(target)
    if not target or not spell or spell == "" then return false end
    if IsFriendlyAura(spell) then return false end
    local byTarget = recentHarmfulAuras[target]
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
    for target, spells in pairs(recentHarmfulAuras) do
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
            recentHarmfulAuras[target] = nil
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
    -- dispels work when we never saw the original affliction line.
    local bestIdx, bestScore = nil, nil
    local i, fade
    for i, fade in ipairs(recentDispelFades) do
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
    for i, cast in ipairs(pendingDispelCasts) do
        local score = DispelPairScore(cast.time, cast.target, now, target)
        if score then
            -- If the cast named a target and it matches this fade, trust it
            -- even when we never saw the original "afflicted by" line.
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
    if string.find(lower, "interrupt", 1, true) then
        if ParseInterruptMessage(message) then return true end
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
        local dur = GetHardCCDuration(selfSpell)
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
        local dur = GetHardCCDuration(spell)
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
        local dur = GetHardCCDuration(spell2)
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
            local dur = GetHardCCDuration(spell3)
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
        local dur = GetHardCCDuration(spell4)
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
local recentAbsorbCredits = {} -- [ "unit|amount" ] = GetTime()
local ABSORB_DEDUPE_WINDOW = 0.2

local function CreditAbsorb(buffedUnit, amount, shieldName)
    amount = tonumber(amount)
    if not amount or amount <= 0 then return end
    buffedUnit = NormalizeName(buffedUnit) or buffedUnit

    local now = GetTime()
    local dedupeKey = tostring(buffedUnit) .. "|" .. tostring(amount)
    local last = recentAbsorbCredits[dedupeKey]
    if last and (now - last) < ABSORB_DEDUPE_WINDOW then
        return
    end
    recentAbsorbCredits[dedupeKey] = now
    -- Occasional prune
    if math.mod(math.floor(now * 5), 25) == 0 then
        local k, ts
        for k, ts in pairs(recentAbsorbCredits) do
            if (now - ts) > 1 then
                recentAbsorbCredits[k] = nil
            end
        end
    end

    local applicator, spell = GetAbsorbApplicator(buffedUnit)

    -- Prefer recent cast aimed at this unit (name + caster)
    if recentShieldByTarget and recentShieldByTarget[buffedUnit] then
        local entry = recentShieldByTarget[buffedUnit]
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
    if (not label or label == "" or label == "Absorb") and absorbAuras[buffedUnit] then
        -- Prefer Power Word: Shield when present, else any active shield on the unit
        if absorbAuras[buffedUnit]["Power Word: Shield"] then
            label = "Power Word: Shield"
            if not applicator then
                applicator = absorbAuras[buffedUnit]["Power Word: Shield"]
            end
        else
            local s, app
            for s, app in pairs(absorbAuras[buffedUnit]) do
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
        Parser:AddDeath(name, lastHitOn[name])
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
        Parser:AddResist(playerName, spell, target)
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

    local src, spell, target, amt

    -- "You miss TARGET."
    _, _, target = string.find(message, "^You miss (.+)%.?$")
    if target then
        Parser:AddMiss(playerName, "Auto Attack", target)
        return true
    end
    -- "Your SPELL misses TARGET."
    _, _, spell, target = string.find(message, "^Your (.+) misses (.+)%.?$")
    if spell and target then
        Parser:AddMiss(playerName, spell, target)
        return true
    end
    -- "SOURCE misses TARGET."
    _, _, src, target = string.find(message, "^(.+) misses (.+)%.?$")
    if src and target and src ~= "You" then
        Parser:AddMiss(src, "Auto Attack", target)
        return true
    end
    -- "SOURCE's SPELL misses TARGET."
    _, _, src, spell, target = string.find(message, "^(.+)'s (.+) misses (.+)%.?$")
    if src and spell and target then
        Parser:AddMiss(src, spell, target)
        return true
    end

    -- Vanilla melee avoid forms:
    -- "You attack. TARGET dodges." / parries / blocks
    _, _, target = string.find(message, "^You attack%. (.+) dodges%.?$")
    if target then
        Parser:AddMiss(playerName, "Auto Attack", target)
        return true
    end
    _, _, target = string.find(message, "^You attack%. (.+) parries%.?$")
    if target then
        Parser:AddMiss(playerName, "Auto Attack", target)
        return true
    end
    _, _, target = string.find(message, "^You attack%. (.+) blocks%.?$")
    if target then
        Parser:AddMiss(playerName, "Auto Attack", target)
        return true
    end
    -- "Your attack. TARGET dodges." (client variant)
    _, _, target = string.find(message, "^Your attack%. (.+) dodges%.?$")
    if target then
        Parser:AddMiss(playerName, "Auto Attack", target)
        return true
    end
    _, _, target = string.find(message, "^Your attack%. (.+) parries%.?$")
    if target then
        Parser:AddMiss(playerName, "Auto Attack", target)
        return true
    end
    _, _, target = string.find(message, "^Your attack%. (.+) blocks%.?$")
    if target then
        Parser:AddMiss(playerName, "Auto Attack", target)
        return true
    end
    -- "SOURCE attacks. TARGET dodges."
    _, _, src, target = string.find(message, "^(.+) attacks%. (.+) dodges%.?$")
    if src and target and src ~= "You" then
        Parser:AddMiss(src, "Auto Attack", target)
        return true
    end
    _, _, src, target = string.find(message, "^(.+) attacks%. (.+) parries%.?$")
    if src and target and src ~= "You" then
        Parser:AddMiss(src, "Auto Attack", target)
        return true
    end
    _, _, src, target = string.find(message, "^(.+) attacks%. (.+) blocks%.?$")
    if src and target and src ~= "You" then
        Parser:AddMiss(src, "Auto Attack", target)
        return true
    end

    -- "Your SPELL was dodged/parried/blocked by TARGET."
    _, _, spell, target = string.find(message, "^Your (.+) was dodged by (.+)%.?$")
    if spell and target then
        Parser:AddMiss(playerName, spell, target)
        return true
    end
    _, _, spell, target = string.find(message, "^Your (.+) was parried by (.+)%.?$")
    if spell and target then
        Parser:AddMiss(playerName, spell, target)
        return true
    end
    _, _, spell, target = string.find(message, "^Your (.+) was blocked by (.+)%.?$")
    if spell and target then
        Parser:AddMiss(playerName, spell, target)
        return true
    end
    _, _, src, spell, target = string.find(message, "^(.+)'s (.+) was dodged by (.+)%.?$")
    if src and spell and target then
        Parser:AddMiss(src, spell, target)
        return true
    end
    _, _, src, spell, target = string.find(message, "^(.+)'s (.+) was parried by (.+)%.?$")
    if src and spell and target then
        Parser:AddMiss(src, spell, target)
        return true
    end
    _, _, src, spell, target = string.find(message, "^(.+)'s (.+) was blocked by (.+)%.?$")
    if src and spell and target then
        Parser:AddMiss(src, spell, target)
        return true
    end

    -- Rare "You glance TARGET for N" form (most clients use hit + (glancing) trailer)
    _, _, target, amt = string.find(message, "^You glance (.+) for (%d+)")
    if target and amt then
        Parser:AddDamage(playerName, tonumber(amt), "Auto Attack", NormalizeName(target), "glance")
        return true
    end
    _, _, src, target, amt = string.find(message, "^(.+) glances (.+) for (%d+)")
    if src and target and amt and src ~= "You" then
        Parser:AddDamage(src, tonumber(amt), "Auto Attack", NormalizeName(target), "glance")
        return true
    end
    return false
end

local function ParseMessage(event, message)
    if not message or message == "" then return end

    -- Full resists (before miss path)
    if string.find(message, "resist", 1, true) or string.find(message, "Resist", 1, true) then
        if ParseResistMessage(message) then
            return
        end
    end

    -- Misses / dodges / glancing (before generic ignore paths)
    if string.find(message, "miss", 1, true)
    or string.find(message, "Miss", 1, true)
    or string.find(message, "dodge", 1, true)
    or string.find(message, "Dodge", 1, true)
    or string.find(message, "parry", 1, true)
    or string.find(message, "Parry", 1, true)
    or string.find(message, "block", 1, true)
    or string.find(message, "glance", 1, true)
    or string.find(message, "Glance", 1, true) then
        if ParseMissMessage(message) then
            return
        end
    end

    -- Hostile deaths (unique-name boss detection)
    if event == "CHAT_MSG_COMBAT_HOSTILE_DEATH"
    or event == "CHAT_MSG_COMBAT_FRIENDLY_DEATH"
    or string.find(message, " dies", 1, true)
    or string.find(message, "You die", 1, true)
    or string.find(message, "you die", 1, true) then
        if ParseEnemyDeath(message) then
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
        if ParseInterruptOrDispel(event, message) then
            return
        end
    end

    -- Hard CC applications / fades
    if string.find(message, "afflicted by", 1, true)
    or string.find(message, "fades from", 1, true)
    or string.find(message, "is afflicted", 1, true) then
        if ParseHardCC(event, message) then
            return
        end
    end

    -- HoT ticks: always credit the caster named in "from X's Spell"
    if string.find(message, "health from", 1, true)
    or string.find(message, "hit points from", 1, true) then
        if ParsePeriodicHealMessage(message) then
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
        if ParseShieldCastMessage(message) then
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
            Parser:AddThreatCast(playerName, spell)
        else
            _, _, spell = string.find(message, "^You cast (.+) on ")
            if spell then
                Parser:AddThreatCast(playerName, spell)
            else
                _, _, spell = string.find(message, "^You cast (.+)%.?$")
                if spell then
                    Parser:AddThreatCast(playerName, spell)
                else
                    _, _, src, spell = string.find(message, "^(.+) performs (.+) on ")
                    if src and spell then
                        Parser:AddThreatCast(src, spell)
                    else
                        _, _, src, spell = string.find(message, "^(.+) casts (.+) on ")
                        if src and spell then
                            Parser:AddThreatCast(src, spell)
                        else
                            _, _, src, spell = string.find(message, "^(.+) casts (.+)%.?$")
                            if src and spell then
                                Parser:AddThreatCast(src, spell)
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
        if ParseReflectMessage(message) then
            return
        end
    end

    -- Standalone absorb messages
    if string.find(message, "absorb", 1, true) or string.find(message, "Absorb", 1, true) then
        if ParseAbsorbMessage(message) then
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
        ParseAuraMessage(event, message)
        -- Continue: some of these events also carry heal patterns
    end

    -- Strip absorb / partial-resist / glancing trailers so patterns match
    local absorbFromTrailer = nil
    local resistFromTrailer = nil
    local glanceFromTrailer = false
    if string.find(message, "%([Gg]lancing%)") then
        glanceFromTrailer = true
        message = string.gsub(message, "%s*%([Gg]lancing%)", "")
    end
    message, absorbFromTrailer = ExtractAbsorbTrailer(message)
    message, resistFromTrailer = ExtractResistTrailer(message)

    local patterns = combatlog_events[event]
    if not patterns then
        -- Unknown / SuperWoW event name: still try the full combat pattern set
        patterns = FALLBACK_COMBAT_PATTERNS
    end
    if not patterns or table.getn(patterns) == 0 then
        if absorbFromTrailer and absorbFromTrailer > 0 then
            local absorbTarget = playerName
            if event and string.find(event, "SELF", 1, true) then
                absorbTarget = playerName
            end
            CreditAbsorb(absorbTarget, absorbFromTrailer, "Absorb")
        end
        return
    end

    for _, pattern in ipairs(patterns) do
        local handler = combatlog_parser[pattern]
        if handler then
            local regex = sanitize(pattern)
            if regex then
                local found = string.find(message, regex)
                if found then
                    local _, _, c1, c2, c3, c4, c5 = string.find(message, regex)
                    local source, spell, target, amount, school, dtype =
                        handler(defaults, c1, c2, c3, c4, c5)

                    amount = tonumber(amount)

                    -- Absorb trailer: the unit who actually took the hit absorbed part of it.
                    -- For normal damage/taken → target (or self).
                    -- For reflection → the unit the damage was reflected *onto*.
                    if absorbFromTrailer and absorbFromTrailer > 0 then
                        local absTarget = nil
                        if dtype == "reflect" then
                            absTarget = target -- reflected damage absorbed by the attacker
                        elseif dtype == "reflect_taken" then
                            absTarget = target or playerName -- we absorbed their reflection
                        elseif dtype == "taken" then
                            absTarget = target or playerName
                        elseif dtype == "damage" then
                            absTarget = target
                        end
                        if absTarget then
                            CreditAbsorb(absTarget, absorbFromTrailer, "Absorb")
                        end
                    end

                    local hitType = "hit"
                    if pattern and string.find(tostring(pattern), "CRIT", 1, true) then
                        hitType = "crit"
                    elseif pattern and string.find(tostring(pattern), "GLANCING", 1, true) then
                        hitType = "glance"
                    elseif glanceFromTrailer then
                        hitType = "glance"
                    end

                    if amount and amount > 0 and source then
                        if dtype == "damage" then
                            local resolvedSource = ResolveSource(source)
                            local tname = target and NormalizeName(target) or nil
                            -- Self-inflicted (Bloodrage, Life Tap, etc.): taken only, not damage done
                            local selfHarm = false
                            if resolvedSource and tname and resolvedSource == tname then
                                selfHarm = true
                            end
                            if not selfHarm then
                                local partial = (resistFromTrailer and resistFromTrailer > 0) and true or false
                                Parser:AddDamage(source, amount, spell, tname, hitType, partial)
                            end
                            if tname and OM.players[tname] then
                                local takenFrom = selfHarm and (spell or "Self") or source
                                Parser:AddDamageTaken(tname, amount, takenFrom)
                            elseif tname and not selfHarm then
                                NoteEnemyHit(tname, amount)
                            end
                        elseif dtype == "heal" then
                            Parser:AddHealing(source, amount, spell, false, target, hitType)
                        elseif dtype == "taken" then
                            Parser:AddDamageTaken(target or playerName, amount, source)
                        elseif dtype == "reflect" then
                            -- Credit the unit wearing the reflection buff (no caster reassignment)
                            local spellName = spell or "Reflect"
                            Parser:AddDamage(source, amount, spellName, target)
                            if target and OM.players[NormalizeName(target)] then
                                Parser:AddDamageTaken(target, amount, source)
                            end
                        elseif dtype == "reflect_taken" then
                            Parser:AddDamageTaken(target or playerName, amount, source)
                        end
                    end
                    return
                end
            end
        end
    end

    -- Pattern miss but trailer present
    if absorbFromTrailer and absorbFromTrailer > 0 then
        CreditAbsorb(playerName, absorbFromTrailer, "Absorb")
    end
end

-- ============================================================
-- Event frame
-- ============================================================

local parseFrame = CreateFrame("Frame")

function Parser:OnLoad()
    playerName = UnitName("player")

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
            -- SuperWoW: arg1 = original event name, arg2 = text with GUIDs
            if arg2 then
                local cleaned = StripAndCacheGuids(arg2)
                ParseDeduped(arg1 or event, cleaned)
            end
            return
        end
        ParseDeduped(event, arg1)
    end)

    -- Always register standard CHAT_MSG combat events so every mode works
    -- without SuperWoW (and as a reliable baseline with SuperWoW).
    local ev
    for ev, _ in pairs(combatlog_events) do
        parseFrame:RegisterEvent(ev)
    end

    local extraEvents = {
        "CHAT_MSG_SPELL_AURA_GONE_SELF",
        "CHAT_MSG_SPELL_AURA_GONE_OTHER",
        "CHAT_MSG_SPELL_PERIODIC_SELF_BUFFS",
        "CHAT_MSG_SPELL_PERIODIC_PARTY_BUFFS",
        "CHAT_MSG_SPELL_PERIODIC_FRIENDLYPLAYER_BUFFS",
        "CHAT_MSG_SPELL_PERIODIC_HOSTILEPLAYER_BUFFS",
        "CHAT_MSG_SPELL_PERIODIC_CREATURE_BUFFS",
        "CHAT_MSG_SPELL_SELF_BUFF",
        "CHAT_MSG_SPELL_PARTY_BUFF",
        "CHAT_MSG_SPELL_FRIENDLYPLAYER_BUFF",
        "CHAT_MSG_SPELL_HOSTILEPLAYER_BUFF",
        "CHAT_MSG_SPELL_CREATURE_VS_SELF_BUFF",
        "CHAT_MSG_SPELL_CREATURE_VS_PARTY_BUFF",
        "CHAT_MSG_SPELL_CREATURE_VS_CREATURE_BUFF",
        "CHAT_MSG_SPELL_PERIODIC_SELF_DAMAGE",
        "CHAT_MSG_SPELL_PERIODIC_PARTY_DAMAGE",
        "CHAT_MSG_SPELL_PERIODIC_FRIENDLYPLAYER_DAMAGE",
        "CHAT_MSG_SPELL_PERIODIC_HOSTILEPLAYER_DAMAGE",
        "CHAT_MSG_SPELL_PERIODIC_CREATURE_DAMAGE",
        "CHAT_MSG_SPELL_BREAK_AURA",
        "CHAT_MSG_SPELL_SELF_DAMAGE",
        "CHAT_MSG_SPELL_PARTY_DAMAGE",
        "CHAT_MSG_SPELL_FRIENDLYPLAYER_DAMAGE",
        "CHAT_MSG_SPELL_HOSTILEPLAYER_DAMAGE",
        "CHAT_MSG_SPELL_PET_DAMAGE",
        "CHAT_MSG_SPELL_DAMAGESHIELDS_ON_SELF",
        "CHAT_MSG_SPELL_DAMAGESHIELDS_ON_OTHERS",
        "CHAT_MSG_COMBAT_HOSTILE_DEATH",
        "CHAT_MSG_COMBAT_FRIENDLY_DEATH",
        -- Melee / ability avoids (misses never fire on *_HITS)
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

    if SuperWoWAvailable() then
        -- Enhanced path on top of CHAT (message de-dupe prevents double counting)
        parseFrame:RegisterEvent("RAW_COMBATLOG")
        if not Parser._guidTicker then
            local tick = CreateFrame("Frame")
            local elapsed = 0
            tick:SetScript("OnUpdate", function()
                elapsed = elapsed + arg1
                if elapsed >= 2 then
                    elapsed = 0
                    RefreshGuidCacheFromUnits()
                end
            end)
            Parser._guidTicker = tick
        end
        RefreshGuidCacheFromUnits()
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00GreedMeter:|r SuperWoW detected — enhanced log + pet GUID path.")
    end
end

function Parser:OnCombatStart()
    Parser:FlushActiveCCs()
    lastHitOn = {}
    fightEnemies = {}
    fightEnemyDeaths = {}
    fightDuplicateNames = {}
    fightIsBoss = false
    fightBossName = nil
    ClearDispelBuffers()
    recentHarmfulAuras = {}
    OM.data.current = {
        players = {},
        ccTargets = {},
        startTime = GetTime(),
        endTime = 0,
        label = "Current",
        isBoss = false,
        duration = 0,
    }
end

function Parser:OnCombatEnd(duration)
    Parser:FlushActiveCCs()

    local now = GetTime()
    OM.data.current.endTime = now
    local startT = OM.data.current.startTime or 0
    duration = duration or ((startT > 0) and (now - startT) or 0)

    -- Trim trailing idle time after the last damage/heal/action
    local lastAct = OM.data.current.lastActivityTime
    if startT > 0 and lastAct and lastAct >= startT and lastAct < now then
        local trimmed = lastAct - startT
        if trimmed > 0 and trimmed < duration then
            duration = trimmed
        end
    end
    if duration < 0 then duration = 0 end
    OM.data.current.duration = duration

    -- Update overall average DPS/HPS from this segment
    if duration > 0 and OM.data.current.players then
        local name, pdata
        for name, pdata in pairs(OM.data.current.players) do
            local o = EnsurePlayer(OM.data.overall, name)
            if o then
                local dmg = pdata.damage or 0
                local heal = pdata.healing or 0
                if dmg > 0 then
                    o.dpsSum = (o.dpsSum or 0) + (dmg / duration)
                    o.dpsSamples = (o.dpsSamples or 0) + 1
                end
                if heal > 0 then
                    o.hpsSum = (o.hpsSum or 0) + (heal / duration)
                    o.hpsSamples = (o.hpsSamples or 0) + 1
                end
            end
        end
        -- Track total active combat time for overall (sum of trimmed fights)
        OM.data.overall.duration = (OM.data.overall.duration or 0) + duration
        if not OM.data.overall.startTime or OM.data.overall.startTime == 0 then
            OM.data.overall.startTime = startT
        end
        OM.data.overall.endTime = now
    end

    -- Final boss check on current target (must still be a unique name)
    if UnitExists("target") and UnitLooksLikeBoss("target") then
        local tname = UnitName("target")
        if tname and IsUniqueEnemyName(tname) then
            fightIsBoss = true
            fightBossName = tname
        end
    end

    -- If the flagged boss name was later revealed as a duplicate pack, clear it
    if fightBossName and not IsUniqueEnemyName(fightBossName) then
        fightIsBoss = false
        fightBossName = nil
    end

    local label = PickFightLabel()
    OM.data.current.label = label
    OM.data.current.isBoss = fightIsBoss and true or false

    -- Only store fights that had some activity
    local hasData = false
    for _, _ in pairs(OM.data.current.players) do
        hasData = true
        break
    end

    if hasData and duration >= 1 then
        local snap = SnapshotSegment(OM.data.current)

        -- Always keep last 2 fights (trash or boss)
        PushFront(OM.data.recentFights, snap, MAX_RECENT_FIGHTS)

        -- Additionally keep last 3 boss fights
        if snap.isBoss then
            PushFront(OM.data.bossFights, snap, MAX_BOSS_FIGHTS)
        end
    end
end

function Parser:OnReset()
    Parser:FlushActiveCCs()
    lastHitOn = {}
    ClearDispelBuffers()
    OM.data.current = { players = {}, ccTargets = {}, startTime = 0, endTime = 0, label = "Current", isBoss = false, duration = 0 }
    OM.data.overall = { players = {}, ccTargets = {}, startTime = 0, endTime = 0, label = "Overall", isBoss = false, duration = 0 }
    OM.data.recentFights = {}
    OM.data.bossFights = {}
    OM.data.paused = nil
    OM.meterPaused = false
    fightEnemies = {}
    fightEnemyDeaths = {}
    fightDuplicateNames = {}
    fightIsBoss = false
    fightBossName = nil
    recentAbsorbCaster = {}
    recentShieldByTarget = {}
    recentAbsorbCredits = {}
    absorbAuras = {}
end

-- Resolve a UI segment key to a data table
-- Keys: "current", "overall", "recent1", "recent2", "boss1", "boss2", "boss3"
function Parser:CreatePausedSnapshot()
    if not OM.data or not OM.data.current then return end
    local src = OM.data.current
    local snap = SnapshotSegment(src)
    -- Freeze duration at the moment of pause
    local dur = 0
    if src.duration and src.duration > 0 then
        dur = src.duration
    else
        local startT = src.startTime or 0
        if startT > 0 then
            local last = src.lastActivityTime
            if last and last > startT then
                dur = last - startT
            else
                dur = GetTime() - startT
            end
        end
    end
    if dur < 0 then dur = 0 end
    snap.duration = dur
    snap.startTime = src.startTime or 0
    snap.endTime = GetTime()
    snap.lastActivityTime = src.lastActivityTime
    snap.label = "Paused"
    snap.isBoss = src.isBoss and true or false
    OM.data.paused = snap
end

function Parser:GetSegment(key)
    if not key or key == "current" then
        return OM.data.current
    elseif key == "overall" then
        return OM.data.overall
    elseif key == "paused" then
        return OM.data.paused
    end
    local _, _, kind, idx = string.find(key, "^(%a+)(%d+)$")
    idx = tonumber(idx)
    if kind == "recent" and idx and OM.data.recentFights[idx] then
        return OM.data.recentFights[idx]
    end
    if kind == "boss" and idx and OM.data.bossFights[idx] then
        return OM.data.bossFights[idx]
    end
    return nil
end

function Parser:OnRosterUpdate()
    playerName = UnitName("player")
end

-- ============================================================
-- Register with Core
-- ============================================================

OM:RegisterModule("Parser", Parser)
