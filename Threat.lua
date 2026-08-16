--[[
    GreedMeter - Threat module

    Optional Threat, Tank, and Overall threat views.
    Uses the server threat addon API when available; otherwise estimates from
    meter data (party/raid only).
]]

local OM = GreedMeter
local UI = GreedMeter.UI

local Threat = {}
OM.modules = OM.modules or {}

-- ============================================================
-- Extra-settings registry (shared by any future modules)
-- Supports optional children (indented, parent-gated).
-- ============================================================

OM.extraSettingsCheckboxes = OM.extraSettingsCheckboxes or {}

--[[
    entry = {
        label     = "Add threat mode",
        key       = "enableThreatMode",
        tooltip   = "...",
        default   = false,
        order     = 10,              -- lower = closer to bottom
        onToggle  = function(checked) end,
        children  = {                -- optional nested checkboxes
            {
                label   = "Tanking mode",
                key     = "enableTankingMode",
                tooltip = "...",
                default = false,
                onToggle = function(checked) end,
            },
        },
    }
]]
function OM:RegisterExtraCheckbox(entry)
    if not entry or not entry.key or not entry.label then return end
    local i
    for i = 1, table.getn(self.extraSettingsCheckboxes) do
        if self.extraSettingsCheckboxes[i].key == entry.key then
            self.extraSettingsCheckboxes[i] = entry
            return
        end
    end
    table.insert(self.extraSettingsCheckboxes, entry)
end

-- ============================================================
-- Defaults
-- ============================================================

OM.defaults = OM.defaults or {}
if OM.defaults.enableThreatMode == nil then
    OM.defaults.enableThreatMode = false
end
if OM.defaults.showPetThreat == nil then
    OM.defaults.showPetThreat = false
end
if OM.defaults.petAsTank == nil then
    OM.defaults.petAsTank = false
end
-- threatView: "single" | "tank" | "overall" | "all"
if OM.defaults.threatView == nil then
    OM.defaults.threatView = "single"
end
-- Migrate legacy checkbox
if OM.defaults.enableTankingMode ~= nil then
    if OM.defaults.enableTankingMode and OM.defaults.threatView == "single" then
        OM.defaults.threatView = "tank"
    end
end

-- ============================================================
-- Constants / state
-- ============================================================

-- Server threat addon API
-- Query:  SendAddonMessage("TWT_UDTSv4" or "TWT_UDTSv4_TM", "limit=N", RAID|PARTY)
-- Reply:  arg2 contains "TWTv4=player:tank:threat:perc:melee;..." optional "#TMTv1=..."
local THREAT_API_PREFIX    = "TWTv4="
local TANK_MODE_API_PREFIX = "TMTv1="
local THREAT_QUERY_BASE    = "TWT_UDTSv4"
local PULL_AGGRO_NAME      = "-Pull Aggro at-"

Threat.usingApi            = false
Threat.lastApiTime         = 0
Threat.apiTimeout          = 6.0
Threat.threats             = {}   -- [name] = { threat, perc, tank, tps, class, melee, estimated }
Threat.tankModeThreats     = {}   -- [guid] = { creature, name, perc }  (API tank-mode multi-mob)
Threat.overallThreat       = {}   -- [name] = { threat, class, estimated }  fight-total threat generated
Threat.threatByTarget      = {}   -- [targetKey][player] = last API threat on that mob
Threat.currentTargetKey    = nil  -- GUID/name key for the mob the last API packet was about
-- Shared work across multiple threat windows (single / tank / overall):
-- dataGen bumps whenever underlying tables change; list caches rebuild at most once per gen.
Threat.dataGen             = 0
Threat.listCache           = {}   -- [view] = { gen=n, list={...} }
Threat.targetingCache      = {}   -- [playerName] = { enemyName, ... }
Threat.targetingCacheGen   = -1
Threat.targetName          = nil
Threat.tankName            = nil
Threat.queryInterval       = 0.50
Threat.lastQuery           = 0
Threat.history             = {}   -- for TPS
Threat.groupCombat         = false -- party/raid combat session (not just local regen)
Threat.fleeingEnemies      = {}   -- [name or guid] = expireTime

-- Improved class baseline modifiers (relative threat generation)
-- Tanks higher, pure DPS lower, healers lowest base on damage contribution
local CLASS_THREAT_MOD = {
    WARRIOR = 1.15,   -- often tanking / high threat kit
    PALADIN = 1.10,
    DRUID   = 1.05,   -- bear form is higher; handled separately for self
    ROGUE   = 0.71,
    HUNTER  = 0.65,
    MAGE    = 0.70,
    WARLOCK = 0.72,
    PRIEST  = 0.55,   -- mostly healing threat
    SHAMAN  = 0.75,
}

-- Damage abilities with higher-than-normal threat coefficients (1.12 approximations).
-- Applied to that spell's damage already stored in the meter (damageSpells).
local SPELL_DAMAGE_THREAT_MULT = {
    ["Mind Blast"] = 2.00,
    ["Searing Pain"] = 2.00,
    ["Shield Slam"] = 1.50,
    ["Revenge"] = 2.00,
    ["Maul"] = 1.75,
    ["Heroic Strike"] = 1.25,
    ["Cleave"] = 1.15,
    ["Thunder Clap"] = 1.75,
    ["Mocking Blow"] = 2.50,
    ["Holy Shield"] = 1.30,
    ["Lacerate"] = 1.30,
    ["Devastate"] = 1.50,
}

-- Non-damaging (or mostly non-damaging) threat applications.
-- Values are flat threat per successful application/cast (classic-era approximations).
local SPELL_FLAT_THREAT = {
    ["Sunder Armor"] = 261,
    ["Demoralizing Shout"] = 43,
    ["Demoralizing Roar"] = 39,
    ["Faerie Fire"] = 108,
    ["Faerie Fire (Feral)"] = 108,
    ["Hamstring"] = 104,

    -- ============================================================
    -- Pet / minion high-threat abilities (KLH Threat Meter 1.12 data)
    -- Rankless keys use the highest rank typically available at 60.
    -- ============================================================
    -- Hunter pet Growl (ranks 1–7 in vanilla; values max→min)
    ["Growl"] = 415,
    ["Growl (Rank 1)"] = 50,
    ["Growl (Rank 2)"] = 65,
    ["Growl (Rank 3)"] = 110,
    ["Growl (Rank 4)"] = 170,
    ["Growl (Rank 5)"] = 240,
    ["Growl (Rank 6)"] = 320,
    ["Growl (Rank 7)"] = 415,

    -- Hunter BM Intimidation (fixed)
    ["Intimidation"] = 580,

    -- Voidwalker Torment (ranks 1–6)
    ["Torment"] = 395,
    ["Torment (Rank 1)"] = 45,
    ["Torment (Rank 2)"] = 75,
    ["Torment (Rank 3)"] = 125,
    ["Torment (Rank 4)"] = 215,
    ["Torment (Rank 5)"] = 300,
    ["Torment (Rank 6)"] = 395,

    -- Voidwalker Suffering (ranks 1–4, AoE threat)
    ["Suffering"] = 600,
    ["Suffering (Rank 1)"] = 150,
    ["Suffering (Rank 2)"] = 300,
    ["Suffering (Rank 3)"] = 450,
    ["Suffering (Rank 4)"] = 600,
}

local function SpellDamageThreatMult(spell)
    if not spell or spell == "" then return 1.0 end
    local m = SPELL_DAMAGE_THREAT_MULT[spell]
    if m then return m end
    -- Partial match for ranks / variants ("Mind Blast(Rank 5)", "Sunder Armor Rank 5")
    local key, mult
    for key, mult in pairs(SPELL_DAMAGE_THREAT_MULT) do
        if string.find(spell, key, 1, true) then
            return mult
        end
    end
    return 1.0
end

local function SpellFlatThreat(spell)
    if not spell or spell == "" then return 0 end
    local v = SPELL_FLAT_THREAT[spell]
    if v and v > 0 then return v end
    local key, flat
    for key, flat in pairs(SPELL_FLAT_THREAT) do
        if flat > 0 and string.find(spell, key, 1, true) then
            return flat
        end
    end
    return 0
end

-- Threat-reducing buffs we can detect on the local player (name patterns)
local THREAT_REDUCE_BUFFS = {
    ["Blessing of Salvation"] = 0.70,
    ["Greater Blessing of Salvation"] = 0.70,
    ["Tranquil Air"] = 0.80,
    ["Fade"] = 0.50,              -- temporary; still useful if active
    ["Shadowform"] = 1.00,        -- no change (placeholder)
    ["Innervate"] = 1.00,
}

local function IsInGroup()
    return (GetNumRaidMembers() and GetNumRaidMembers() > 0)
        or (GetNumPartyMembers() and GetNumPartyMembers() > 0)
end

-- True if the player OR any party/raid member is in combat.
-- Healers often leave themselves out of combat; overall threat still needs to run.
local function IsGroupInCombat()
    if UnitAffectingCombat("player") then
        return true
    end
    local i
    local nParty = GetNumPartyMembers() or 0
    for i = 1, nParty do
        if UnitExists("party" .. i) and UnitAffectingCombat("party" .. i) then
            return true
        end
    end
    local nRaid = GetNumRaidMembers() or 0
    for i = 1, nRaid do
        if UnitExists("raid" .. i) and UnitAffectingCombat("raid" .. i) then
            return true
        end
    end
    return false
end

local function HasHostileTarget()
    if not UnitExists("target") then return false end
    if UnitIsPlayer("target") or UnitIsFriend("player", "target") then return false end
    return true
end

local function ShowPetThreatEnabled()
    return OM:GetSetting("showPetThreat") == true
end

local function PetAsTankEnabled()
    return OM:GetSetting("petAsTank") == true
end

-- Local pet unit token / name (hunter pet or warlock minion)
local function GetLocalPetName()
    if UnitExists("pet") then
        return UnitName("pet")
    end
    return nil
end

-- Unit we treat as the "tank actor" for tank-mode status checks
local function GetTankActorUnit()
    if PetAsTankEnabled() and UnitExists("pet") then
        return "pet"
    end
    return "player"
end

local function GetTankActorName()
    local u = GetTankActorUnit()
    return UnitName(u)
end

-- Sum damage attributed to the owner's pet from meter spell totals.
-- Parser stores pet hits as "Pet: <spell>" (or "Pet: Damage" when merged).
local function PetDamageFromMeterData(data)
    if not data or not data.damageSpells then return 0 end
    local total = 0
    local spell, amt
    for spell, amt in pairs(data.damageSpells) do
        if type(spell) == "string" and string.sub(spell, 1, 5) == "Pet: " then
            total = total + (amt or 0)
        end
    end
    return total
end

-- Pet/minion ability names that generate flat threat (matched as substring)
local PET_FLAT_THREAT_NAMES = {
    "Growl",
    "Intimidation",
    "Torment",
    "Suffering",
}

local function IsPetFlatThreatSpell(spell)
    if not spell or type(spell) ~= "string" then return false end
    local i
    for i = 1, table.getn(PET_FLAT_THREAT_NAMES) do
        if string.find(spell, PET_FLAT_THREAT_NAMES[i], 1, true) then
            return true
        end
    end
    return false
end

-- Flat threat from pet/minion threat abilities credited on the owner row
local function PetAbilityThreatFromMeterData(data)
    if not data or not data.threatCasts then return 0 end
    local total = 0
    local spell, count
    for spell, count in pairs(data.threatCasts) do
        if IsPetFlatThreatSpell(spell) then
            count = count or 0
            if count > 0 then
                total = total + count * SpellFlatThreat(spell)
            end
        end
    end
    return total
end

-- Use RAID channel in a raid, otherwise PARTY
local function GetThreatChannel()
    if GetNumRaidMembers and GetNumRaidMembers() > 0 then
        return "RAID"
    end
    return "PARTY"
end

-- API replies are only expected for elite/worldboss targets that are in combat.
local function IsThreatApiTarget()
    if not IsInGroup() then return false end
    if not UnitExists("target") then return false end
    if UnitIsPlayer("target") or UnitIsFriend("player", "target") then return false end

    local classification = UnitClassification and UnitClassification("target") or nil
    if classification ~= "worldboss"
        and classification ~= "elite"
        and classification ~= "rareelite" then
        return false
    end

    -- No threat table until the mob is actually in combat
    if UnitAffectingCombat and not UnitAffectingCombat("target") then
        return false
    end
    return true
end

local function GetPlayerClass(name)
    if OM.players and OM.players[name] and OM.players[name].class then
        return OM.players[name].class
    end
    if name == UnitName("player") then
        local _, c = UnitClass("player")
        return c
    end
    return nil
end

local function ClearThreatTable()
    local k
    for k in pairs(Threat.threats) do
        Threat.threats[k] = nil
    end
    Threat.tankName = nil
end

local function ClearTankModeTable()
    local k
    for k in pairs(Threat.tankModeThreats) do
        Threat.tankModeThreats[k] = nil
    end
end

-- threatView setting: single | tank | overall | all
local function GetThreatView()
    local v = OM:GetSetting("threatView")
    if v == "tank" or v == "overall" or v == "all" or v == "single" then
        return v
    end
    -- Legacy migration from enableTankingMode checkbox
    if OM:GetSetting("enableTankingMode") == true then
        return "tank"
    end
    return "single"
end

local function IsThreatModeKey(mode)
    return mode == "threat" or mode == "tank" or mode == "overall"
end

-- Effective view for a given frame mode
local function EffectiveView(mode)
    if mode == "tank" then return "tank" end
    if mode == "overall" then return "overall" end
    if mode == "threat" then
        local v = GetThreatView()
        if v == "all" or v == "single" then return "single" end
        return v -- tank or overall when only that mode is registered as "threat"
    end
    return "single"
end

local function TankViewActive(mode)
    return EffectiveView(mode or "threat") == "tank"
end

local function OverallViewActive(mode)
    return EffectiveView(mode or "threat") == "overall"
end

-- Back-compat alias used in a few places
local function TankingModeEnabled()
    if not OM:GetSetting("enableThreatMode") then return false end
    local v = GetThreatView()
    return v == "tank" or v == "all"
end

local function InvalidateThreatCaches()
    Threat.dataGen = (Threat.dataGen or 0) + 1
    -- listCache entries become stale via gen mismatch; drop tables to free memory
    Threat.listCache = {}
    -- targeting cache is tied to targetingCacheGen
end

-- Request TMTv1 multi-mob payload only when a tank window (or tank setting) needs it
local function NeedTankModeApi()
    if not OM:GetSetting("enableThreatMode") then return false end
    if Threat.AnyFrameInTankView and Threat:AnyFrameInTankView() then
        return true
    end
    local v = GetThreatView()
    return v == "tank" or v == "all"
end

-- ============================================================
-- GUID helpers (optional enhanced client APIs when present)
-- ============================================================

local function HasSuperWoW()
    if OM and OM.HasSuperWoW then
        return OM:HasSuperWoW()
    end
    return (SUPERWOW_VERSION or SUPERWOW_STRING or SuperWoW) and true or false
end

-- Returns a stable GUID string for a unit token, or nil
local function GetUnitGUID(unit)
    if not unit then return nil end
    -- Enhanced clients: second return of UnitExists may be a GUID
    local exists, guid = UnitExists(unit)
    if exists and type(guid) == "string" and guid ~= "" and guid ~= unit then
        -- Prefer values that look like GUIDs (0x...) when present
        if string.find(guid, "0x") or string.len(guid) >= 8 then
            return guid
        end
    end
    -- Some clients also expose UnitGUID(unit)
    if UnitGUID then
        local g = UnitGUID(unit)
        if type(g) == "string" and g ~= "" then
            return g
        end
        -- Some clients return UnitGUID as hi, lo numbers
        if type(g) == "number" then
            local hi, lo = UnitGUID(unit)
            if hi and lo then
                return string.format("0x%08X%08X", hi, lo)
            end
        end
    end
    return nil
end

-- Short suffix for UI when multiple mobs share a name
local function ShortGuidSuffix(guid)
    if not guid or guid == "" then return nil end
    local s = tostring(guid)
    -- strip 0x prefix and take last 4 hex chars
    s = string.gsub(s, "^0[xX]", "")
    if string.len(s) > 4 then
        s = string.sub(s, -4)
    end
    return s
end

-- Target a specific enemy by GUID when available, else by name
local function TargetEnemy(entry)
    if not entry then return end
    local guid = entry.data and entry.data.guid
    local name = entry.name
    if guid and HasSuperWoW() and TargetUnit then
        -- Stale GUIDs can crash some clients; only target when UnitExists.
        local exists = UnitExists(guid)
        if exists then
            TargetUnit(guid)
            return
        end
        -- fall through to name targeting
    end
    if name and name ~= "" and TargetByName then
        TargetByName(name, 1)
    end
end

-- Remember the current hostile target as its own GUID-keyed enemy row
-- (lets Tank mode accumulate distinct same-name mobs as you tab through them)
local function RememberHostileUnit(unit)
    if not unit or not UnitExists(unit) then return end
    if UnitIsPlayer(unit) or UnitIsFriend("player", unit) then return end

    local name = UnitName(unit) or "Enemy"
    local guid = GetUnitGUID(unit)
    if not guid or guid == "" then
        guid = "name:" .. name
    end

    local existing = Threat.tankModeThreats[guid]
    if not existing then
        Threat.tankModeThreats[guid] = {
            creature  = name,
            name      = name,
            guid      = guid,
            perc      = 0,
            threat    = 0,
            status    = "red",
            estimated = true,
        }
    else
        existing.creature = existing.creature or name
        existing.name = name
        existing.guid = guid
    end
end

local function RememberHostileTarget()
    if not TankingModeEnabled() and not (Threat.AnyFrameInTankView and Threat:AnyFrameInTankView()) then
        -- Still allow remember when a tank window is open even if threatView setting is single
    end
    if UnitExists("target")
        and not UnitIsPlayer("target") and not UnitIsFriend("player", "target") then
        RememberHostileUnit("target")
    end
    -- Pet-as-tank: track what the pet is hitting
    if PetAsTankEnabled() and UnitExists("pettarget")
        and not UnitIsPlayer("pettarget") and not UnitIsFriend("player", "pettarget") then
        RememberHostileUnit("pettarget")
    end
end


local function GetLocalThreatModifier()
    local mod = 1.0
    local _, class = UnitClass("player")

    -- Warrior stance (GetShapeshiftFormInfo is available in 1.12)
    if class == "WARRIOR" then
        local i
        for i = 1, 3 do
            local _, name, isActive = GetShapeshiftFormInfo(i)
            if isActive then
                if name and string.find(string.lower(name), "defensive") then
                    mod = mod * 1.30
                elseif name and string.find(string.lower(name), "berserker") then
                    mod = mod * 0.80
                elseif name and string.find(string.lower(name), "battle") then
                    mod = mod * 0.80
                end
                break
            end
        end
    elseif class == "DRUID" then
        -- Bear / Dire Bear roughly 1.3 threat; cat lower
        local i
        for i = 1, 5 do
            local _, name, isActive = GetShapeshiftFormInfo(i)
            if isActive and name then
                local lower = string.lower(name)
                if string.find(lower, "bear") then
                    mod = mod * 1.30
                elseif string.find(lower, "cat") then
                    mod = mod * 0.71
                end
                break
            end
        end
    end

    -- Scan buffs for major threat reducers (local player only)
    local bi
    for bi = 1, 32 do
        local buffTexture = UnitBuff("player", bi)
        if not buffTexture then break end
        -- We only have texture in 1.12 without SuperWoW tooltip scanning;
        -- use a conservative approach via tooltip if available.
        -- Many private servers still expose the name via GameTooltip scan.
    end

    -- Tooltip-based buff name scan (works on most 1.12 clients)
    if not Threat._buffTip then
        Threat._buffTip = CreateFrame("GameTooltip", "GreedMeterThreatBuffTip", nil, "GameTooltipTemplate")
        Threat._buffTip:SetOwner(WorldFrame, "ANCHOR_NONE")
    end
    local tip = Threat._buffTip
    local bi2
    for bi2 = 1, 32 do
        tip:ClearLines()
        tip:SetUnitBuff("player", bi2)
        local text = getglobal("GreedMeterThreatBuffTipTextLeft1")
        local buffName = text and text:GetText()
        if not buffName then break end
        local reduce = THREAT_REDUCE_BUFFS[buffName]
        if reduce then
            mod = mod * reduce
        end
    end

    return mod
end

-- ============================================================
-- Server threat API path
-- ============================================================

local function SendThreatQuery()
    -- Only query when the server is expected to answer
    if not IsThreatApiTarget() then return end

    local query = THREAT_QUERY_BASE
    -- Tank-mode multi-mob payload only when a tank view actually needs it
    if NeedTankModeApi() then
        query = query .. "_TM"
    end

    -- limit = how many players the server should include in the reply
    local msg = "limit=19"
    local channel = GetThreatChannel()
    SendAddonMessage(query, msg, channel)
end

local function ParseThreatPacket(packet)
    local start = string.find(packet, THREAT_API_PREFIX, 1, true)
    if not start then return false end

    -- Packet may contain "TWTv4=...#TMTv1=..." when tank mode is active
    local threatPart = packet
    local tankPart = nil
    local hash = string.find(packet, "#", 1, true)
    if hash then
        threatPart = string.sub(packet, 1, hash - 1)
        tankPart = string.sub(packet, hash + 1)
    end

    local dataStart = string.find(threatPart, THREAT_API_PREFIX, 1, true)
    local data = string.sub(threatPart, dataStart + string.len(THREAT_API_PREFIX))

    ClearThreatTable()
    Threat.usingApi = true
    Threat.lastApiTime = GetTime()

    -- Snapshots may be broadcast on PARTY/RAID when anyone queries.
    -- Apply them to Overall even when this client has no hostile target.
    if UnitExists("target")
        and not UnitIsPlayer("target")
        and not UnitIsFriend("player", "target") then
        Threat.targetName = UnitName("target")
        Threat.currentTargetKey = GetUnitGUID("target")
            or ("name:" .. (Threat.targetName or "?"))
    else
        -- No local hostile target: retain last key so we keep filling the same
        -- mob bucket, or use a shared fight key if we have never targeted.
        if not Threat.currentTargetKey then
            Threat.currentTargetKey = "raid:active"
        end
        -- targetName left as last known for UI title
    end

    local pos = 1
    local len = string.len(data)
    while pos <= len do
        local semi = string.find(data, ";", pos, true) or (len + 1)
        local chunk = string.sub(data, pos, semi - 1)
        pos = semi + 1
        if chunk and chunk ~= "" then
            local parts = {}
            local p = 1
            local clen = string.len(chunk)
            while p <= clen do
                local colon = string.find(chunk, ":", p, true) or (clen + 1)
                table.insert(parts, string.sub(chunk, p, colon - 1))
                p = colon + 1
            end
            if table.getn(parts) >= 4 then
                local player = parts[1]
                local tank   = parts[2] == "1"
                local threat = tonumber(parts[3]) or 0
                local perc   = tonumber(parts[4]) or 0
                local melee  = parts[5] == "1"
                if player and player ~= "" then
                    local tps = 0
                    local hist = Threat.history[player]
                    local now = GetTime()
                    if hist and hist.time and (now - hist.time) > 0.05 then
                        tps = (threat - (hist.threat or 0)) / (now - hist.time)
                        if tps < 0 then tps = 0 end
                    end
                    Threat.history[player] = { threat = threat, time = now }
                    Threat.threats[player] = {
                        threat    = threat,
                        perc      = perc,
                        tank      = tank,
                        tps       = tps,
                        melee     = melee,
                        class     = GetPlayerClass(player),
                        estimated = false,
                    }
                    if tank then
                        Threat.tankName = player
                    end
                end
            end
        end
    end

    -- Optional tank-mode multi-mob block
    if tankPart and string.find(tankPart, TANK_MODE_API_PREFIX, 1, true) then
        ClearTankModeTable()
        local tStart = string.find(tankPart, TANK_MODE_API_PREFIX, 1, true)
        local tData = string.sub(tankPart, tStart + string.len(TANK_MODE_API_PREFIX))
        local tp = 1
        local tlen = string.len(tData)
        while tp <= tlen do
            local semi = string.find(tData, ";", tp, true) or (tlen + 1)
            local chunk = string.sub(tData, tp, semi - 1)
            tp = semi + 1
            if chunk and chunk ~= "" then
                local parts = {}
                local p = 1
                local clen = string.len(chunk)
                while p <= clen do
                    local colon = string.find(chunk, ":", p, true) or (clen + 1)
                    table.insert(parts, string.sub(chunk, p, colon - 1))
                    p = colon + 1
                end
                -- TMTv1 fields: creature:guid:secondPlayer:secondPerc
                -- creature = mob name, name = runner-up player, perc = their threat %
                -- Presence of a row means YOU are tanking that mob.
                if table.getn(parts) >= 4 then
                    local creature = parts[1]
                    local guid     = parts[2]
                    local secondPlayer = parts[3]
                    local secondPerc   = tonumber(parts[4]) or 0
                    if not guid or guid == "" or guid == secondPlayer or guid == creature then
                        guid = "row:" .. tostring(creature) .. ":" .. tostring(secondPlayer) .. ":" .. tostring(secondPerc) .. ":" .. tostring(tp)
                    end
                    local status = (secondPerc >= 90) and "yellow" or "green"
                    -- Sort key: more contested (higher second %) → lower value → nearer top
                    local threat = math.max(1, 100 - secondPerc)
                    Threat.tankModeThreats[guid] = {
                        creature  = creature,
                        name      = secondPlayer, -- runner-up (kept for tooltip)
                        guid      = guid,
                        perc      = 100,          -- you are the tank on this row
                        secondPerc = secondPerc,
                        threat    = threat,
                        status    = status,
                        estimated = false,
                    }
                end
            end
        end
    end

    -- Pull-aggro threshold is part of single-target Threat view
    Threat:AddPullAggroRow()
    Threat:UpdateOverallFromPlayerThreats()
    InvalidateThreatCaches()

    return true
end

function Threat:AddPullAggroRow()
    local tankThreat = 0
    local myMelee = false
    local me = UnitName("player")
    local name, data
    for name, data in pairs(self.threats) do
        if data.tank then
            tankThreat = data.threat or 0
            break
        end
    end
    if self.threats[me] then
        myMelee = self.threats[me].melee and true or false
    end

    -- Classic rule: melee pulls at 110% of tank, ranged at 130%
    local mult = myMelee and 1.1 or 1.3
    local pullThreat = tankThreat * mult
    if pullThreat <= 0 then pullThreat = 1 end

    self.threats[PULL_AGGRO_NAME] = {
        threat    = pullThreat,
        perc      = myMelee and 110 or 130,
        tank      = false,
        tps       = 0,
        melee     = false,
        class     = nil,
        isPull    = true,
        estimated = not self.usingApi,
    }
end

-- ============================================================
-- 1.12 estimation fallback (party/raid only)
-- Uses the damage meter segment only — no second pass over combat log
-- and no parallel damage/heal sample buffers.
-- ============================================================

local function SegmentDuration(segment)
    if not segment or not segment.startTime or segment.startTime <= 0 then
        return 0
    end
    local endT = segment.endTime or 0
    local now = GetTime()
    local dur
    if endT and endT > segment.startTime then
        dur = endT - segment.startTime
    else
        dur = now - segment.startTime
    end
    -- Prefer trimmed activity window when the meter recorded it
    local lastAct = segment.lastActivityTime
    if lastAct and lastAct >= segment.startTime and lastAct <= now then
        local trimmed = lastAct - segment.startTime
        if trimmed > 0 and (dur <= 0 or trimmed < dur) then
            dur = trimmed
        end
    end
    if dur < 1 then dur = 1 end
    return dur
end

-- Classic-style relative threat from meter totals already parsed by GreedMeter.
local function ThreatFromMeterPlayer(name, data, me, localMod)
    if not data then return 0, nil end
    local class = data.class or GetPlayerClass(name)
    local mod = 1.0
    if class and CLASS_THREAT_MOD[class] then
        mod = CLASS_THREAT_MOD[class]
    end
    if me and name == me then
        mod = mod * (localMod or 1.0)
    end

    -- Damage threat: prefer per-spell totals so high-threat abilities can be weighted.
    -- Meter already parsed these once into data.damage / data.damageSpells.
    local dmgThreat = 0
    local accounted = 0
    if data.damageSpells then
        local spell, amt
        for spell, amt in pairs(data.damageSpells) do
            amt = amt or 0
            dmgThreat = dmgThreat + amt * SpellDamageThreatMult(spell)
            accounted = accounted + amt
        end
    end
    local totalDmg = data.damage or 0
    local rest = totalDmg - accounted
    if rest > 0 then
        dmgThreat = dmgThreat + rest
    elseif accounted <= 0 then
        dmgThreat = totalDmg
    end

    -- Healing threat (~0.5x effective heal — parser stores effective in data.healing)
    local healThreat = (data.healing or 0) * 0.5

    -- Flat threat from non-damaging applications (Sunder, Demo Shout, etc.)
    local flatThreat = 0
    if data.threatCasts then
        local spell, count
        for spell, count in pairs(data.threatCasts) do
            count = count or 0
            if count > 0 then
                flatThreat = flatThreat + count * SpellFlatThreat(spell)
            end
        end
    end

    local threat = (dmgThreat + healThreat + flatThreat) * mod
    return threat, class
end

local function BuildEstimatedThreat()
    ClearThreatTable()
    Threat.usingApi = false
    Threat.targetName = UnitName("target")

    -- Solo allowed when "Show pets" is on so hunters/locks can quest with threat bars
    if not IsInGroup() and not ShowPetThreatEnabled() then
        return
    end
    if not HasHostileTarget() then
        return
    end

    if not UI or not UI.GetSegmentData then return end
    local segment = UI.GetSegmentData("current")
    if not segment or not segment.players then return end

    local me = UnitName("player")
    local localMod = 1.0
    if me then
        localMod = GetLocalThreatModifier()
    end

    local tankUnit = GetTankActorUnit()
    local tankName = GetTankActorName() or me
    local iAmTanking = UnitExists("targettarget") and UnitIsUnit(tankUnit, "targettarget")
    if PetAsTankEnabled() and not iAmTanking and UnitExists("pettargettarget") then
        iAmTanking = UnitIsUnit("pet", "pettargettarget")
    end

    local maxThreat = 0
    local list = {}
    local name, data
    for name, data in pairs(segment.players) do
        local threat, class = ThreatFromMeterPlayer(name, data, me, localMod)
        local petThreat = 0
        if ShowPetThreatEnabled() and me and name == me then
            local petDmg = PetDamageFromMeterData(data)
            local growlThreat = PetAbilityThreatFromMeterData(data)
            local petPortion = petDmg + growlThreat
            if petPortion > 0 then
                -- Remove pet portion from the owner row (class/stance mod was applied to the sum)
                local stripped = threat - (petPortion * localMod)
                if stripped < 0 then stripped = 0 end
                threat = stripped
                -- Pet threat is not scaled by the hunter's stance/class mod
                petThreat = petPortion
            end
        end
        if name == tankName and iAmTanking then
            threat = threat * 1.15
        end
        if threat > 0 then
            table.insert(list, {
                name = name,
                threat = threat,
                class = class,
                isLikelyTank = (name == tankName and iAmTanking) or false,
                isPet = false,
            })
            if threat > maxThreat then maxThreat = threat end
        end
        if petThreat > 0 then
            local petName = GetLocalPetName() or "Pet"
            local petIsTank = PetAsTankEnabled() and iAmTanking
            if petIsTank then
                petThreat = petThreat * 1.15
            end
            table.insert(list, {
                name = petName,
                threat = petThreat,
                class = class,
                isLikelyTank = petIsTank,
                isPet = true,
            })
            if petThreat > maxThreat then maxThreat = petThreat end
        end
    end

    -- Solo with show pets but no segment player row yet: still show pet if we have a name
    if ShowPetThreatEnabled() and not IsInGroup() and table.getn(list) == 0 and me then
        local pdata = segment.players[me]
        if pdata then
            local petDmg = PetDamageFromMeterData(pdata)
            local growlThreat = PetAbilityThreatFromMeterData(pdata)
            local petPortion = petDmg + growlThreat
            if petPortion > 0 then
                local petName = GetLocalPetName() or "Pet"
                table.insert(list, {
                    name = petName,
                    threat = petPortion,
                    class = pdata.class,
                    isLikelyTank = iAmTanking and PetAsTankEnabled(),
                    isPet = true,
                })
                maxThreat = petPortion
            end
        end
    end

    local ttName = UnitExists("targettarget") and UnitName("targettarget") or nil
    local duration = SegmentDuration(segment)
    local i
    for i = 1, table.getn(list) do
        local e = list[i]
        local perc = 0
        if maxThreat > 0 then
            perc = math.floor((e.threat / maxThreat) * 100 + 0.5)
        end
        local isTank = e.isLikelyTank
            or (ttName and e.name == ttName)
            or (perc >= 100 and maxThreat > 0 and e.threat >= maxThreat)
        local tps = 0
        if duration > 0 then
            tps = e.threat / duration
        end
        Threat.threats[e.name] = {
            threat    = e.threat,
            perc      = perc,
            tank      = isTank,
            tps       = tps,
            melee     = false,
            class     = e.class,
            estimated = true,
            isPet     = e.isPet and true or false,
        }
        if isTank then
            Threat.tankName = e.name
        end
    end

    Threat:AddPullAggroRow()
    Threat:UpdateOverallFromPlayerThreats()
    InvalidateThreatCaches()
end

-- Overall rankings with no personal target — still only meter totals.
local function BuildEstimatedOverallOnly()
    if not IsInGroup() then return end
    if not UI or not UI.GetSegmentData then return end

    local segment = UI.GetSegmentData("current")
    if not segment or not segment.players then return end

    local me = UnitName("player")
    local localMod = 1.0
    if me then
        localMod = GetLocalThreatModifier()
    end
    local duration = SegmentDuration(segment)

    local name, data
    for name, data in pairs(segment.players) do
        local threat, class = ThreatFromMeterPlayer(name, data, me, localMod)
        if threat > 0 then
            local tps = 0
            if duration > 0 then
                tps = threat / duration
            end
            Threat.overallThreat[name] = {
                threat    = threat,
                class     = class,
                estimated = true,
                tank      = false,
                tps       = tps,
            }
        end
    end
    InvalidateThreatCaches()
end

-- ============================================================
-- Enemy status (Tank mode): red / yellow / green
-- ============================================================

-- perc = your threat as % of the highest threat on that mob (API convention)
local function EnemyStatusFromPerc(perc)
    perc = tonumber(perc) or 0
    if perc < 100 then
        return "red"      -- you do not have aggro
    end
    -- You are at (or are) max threat. Without second-place data we treat
    -- a thin margin above 100 as contested when API later supplies it;
    -- for a plain 100% reading mark green (secure lead on the meter).
    return "green"
end

-- When we also know the runner-up ratio (0-1 of your threat), refine yellow
local function EnemyStatusFromLead(myThreat, secondThreat)
    myThreat = tonumber(myThreat) or 0
    secondThreat = tonumber(secondThreat) or 0
    if myThreat <= 0 then
        return "red"
    end
    if secondThreat > myThreat then
        return "red"      -- someone else is ahead
    end
    local ratio = secondThreat / myThreat
    if ratio >= 0.90 then
        return "yellow"   -- someone is close to pulling
    end
    return "green"
end

-- Live snapshot of the tank actor's threat on the current target
-- (player by default; pet when "Use pet as Tank" is on)
local function CurrentTargetThreatSnapshot()
    local actor = GetTankActorName() or UnitName("player")
    local actorUnit = GetTankActorUnit()
    local myData = actor and Threat.threats[actor]
    local myThreat = myData and (myData.threat or 0) or 0
    local myPerc = myData and (myData.perc or 0) or 0
    -- Pet-as-tank: also try player row if pet has no estimate yet
    if PetAsTankEnabled() and myThreat <= 0 then
        local petName = GetLocalPetName()
        if petName and Threat.threats[petName] then
            myData = Threat.threats[petName]
            myThreat = myData.threat or 0
            myPerc = myData.perc or 0
            actor = petName
        end
    end
    local iAmTanking = UnitExists("targettarget") and UnitIsUnit(actorUnit, "targettarget")
    -- If looking at pettarget, check that unit's targettarget
    if not iAmTanking and PetAsTankEnabled() and UnitExists("pettarget") then
        if UnitExists("pettargettarget") and UnitIsUnit("pet", "pettargettarget") then
            iAmTanking = true
        end
    end
    local second = 0
    local n, d
    for n, d in pairs(Threat.threats) do
        if n ~= actor and not d.isPull and (d.threat or 0) > second then
            second = d.threat or 0
        end
    end

    local status
    if iAmTanking then
        status = EnemyStatusFromLead(myThreat, second)
        if myThreat <= 0 then
            myThreat = 1
            myPerc = 100
        end
    else
        status = "red"
        if myThreat <= 0 and myPerc <= 0 then
            myThreat = 0
        end
    end
    return myThreat, myPerc, status, iAmTanking
end


-- Resolve max HP / boss classification for a tank-mode enemy row.
-- Prefer GUID unit tokens when available, otherwise the current target
-- or party/raid members' targets.
local function ResolveEnemyMaxHP(guid, name)
    local function inspect(unit)
        if not unit or not UnitExists(unit) then return 0, false end
        if UnitIsPlayer(unit) or UnitIsFriend("player", unit) then return 0, false end
        local maxHP = UnitHealthMax(unit) or 0
        local isBoss = false
        if UnitClassification then
            local c = UnitClassification(unit)
            if c == "worldboss" then
                isBoss = true
            end
        end
        -- Level -1 is a classic boss marker on many 1.12 clients
        if UnitLevel then
            local lvl = UnitLevel(unit)
            if lvl and lvl < 0 then
                isBoss = true
            end
        end
        return maxHP, isBoss
    end

    if guid and type(guid) == "string"
        and not string.find(guid, "^name:")
        and not string.find(guid, "^row:")
        and not string.find(guid, "^test") then
        local hp, boss = inspect(guid)
        if hp > 0 or boss then return hp, boss end
    end

    if UnitExists("target") and not UnitIsPlayer("target") and not UnitIsFriend("player", "target") then
        local tGuid = GetUnitGUID("target")
        local tName = UnitName("target")
        if (guid and tGuid and tGuid == guid) or (name and tName and tName == name) then
            return inspect("target")
        end
    end

    -- Scan group targets for a matching GUID/name
    local function scan(unit)
        if not UnitExists(unit) then return nil end
        local uGuid = GetUnitGUID(unit)
        local uName = UnitName(unit)
        if (guid and uGuid and uGuid == guid) or (name and uName and uName == name) then
            local hp, boss = inspect(unit)
            return hp, boss
        end
        return nil
    end
    local i
    for i = 1, 4 do
        local hp, boss = scan("party" .. i .. "target")
        if hp then return hp, boss end
    end
    for i = 1, 40 do
        local hp, boss = scan("raid" .. i .. "target")
        if hp then return hp, boss end
    end
    return 0, false
end

-- Flag list entries whose max HP is much higher than the rest (boss among adds).
local function MarkBossesByRelativeHP(list)
    if not list or table.getn(list) < 2 then return end

    local hps = {}
    local i
    for i = 1, table.getn(list) do
        local hp = list[i].data and list[i].data.maxHP or 0
        if hp > 0 then
            table.insert(hps, hp)
        end
    end
    if table.getn(hps) < 2 then return end

    table.sort(hps, function(a, b) return a < b end)
    -- Median of the lower half (exclude the top outlier when computing "typical" add HP)
    local n = table.getn(hps)
    local typical
    if n >= 3 then
        -- median of all but the largest value
        local trimmed = n - 1
        local mid = math.floor((trimmed + 1) / 2)
        if math.mod(trimmed, 2) == 0 then
            typical = (hps[mid] + hps[mid + 1]) / 2
        else
            typical = hps[mid]
        end
    else
        typical = hps[1] -- smaller of the two
    end
    if not typical or typical <= 0 then return end

    -- Boss threshold: at least 2.5x typical add HP (and preferably the clear top)
    local threshold = typical * 2.5
    for i = 1, table.getn(list) do
        local d = list[i].data
        if d and not d.isBoss then
            local hp = d.maxHP or 0
            if hp >= threshold then
                d.isBoss = true
            end
        end
    end
end

-- ============================================================
-- Flee detection (tank mode LOST → FLEEING)
-- ============================================================

local FLEE_FLAG_DURATION = 8.0

local FLEE_DEBUFFS = {
    ["Fear"] = true,
    ["Psychic Scream"] = true,
    ["Intimidating Shout"] = true,
    ["Howl of Terror"] = true,
    ["Scare Beast"] = true,
    ["Seduction"] = true,
    ["Blind"] = true,
}

local function MarkEnemyFleeing(name, guid)
    local untilT = GetTime() + FLEE_FLAG_DURATION
    if guid and guid ~= "" then
        Threat.fleeingEnemies[guid] = untilT
    end
    if name and name ~= "" then
        Threat.fleeingEnemies[name] = untilT
    end
end

local function ClearEnemyFleeing(name, guid)
    if guid then Threat.fleeingEnemies[guid] = nil end
    if name then Threat.fleeingEnemies[name] = nil end
end

local function IsEnemyMarkedFleeing(name, guid)
    local now = GetTime()
    local t
    if guid then
        t = Threat.fleeingEnemies[guid]
        if t and t > now then return true end
        if t then Threat.fleeingEnemies[guid] = nil end
    end
    if name then
        t = Threat.fleeingEnemies[name]
        if t and t > now then return true end
        if t then Threat.fleeingEnemies[name] = nil end
    end
    return false
end

-- Live inspect: fear-like debuffs on a unit token (target / SuperWoW GUID)
local function UnitHasFleeDebuff(unit)
    if not unit or not UnitExists(unit) then return false end
    if not UnitDebuff then return false end
    local i
    for i = 1, 16 do
        -- 1.12 UnitDebuff returns texture, stacks, debuffType (no name on many clients)
        local texture, applications, debuffType = UnitDebuff(unit, i)
        if not texture then break end
        -- Prefer tooltip scan for the name when available
    end
    -- GameTooltip-based name scan (works on 1.12)
    if not GameTooltip or not GameTooltip.SetUnitDebuff then
        return false
    end
    for i = 1, 16 do
        local texture = UnitDebuff(unit, i)
        if not texture then break end
        GameTooltip:SetOwner(UIParent, "ANCHOR_NONE")
        GameTooltip:SetUnitDebuff(unit, i)
        local tipName = GameTooltipTextLeft1 and GameTooltipTextLeft1:GetText()
        GameTooltip:Hide()
        if tipName and FLEE_DEBUFFS[tipName] then
            return true
        end
        -- Partial match for ranked names
        if tipName then
            local k
            for k in pairs(FLEE_DEBUFFS) do
                if string.find(tipName, k, 1, true) then
                    return true
                end
            end
        end
    end
    return false
end

local function DetectFleeOnUnit(unit, name, guid)
    if UnitHasFleeDebuff(unit) then
        MarkEnemyFleeing(name, guid)
        return true
    end
    return IsEnemyMarkedFleeing(name, guid)
end

-- Combat log / emote lines that indicate a mob is fleeing
local function ParseFleeMessage(message)
    if not message or message == "" then return end
    local lower = string.lower(message)
    if not (string.find(lower, "flee", 1, true)
        or string.find(lower, "run away", 1, true)
        or string.find(lower, "runs away", 1, true)) then
        return
    end
    -- "%s attempts to run away in fear!" / "%s flees in fear!" / "X flees."
    local name
    local _
    _, _, name = string.find(message, "^(.+) attempts to run away")
    if not name then
        _, _, name = string.find(message, "^(.+) flees")
    end
    if not name then
        _, _, name = string.find(message, "^(.+) runs away")
    end
    if not name then return end
    name = string.gsub(name, "%s+$", "")
    if name == "" or name == "You" or name == "you" then return end
    MarkEnemyFleeing(name, nil)
end


function Threat:BuildEnemyList(hiddenNames)
    local list = {}

    -- Track player target and (when enabled) pet target
    RememberHostileTarget()

    local function RefreshActiveUnit(unit)
        if not unit or not UnitExists(unit) then return end
        if UnitIsPlayer(unit) or UnitIsFriend("player", unit) then return end
        local tName = UnitName(unit) or "Target"
        local tGuid = GetUnitGUID(unit) or ("name:" .. tName)
        local myThreat, myPerc, status = CurrentTargetThreatSnapshot()
        -- When using pet as tank and this is the player's target (not pettarget),
        -- still report the pet actor's status on that mob.
        local row = self.tankModeThreats[tGuid]
        if row then
            row.name = tName
            row.creature = row.creature or tName
            row.threat = myThreat
            row.perc = myPerc
            row.status = status
            if myThreat > 0 or status ~= "red" then
                row.estimated = not self.usingApi
            end
        end
    end

    RefreshActiveUnit("target")
    if PetAsTankEnabled() then
        RefreshActiveUnit("pettarget")
    end

    -- Multi-mob table is GUID-keyed so same-name mobs stay distinct
    local guid, info
    for guid, info in pairs(self.tankModeThreats) do
        local mobName = info.creature or info.name or "?"
        -- TMTv1: creature=mob, name=second-highest player, perc=their share
        -- Our estimation rows use name=mob. Prefer creature when it looks like a mob label.
        if info.creature and info.creature ~= "" then
            mobName = info.creature
        end
        local hideKey = guid or mobName
        if not hiddenNames or (not hiddenNames[mobName] and not hiddenNames[hideKey]) then
            local perc = tonumber(info.perc) or 0
            local threat = tonumber(info.threat) or 0
            local status = info.status
            local estimated = info.estimated

            -- API tank-mode rows: you are tanking this mob; perc is the runner-up's %
            if not info.isTest and not estimated and (info.guid or guid)
                and not string.find(tostring(guid), "^name:")
                and not string.find(tostring(guid), "^row:")
                and status == nil then
                -- Tanking: contested if second place is high
                if perc >= 90 then
                    status = "yellow"
                else
                    status = "green"
                end
                -- Sort key: lower margin → lower value → sorts nearer the top (danger)
                if threat <= 0 then
                    threat = math.max(1, 100 - perc)
                end
                -- Display perc as YOUR share (you're the tank on this row)
                perc = 100
            end

            if not status then
                status = EnemyStatusFromPerc(perc)
            end
            if threat <= 0 and status ~= "red" then
                threat = 1
            end
            if threat <= 0 and perc > 0 then
                threat = perc
            end

            local rowGuid = info.guid or guid
            local maxHP, isBossUnit = ResolveEnemyMaxHP(rowGuid, mobName)
            table.insert(list, {
                name  = mobName,
                data  = {
                    threat    = threat,
                    perc      = perc,
                    status    = status,
                    isEnemy   = true,
                    guid      = rowGuid,
                    creature  = info.creature,
                    estimated = estimated,
                    isTest    = info.isTest,
                    secondPlayer = (info.name and info.creature and info.name ~= info.creature) and info.name or nil,
                    maxHP     = maxHP,
                    isBoss    = isBossUnit,
                },
                value = threat,
            })
        end
    end

    -- Mark bosses by relative max HP: significantly tougher than peers in this list
    MarkBossesByRelativeHP(list)

    -- Annotate fleeing (combat-log/emote flag; live fear scan only on current target)
    local li
    for li = 1, table.getn(list) do
        local e = list[li]
        local d = e.data
        if d then
            local guid = d.guid
            local fleeing = IsEnemyMarkedFleeing(e.name, guid)
            if not fleeing and UnitExists("target") and UnitName("target") == e.name then
                fleeing = DetectFleeOnUnit("target", e.name, guid)
            end
            -- If we have solid aggro again, clear a stale flee flag
            if d.status == "green" or d.status == "yellow" then
                ClearEnemyFleeing(e.name, guid)
                fleeing = false
            end
            d.fleeing = fleeing and true or false
        end
    end

    -- Sort priority (top → bottom):
    --   1) Bosses still pinned first
    --   2) LOST (no aggro, not fleeing)
    --   3) FLEEING
    --   4) Contested / secure aggro (yellow / green)
    -- Within a group: lowest threat first (weakest hold nearer the top)
    local function AggroRank(d)
        if not d then return 1 end
        if d.fleeing then return 2 end
        local s = d.status
        if s == "green" or s == "yellow" then
            return 1  -- have / contested aggro — bottom group
        end
        return 3      -- LOST
    end

    table.sort(list, function(a, b)
        local aBoss = (a.data and a.data.isBoss) and 1 or 0
        local bBoss = (b.data and b.data.isBoss) and 1 or 0
        if aBoss ~= bBoss then
            return aBoss > bBoss
        end
        local ar = AggroRank(a.data)
        local br = AggroRank(b.data)
        if ar ~= br then
            return ar > br
        end
        if a.value == b.value then
            local ga = (a.data and a.data.guid) or a.name
            local gb = (b.data and b.data.guid) or b.name
            return tostring(ga) < tostring(gb)
        end
        return a.value < b.value
    end)

    -- Disambiguate identical names
    local nameCounts = {}
    local i
    for i = 1, table.getn(list) do
        local n = list[i].name
        nameCounts[n] = (nameCounts[n] or 0) + 1
    end
    local nameIndex = {}
    for i = 1, table.getn(list) do
        local e = list[i]
        e.rank = i
        if nameCounts[e.name] and nameCounts[e.name] > 1 then
            nameIndex[e.name] = (nameIndex[e.name] or 0) + 1
            local suffix = ShortGuidSuffix(e.data and e.data.guid)
            if suffix and not string.find(tostring(e.data.guid), "^name:")
                and not string.find(tostring(e.data.guid), "^row:")
                and not string.find(tostring(e.data.guid), "^test") then
                e.displayName = e.name .. " [" .. suffix .. "]"
            else
                e.displayName = e.name .. " #" .. tostring(nameIndex[e.name])
            end
        else
            e.displayName = e.name
        end
    end
    return list
end

-- ============================================================
-- Sorted list for the meter
-- ============================================================

-- Accumulate fight-total threat generated per player (not target-specific)
-- Rebuild overallThreat from per-target API snapshots when possible.
-- The server API returns every party/raid member's threat on one mob
-- (the current target). It does not return a full player×mob matrix. So we:
--   1) Store each packet under that mob's key (GUID or name)
--   2) Sum each player's threat across all mobs observed this fight
function Threat:UpdateOverallFromPlayerThreats()
    local targetKey = self.currentTargetKey
    if not targetKey then
        -- Fall back to name of current target if known
        if UnitExists("target") and not UnitIsPlayer("target") then
            targetKey = GetUnitGUID("target") or ("name:" .. (UnitName("target") or "?"))
            self.currentTargetKey = targetKey
        end
    end

    local anyApi = false
    local name, data

    -- If we have a live target key, snapshot current threats table into that bucket
    if targetKey then
        if not self.threatByTarget[targetKey] then
            self.threatByTarget[targetKey] = {}
        end
        local bucket = self.threatByTarget[targetKey]
        for name, data in pairs(self.threats) do
            if name and not data.isPull then
                bucket[name] = data.threat or 0
                if data.estimated == false then
                    anyApi = true
                end
            end
        end
    end

    -- Sum across all observed targets for each player
    local totals = {}  -- [player] = { threat, class, tank, tps, estimated }
    local tKey, bucket
    for tKey, bucket in pairs(self.threatByTarget) do
        for name, threat in pairs(bucket) do
            local row = totals[name]
            if not row then
                row = { threat = 0, class = GetPlayerClass(name), tank = false, tps = 0, estimated = false }
                totals[name] = row
            end
            row.threat = row.threat + (threat or 0)
        end
    end

    -- Overlay class/tank/tps/estimated from the live single-target table
    for name, data in pairs(self.threats) do
        if name and not data.isPull then
            local row = totals[name]
            if not row then
                -- No per-target buckets yet (estimate-only path): keep previous behavior
                local prev = self.overallThreat[name]
                local prevT = prev and prev.threat or 0
                local t = data.threat or 0
                local best = t
                if prevT > best then best = prevT end
                if data.estimated == false and t > prevT then
                    best = t
                end
                self.overallThreat[name] = {
                    threat    = best,
                    class     = data.class or GetPlayerClass(name),
                    estimated = data.estimated and true or false,
                    tank      = data.tank,
                    tps       = data.tps or 0,
                }
            else
                row.class = data.class or row.class or GetPlayerClass(name)
                row.tank = data.tank or row.tank
                row.tps = data.tps or row.tps
                if data.estimated == false then
                    row.estimated = false
                end
            end
        end
    end

    for name, row in pairs(totals) do
        self.overallThreat[name] = {
            threat    = row.threat,
            class     = row.class,
            estimated = row.estimated,
            tank      = row.tank,
            tps       = row.tps,
        }
    end
end

-- Enemies currently targeting a given player (group-visible hostile units)
-- Returns ordered list of unique enemy names.
function Threat:GetEnemiesTargetingPlayer(playerName)
    local names = {}
    if not playerName or playerName == "" then return names end

    -- One unit-token scan per player per data generation (shared across windows)
    if self.targetingCacheGen == self.dataGen and self.targetingCache[playerName] then
        return self.targetingCache[playerName]
    end
    if self.targetingCacheGen ~= self.dataGen then
        self.targetingCache = {}
        self.targetingCacheGen = self.dataGen or 0
    end

    local seen = {}

    local function considerEnemyUnit(unit)
        if not unit or not UnitExists(unit) then return end
        if UnitIsPlayer(unit) or UnitIsFriend("player", unit) then return end
        if UnitIsDead(unit) or UnitIsCorpse(unit) then return end
        local tt = unit .. "target"
        if not UnitExists(tt) then return end
        if UnitName(tt) ~= playerName then return end
        local enemyName = UnitName(unit)
        if not enemyName or enemyName == "" then return end
        local key = GetUnitGUID(unit) or (enemyName .. ":" .. tostring(UnitHealth(unit)))
        if seen[key] then return end
        seen[key] = true
        table.insert(names, enemyName)
    end

    -- Direct unit tokens
    considerEnemyUnit("target")
    considerEnemyUnit("mouseover")
    considerEnemyUnit("pettarget")

    -- Party / raid members' targets (common way to see adds in 1.12)
    local i
    for i = 1, 4 do
        considerEnemyUnit("party" .. i .. "target")
        considerEnemyUnit("partypet" .. i .. "target")
    end
    for i = 1, 40 do
        considerEnemyUnit("raid" .. i .. "target")
        considerEnemyUnit("raidpet" .. i .. "target")
    end

    -- Known GUID-keyed enemies can be addressed as unit tokens on some clients
    if HasSuperWoW() then
        local guid, info
        for guid, info in pairs(self.tankModeThreats) do
            if type(guid) == "string" and not string.find(guid, "^name:")
                and not string.find(guid, "^row:")
                and not string.find(guid, "^test") then
                considerEnemyUnit(guid)
            end
        end
    end

    self.targetingCache[playerName] = names
    return names
end

-- Stable fake "targeted by" lists for Test mode previews
local function FakeTargetingForTest(playerName, isTank)
    if isTank then
        return { "Onyxia", "Onyxian Warder", "Onyxian Warder", "Onyxian Guard" }
    end
    -- Lightweight pseudo-random from name length so rows look different
    local n = string.len(playerName or "")
    if math.mod(n, 5) == 0 then
        return { "Onyxian Whelp" }
    elseif math.mod(n, 5) == 1 then
        return { "Onyxian Whelp", "Onyxian Whelp" }
    elseif math.mod(n, 5) == 2 then
        return { "Lava Spawn" }
    end
    return {}
end

function Threat:BuildOverallList(hiddenNames)
    local list = {}
    local name, data
    for name, data in pairs(self.overallThreat) do
        if not hiddenNames or not hiddenNames[name] then
            local value = data.threat or 0
            if value > 0 then
                local targeting = self:GetEnemiesTargetingPlayer(name)
                if self.testDataActive and table.getn(targeting) == 0 then
                    targeting = FakeTargetingForTest(name, data.tank)
                end
                table.insert(list, {
                    name = name,
                    data = {
                        threat         = value,
                        perc           = 0,
                        tank           = data.tank,
                        tps            = data.tps or 0,
                        class          = data.class,
                        estimated      = data.estimated,
                        isOverall      = true,
                        isTest         = self.testDataActive,
                        targetedBy     = targeting,
                        targetedByCount = table.getn(targeting),
                    },
                    value = value,
                })
            end
        end
    end
    -- Also include anyone present only in current target threats
    for name, data in pairs(self.threats) do
        if not data.isPull and (not self.overallThreat[name] or (self.overallThreat[name].threat or 0) <= 0) then
            if not hiddenNames or not hiddenNames[name] then
                local value = data.threat or 0
                if value > 0 then
                    local targeting = self:GetEnemiesTargetingPlayer(name)
                    if self.testDataActive and table.getn(targeting) == 0 then
                        targeting = FakeTargetingForTest(name, data.tank)
                    end
                    table.insert(list, {
                        name = name,
                        data = {
                            threat         = value,
                            perc           = data.perc or 0,
                            tank           = data.tank,
                            tps            = data.tps or 0,
                            class          = data.class,
                            estimated      = data.estimated,
                            isOverall      = true,
                            isTest         = self.testDataActive,
                            targetedBy     = targeting,
                            targetedByCount = table.getn(targeting),
                        },
                        value = value,
                    })
                end
            end
        end
    end
    table.sort(list, function(a, b)
        if a.value == b.value then return a.name < b.name end
        return a.value > b.value
    end)
    local maxVal = 0
    if list[1] then maxVal = list[1].value or 0 end
    local i
    for i = 1, table.getn(list) do
        list[i].rank = i
        if maxVal > 0 then
            list[i].data.perc = math.floor((list[i].value / maxVal) * 100 + 0.5)
        end
    end
    return list
end

function Threat:GetSortedList(hiddenNames, mode)
    mode = mode or "threat"
    local view = EffectiveView(mode)
    local gen = self.dataGen or 0

    -- Shared list cache: multiple windows on the same view reuse one build
    local function filterHidden(src)
        if not src then return {} end
        if not hiddenNames then
            -- Shallow copy so RefreshFrame can append a Total row safely
            local copy = {}
            local i
            for i = 1, table.getn(src) do
                copy[i] = src[i]
            end
            return copy
        end
        local out = {}
        local i
        for i = 1, table.getn(src) do
            local e = src[i]
            local hideKey = (e.data and e.data.guid) or e.name
            if not hiddenNames[e.name] and not hiddenNames[hideKey] then
                table.insert(out, e)
            end
        end
        for i = 1, table.getn(out) do
            out[i].rank = i
        end
        return out
    end

    local cached = self.listCache and self.listCache[view]
    -- Tank list includes live flee/HP probes — reuse briefly, then rebuild
    -- Single-target must refresh often so targettarget (aggro) switches show up
    local maxAge = 0.5
    if cached and cached.gen == gen and cached.list then
        local age = GetTime() - (cached.time or 0)
        if age <= maxAge then
            return filterHidden(cached.list)
        end
    end

    local list
    if view == "tank" then
        list = self:BuildEnemyList(nil)  -- unfiltered; hide applied below
    elseif view == "overall" then
        self:UpdateOverallFromPlayerThreats()
        list = self:BuildOverallList(nil)
    else
        -- Single-target Threat mode → players + Pull Aggro row
        -- Live aggro always comes from who the enemy is attacking right now.
        -- Estimates/API numbers can lag; targettarget is ground truth for "has threat".
        local aggroName = nil
        if UnitExists("target") and UnitExists("targettarget")
            and not UnitIsDead("targettarget") then
            aggroName = UnitName("targettarget")
        end
        -- When using pet as tank and looking at pet's mob, prefer pettargettarget
        if PetAsTankEnabled() and UnitExists("pettarget") and UnitExists("pettargettarget")
            and not UnitIsDead("pettargettarget") then
            -- If player has no target or target is the pet's mob, use pet's aggro target
            if not aggroName or (UnitExists("target") and UnitIsUnit("target", "pettarget")) then
                aggroName = UnitName("pettargettarget")
            end
        end

        -- If the live aggro holder changed, force a fresh list even if dataGen is stale
        if aggroName ~= self._lastAggroName then
            self._lastAggroName = aggroName
            -- don't return cached below — we're already past the cache check with a rebuild
        end

        list = {}
        local name, data
        for name, data in pairs(self.threats) do
            local value = data.threat or 0
            if not data.isPull then
                -- Override tank flag from live unit targeting
                if aggroName and name == aggroName then
                    data.tank = true
                    self.tankName = name
                else
                    data.tank = false
                end
            end
            if value > 0 or data.tank or data.isPull then
                table.insert(list, {
                    name  = name,
                    data  = data,
                    value = value,
                })
            end
        end

        -- If the mob is on someone not yet in the threat table (common mid-estimate),
        -- inject a row so they still appear at the top.
        if aggroName and not self.threats[aggroName] then
            local injected = {
                threat    = 1,
                perc      = 100,
                tank      = true,
                tps       = 0,
                melee     = false,
                class     = GetPlayerClass(aggroName),
                estimated = true,
            }
            self.threats[aggroName] = injected
            self.tankName = aggroName
            table.insert(list, {
                name  = aggroName,
                data  = injected,
                value = 1,
            })
        end

        table.sort(list, function(a, b)
            local aPull = a.data and a.data.isPull
            local bPull = b.data and b.data.isPull
            local aTank = a.data and a.data.tank and not aPull
            local bTank = b.data and b.data.tank and not bPull

            -- Whoever currently has aggro is always first (above Pull Aggro too)
            if aTank and not bTank then return true end
            if bTank and not aTank then return false end

            if aPull and not bPull then
                return a.value > (b.value or 0)
            end
            if bPull and not aPull then
                return (a.value or 0) > b.value
            end
            if a.value == b.value then
                return (a.name or "") < (b.name or "")
            end
            return a.value > b.value
        end)

        local i
        for i = 1, table.getn(list) do
            list[i].rank = i
        end
    end

    if not self.listCache then self.listCache = {} end
    self.listCache[view] = { gen = gen, list = list, time = GetTime() }
    return filterHidden(list)
end

function Threat:AnyFrameInThreatMode()
    if not UI or not UI.frames then return false end
    local _, f
    for _, f in ipairs(UI.frames) do
        if f:IsShown() and IsThreatModeKey(f.mode) then
            return true
        end
    end
    return false
end

function Threat:AnyFrameInTankView()
    if not UI or not UI.frames then return false end
    local _, f
    for _, f in ipairs(UI.frames) do
        if f:IsShown() and TankViewActive(f.mode) then
            return true
        end
    end
    return false
end

-- ============================================================
-- UI hooks
-- ============================================================

-- Format secondary text for a threat entry (used by our own RefreshFrame path)

local function FormatThreatSecondary(data)
    if not data then return "0" end

    -- Enemy row (Tank view)
    if data.isEnemy then
        local perc = data.perc or 0
        local threat = data.threat or 0
        local text
        if UI.FormatNumber then
            text = UI.FormatNumber(threat)
        else
            text = tostring(math.floor(threat + 0.5))
        end
        text = text .. " (" .. tostring(math.floor(perc + 0.5)) .. "%)"
        if data.status == "green" then
            text = text .. " OK"
        elseif data.status == "yellow" then
            text = text .. " !!"
        elseif data.fleeing then
            text = text .. " FLEEING"
        else
            text = text .. " LOST"
        end
        if data.estimated then text = text .. "*" end
        return text
    end

    -- Overall fight threat (respects Customization column toggles)
    if data.isOverall then
        local function show(key)
            if UI.GetColumnSetting then
                return UI.GetColumnSetting("overall", key)
            end
            -- Fallbacks if helpers not loaded yet
            if key == "share" or key == "rate" then return false end
            return true
        end

        local threat = data.threat or 0
        local perc   = data.perc or 0
        local tps    = data.tps or 0
        local count  = data.targetedByCount or 0
        local text   = ""

        if show("amount") then
            if UI.FormatNumber then
                text = UI.FormatNumber(threat)
            else
                text = tostring(math.floor(threat + 0.5))
            end
        end

        if show("share") then
            text = text .. " (" .. tostring(math.floor(perc + 0.5)) .. "%)"
        end

        if show("rate") and tps and tps > 0 then
            if UI.FormatNumber then
                text = text .. " " .. UI.FormatNumber(tps)
            else
                text = text .. " " .. string.format("%.0f", tps)
            end
        end

        -- "Targeted by" — enemy count in parentheses (was always on before)
        if show("targeted") then
            text = text .. " (" .. tostring(count) .. ")"
        end

        if data.estimated then
            text = text .. "*"
        end
        if text == "" or text == "*" then
            return "0"
        end
        return text
    end

    if data.isPull then
        local t
        if UI.FormatNumber then
            t = UI.FormatNumber(data.threat or 0)
        else
            t = tostring(math.floor((data.threat or 0) + 0.5))
        end
        return t .. " (" .. tostring(data.perc or 0) .. "%)"
    end

    local threat = data.threat or 0
    local perc   = data.perc or 0
    local tps    = data.tps or 0

    local function show(key)
        if UI.GetColumnSetting then
            return UI.GetColumnSetting("threat", key)
        end
        return true
    end

    local text = ""
    if show("amount") then
        if UI.FormatNumber then
            text = UI.FormatNumber(threat)
        else
            text = tostring(math.floor(threat + 0.5))
        end
    end

    -- % of main tank / raw percent
    if show("share") then
        local shareStr
        if Threat.tankName and not data.tank then
            local tankData = Threat.threats[Threat.tankName]
            local tankThreat = tankData and tankData.threat or 0
            if tankThreat > 0 then
                local ofTank = math.floor((threat / tankThreat) * 100 + 0.5)
                shareStr = " (" .. tostring(ofTank) .. "% MT)"
            else
                shareStr = " (" .. tostring(perc) .. "%)"
            end
        else
            shareStr = " (" .. tostring(perc) .. "%)"
        end
        text = text .. shareStr
    end

    if show("rate") and tps and tps > 0 then
        if UI.FormatNumber then
            text = text .. "(" .. UI.FormatNumber(tps) .. ")"
        else
            text = text .. "(" .. string.format("%.0f", tps) .. ")"
        end
    end
    if data.estimated then
        text = text .. "*"
    end
    if text == "" or text == "*" then
        return "0"
    end
    return text
end

local function GetThreatBarColor(name, data)
    -- Tank mode enemy colors
    if data and data.isEnemy then
        if data.status == "green" then
            return 0.2, 0.85, 0.2
        elseif data.status == "yellow" then
            return 1.0, 0.85, 0.15
        else
            return 0.95, 0.2, 0.2
        end
    end

    if OM.GetSetting and OM:GetSetting("classColors") == false then
        return 0.55, 0.55, 0.55
    end
    -- Pull Aggro threshold row stays distinct (not a player)
    if data and data.isPull then
        return 1.0, 0.35, 0.35
    end
    -- Always use class color for players (including the current tank)
    local class = data and data.class
    if not class and OM.players and OM.players[name] then
        class = OM.players[name].class
    end
    if not class and name == UnitName("player") then
        local _, c = UnitClass("player")
        class = c
    end
    local colors = UI.CLASS_COLORS
    if class and colors and colors[class] then
        return colors[class][1], colors[class][2], colors[class][3]
    end
    return 0.6, 0.6, 0.6
end

-- TargetEnemy is defined above with SuperWoW GUID support

-- Drive the meter bars for threat mode. Frames.lua captures local copies of
-- BuildSortedList / GetMetric / GetSecondaryText at load time, so replacing
-- UI.BuildSortedList never reaches RefreshFrame. We therefore own the full
-- refresh path when f.mode == "threat".
function Threat:RefreshFrame(f)
    if not f then return end

    -- Ensure test data is present when Test mode is on (no party required)
    if OM:GetSetting("testMode") == true then
        if not self.testDataActive then
            self:LoadTestData()
        end
    end

    if not f.visibleBars and UI.LayoutBars then
        UI:LayoutBars(f)
    end

    local mode = f.mode or "threat"
    local view = EffectiveView(mode)
    local tankMode = (view == "tank")
    local overallMode = (view == "overall")

    if f.title then
        if tankMode then
            f.title:SetText((UI.MODE_LABELS and UI.MODE_LABELS.tank) or "Tank")
        elseif overallMode then
            f.title:SetText((UI.MODE_LABELS and UI.MODE_LABELS.overall) or "Overall Threat")
        else
            f.title:SetText((UI.MODE_LABELS and UI.MODE_LABELS.threat) or "Threat")
        end
    end

    local list = self:GetSortedList(f.hiddenNames, mode)

    -- Optional total bar (player lists only — not for enemy tank mode)
    if not tankMode and OM.GetSetting and OM:GetSetting("showTotal") and table.getn(list) > 0 then
        local totalVal = 0
        local _, entry
        for _, entry in ipairs(list) do
            if not entry.data or not entry.data.isPull then
                totalVal = totalVal + (entry.value or 0)
            end
        end
        table.insert(list, {
            name = "Total",
            data = { threat = totalVal, perc = 100, tank = false, tps = 0 },
            value = totalVal,
            isTotal = true,
        })
    end

    local maxVal = 0
    local _, entry
    for _, entry in ipairs(list) do
        if not entry.isTotal and entry.value and entry.value > maxVal then
            maxVal = entry.value
        end
    end
    if maxVal <= 0 and list[1] then
        maxVal = list[1].value or 1
    end
    if maxVal <= 0 then maxVal = 1 end

    local hideTitle = OM.GetSetting and OM:GetSetting("hideTitle") == true
    if UI.ApplyHeaderLayout then
        UI:ApplyHeaderLayout(f, hideTitle, 0)
    end

    local MAX_BARS = UI.MAX_BARS or 40
    local fit = f.visibleBars or MAX_BARS

    local hasTotal = false
    local totalEntry = nil
    local playerList = {}
    for _, entry in ipairs(list) do
        if entry.isTotal then
            hasTotal = true
            totalEntry = entry
        else
            table.insert(playerList, entry)
        end
    end

    local playerSlots = fit
    if hasTotal and fit > 1 then
        playerSlots = fit - 1
    elseif hasTotal and fit == 1 then
        playerSlots = 0
    end

    local playerCount = table.getn(playerList)
    local maxScroll = playerCount - playerSlots
    if maxScroll < 0 then maxScroll = 0 end
    f.maxScroll = maxScroll
    if not f.scrollOffset then f.scrollOffset = 0 end
    if f.scrollOffset > maxScroll then f.scrollOffset = maxScroll end
    if f.scrollOffset < 0 then f.scrollOffset = 0 end
    local scroll = f.scrollOffset

    local barH = 16
    if OM.GetSetting then
        barH = tonumber(OM:GetSetting("barHeight")) or 16
    end

    local shown = 0
    local i
    for i = 1, MAX_BARS do
        local bar = f.bars and f.bars[i]
        if not bar then break end

        local entry = nil
        if i <= playerSlots then
            entry = playerList[i + scroll]
        elseif hasTotal and i == playerSlots + 1 then
            entry = totalEntry
        end

        if entry and i <= fit then
            shown = shown + 1
            local pct = (entry.value or 0) / maxVal
            if pct > 1 then pct = 1 end
            if pct < 0 then pct = 0 end

            bar:Show()
            bar:SetValue(pct)

            local r, g, b
            if entry.isTotal then
                r, g, b = 0.7, 0.7, 0.7
            else
                r, g, b = GetThreatBarColor(entry.name, entry.data)
            end
            bar:SetStatusBarColor(r, g, b, 0.9)

            local rank = entry.rank or (i + scroll)
            local isEnemy = entry.data and entry.data.isEnemy
            local showIcon = OM.GetSetting and OM:GetSetting("showClassIcons")
                and not (entry.data and entry.data.isPull)
                and not isEnemy
                and not entry.isTotal

            if showIcon and bar.classIcon then
                local class = entry.data and entry.data.class
                local coords = UI.CLASS_ICON_TCOORDS and class and UI.CLASS_ICON_TCOORDS[class]
                if coords then
                    bar.classIcon:SetWidth(barH)
                    bar.classIcon:SetHeight(barH)
                    bar.classIcon:SetTexture("Interface\\Glues\\CharacterCreate\\UI-CharacterCreate-Classes")
                    bar.classIcon:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
                    bar.classIcon:Show()
                    bar.nameText:ClearAllPoints()
                    bar.nameText:SetPoint("LEFT", bar.classIcon, "RIGHT", 2, 0)
                else
                    bar.classIcon:Hide()
                    bar.nameText:ClearAllPoints()
                    bar.nameText:SetPoint("LEFT", bar, "LEFT", 4, 0)
                end
            else
                if bar.classIcon then bar.classIcon:Hide() end
                if bar.nameText then
                    bar.nameText:ClearAllPoints()
                    bar.nameText:SetPoint("LEFT", bar, "LEFT", 4, 0)
                end
            end

            if bar.nameText then
                if entry.data and entry.data.isPull then
                    bar.nameText:SetText(entry.name)
                else
                    local label = entry.displayName or entry.name
                    if UI.FormatBarName then
                        bar.nameText:SetText(UI.FormatBarName(rank, label, mode))
                    else
                        bar.nameText:SetText(rank .. ". " .. label)
                    end
                end
            end
            if bar.valueText then
                bar.valueText:SetText(FormatThreatSecondary(entry.data))
            end

            bar.entry = entry
            bar.mode = mode
            bar.duration = 0

            -- Tank view: click a bar to target that enemy (taunt / switch assist).
            -- StatusBar is not a Button in 1.12, so OnClick is unavailable — use OnMouseUp.
            -- With SuperWoW, TargetUnit(guid) selects the exact mob even when names match.
            if isEnemy then
                bar:SetScript("OnMouseUp", function()
                    if arg1 ~= "LeftButton" then return end
                    local e = this.entry
                    if e then
                        TargetEnemy(e)
                    end
                end)
            else
                bar:SetScript("OnMouseUp", nil)
            end
        else
            bar:Hide()
            bar.entry = nil
            bar:SetScript("OnMouseUp", nil)
        end
    end

    if f.emptyLabel then
        if shown == 0 then
            f.emptyLabel:Show()
        else
            f.emptyLabel:Hide()
        end
    end
end

local function InstallUIHooks()
    if Threat._hooksInstalled then return end
    Threat._hooksInstalled = true

    -- Own the refresh path for threat modes (see note above about Frames.lua locals)
    if UI.RefreshFrame then
        local oldRefreshFrame = UI.RefreshFrame
        UI.RefreshFrame = function(self, f)
            if f and IsThreatModeKey(f.mode) then
                return Threat:RefreshFrame(f)
            end
            return oldRefreshFrame(self, f)
        end
    end

    -- Tooltip: bar OnEnter often calls UI.ShowBarTooltip if present
    local oldTooltip = UI.ShowBarTooltip
    if oldTooltip then
        UI.ShowBarTooltip = function(bar)
            if bar and IsThreatModeKey(bar.mode) and bar.entry and bar.entry.data then
                local d = bar.entry.data
                GameTooltip:SetOwner(bar, "ANCHOR_RIGHT")
                if d.isEnemy then
                    GameTooltip:AddLine(bar.entry.name or "?", 1, 1, 1)
                    GameTooltip:AddDoubleLine("Your threat", tostring(math.floor((d.threat or 0) + 0.5)), 0.8, 0.8, 0.8, 1, 1, 1)
                    GameTooltip:AddDoubleLine("% of max", tostring(math.floor((d.perc or 0) + 0.5)) .. "%", 0.8, 0.8, 0.8, 1, 1, 1)
                    if d.status == "green" then
                        GameTooltip:AddLine("Solid threat lead", 0.2, 1, 0.2)
                    elseif d.status == "yellow" then
                        GameTooltip:AddLine("Contested — someone is close", 1, 0.85, 0.2)
                    else
                        GameTooltip:AddLine("You do not have aggro", 1, 0.3, 0.3)
                    end
                    GameTooltip:AddLine("Click to target", 0.6, 0.6, 0.6)
                elseif d.isOverall then
                    GameTooltip:AddLine(bar.entry.name or "?", 1, 1, 1)
                    GameTooltip:AddDoubleLine("Total threat", tostring(math.floor((d.threat or 0) + 0.5)), 0.8, 0.8, 0.8, 1, 1, 1)
                    if d.perc and d.perc > 0 then
                        GameTooltip:AddDoubleLine("% of max", tostring(d.perc) .. "%", 0.8, 0.8, 0.8, 1, 1, 1)
                    end
                    local count = d.targetedByCount or 0
                    GameTooltip:AddDoubleLine("Enemies targeting", tostring(count), 0.8, 0.8, 0.8, 1, 0.85, 0.3)
                    if d.targetedBy and table.getn(d.targetedBy) > 0 then
                        GameTooltip:AddLine("Targeted by:", 0.7, 0.7, 0.7)
                        local ti
                        for ti = 1, table.getn(d.targetedBy) do
                            GameTooltip:AddLine("  " .. d.targetedBy[ti], 1, 0.85, 0.4)
                        end
                    elseif count == 0 then
                        GameTooltip:AddLine("No visible enemies targeting this player.", 0.5, 0.5, 0.5)
                    end
                elseif d.isPull then
                    GameTooltip:AddLine("Pull Aggro Threshold", 1, 0.4, 0.4)
                    GameTooltip:AddLine("Threat needed to pull from the current tank.", 0.7, 0.7, 0.7, 1)
                    GameTooltip:AddDoubleLine("Threshold", tostring(math.floor((d.threat or 0) + 0.5)), 0.8, 0.8, 0.8, 1, 1, 1)
                    GameTooltip:AddDoubleLine("% of tank", tostring(d.perc or 0) .. "%", 0.8, 0.8, 0.8, 1, 1, 1)
                else
                    GameTooltip:AddLine(bar.entry.name or "?", 1, 1, 1)
                    GameTooltip:AddDoubleLine("Threat", tostring(math.floor((d.threat or 0) + 0.5)), 0.8, 0.8, 0.8, 1, 1, 1)
                    GameTooltip:AddDoubleLine("% of max", tostring(d.perc or 0) .. "%", 0.8, 0.8, 0.8, 1, 1, 1)
                    if Threat.tankName and Threat.threats[Threat.tankName] then
                        local tt = Threat.threats[Threat.tankName].threat or 0
                        if tt > 0 then
                            local ofTank = math.floor(((d.threat or 0) / tt) * 100 + 0.5)
                            GameTooltip:AddDoubleLine("% of tank", ofTank .. "%", 0.8, 0.8, 0.8, 1, 1, 1)
                            local toPull = (tt * ((d.melee and 1.1) or 1.3)) - (d.threat or 0)
                            if toPull < 0 then toPull = 0 end
                            GameTooltip:AddDoubleLine("Threat to pull", tostring(math.floor(toPull + 0.5)), 0.8, 0.8, 0.8, 1, 0.5, 0.5)
                        end
                    end
                    if d.tps and d.tps > 0 then
                        GameTooltip:AddDoubleLine("TPS", string.format("%.1f", d.tps), 0.8, 0.8, 0.8, 1, 1, 1)
                    end
                    if d.tank then
                        GameTooltip:AddLine("Tanking", 0.2, 1, 0.2)
                    end
                end
                if d.isTest then
                    GameTooltip:AddLine("Test data", 0.5, 0.8, 1)
                elseif d.estimated then
                    GameTooltip:AddLine("Estimated (no Turtle API)", 1, 0.7, 0.2)
                else
                    GameTooltip:AddLine("Turtle Threat API", 0.4, 1, 0.4)
                end
                if Threat.tankName and not d.isEnemy then
                    GameTooltip:AddLine("Tank: " .. Threat.tankName, 0.6, 0.8, 1)
                end
                GameTooltip:Show()
                return
            end
            return oldTooltip(bar)
        end
    end
end

-- ============================================================
-- Mode list management
-- ============================================================

local THREAT_MODE_KEYS = { "threat", "tank", "overall" }

local function EnsureModeInList(enabled)
    if not UI.MODE_ORDER or not UI.MODE_LABELS then return end

    -- IMPORTANT: mutate the existing table in place.
    -- UI/Frames.lua keeps a local reference (local MODE_ORDER = UI.MODE_ORDER)
    -- captured at load time. Replacing UI.MODE_ORDER with a new table would
    -- leave that local pointing at the old list and the Mode dropdown would
    -- never show our modes.
    local i, k
    for i = table.getn(UI.MODE_ORDER), 1, -1 do
        local key = UI.MODE_ORDER[i]
        if key == "threat" or key == "tank" or key == "overall" then
            table.remove(UI.MODE_ORDER, i)
        end
    end
    UI.MODE_LABELS.threat = nil
    UI.MODE_LABELS.tank = nil
    UI.MODE_LABELS.overall = nil

    if not enabled then
        if UI.frames then
            local _, f
            for _, f in ipairs(UI.frames) do
                if IsThreatModeKey(f.mode) then
                    f.mode = "damage"
                    if f.title then f.title:SetText(UI.MODE_LABELS.damage or "Damage") end
                    if UI.RefreshFrame then UI:RefreshFrame(f) end
                end
            end
        end
        return
    end

    local view = GetThreatView()
    if view == "all" then
        table.insert(UI.MODE_ORDER, "threat")
        table.insert(UI.MODE_ORDER, "tank")
        table.insert(UI.MODE_ORDER, "overall")
        UI.MODE_LABELS.threat  = "Threat"
        UI.MODE_LABELS.tank    = "Tank"
        UI.MODE_LABELS.overall = "Overall Threat"
    elseif view == "tank" then
        table.insert(UI.MODE_ORDER, "tank")
        UI.MODE_LABELS.tank = "Tank"
    elseif view == "overall" then
        table.insert(UI.MODE_ORDER, "overall")
        UI.MODE_LABELS.overall = "Overall Threat"
    else
        table.insert(UI.MODE_ORDER, "threat")
        UI.MODE_LABELS.threat = "Threat"
    end

    -- If a frame is stuck on a mode that was removed, snap to a valid one
    if UI.frames then
        local valid = {}
        if view == "all" then
            valid.threat = true
            valid.tank = true
            valid.overall = true
        elseif view == "tank" then
            valid.tank = true
        elseif view == "overall" then
            valid.overall = true
        else
            valid.threat = true
        end
        local _, f
        for _, f in ipairs(UI.frames) do
            if IsThreatModeKey(f.mode) and not valid[f.mode] then
                if valid.threat then
                    f.mode = "threat"
                elseif valid.tank then
                    f.mode = "tank"
                elseif valid.overall then
                    f.mode = "overall"
                else
                    f.mode = "damage"
                end
                if UI.RefreshFrame then UI:RefreshFrame(f) end
            end
        end
    end
end

-- ============================================================
-- Settings checkboxes (parent + child, non-colliding)
-- ============================================================

local function SyncChildEnabled(parentCb, childCb, parentKey)
    local parentOn = OM:GetSetting(parentKey) == true
    if parentOn then
        childCb:Enable()
        if childCb.label then childCb.label:SetTextColor(1, 1, 1) end
    else
        childCb:Disable()
        if childCb.label then childCb.label:SetTextColor(0.5, 0.5, 0.5) end
        -- Force child off when parent is off
        if OM:GetSetting(childCb.settingKey) then
            OM:SetSetting(childCb.settingKey, false)
            childCb:SetChecked(nil)
            if childCb.onToggle then childCb.onToggle(false) end
        end
    end
end

local THREAT_VIEW_OPTIONS = {
    { key = "single",  label = "Single target" },
    { key = "tank",    label = "Tank" },
    { key = "overall", label = "Overall" },
    { key = "all",     label = "All" },
}

local function ThreatViewLabel(key)
    local i
    for i = 1, table.getn(THREAT_VIEW_OPTIONS) do
        if THREAT_VIEW_OPTIONS[i].key == key then
            return THREAT_VIEW_OPTIONS[i].label
        end
    end
    return "Single target"
end

local function AddThreatCheckboxToSettings(f)
    if not f or f._greedThreatCheckbox then return end

    local extras = OM.extraSettingsCheckboxes or {}
    if table.getn(extras) == 0 then return end

    table.sort(extras, function(a, b)
        return (a.order or 100) < (b.order or 100)
    end)

    -- Rows: parent checkbox + optional child dropdown (counts as 2 rows) + child checkboxes
    local totalRows = 0
    local i
    for i = 1, table.getn(extras) do
        totalRows = totalRows + 1
        if extras[i].childDropdown then
            totalRows = totalRows + 1 -- one combined label+dropdown row
        end
        if extras[i].children then
            totalRows = totalRows + table.getn(extras[i].children)
        end
    end

    -- Sit above the bottom Customization / Close buttons (~36-44px)
    local baseY = 44
    local rowH  = 22
    local dropH = 32 -- UIDropDownMenu is taller than a checkbox row
    -- Extra vertical space if any dropdown is present
    local hasDrop = false
    for i = 1, table.getn(extras) do
        if extras[i].childDropdown then hasDrop = true break end
    end
    local y = baseY + (totalRows - 1) * rowH + (hasDrop and (dropH - rowH) or 0)

    for i = 1, table.getn(extras) do
        local entry = extras[i]

        local cb = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
        cb:SetWidth(24)
        cb:SetHeight(24)
        cb:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 16, y)
        local fs = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetPoint("LEFT", cb, "RIGHT", 2, 0)
        fs:SetText(entry.label)
        cb.label = fs
        cb.settingKey = entry.key

        local cur = OM:GetSetting(entry.key)
        if cur == nil then cur = entry.default end
        cb:SetChecked(cur and 1 or nil)

        local childCbs = {}
        local childDrop = nil
        local childDropBtn = nil

        local function SyncDropdownEnabled()
            if not childDrop then return end
            local parentOn = OM:GetSetting(entry.key) == true
            if parentOn then
                if UIDropDownMenu_EnableDropDown then
                    UIDropDownMenu_EnableDropDown(childDrop)
                end
                if childDropBtn then
                    childDropBtn:Enable()
                    childDropBtn:EnableMouse(true)
                end
                if childDrop.label then childDrop.label:SetTextColor(1, 1, 1) end
            else
                if UIDropDownMenu_DisableDropDown then
                    UIDropDownMenu_DisableDropDown(childDrop)
                end
                if childDropBtn then
                    childDropBtn:Disable()
                    childDropBtn:EnableMouse(false)
                end
                -- Close any open list
                if CloseDropDownMenus then CloseDropDownMenus() end
                if childDrop.label then childDrop.label:SetTextColor(0.5, 0.5, 0.5) end
            end
        end

        cb:SetScript("OnClick", function()
            local checked = this:GetChecked() and true or false
            OM:SetSetting(entry.key, checked)
            if entry.onToggle then entry.onToggle(checked) end
            local c
            for _, c in ipairs(childCbs) do
                SyncChildEnabled(this, c, entry.key)
            end
            SyncDropdownEnabled()
            if UI.ApplySettingsToFrames then UI:ApplySettingsToFrames() end
        end)

        if entry.tooltip then
            cb:SetScript("OnEnter", function()
                GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
                GameTooltip:SetText(entry.tooltip, nil, nil, nil, nil, 1)
                GameTooltip:Show()
            end)
            cb:SetScript("OnLeave", function() GameTooltip:Hide() end)
        end

        y = y - rowH

        -- Child dropdown on one row: "Threat view:" label left, dropdown to its right
        if entry.childDropdown then
            local ddInfo = entry.childDropdown
            local opts = ddInfo.options or THREAT_VIEW_OPTIONS

            local lbl = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            lbl:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 40, y + 6)
            lbl:SetText(ddInfo.label or "View:")

            local ddName = "GreedMeterThreatViewDropDown"
            local dd = CreateFrame("Frame", ddName, f, "UIDropDownMenuTemplate")
            -- Sit to the right of the label so it never covers the text
            dd:SetPoint("LEFT", lbl, "RIGHT", -8, -2)
            dd.label = lbl
            childDrop = dd
            childDropBtn = getglobal(ddName .. "Button")

            local function OnSelect()
                if OM:GetSetting(entry.key) ~= true then return end
                local id = this:GetID()
                local opt = opts[id]
                if not opt then return end
                OM:SetSetting(ddInfo.key, opt.key)
                UIDropDownMenu_SetSelectedID(dd, id)
                UIDropDownMenu_SetText(opt.label, dd)
                if ddInfo.onChange then ddInfo.onChange(opt.key) end
            end

            local function Init()
                if OM:GetSetting(entry.key) ~= true then return end
                local curKey = OM:GetSetting(ddInfo.key) or ddInfo.default or "single"
                local oi
                for oi = 1, table.getn(opts) do
                    local info = {}
                    info.text = opts[oi].label
                    info.func = OnSelect
                    info.checked = (opts[oi].key == curKey)
                    UIDropDownMenu_AddButton(info)
                end
            end

            UIDropDownMenu_Initialize(dd, Init)
            UIDropDownMenu_SetWidth(110, dd)
            UIDropDownMenu_SetButtonWidth(110, dd)
            local curKey = OM:GetSetting(ddInfo.key) or ddInfo.default or "single"
            UIDropDownMenu_SetText(ThreatViewLabel(curKey), dd)
            local sel = 1
            local oi
            for oi = 1, table.getn(opts) do
                if opts[oi].key == curKey then sel = oi break end
            end
            UIDropDownMenu_SetSelectedID(dd, sel)

            if ddInfo.tooltip then
                dd:SetScript("OnEnter", function()
                    if OM:GetSetting(entry.key) ~= true then return end
                    GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
                    GameTooltip:SetText(ddInfo.tooltip, nil, nil, nil, nil, 1)
                    GameTooltip:Show()
                end)
                dd:SetScript("OnLeave", function() GameTooltip:Hide() end)
            end

            SyncDropdownEnabled()
            y = y - dropH
        end

        -- Optional child checkboxes (legacy)
        if entry.children then
            local ci
            for ci = 1, table.getn(entry.children) do
                local child = entry.children[ci]
                local ccb = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
                ccb:SetWidth(20)
                ccb:SetHeight(20)
                ccb:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 36, y)
                local cfs = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                cfs:SetPoint("LEFT", ccb, "RIGHT", 2, 0)
                cfs:SetText(child.label)
                ccb.label = cfs
                ccb.settingKey = child.key
                ccb.onToggle = child.onToggle

                local ccur = OM:GetSetting(child.key)
                if ccur == nil then ccur = child.default end
                ccb:SetChecked(ccur and 1 or nil)

                ccb:SetScript("OnClick", function()
                    local checked = this:GetChecked() and true or false
                    OM:SetSetting(child.key, checked)
                    if child.onToggle then child.onToggle(checked) end
                    if UI.ApplySettingsToFrames then UI:ApplySettingsToFrames() end
                end)

                if child.tooltip then
                    ccb:SetScript("OnEnter", function()
                        GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
                        GameTooltip:SetText(child.tooltip, nil, nil, nil, nil, 1)
                        GameTooltip:Show()
                    end)
                    ccb:SetScript("OnLeave", function() GameTooltip:Hide() end)
                end

                table.insert(childCbs, ccb)
                SyncChildEnabled(cb, ccb, entry.key)
                y = y - rowH
            end
        end
    end

    f._greedThreatCheckbox = true

    -- Grow the frame just enough for threat extras + bottom button strip
    local threatBlockH = totalRows * rowH + (hasDrop and (dropH - rowH) or 0) + 12
    local minMain = 300  -- main settings content (checkboxes + right column)
    local needed = minMain + threatBlockH
    if needed < 340 then needed = 340 end
    if f:GetHeight() < needed then
        f:SetHeight(needed)
    end
end

local function HookSettingsFrame()
    if not UI or not UI.CreateSettingsFrame then return end
    if Threat._settingsHooked then return end
    Threat._settingsHooked = true

    local oldCreate = UI.CreateSettingsFrame
    UI.CreateSettingsFrame = function(self)
        local f = oldCreate(self)
        AddThreatCheckboxToSettings(f)
        return f
    end

    if UI.settingsFrame then
        AddThreatCheckboxToSettings(UI.settingsFrame)
    end
end

-- ============================================================
-- Events / update loop
-- ============================================================

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("CHAT_MSG_ADDON")
eventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
eventFrame:RegisterEvent("PARTY_MEMBERS_CHANGED")
eventFrame:RegisterEvent("RAID_ROSTER_UPDATE")
-- Flee / fear combat-log lines
eventFrame:RegisterEvent("CHAT_MSG_MONSTER_EMOTE")
eventFrame:RegisterEvent("CHAT_MSG_MONSTER_SAY")
eventFrame:RegisterEvent("CHAT_MSG_COMBAT_HOSTILE_DEATH")
eventFrame:RegisterEvent("CHAT_MSG_SPELL_PERIODIC_HOSTILEPLAYER_DAMAGE")
eventFrame:RegisterEvent("CHAT_MSG_SPELL_PERIODIC_CREATURE_DAMAGE")
eventFrame:RegisterEvent("CHAT_MSG_SPELL_AURA_GONE_OTHER")
eventFrame:RegisterEvent("CHAT_MSG_SPELL_AURA_GONE_SELF")
eventFrame:RegisterEvent("CHAT_MSG_COMBAT_MISC_INFO")
eventFrame:RegisterEvent("CHAT_MSG_SYSTEM")

eventFrame:SetScript("OnEvent", function()
    if not OM:GetSetting("enableThreatMode") then return end

    if event == "CHAT_MSG_ADDON" then
        if arg2 and string.find(arg2, THREAT_API_PREFIX, 1, true) then
            if ParseThreatPacket(arg2) then
                if Threat:AnyFrameInThreatMode() and UI.Refresh then
                    UI:Refresh()
                end
            end
        end
    elseif event == "PLAYER_TARGET_CHANGED" then
        -- Do NOT wipe tankModeThreats here — Tank mode needs to keep every
        -- distinct GUID (including multiple same-name mobs) across target swaps.
        ClearThreatTable()
        Threat.usingApi = false
        Threat.targetName = UnitName("target")
        RememberHostileTarget()
        InvalidateThreatCaches()
        if Threat:AnyFrameInThreatMode() and UI.Refresh then
            UI:Refresh()
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        -- Leaving combat: drop the accumulated enemy list and flee flags
        if not OM:GetSetting("testMode") then
            ClearTankModeTable()
        end
        local k
        for k in pairs(Threat.fleeingEnemies) do
            Threat.fleeingEnemies[k] = nil
        end
    elseif event == "PARTY_MEMBERS_CHANGED" or event == "RAID_ROSTER_UPDATE" then
        if not IsInGroup() then
            ClearThreatTable()
            if not OM:GetSetting("testMode") then
                ClearTankModeTable()
            end
            Threat.usingApi = false
            if Threat:AnyFrameInThreatMode() and UI.Refresh then
                UI:Refresh()
            end
        end
    elseif event == "CHAT_MSG_MONSTER_EMOTE"
        or event == "CHAT_MSG_MONSTER_SAY"
        or event == "CHAT_MSG_COMBAT_MISC_INFO"
        or event == "CHAT_MSG_SYSTEM"
        or event == "CHAT_MSG_SPELL_PERIODIC_CREATURE_DAMAGE"
        or event == "CHAT_MSG_SPELL_PERIODIC_HOSTILEPLAYER_DAMAGE"
        or event == "CHAT_MSG_SPELL_AURA_GONE_OTHER"
        or event == "CHAT_MSG_SPELL_AURA_GONE_SELF" then
        if arg1 and type(arg1) == "string" then
            ParseFleeMessage(arg1)
        end
    end
end)

-- ============================================================
-- Test mode: fake threat list (same roster as /gdm test)
-- ============================================================

Threat.testDataActive = false

function Threat:LoadTestData()
    -- Same 40-player roster as Core/Commands.lua LoadTestData for consistency
    local classes = {
        "WARRIOR", "MAGE", "ROGUE", "DRUID", "HUNTER",
        "SHAMAN", "PRIEST", "WARLOCK", "PALADIN",
    }
    local names = {
        "Grommash", "Jaina", "Valeera", "Malfurion", "Rexxar",
        "Thrall", "Anduin", "Guldan", "Uther", "Garrosh",
        "Khadgar", "Garona", "Cenarius", "Alleria", "Voljin",
        "Velen", "Medivh", "Liadrin", "Saurfang", "Aegwynn",
        "Sylvanas", "Illidan", "Tyrande", "Cairne", "Varok",
        "Kaelthas", "Maiev", "Arthas", "Kelthuzad", "Anubarak",
        "Muradin", "Bolvar", "Alexstrasza", "Ysera", "Nozdormu",
        "Malygos", "Neltharion", "Ragnaros", "Nefarian", "Onyxia",
    }

    ClearThreatTable()
    ClearTankModeTable()
    Threat.usingApi = false
    Threat.testDataActive = true
    Threat.targetName = "Onyxia"
    Threat.tankName = "Saurfang"

    -- Tank sits at the top with a solid lead; everyone else cascades down.
    -- Values are absolute threat numbers (similar scale to live API output).
    local tankThreat = 125000
    local entries = {
        -- name, threat, melee?
        { "Saurfang",   tankThreat, true },
        { "Grommash",   98000,  true },
        { "Varok",      91000,  true },
        { "Garrosh",    87000,  true },
        { "Uther",      82000,  true },
        { "Bolvar",     78000,  true },
        { "Malfurion",  74000,  true },
        { "Cairne",     70000,  true },
        { "Thrall",     65000,  false },
        { "Rexxar",     61000,  false },
        { "Illidan",    58000,  true },
        { "Valeera",    54000,  true },
        { "Garona",     51000,  true },
        { "Maiev",      48000,  true },
        { "Jaina",      45000,  false },
        { "Khadgar",    42000,  false },
        { "Kaelthas",   40000,  false },
        { "Guldan",     38000,  false },
        { "Medivh",     36000,  false },
        { "Kelthuzad",  34000,  false },
        { "Anduin",     32000,  false },
        { "Velen",      30000,  false },
        { "Liadrin",    28000,  true },
        { "Tyrande",    26000,  false },
        { "Alleria",    24000,  false },
        { "Sylvanas",   22000,  false },
        { "Voljin",     20000,  false },
        { "Cenarius",   18000,  false },
        { "Aegwynn",    16000,  false },
        { "Arthas",     14000,  true },
        { "Anubarak",   12000,  true },
        { "Muradin",    11000,  true },
        { "Alexstrasza",10000,  false },
        { "Ysera",       9000,  false },
        { "Nozdormu",    8000,  false },
        { "Malygos",     7000,  false },
        { "Neltharion",  6000,  false },
        { "Ragnaros",    5000,  false },
        { "Nefarian",    4000,  false },
        { "Onyxia",      3000,  false },
    }

    local i
    for i = 1, table.getn(entries) do
        local e = entries[i]
        local name = e[1]
        local threat = e[2]
        local melee = e[3]
        local perc = 0
        if tankThreat > 0 then
            perc = math.floor((threat / tankThreat) * 100 + 0.5)
        end
        -- Mild TPS so the secondary text looks alive
        local tps = math.floor(threat / 180 + math.random(0, 40))
        local class = nil
        local ni
        for ni = 1, table.getn(names) do
            if names[ni] == name then
                class = classes[((ni - 1) - math.floor((ni - 1) / 9) * 9) + 1]
                break
            end
        end
        Threat.threats[name] = {
            threat    = threat,
            perc      = perc,
            tank      = (name == Threat.tankName),
            tps       = tps,
            melee     = melee,
            class     = class,
            estimated = false,  -- present as clean "API-style" numbers in test
            isTest    = true,
        }
    end

    -- Normal Threat mode always includes Pull Aggro threshold
    Threat:AddPullAggroRow()
    if Threat.threats[PULL_AGGRO_NAME] then
        Threat.threats[PULL_AGGRO_NAME].isTest = true
        Threat.threats[PULL_AGGRO_NAME].estimated = false
    end

    -- Fake multi-enemy set for Tank mode preview (lowest threat first when sorted)
    -- status: red = no aggro, yellow = contested, green = solid lead
    local fakeEnemies = {
        { guid = "test1", creature = "Onyxian Whelp",   name = "Onyxian Whelp",   threat = 0,     perc = 0,   status = "red" },
        { guid = "test2", creature = "Onyxian Whelp",   name = "Onyxian Whelp",   threat = 1200,  perc = 35,  status = "red" },
        { guid = "test3", creature = "Onyxian Warder",  name = "Onyxian Warder",  threat = 45000, perc = 92,  status = "yellow" },
        { guid = "test4", creature = "Onyxia",          name = "Onyxia",          threat = 125000,perc = 100, status = "green" },
        { guid = "test5", creature = "Onyxian Warder",  name = "Onyxian Warder",  threat = 80000, perc = 100, status = "green" },
        { guid = "test6", creature = "Onyxian Whelp",   name = "Onyxian Whelp",   threat = 500,   perc = 12,  status = "red" },
        { guid = "test7", creature = "Onyxian Guard",   name = "Onyxian Guard",   threat = 62000, perc = 96,  status = "yellow" },
        { guid = "test8", creature = "Lava Spawn",      name = "Lava Spawn",      threat = 0,     perc = 0,   status = "red" },
    }
    local fi
    for fi = 1, table.getn(fakeEnemies) do
        local e = fakeEnemies[fi]
        Threat.tankModeThreats[e.guid] = {
            creature  = e.creature,
            name      = e.name,
            threat    = e.threat,
            perc      = e.perc,
            status    = e.status,
            isTest    = true,
            estimated = false,
        }
    end

    -- Overall fight totals for Overall view / test
    local oi
    for oi = 1, table.getn(entries) do
        local e = entries[oi]
        local name = e[1]
        local threat = math.floor((e[2] or 0) * 1.35) -- slightly higher than single-target snapshot
        local class = nil
        local ni
        for ni = 1, table.getn(names) do
            if names[ni] == name then
                class = classes[((ni - 1) - math.floor((ni - 1) / 9) * 9) + 1]
                break
            end
        end
        Threat.overallThreat[name] = {
            threat    = threat,
            class     = class,
            estimated = false,
            tank      = (name == Threat.tankName),
        }
    end
    InvalidateThreatCaches()
end

function Threat:ClearTestData()
    self.testDataActive = false
    ClearThreatTable()
    ClearTankModeTable()
    local k
    for k in pairs(self.overallThreat) do
        self.overallThreat[k] = nil
    end
    for k in pairs(self.threatByTarget) do
        self.threatByTarget[k] = nil
    end
    self.currentTargetKey = nil
    self.history = {}
    self.usingApi = false
    self.tankName = nil
    self.targetName = nil
    InvalidateThreatCaches()
end

local elapsed = 0
eventFrame:SetScript("OnUpdate", function()
    if not OM:GetSetting("enableThreatMode") then return end
    if not Threat:AnyFrameInThreatMode() then return end

    elapsed = elapsed + arg1
    if elapsed < 0.25 then return end
    elapsed = 0

    -- Test mode: keep showing the fake lists; do not query API or estimate
    if OM:GetSetting("testMode") == true then
        if not Threat.testDataActive then
            Threat:LoadTestData()
        end
        if UI.Refresh then UI:Refresh() end
        return
    elseif Threat.testDataActive then
        Threat:ClearTestData()
    end

    local now = GetTime()
    -- Target in combat counts as a fight session even if you are not flagged
    local targetCombat = UnitExists("target") and UnitAffectingCombat and UnitAffectingCombat("target")
    local groupCombat = IsGroupInCombat() or (targetCombat and true or false)
    local hostileTarget = HasHostileTarget()
    local apiTarget = IsThreatApiTarget()

    -- Aggro holder changed → rebuild threat list ranking immediately
    local liveAggro = nil
    if UnitExists("target") and UnitExists("targettarget") and not UnitIsDead("targettarget") then
        liveAggro = UnitName("targettarget")
    end
    if liveAggro ~= Threat._lastAggroName then
        Threat._lastAggroName = liveAggro
        -- Update tank flags on the live table so any open window re-sorts
        local n, d
        for n, d in pairs(Threat.threats) do
            if d and not d.isPull then
                d.tank = (liveAggro and n == liveAggro) or false
            end
        end
        if liveAggro then
            Threat.tankName = liveAggro
        end
        InvalidateThreatCaches()
    end

    -- Group combat session: start/stop with the party/target, not only local regen.
    if groupCombat and not Threat.groupCombat then
        Threat.groupCombat = true
        local k
        for k in pairs(Threat.overallThreat) do
            Threat.overallThreat[k] = nil
        end
        for k in pairs(Threat.threatByTarget) do
            Threat.threatByTarget[k] = nil
        end
        Threat.currentTargetKey = nil
        Threat.usingApi = false
        InvalidateThreatCaches()
    elseif not groupCombat and Threat.groupCombat then
        Threat.groupCombat = false
    end

    -- Live server threat API
    if apiTarget then
        if (now - Threat.lastQuery) >= Threat.queryInterval then
            Threat.lastQuery = now
            SendThreatQuery()
        end
    end

    if Threat.usingApi and (now - Threat.lastApiTime) > Threat.apiTimeout then
        Threat.usingApi = false
    end

    if not Threat.usingApi then
        if hostileTarget then
            -- Fallback estimate when API is silent (trash, no response, etc.)
            BuildEstimatedThreat()
        elseif IsInGroup() and (groupCombat or Threat.groupCombat) then
            BuildEstimatedOverallOnly()
        end
    -- When API is live, keep the last snapshots even without a local target.
    -- Do not overwrite with estimates until the API times out.
    end

    if UI.Refresh then
        UI:Refresh()
    end
end)

-- ============================================================
-- Module lifecycle
-- ============================================================

function Threat:OnLoad()
    if OM.InitDB and not OM.db then
        OM:InitDB()
    end
    if OM.db then
        if OM.db.enableThreatMode == nil then OM.db.enableThreatMode = false end
        if OM.db.showPetThreat == nil then OM.db.showPetThreat = false end
        if OM.db.petAsTank == nil then OM.db.petAsTank = false end
        if OM.db.threatView == nil then
            -- migrate legacy tank checkbox
            if OM.db.enableTankingMode then
                OM.db.threatView = "tank"
            else
                OM.db.threatView = "single"
            end
        end
    end

    InstallUIHooks()
    HookSettingsFrame()

    -- Extend core test data so Threat mode is populated too
    if OM.LoadTestData and not Threat._loadTestHooked then
        Threat._loadTestHooked = true
        local oldLoad = OM.LoadTestData
        OM.LoadTestData = function(self)
            oldLoad(self)
            if OM:GetSetting("enableThreatMode") then
                Threat:LoadTestData()
                if UI and UI.Refresh then UI:Refresh() end
            end
        end
    end

    OM:RegisterExtraCheckbox({
        label   = "Add threat mode",
        key     = "enableThreatMode",
        default = false,
        order   = 10,
        tooltip = "Enables threat metering on meter windows.\nUse the Threat view dropdown to choose Single target, Tank, Overall, or All (adds every view as its own Mode option).",
        onToggle = function(checked)
            EnsureModeInList(checked)
            if not checked then
                Threat:ClearTestData()
            elseif OM:GetSetting("testMode") then
                Threat:LoadTestData()
                if UI and UI.Refresh then UI:Refresh() end
            end
            if checked then
                DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00GreedMeter:|r Threat mode enabled. Pick a view and select it from Mode on a meter window.")
            else
                DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00GreedMeter:|r Threat mode disabled.")
            end
        end,
        childDropdown = {
            label   = "Threat view:",
            key     = "threatView",
            default = "single",
            options = THREAT_VIEW_OPTIONS,
            tooltip = "Single target — player threat on your current target (with Pull Aggro).\nTank — enemies you are fighting, lowest of your threat first; click to target.\nOverall — each player's total threat generated this fight (not target-specific).\nAll — adds Threat, Tank, and Overall Threat as separate Mode options.",
            onChange = function(key)
                EnsureModeInList(OM:GetSetting("enableThreatMode") == true)
                if OM:GetSetting("testMode") and OM:GetSetting("enableThreatMode") then
                    Threat:LoadTestData()
                end
                DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00GreedMeter:|r Threat view: " .. ThreatViewLabel(key))
                if UI and UI.Refresh then UI:Refresh() end
            end,
        },
    })

    EnsureModeInList(OM:GetSetting("enableThreatMode") == true)

    -- If both threat + test were already on from a previous session, fill test threat
    if OM:GetSetting("enableThreatMode") and OM:GetSetting("testMode") then
        Threat:LoadTestData()
    end
end

function Threat:OnCombatStart()
    if not OM:GetSetting("enableThreatMode") then return end
    -- Don't wipe test data when "combat" starts while testing
    if OM:GetSetting("testMode") then return end
    -- Single-target snapshot resets on local combat entry.
    -- overallThreat is owned by the group-combat session in OnUpdate so a
    -- healer entering combat mid-fight does not wipe the whole meter.
    ClearThreatTable()
    ClearTankModeTable()
    Threat.usingApi = false
    Threat.testDataActive = false
end

function Threat:OnCombatEnd()
    -- keep last values visible for review
end

function Threat:OnReset()
    -- Always wipe threat tables first. Reload fake data only if test mode is still on.
    Threat:ClearTestData()
    if OM:GetSetting("testMode") and OM:GetSetting("enableThreatMode") then
        Threat:LoadTestData()
    end
end

OM:RegisterModule("Threat", Threat)
