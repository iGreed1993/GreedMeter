--[[
    GreedMeter - Threat module
    Drop-in file that adds an optional "Threat" mode (and optional Tank mode).

    - Settings checkbox: "Add threat mode"
        - Child checkbox: "Tank mode" (indented, enabled only when parent is on)
    - Threat mode (default): player threat on current target, Pull Aggro threshold,
      % of MT — uses Turtle API when present, else 1.12 estimation (party/raid only)
    - Tank mode: lists enemies you are in combat with, ordered by your threat on them
      (lowest first). Bar colors: red = you do not have aggro, yellow = contested,
      green = solid lead. Click a bar to target that enemy.
    - Extra checkboxes register through a shared list so other modules do not collide

    Installation:
      1. Copy this file into your GreedMeter folder (same level as GreedMeter.toc)
      2. Add this line to GreedMeter.toc (after the UI section is fine):
           Threat.lua
      3. /reload
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

local THREAT_API_PREFIX    = "TWTv4="
local TANK_MODE_API_PREFIX = "TMTv1="
local THREAT_QUERY_BASE    = "TWT_UDTSv4"
local THREAT_CHANNEL       = "RAID"
local PULL_AGGRO_NAME      = "-Pull Aggro at-"

Threat.usingApi            = false
Threat.lastApiTime         = 0
Threat.apiTimeout          = 4.0
Threat.threats             = {}   -- [name] = { threat, perc, tank, tps, class, melee, estimated }
Threat.tankModeThreats     = {}   -- [guid] = { creature, name, perc }  (API tank-mode multi-mob)
Threat.overallThreat       = {}   -- [name] = { threat, class, estimated }  fight-total threat generated
Threat.targetName          = nil
Threat.tankName            = nil
Threat.queryInterval       = 0.55
Threat.lastQuery           = 0
Threat.history             = {}   -- for TPS
Threat.estimateHistory     = {}   -- sliding window samples for estimation

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

-- ============================================================
-- SuperWoW / GUID helpers
-- SuperWoW: UnitExists(unit) returns exists, guid
--           Unit* APIs accept a GUID string as the unit argument
--           TargetUnit(guid) selects that exact unit
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
    -- SuperWoW: second return of UnitExists is the GUID
    local exists, guid = UnitExists(unit)
    if exists and type(guid) == "string" and guid ~= "" and guid ~= unit then
        -- Prefer values that look like GUIDs (0x...) when present
        if string.find(guid, "0x") or string.len(guid) >= 8 then
            return guid
        end
    end
    -- Some SuperWoW / companion DLLs expose UnitGUID(unit)
    if UnitGUID then
        local g = UnitGUID(unit)
        if type(g) == "string" and g ~= "" then
            return g
        end
        -- GudaIO-style: UnitGUID returns hi, lo numbers
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

-- Target a specific enemy by GUID (SuperWoW) or fall back to name
local function TargetEnemy(entry)
    if not entry then return end
    local guid = entry.data and entry.data.guid
    local name = entry.name
    if guid and HasSuperWoW() then
        -- SuperWoW accepts GUID as a unit token
        if TargetUnit then
            TargetUnit(guid)
            return
        end
    end
    if name and name ~= "" and TargetByName then
        TargetByName(name, 1)
    end
end

-- Remember the current hostile target as its own GUID-keyed enemy row
-- (lets Tank mode accumulate distinct same-name mobs as you tab through them)
local function RememberHostileTarget()
    if not TankingModeEnabled() then return end
    if not UnitExists("target") then return end
    if UnitIsPlayer("target") or UnitIsFriend("player", "target") then return end

    local name = UnitName("target") or "Enemy"
    local guid = GetUnitGUID("target")
    if not guid or guid == "" then
        -- Without SuperWoW we cannot distinguish same-name mobs reliably
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
            estimated = not Threat.usingApi,
        }
    else
        existing.name = name
        existing.creature = existing.creature or name
    end
end

-- ============================================================
-- Local player threat modifiers (stance + buffs)
-- ============================================================

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
-- Turtle API path
-- ============================================================

local function SendThreatQuery()
    if not IsInGroup() then return end
    if not UnitExists("target") or UnitIsPlayer("target") or UnitIsFriend("player", "target") then
        return
    end

    local query = THREAT_QUERY_BASE
    if TankingModeEnabled() then
        query = query .. "_TM"
    end
    local msg = "limit=20"
    SendAddonMessage(query, msg, THREAT_CHANNEL)
    if GetNumRaidMembers() == 0 and GetNumPartyMembers() > 0 then
        SendAddonMessage(query, msg, "PARTY")
    end
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
    Threat.targetName = UnitName("target")

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
                -- TWThreat TMTv1: creature:guid:secondPlayer:secondPerc
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
-- Improved 1.12 estimation fallback (party/raid only)
-- ============================================================

local ESTIMATE_WINDOW = 8.0   -- seconds of recent activity to weight

local function RecordEstimateSample()
    if not UI or not UI.GetSegmentData then return end
    local segment = UI.GetSegmentData("current")
    if not segment or not segment.players then return end

    local now = GetTime()
    local name, data
    for name, data in pairs(segment.players) do
        local dmg = data.damage or 0
        local heal = data.healing or 0
        local hist = Threat.estimateHistory[name]
        if not hist then
            Threat.estimateHistory[name] = {
                lastDmg = dmg,
                lastHeal = heal,
                samples = {},
            }
            hist = Threat.estimateHistory[name]
        end

        local dDmg = dmg - (hist.lastDmg or 0)
        local dHeal = heal - (hist.lastHeal or 0)
        if dDmg < 0 then dDmg = 0 end
        if dHeal < 0 then dHeal = 0 end
        hist.lastDmg = dmg
        hist.lastHeal = heal

        if dDmg > 0 or dHeal > 0 then
            table.insert(hist.samples, {
                t = now,
                dmg = dDmg,
                heal = dHeal,
            })
        end

        -- Prune old samples
        local pruned = {}
        local i
        for i = 1, table.getn(hist.samples) do
            if (now - hist.samples[i].t) <= ESTIMATE_WINDOW then
                table.insert(pruned, hist.samples[i])
            end
        end
        hist.samples = pruned
    end
end

local function BuildEstimatedThreat()
    ClearThreatTable()
    Threat.usingApi = false
    Threat.targetName = UnitName("target")

    -- Estimation only functions in party/raid (same gate as the live API)
    if not IsInGroup() then
        return
    end
    if not UnitExists("target") or UnitIsPlayer("target") or UnitIsFriend("player", "target") then
        return
    end

    RecordEstimateSample()

    if not UI or not UI.GetSegmentData then return end
    local segment = UI.GetSegmentData("current")
    if not segment or not segment.players then return end

    local me = UnitName("player")
    local localMod = 1.0
    if me then
        localMod = GetLocalThreatModifier()
    end

    -- Is the local player currently the mob's target? (likely tanking)
    local iAmTanking = UnitExists("targettarget") and UnitIsUnit("player", "targettarget")

    local maxThreat = 0
    local list = {}
    local name, data
    for name, data in pairs(segment.players) do
        local class = data.class or GetPlayerClass(name)
        local mod = 1.0
        if class and CLASS_THREAT_MOD[class] then
            mod = CLASS_THREAT_MOD[class]
        end
        if name == me then
            mod = mod * localMod
            if iAmTanking then
                mod = mod * 1.15   -- small bias when we are the current target
            end
        end

        -- Prefer recent window contribution; fall back to full-fight totals
        local recentDmg, recentHeal = 0, 0
        local hist = Threat.estimateHistory[name]
        if hist and hist.samples and table.getn(hist.samples) > 0 then
            local i
            for i = 1, table.getn(hist.samples) do
                recentDmg = recentDmg + (hist.samples[i].dmg or 0)
                recentHeal = recentHeal + (hist.samples[i].heal or 0)
            end
        end

        local useDmg, useHeal
        if recentDmg > 0 or recentHeal > 0 then
            -- Scale recent activity up so bars feel responsive, blend with totals
            local totalDmg = data.damage or 0
            local totalHeal = data.healing or 0
            useDmg = recentDmg * 2.5 + totalDmg * 0.15
            useHeal = recentHeal * 2.5 + totalHeal * 0.15
        else
            useDmg = data.damage or 0
            useHeal = data.healing or 0
        end

        -- Classic: damage 1:1, healing 0.5:1
        local threat = (useDmg + useHeal * 0.5) * mod
        if threat > 0 then
            table.insert(list, {
                name = name,
                threat = threat,
                class = class,
                isLikelyTank = (name == me and iAmTanking) or false,
            })
            if threat > maxThreat then maxThreat = threat end
        end
    end

    -- Also consider targettarget as tank if they are in the list
    local ttName = UnitExists("targettarget") and UnitName("targettarget") or nil

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
        Threat.threats[e.name] = {
            threat    = e.threat,
            perc      = perc,
            tank      = isTank,
            tps       = 0,
            melee     = false,
            class     = e.class,
            estimated = true,
        }
        if isTank then
            Threat.tankName = e.name
        end
    end

    Threat:AddPullAggroRow()
    Threat:UpdateOverallFromPlayerThreats()
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

-- Live snapshot of the player's threat situation on the current target
local function CurrentTargetThreatSnapshot()
    local me = UnitName("player")
    local myData = me and Threat.threats[me]
    local myThreat = myData and (myData.threat or 0) or 0
    local myPerc = myData and (myData.perc or 0) or 0
    local iAmTanking = UnitExists("targettarget") and UnitIsUnit("player", "targettarget")
    local second = 0
    local n, d
    for n, d in pairs(Threat.threats) do
        if n ~= me and not d.isPull and (d.threat or 0) > second then
            second = d.threat or 0
        end
    end

    local status
    if iAmTanking then
        status = EnemyStatusFromLead(myThreat, second)
        -- Ensure non-zero so bars render while tanking even if API/estimate is lagging
        if myThreat <= 0 then
            myThreat = 1
            myPerc = 100
        end
    else
        status = "red"
        if myThreat <= 0 and myPerc <= 0 then
            -- still show the row; 0 threat is valid when you have no aggro
            myThreat = 0
        end
    end
    return myThreat, myPerc, status, iAmTanking
end

function Threat:BuildEnemyList(hiddenNames)
    local list = {}

    -- Always remember / refresh the current hostile target so the list is not stuck at 0
    if UnitExists("target")
        and not UnitIsPlayer("target") and not UnitIsFriend("player", "target") then
        RememberHostileTarget()
        local tName = UnitName("target") or "Target"
        local tGuid = GetUnitGUID("target") or ("name:" .. tName)
        local myThreat, myPerc, status = CurrentTargetThreatSnapshot()
        local row = self.tankModeThreats[tGuid]
        if row then
            row.name = tName
            row.creature = row.creature or tName
            row.threat = myThreat
            row.perc = myPerc
            row.status = status
            -- Prefer live numbers over a stale API row for the active target
            if myThreat > 0 or status ~= "red" then
                row.estimated = not self.usingApi
            end
        end
    end

    -- Multi-mob table is GUID-keyed so same-name mobs stay distinct
    local guid, info
    for guid, info in pairs(self.tankModeThreats) do
        local mobName = info.creature or info.name or "?"
        -- TWThreat TMTv1 format: creature=mob, name=second-highest PLAYER, perc=their %
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

            table.insert(list, {
                name  = mobName,
                data  = {
                    threat    = threat,
                    perc      = perc,
                    status    = status,
                    isEnemy   = true,
                    guid      = info.guid or guid,
                    creature  = info.creature,
                    estimated = estimated,
                    isTest    = info.isTest,
                    secondPlayer = (info.name and info.creature and info.name ~= info.creature) and info.name or nil,
                },
                value = threat,
            })
        end
    end

    -- Lowest threat first (enemies you are weakest on at the top)
    table.sort(list, function(a, b)
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
function Threat:UpdateOverallFromPlayerThreats()
    local name, data
    for name, data in pairs(self.threats) do
        if name and not data.isPull then
            local t = data.threat or 0
            local prev = self.overallThreat[name]
            local prevT = prev and prev.threat or 0
            -- Track peak observed on any target + blend with cumulative estimate
            local best = t
            if prevT > best then best = prevT end
            -- If threat rose this tick, add the delta as "generated"
            local hist = self.history[name]
            if hist and hist.threat and t > hist.threat then
                best = prevT + (t - hist.threat)
            end
            self.overallThreat[name] = {
                threat    = best,
                class     = data.class or GetPlayerClass(name),
                estimated = data.estimated,
                tank      = data.tank,
            }
        end
    end
end

-- Enemies currently targeting a given player (group-visible hostile units)
-- Returns ordered list of unique enemy names.
function Threat:GetEnemiesTargetingPlayer(playerName)
    local names = {}
    if not playerName or playerName == "" then return names end

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

    -- SuperWoW: known GUID-keyed enemies can be addressed as unit tokens
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
                        tps            = 0,
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

    if view == "tank" then
        return self:BuildEnemyList(hiddenNames)
    end
    if view == "overall" then
        self:UpdateOverallFromPlayerThreats()
        return self:BuildOverallList(hiddenNames)
    end

    -- Single-target Threat mode → players + Pull Aggro row
    local list = {}
    local name, data
    for name, data in pairs(self.threats) do
        if not hiddenNames or not hiddenNames[name] then
            local value = data.threat or 0
            if value > 0 or data.tank or data.isPull then
                table.insert(list, {
                    name  = name,
                    data  = data,
                    value = value,
                })
            end
        end
    end

    table.sort(list, function(a, b)
        -- Pull Aggro sits just under the current tank
        if a.data and a.data.isPull and b.data and b.data.tank then
            return false
        end
        if b.data and b.data.isPull and a.data and a.data.tank then
            return true
        end
        if a.data and a.data.isPull then
            return a.value > (b.value or 0)
        end
        if b.data and b.data.isPull then
            return (a.value or 0) > b.value
        end
        if a.value == b.value then
            return a.name < b.name
        end
        return a.value > b.value
    end)

    local i
    for i = 1, table.getn(list) do
        list[i].rank = i
    end
    return list
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
        else
            text = text .. " LOST"
        end
        if data.estimated then text = text .. "*" end
        return text
    end

    -- Overall fight threat — parentheses show # of enemies currently targeting them
    if data.isOverall then
        local threat = data.threat or 0
        local count = data.targetedByCount or 0
        local text
        if UI.FormatNumber then
            text = UI.FormatNumber(threat)
        else
            text = tostring(math.floor(threat + 0.5))
        end
        text = text .. " (" .. tostring(count) .. ")"
        if data.estimated then text = text .. "*" end
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
    local text
    if UI.FormatNumber then
        text = UI.FormatNumber(threat)
    else
        text = tostring(math.floor(threat + 0.5))
    end

    -- Always show % of main tank in normal Threat mode
    if Threat.tankName and not data.tank then
        local tankData = Threat.threats[Threat.tankName]
        local tankThreat = tankData and tankData.threat or 0
        if tankThreat > 0 then
            local ofTank = math.floor((threat / tankThreat) * 100 + 0.5)
            text = text .. " (" .. tostring(ofTank) .. "% MT)"
        else
            text = text .. " (" .. tostring(perc) .. "%)"
        end
    else
        text = text .. " (" .. tostring(perc) .. "%)"
    end

    if tps and tps > 0 then
        if UI.FormatNumber then
            text = text .. "(" .. UI.FormatNumber(tps) .. ")"
        else
            text = text .. "(" .. string.format("%.0f", tps) .. ")"
        end
    end
    if data.estimated then
        text = text .. "*"
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
                    bar.nameText:SetText(rank .. ". " .. label)
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

    local baseY = 40
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

    local extraH = math.max(0, (totalRows - 1) * rowH)
    if f:GetHeight() < 510 + extraH then
        f:SetHeight(510 + extraH)
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
        if Threat:AnyFrameInThreatMode() and UI.Refresh then
            UI:Refresh()
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        -- Leaving combat: drop the accumulated enemy list
        if not OM:GetSetting("testMode") then
            ClearTankModeTable()
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
end

function Threat:ClearTestData()
    if not self.testDataActive then return end
    self.testDataActive = false
    ClearThreatTable()
    ClearTankModeTable()
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

    -- Live API path (party/raid + valid hostile target)
    if IsInGroup() and UnitExists("target")
        and not UnitIsPlayer("target") and not UnitIsFriend("player", "target") then
        if (now - Threat.lastQuery) >= Threat.queryInterval then
            Threat.lastQuery = now
            SendThreatQuery()
        end
    end

    if Threat.usingApi and (now - Threat.lastApiTime) > Threat.apiTimeout then
        Threat.usingApi = false
    end

    if not Threat.usingApi then
        -- Estimation also gated to party/raid inside BuildEstimatedThreat
        BuildEstimatedThreat()
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
    ClearThreatTable()
    ClearTankModeTable()
    local k
    for k in pairs(Threat.overallThreat) do
        Threat.overallThreat[k] = nil
    end
    Threat.usingApi = false
    Threat.estimateHistory = {}
    Threat.testDataActive = false
end

function Threat:OnCombatEnd()
    -- keep last values visible for review
end

function Threat:OnReset()
    if OM:GetSetting("testMode") and OM:GetSetting("enableThreatMode") then
        Threat:LoadTestData()
        return
    end
    ClearThreatTable()
    ClearTankModeTable()
    local k
    for k in pairs(Threat.overallThreat) do
        Threat.overallThreat[k] = nil
    end
    Threat.history = {}
    Threat.estimateHistory = {}
    Threat.usingApi = false
    Threat.testDataActive = false
end

OM:RegisterModule("Threat", Threat)
