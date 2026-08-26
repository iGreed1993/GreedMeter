--[[
    GreedMeter - Parser / API
    Shared data plane: AddDamage/AddMiss/..., segments, combat lifecycle,
    GUID helpers. Chat and Nampower backends call Parser methods defined here.
]]

local OM = GreedMeter
local Parser = {}
GreedMeter.ParserNS = GreedMeter.ParserNS or {}
GreedMeter.ParserNS.Parser = Parser

-- Lua 5.0 allows only 32 upvalues per function. Keep shared helpers/state on
-- these tables so large functions (ParseMessage, etc.) close over ~1-2 upvalues.
local H = {} -- helper bag
local ST = {} -- fight/parser state bag
H.getPlayerName = function() return ST.playerName or UnitName("player") end
H.NormalizeName = function(n) return n end -- replaced after real NormalizeName exists

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

-- Per-fight enemy tracking for naming + boss detection (on ST for upvalue relief)
ST.fightEnemies = {}        -- [name] = damage dealt to them by group
ST.fightEnemyDeaths = {}    -- [name] = how many times this name died this fight
ST.fightDuplicateNames = {} -- [name] = true if name is not unique (pack trash)
ST.fightEnemyBossLike = {}  -- [name] = true if UnitLooksLikeBoss while hitting them
ST.fightIsBoss = false
ST.fightBossName = nil

-- ============================================================
-- Helpers
-- ============================================================

ST.playerName = nil
local playerName = nil -- mirrored; prefer ST.playerName in new code

-- Optional mode gates (Advanced Customization "Enabled" checkboxes).
-- Disabled modes skip storing metrics to save CPU/memory.
local function ModeEnabled(mode)
    local UI = GreedMeter and GreedMeter.UI
    if UI and UI.IsModeEnabled then
        return UI.IsModeEnabled(mode)
    end
    return true
end


-- Resolve "You" and SuperWoW-style pet ownership names
local function NormalizeName(name)
    if not name or name == "" then return nil end
    if type(name) ~= "string" then name = tostring(name) end
    -- Strip residual GUID/color codes if any slipped through
    name = string.gsub(name, "|c%x%x%x%x%x%x%x%x", "")
    name = string.gsub(name, "|r", "")
    name = string.gsub(name, "^%s+", "")
    name = string.gsub(name, "%s+$", "")
    if name == "" then return nil end
    if name == "you" or name == "You" or name == "YOU" then
        return ST.playerName or UnitName("player")
    end
    -- Reject combat-log keywords that bad pattern captures treat as "targets"
    local lower = string.lower(name)
    local BAD = {
        hit=true, hits=true, crit=true, crits=true,
        miss=true, misses=true, missed=true,
        dodge=true, dodges=true, parry=true, parries=true,
        block=true, blocks=true, blocked=true,
        resist=true, resists=true, resisted=true,
        glance=true, glancing=true, crush=true, crushing=true,
        absorb=true, absorbs=true, absorbed=true,
        by=true, from=true, ["for"]=true, with=true, to=true, ["on"]=true,
        you=true, your=true, attack=true, attacks=true,
        of=true, the=true, a=true, an=true, is=true, are=true,
        damage=true, healing=true, heal=true, heals=true, healed=true,
        performs=true, casts=true, gains=true, fades=true,
        suffers=true, afflicted=true, reflects=true, reflected=true,
        partial=true, falls=true, dies=true, slain=true,
        begins=true, able=true, unable=true,
    }
    if BAD[lower] then return nil end
    -- Single-character / pure-number captures are never unit names
    if string.len(name) <= 1 then return nil end
    if tonumber(name) then return nil end
    -- SuperWoW: "PetName (OwnerName)" — record ownership for ResolveSource
    local _, _, pet, owner = string.find(name, "^(.+) %((.+)%)$")
    if pet and owner then
        if OM.SetPetOwner then
            OM:SetPetOwner(pet, owner)
        else
            OM.heuristicPets = OM.heuristicPets or {}
            OM.heuristicPets[pet] = owner
        end
    end
    return name
end


-- Exact match first, then substring (handles rank suffixes / variants).
-- Used by absorb / interrupt / dispel / CC spell tables.
H.NormalizeName = NormalizeName

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
    -- Never cache combat-log keywords / invalid captures (poisoned GUID maps
    -- showed up as Targets like "hit", "crits", "missed" when Nampower was on).
    name = NormalizeName(name)
    if not name then return end
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

-- ST.absorbAuras[targetName] = { [shieldName] = applicatorName }
ST.absorbAuras = {}
-- ST.recentAbsorbCaster[spellName] = { name = "Caster", time = GetTime() }
ST.recentAbsorbCaster = {}
-- ST.recentShieldByTarget[targetName] = { caster = "Caster", spell = "...", time = GetTime() }
ST.recentShieldByTarget = {}
local RECENT_CASTER_TIMEOUT = 8

local function IsAbsorbShield(spell)
    return SpellInSet(ABSORB_SHIELDS, spell)
end

local function NoteRecentAbsorbCaster(spell, caster, target)
    if not spell or not caster or not IsAbsorbShield(spell) then return end
    caster = NormalizeName(caster)
    ST.recentAbsorbCaster[spell] = {
        name = caster,
        time = GetTime(),
    }
    target = NormalizeName(target)
    if target then
        ST.recentShieldByTarget[target] = {
            caster = caster,
            spell = spell,
            time = GetTime(),
        }
    end
end

local function GetRecentAbsorbCaster(spell)
    if not spell then return nil end
    local entry = ST.recentAbsorbCaster[spell]
    if not entry then
        for s, e in pairs(ST.recentAbsorbCaster) do
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
    if not ST.absorbAuras[target] then
        ST.absorbAuras[target] = {}
    end
    ST.absorbAuras[target][spell] = applicator
end

local function ClearAbsorbAura(target, spell)
    target = NormalizeName(target)
    if not target or not ST.absorbAuras[target] then return end
    if spell then
        for name, _ in pairs(ST.absorbAuras[target]) do
            if name == spell or string.find(name, spell, 1, true) or string.find(spell, name, 1, true) then
                ST.absorbAuras[target][name] = nil
            end
        end
        local empty = true
        for _ in pairs(ST.absorbAuras[target]) do empty = false break end
        if empty then ST.absorbAuras[target] = nil end
    else
        ST.absorbAuras[target] = nil
    end
end

local function GetAbsorbApplicator(buffedUnit)
    buffedUnit = NormalizeName(buffedUnit)
    if not buffedUnit or not ST.absorbAuras[buffedUnit] then return nil, nil end
    for spell, applicator in pairs(ST.absorbAuras[buffedUnit]) do
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
    if ST.fightDuplicateNames[name] then return false end
    local deaths = ST.fightEnemyDeaths[name] or 0
    -- 2+ deaths of the same name = pack trash, not a unique boss
    if deaths >= 2 then return false end
    return true
end

local function MarkDuplicateName(name)
    if not name then return end
    ST.fightDuplicateNames[name] = true
    -- Clear boss flag for this name if set
    if ST.fightBossName == name then
        ST.fightIsBoss = false
        ST.fightBossName = nil
        -- Try to recover another unique boss candidate from enemies hit
        -- (left for combat-end / next elite hit)
    end
end

local function NoteEnemyDeath(name)
    name = NormalizeName(name)
    if not name or OM.players[name] then return end
    ST.fightEnemyDeaths[name] = (ST.fightEnemyDeaths[name] or 0) + 1
    if ST.fightEnemyDeaths[name] >= 2 then
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
            if enemyHP >= avgHP * 4 then
                return true
            end
            -- Near group level + meaningful HP pool (covers early dungeon bosses)
            if level > 0 and level >= (avgLevel - 3) and enemyHP >= avgHP * 2.5 then
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
    ST.fightEnemies[enemyName] = (ST.fightEnemies[enemyName] or 0) + amount

    -- Never promote non-unique names to boss
    if not IsUniqueEnemyName(enemyName) then
        return
    end

    -- While the unit is still available, remember if it matches boss criteria
    local units = { "target", "targettarget", "pettarget", "mouseover" }
    local ui
    for ui = 1, table.getn(units) do
        local u = units[ui]
        if UnitExists(u) and UnitName(u) == enemyName and UnitLooksLikeBoss(u) then
            ST.fightEnemyBossLike[enemyName] = true
            ST.fightIsBoss = true
            ST.fightBossName = enemyName
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
        takenSpellDetails = {},
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
            for i = 1, table.getn(data.dispels.list) do local v = data.dispels.list[i]
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
            for i = 1, table.getn(data.interrupts.list) do local v = data.interrupts.list[i]
                p.interrupts.list[i] = v
            end
        end
    end
    if data.ccBreaks then
        p.ccBreaks.count = data.ccBreaks.count or 0
        if data.ccBreaks.list then
            for i = 1, table.getn(data.ccBreaks.list) do local v = data.ccBreaks.list[i]
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
            for i = 1, table.getn(data.deaths.list) do local v = data.deaths.list[i]
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
                    misses = d.misses or 0, dodges = d.dodges or 0, parries = d.parries or 0,
                    blocks = d.blocks or 0, glances = d.glances or 0, crushes = d.crushes or 0,
                    resists = d.resists or 0, partials = d.partials or 0,
                    total = d.total or 0, count = d.count or 0,
                    min = d.min, max = d.max, overheal = d.overheal or 0, byTarget = {},
                }
                if d.byTarget then
                    local tn, td
                    for tn, td in pairs(d.byTarget) do
                        if type(td) == "table" then
                            copy.byTarget[tn] = {
                                hits = td.hits or 0, crits = td.crits or 0,
                                misses = td.misses or 0, dodges = td.dodges or 0, parries = td.parries or 0,
                                blocks = td.blocks or 0, glances = td.glances or 0, crushes = td.crushes or 0,
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
                    misses = d.misses or 0, dodges = d.dodges or 0, parries = d.parries or 0,
                    blocks = d.blocks or 0, glances = d.glances or 0, crushes = d.crushes or 0,
                    resists = d.resists or 0, partials = d.partials or 0,
                    total = d.total or 0, count = d.count or 0,
                    min = d.min, max = d.max, overheal = d.overheal or 0, byTarget = {},
                }
                if d.byTarget then
                    local tn, td
                    for tn, td in pairs(d.byTarget) do
                        if type(td) == "table" then
                            copy.byTarget[tn] = {
                                hits = td.hits or 0, crits = td.crits or 0,
                                misses = td.misses or 0, dodges = td.dodges or 0, parries = td.parries or 0,
                                blocks = td.blocks or 0, glances = td.glances or 0, crushes = td.crushes or 0,
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
    if data.takenSpellDetails then
        local spell, d
        if not p.takenSpellDetails then p.takenSpellDetails = {} end
        for spell, d in pairs(data.takenSpellDetails) do
            if type(d) == "table" then
                local copy = {
                    hits = d.hits or 0, crits = d.crits or 0,
                    misses = d.misses or 0, dodges = d.dodges or 0, parries = d.parries or 0,
                    blocks = d.blocks or 0, glances = d.glances or 0, crushes = d.crushes or 0,
                    resists = d.resists or 0, partials = d.partials or 0,
                    total = d.total or 0, count = d.count or 0,
                    min = d.min, max = d.max, overheal = d.overheal or 0, byTarget = {},
                }
                if d.byTarget then
                    local tn, td
                    for tn, td in pairs(d.byTarget) do
                        if type(td) == "table" then
                            copy.byTarget[tn] = {
                                hits = td.hits or 0, crits = td.crits or 0,
                                misses = td.misses or 0, dodges = td.dodges or 0, parries = td.parries or 0,
                                blocks = td.blocks or 0, glances = td.glances or 0, crushes = td.crushes or 0,
                                resists = td.resists or 0, partials = td.partials or 0,
                                total = td.total or 0, count = td.count or 0,
                                min = td.min, max = td.max,
                            }
                        end
                    end
                end
                p.takenSpellDetails[spell] = copy
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
                for i = 1, table.getn(data.list) do local v = data.list[i]
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

-- At segment save: any damaged enemy that looked like a boss → boss segment
local function ResolveBossFromDamagedEnemies(seg)
    local totals = {}
    local name, dmg

    if ST.fightEnemies then
        for name, dmg in pairs(ST.fightEnemies) do
            totals[name] = (totals[name] or 0) + (dmg or 0)
        end
    end
    -- Also fold per-player damageTo (covers any path that skipped NoteEnemyHit)
    if seg and seg.players then
        local _, pdata
        for _, pdata in pairs(seg.players) do
            if pdata and pdata.damageTo then
                for name, dmg in pairs(pdata.damageTo) do
                    if name and not (OM.players and OM.players[name]) then
                        totals[name] = (totals[name] or 0) + (dmg or 0)
                    end
                end
            end
        end
    end

    local bestName, bestDmg = nil, -1
    local units = { "target", "targettarget", "pettarget", "mouseover" }
    for name, dmg in pairs(totals) do
        if IsUniqueEnemyName(name) then
            local bossLike = ST.fightEnemyBossLike and ST.fightEnemyBossLike[name]
            if not bossLike then
                local ui
                for ui = 1, table.getn(units) do
                    local u = units[ui]
                    if UnitExists(u) and UnitName(u) == name and UnitLooksLikeBoss(u) then
                        bossLike = true
                        if ST.fightEnemyBossLike then
                            ST.fightEnemyBossLike[name] = true
                        end
                        break
                    end
                end
            end
            if bossLike and dmg > bestDmg then
                bestDmg = dmg
                bestName = name
            end
        end
    end

    if bestName then
        ST.fightIsBoss = true
        ST.fightBossName = bestName
    else
        ST.fightIsBoss = false
        ST.fightBossName = nil
    end
end

local function PickFightLabel()
    if ST.fightBossName then
        return ST.fightBossName
    end
    local bestName, bestDmg = nil, -1
    for name, dmg in pairs(ST.fightEnemies) do
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
-- ST.lastHitOn[target] = { source, spell, amount, time }
ST.lastHitOn = {}

local function NoteLastHit(target, source, spell, amount)
    target = NormalizeName(target)
    source = NormalizeName(source)
    if not target then return end
    ST.lastHitOn[target] = {
        source = source or "Unknown",
        spell = spell or "Melee",
        amount = amount or 0,
        time = GetTime(),
    }
end

-- Stamp last combat activity on the current segment (for trailing-idle duration trim)
-- Begin a meter combat segment before the first event is stored (pre-REGEN hits).
local function EnsureInCombat()
    if OM and not OM.inCombat and OM.StartCombat then
        OM:StartCombat()
    end
end

local function NoteActivity()
    if OM.data and OM.data.current then
        local now = GetTime()
        OM.data.current.lastActivityTime = now
        local st = OM.data.current.startTime or 0
        if st <= 0 then
            OM.data.current.startTime = now
        end
        -- Overall session clock starts on first combat activity
        if OM.data.overall then
            local ost = OM.data.overall.startTime or 0
            if ost <= 0 then
                OM.data.overall.startTime = now
            end
            OM.data.overall.lastActivityTime = now
        end
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
        hits = 0, crits = 0, misses = 0, dodges = 0, parries = 0,
        blocks = 0, glances = 0, crushes = 0,
        resists = 0, partials = 0,
        total = 0, overheal = 0, count = 0, min = nil, max = nil,
    }
end

local function ApplyOutcomeToBucket(s, amount, hitType, partialFlag, isTaken)
    if not s then return end
    -- isTaken: when false/nil, dodge+parry also increment misses so damage-done
    -- detail "Miss" column includes them. Taken mode keeps separate columns.
    if hitType == "miss" then
        s.misses = (s.misses or 0) + 1
        return
    elseif hitType == "dodge" then
        s.dodges = (s.dodges or 0) + 1
        if not isTaken then
            s.misses = (s.misses or 0) + 1
        end
        return
    elseif hitType == "parry" then
        s.parries = (s.parries or 0) + 1
        if not isTaken then
            s.misses = (s.misses or 0) + 1
        end
        return
    elseif hitType == "block" then
        -- Full avoid block (attack was blocked with no damage line)
        s.blocks = (s.blocks or 0) + 1
        return
    elseif hitType == "resist" then
        s.resists = (s.resists or 0) + 1
        return
    elseif hitType == "crit" then
        s.crits = (s.crits or 0) + 1
    elseif hitType == "glance" then
        s.glances = (s.glances or 0) + 1
    elseif hitType == "crush" then
        s.crushes = (s.crushes or 0) + 1
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

local function NoteSpellOutcome(p, spell, amount, hitType, isHeal, target, partialFlag, isTaken, overhealAmount)
    if not p or not spell or spell == "" then return end
    hitType = hitType or "hit"
    overhealAmount = tonumber(overhealAmount) or 0
    local bagName
    if isTaken then
        bagName = "takenSpellDetails"
    elseif isHeal then
        bagName = "healSpellDetails"
    else
        bagName = "damageSpellDetails"
    end
    if not p[bagName] then p[bagName] = {} end
    local s = p[bagName][spell]
    if not s then
        s = EmptyOutcomeBucket()
        s.byTarget = {}
        p[bagName][spell] = s
    end
    if not s.byTarget then s.byTarget = {} end
    ApplyOutcomeToBucket(s, amount, hitType, partialFlag, isTaken)
    if overhealAmount > 0 then
        s.overheal = (s.overheal or 0) + overhealAmount
    end
    if target and target ~= "" then
        local ts = s.byTarget[target]
        if not ts then
            ts = EmptyOutcomeBucket()
            s.byTarget[target] = ts
        end
        ApplyOutcomeToBucket(ts, amount, hitType, partialFlag, isTaken)
        if overhealAmount > 0 then
            ts.overheal = (ts.overheal or 0) + overhealAmount
        end
    end
end

function Parser:AddDamage(source, amount, spell, target, hitType, partialFlag, isPeriodic)
    EnsureInCombat()
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
    -- Pets always attribute to their owner on the meter (never their own bar).
    -- mergePetDamage only controls tooltip spell breakdown (one line vs per-ability).
    if source and OM.GetPetOwner then
        local owner = OM:GetPetOwner(source)
        if owner then
            isPet = true
            source = owner
        end
    end
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
                if not OM.players[target] then
                    NoteEnemyHit(target, amount)
                end
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
function Parser:AddMiss(source, spell, target, avoidType)
    EnsureInCombat()
    -- avoidType: "miss" (default), "dodge", "parry", "block"
    -- Outbound avoids (swing/spell avoided by the target).
    if not ModeEnabled("damage") then return end
    local me = ST.playerName or UnitName("player")
    if source == "You" or source == "you" or source == nil or source == "" then
        source = me
    end
    source = ResolveSource(source) or source or me
    if not source or source == "" then
        source = me
    end
    if not source then return end
    -- Always accept the local player (case-insensitive); group members via roster
    local sourceOK = false
    if me and string.lower(tostring(source)) == string.lower(tostring(me)) then
        source = me
        sourceOK = true
    elseif OM.players and OM.players[source] then
        sourceOK = true
    elseif IsTracked and IsTracked(source) then
        sourceOK = true
    end
    if not sourceOK then return end
    spell = spell or "Auto Attack"
    target = NormalizeName(target)
    avoidType = avoidType or "miss"
    local function apply(seg)
        if not seg then return end
        local p = EnsurePlayer(seg, source)
        if p then
            NoteSpellOutcome(p, spell, 0, avoidType, false, target, false)
        end
    end
    apply(OM.data.current)
    apply(OM.data.overall)
    NoteActivity()
end

function Parser:AddBlock(source, spell, target)
    EnsureInCombat()
    source = ResolveSource(source)
    if not source then return end
    if not OM.players[source] and not IsTracked(source) then return end
    spell = spell or "Auto Attack"
    target = NormalizeName(target)
    local function apply(seg)
        if not seg then return end
        local p = EnsurePlayer(seg, source)
        if p then
            NoteSpellOutcome(p, spell, 0, "block", false, target, false)
        end
    end
    apply(OM.data and OM.data.current)
    apply(OM.data and OM.data.overall)
end

function Parser:AddResist(source, spell, target)
    EnsureInCombat()
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
    EnsureInCombat()
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
            NoteSpellOutcome(p, spell, credited, hitType or "hit", true, healTarget, false, nil, over)
        end
        if healTarget and credited > 0 then
            p.healingTo[healTarget] = (p.healingTo[healTarget] or 0) + credited
        end
    end

    apply(OM.data.current)
    apply(OM.data.overall)
    NoteActivity()
end

function Parser:AddDamageTaken(target, amount, source, spell, hitType, partialFlag, isPeriodic)
    EnsureInCombat()
    if not ModeEnabled("taken") then return end
    target = NormalizeName(target)
    amount = tonumber(amount) or 0
    if not target or amount <= 0 then return end
    if not OM.players[target] then return end -- only track damage taken by the group

    source = NormalizeName(source) or "Unknown"
    spell = spell or "Auto Attack"
    hitType = hitType or "hit"
    NoteLastHit(target, source, spell, amount)

    local function apply(seg)
        if not seg then return end
        local p = EnsurePlayer(seg, target)
        if not p then return end
        p.damageTaken = (p.damageTaken or 0) + amount
        if not p.damageTakenBy then p.damageTakenBy = {} end
        p.damageTakenBy[source] = (p.damageTakenBy[source] or 0) + amount
        -- byTarget on taken details = attacker name
        NoteSpellOutcome(p, spell, amount, hitType, false, source, partialFlag, true)
    end
    apply(OM.data and OM.data.current)
    apply(OM.data and OM.data.overall)
    -- DoT ticks still count for meters, but must not keep the segment alive
    if not isPeriodic then
        NoteActivity()
    end
end

-- Incoming avoid (enemy missed / dodge-parry-block): no damage amount
function Parser:AddTakenAvoid(target, spell, source, avoidType)
    EnsureInCombat()
    if not ModeEnabled("taken") then return end
    target = NormalizeName(target)
    if not target or not OM.players[target] then return end
    source = NormalizeName(source) or "Unknown"
    spell = spell or "Auto Attack"
    avoidType = avoidType or "miss"
    local function apply(seg)
        if not seg then return end
        local p = EnsurePlayer(seg, target)
        if p then
            NoteSpellOutcome(p, spell, 0, avoidType, false, source, false, true)
        end
    end
    apply(OM.data and OM.data.current)
    apply(OM.data and OM.data.overall)
    NoteActivity()
end

function Parser:AddDispel(source, what, target)
    if not ModeEnabled("dispels") then return end
    source = ResolveSource(source)
    if not source then return end
    -- Prefer group members
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
-- Lists enemies that were CC'd and estimates full duration.
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
    -- Do not track the player's group as CC targets in this mode
    if OM.players and OM.players[target] then return end
    -- Guard against combat-log fragment targets ("on", "with", etc.)
    if string.len(target) < 3 then return end

    spell = spell or "Unknown"
    -- Reject fragment spell names
    local sl = string.lower(spell)
    if sl == "on" or sl == "with" or sl == "by" or sl == "from" or string.len(spell) < 3 then
        return
    end
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

H.EnsurePlayer = EnsurePlayer
H.IsUniqueEnemyName = IsUniqueEnemyName
H.UnitLooksLikeBoss = UnitLooksLikeBoss
H.PickFightLabel = PickFightLabel
H.PushFront = PushFront
H.SnapshotSegment = SnapshotSegment
H.DeepCopyPlayerData = DeepCopyPlayerData
H.MAX_RECENT_FIGHTS = MAX_RECENT_FIGHTS
H.MAX_BOSS_FIGHTS = MAX_BOSS_FIGHTS
H.NoteLastHit = NoteLastHit
H.NoteActivity = NoteActivity
H.EnsureInCombat = EnsureInCombat
H.ModeEnabled = ModeEnabled
H.ST = ST
H.OM = OM
H.Parser = Parser
H.getPlayerName = function() return ST.playerName or UnitName("player") end
H.NormalizeName = NormalizeName
H.ResolveSource = ResolveSource
H.NoteEnemyHit = NoteEnemyHit
H.ResolveBossFromDamagedEnemies = ResolveBossFromDamagedEnemies

-- ClearDispelBuffers is defined in Backend_Chat; resolve at call time
H.ClearDispelBuffers = function()
    local NS = GreedMeter.ParserNS
    if NS and NS.ClearDispelBuffers then
        NS.ClearDispelBuffers()
    end
end

function Parser:OnCombatStart()
    local P = H.Parser
    local S = H.ST
    local O = H.OM
    P:FlushActiveCCs()
    S.lastHitOn = {}
    S.fightEnemies = {}
    S.fightEnemyDeaths = {}
    S.fightDuplicateNames = {}
    S.fightEnemyBossLike = {}
    S.fightIsBoss = false
    S.fightBossName = nil
    H.ClearDispelBuffers()
    S.recentHarmfulAuras = {}

    -- Always start Current empty. Keeping the previous players table to catch
    -- pre-pull hits was too aggressive (late combat-log lines after REGEN_ENABLED
    -- set lastActivityTime past endTime, so the next fight reused the old totals).
    -- Opening-hit timing is handled by backdating startTime on the first event
    -- after combat starts (see NoteActivity / first damage).
    local now = GetTime()
    O.data.current = {
        players = {},
        ccTargets = {},
        startTime = now,
        endTime = 0,
        label = "Current",
        isBoss = false,
        duration = 0,
        lastActivityTime = nil,
    }
end

function Parser:OnCombatEnd(duration)
    local P = H.Parser
    local O = H.OM
    local S = H.ST
    local EnsurePlayer = H.EnsurePlayer
    local IsUniqueEnemyName = H.IsUniqueEnemyName
    local UnitLooksLikeBoss = H.UnitLooksLikeBoss
    local PickFightLabel = H.PickFightLabel
    local SnapshotSegment = H.SnapshotSegment
    local PushFront = H.PushFront
    local MAX_RECENT_FIGHTS = H.MAX_RECENT_FIGHTS
    local MAX_BOSS_FIGHTS = H.MAX_BOSS_FIGHTS

    P:FlushActiveCCs()

    local now = GetTime()
    local startT = O.data.current.startTime or 0
    duration = duration or ((startT > 0) and (now - startT) or 0)

    local lastAct = O.data.current.lastActivityTime
    if startT > 0 and lastAct and lastAct >= startT then
        local trimmed = lastAct - startT
        if trimmed > 0 and (duration <= 0 or trimmed < duration) then
            duration = trimmed
        end
    end
    if duration < 0 then duration = 0 end
    O.data.current.duration = duration
    -- Freeze endTime to last activity so the UI does not keep ticking
    if lastAct and lastAct >= startT then
        O.data.current.endTime = lastAct
    else
        O.data.current.endTime = now
    end

    if duration > 0 and O.data.current.players then
        -- Never divide by sub-second durations for overall rate averages
        local rateDur = duration
        if rateDur < 1 then rateDur = 1 end
        local name, pdata
        for name, pdata in pairs(O.data.current.players) do
            local o = EnsurePlayer(O.data.overall, name)
            if o then
                local dmg = pdata.damage or 0
                local heal = pdata.healing or 0
                if dmg > 0 then
                    o.dpsSum = (o.dpsSum or 0) + (dmg / rateDur)
                    o.dpsSamples = (o.dpsSamples or 0) + 1
                end
                if heal > 0 then
                    o.hpsSum = (o.hpsSum or 0) + (heal / rateDur)
                    o.hpsSamples = (o.hpsSamples or 0) + 1
                end
            end
        end
        O.data.overall.duration = (O.data.overall.duration or 0) + duration
        if not O.data.overall.startTime or O.data.overall.startTime == 0 then
            O.data.overall.startTime = startT
        end
        O.data.overall.endTime = now
    end

    -- Boss segment = any unique enemy damaged this fight that matched boss criteria
    if H.ResolveBossFromDamagedEnemies then
        H.ResolveBossFromDamagedEnemies(O.data.current)
    else
        ResolveBossFromDamagedEnemies(O.data.current)
    end
    -- Sync into S (OnCombatEnd uses S alias of ST)
    S.fightIsBoss = ST.fightIsBoss
    S.fightBossName = ST.fightBossName

    if S.fightBossName and not IsUniqueEnemyName(S.fightBossName) then
        S.fightIsBoss = false
        S.fightBossName = nil
        ST.fightIsBoss = false
        ST.fightBossName = nil
    end

    local label = PickFightLabel()
    O.data.current.label = label
    O.data.current.isBoss = S.fightIsBoss and true or false

    local hasData = false
    for _, _ in pairs(O.data.current.players) do
        hasData = true
        break
    end

    if hasData and duration >= 0.5 then
        local snap = SnapshotSegment(O.data.current)
        PushFront(O.data.recentFights, snap, MAX_RECENT_FIGHTS)
        if snap.isBoss then
            PushFront(O.data.bossFights, snap, MAX_BOSS_FIGHTS)
        end
    end
end

function Parser:OnReset()
    local P = H.Parser or Parser
    local O = H.OM or OM
    local S = H.ST or ST
    if not S then S = {} ; H.ST = S end
    if P and P.FlushActiveCCs then P:FlushActiveCCs() end
    S.lastHitOn = {}
    if H.ClearDispelBuffers then H.ClearDispelBuffers() end
    O.data.current = { players = {}, ccTargets = {}, startTime = 0, endTime = 0, label = "Current", isBoss = false, duration = 0 }
    O.data.overall = { players = {}, ccTargets = {}, startTime = 0, endTime = 0, label = "Overall", isBoss = false, duration = 0 }
    O.data.recentFights = {}
    O.data.bossFights = {}
    O.data.paused = nil
    O.meterPaused = false
    S.fightEnemies = {}
    S.fightEnemyDeaths = {}
    S.fightDuplicateNames = {}
    S.fightEnemyBossLike = {}
    S.fightIsBoss = false
    S.fightBossName = nil
    S.recentAbsorbCaster = {}
    S.recentShieldByTarget = {}
    S.recentAbsorbCredits = {}
    S.absorbAuras = {}
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
    playerName = UnitName("player"); ST.playerName = playerName
end

-- ============================================================
-- Register with Core
-- ============================================================


-- ============================================================
-- Cross-file exports (Lua 5.0 has no shared locals between files)
-- ============================================================
local NS = GreedMeter.ParserNS
NS.Parser = Parser
NS.H = H
NS.ST = ST

NS.ModeEnabled = ModeEnabled
NS.IsAbsorbShield = IsAbsorbShield
NS.NoteRecentAbsorbCaster = NoteRecentAbsorbCaster
NS.GetRecentAbsorbCaster = GetRecentAbsorbCaster
NS.SetAbsorbAura = SetAbsorbAura
NS.ClearAbsorbAura = ClearAbsorbAura
NS.GetAbsorbApplicator = GetAbsorbApplicator

NS.SpellInSet = SpellInSet
NS.SpellLookup = SpellLookup
NS.PushCapped = PushCapped
NS.ForEachGroupUnit = ForEachGroupUnit
NS.FindUnitByName = FindUnitByName
NS.SplitOverheal = SplitOverheal
NS.MarkDuplicateName = MarkDuplicateName
NS.NoteEnemyDeath = NoteEnemyDeath
NS.NoteEnemyHit = NoteEnemyHit
NS.UnitLooksLikeBoss = UnitLooksLikeBoss
NS.GetGroupAverageMaxHP = GetGroupAverageMaxHP
NS.EmptyOutcomeBucket = EmptyOutcomeBucket
NS.NoteSpellOutcome = NoteSpellOutcome
NS.NoteLastHit = NoteLastHit

NS.NormalizeName = NormalizeName
NS.EnsurePlayer = EnsurePlayer
NS.ResolveSource = ResolveSource
NS.IsTracked = IsTracked
NS.SuperWoWAvailable = SuperWoWAvailable
NS.CacheGuid = CacheGuid
NS.StripAndCacheGuids = StripAndCacheGuids
NS.RefreshGuidCacheFromUnits = RefreshGuidCacheFromUnits
NS.NoteActivity = NoteActivity
NS.DeepCopyPlayerData = DeepCopyPlayerData
NS.SnapshotSegment = SnapshotSegment
NS.PickFightLabel = PickFightLabel
NS.PushFront = PushFront
NS.ClearDispelBuffers = ClearDispelBuffers
NS.IsUniqueEnemyName = IsUniqueEnemyName
NS.guidToName = guidToName
NS.nameToGuid = nameToGuid

function Parser:CacheGuid(name, guid)
    CacheGuid(name, guid)
end

function Parser:NameFromGuid(guid)
    if not guid or guid == "" then return nil end
    return guidToName[guid]
end

OM:RegisterModule("Parser", Parser)

