--[[
    GreedMeter - Parser / Backend_Nampower
    Structured combat path when the nampower client DLL is present.

    Handles: damage, miss/avoid, healing, damage taken, dispels, hard CC apply/end,
             environmental damage, deaths.

    Interrupts stay on the chat backend (nampower has no reliable interrupt event).
    Non-damaging threat casts (Sunder, Growl, Torment, …) use AURA_CAST → AddThreatCast.

    SuperWoW GUID/pet helpers and threat remain independent of this backend.
]]

local OM = GreedMeter
local NS = GreedMeter.ParserNS
local Parser = NS.Parser

local NP = {}
NS.Backends.Nampower = NP

-- Victim states
local VICTIM_MISS = 0
local VICTIM_DODGE = 2
local VICTIM_PARRY = 3
local VICTIM_BLOCK = 5

local AA_CRIT = 128
local AA_GLANCING = 16384
local AA_CRUSHING = 32768
local SPELL_CRIT = 2

-- Match Main.lua HARD_CC_SPELLS (names). Duration = base estimate seconds.
local HARD_CC = {
    ["Sap"] = 45, ["Cheap Shot"] = 4, ["Kidney Shot"] = 4, ["Gouge"] = 4, ["Blind"] = 10,
    ["Concussion Blow"] = 5, ["Charge Stun"] = 1, ["Intercept Stun"] = 1, ["Intimidating Shout"] = 8,
    ["Polymorph"] = 50, ["Polymorph: Pig"] = 50, ["Polymorph: Turtle"] = 50, ["Impact"] = 2,
    ["Fear"] = 20, ["Howl of Terror"] = 15, ["Seduction"] = 15, ["Death Coil"] = 3, ["Pyroclasm"] = 3,
    ["Psychic Scream"] = 8, ["Blackout"] = 3,
    ["Bash"] = 3, ["Pounce"] = 3, ["Hibernate"] = 40,
    ["Hammer of Justice"] = 6, ["Repentance"] = 6,
    ["Scatter Shot"] = 4, ["Intimidation"] = 3, ["Wyvern Sting"] = 12,
    ["Freezing Trap Effect"] = 20, ["Freezing Trap"] = 20, ["Scare Beast"] = 20,
    ["War Stomp"] = 2, ["Tidal Charm"] = 3, ["Reckless Charge"] = 30, ["Shackle Undead"] = 50,
}

local PENDING_AURA_WINDOW = 2.0
-- pendingAuraCasts[targetGuid .. "|" .. spellId] = { casterGuid, time, spellName, duration }
local pendingAuraCasts = {}

local function HasBit(value, bit)
    value = tonumber(value)
    bit = tonumber(bit)
    if not value or not bit or bit == 0 then return false end
    return math.mod(math.floor(value / bit), 2) == 1
end

local function SpellName(spellId)
    spellId = tonumber(spellId)
    if not spellId then return nil end
    if type(GetSpellRecField) == "function" then
        local ok, name = pcall(GetSpellRecField, spellId, "name")
        if ok and name and name ~= "" then return name end
    end
    return "Spell " .. tostring(spellId)
end

local function IsHardCCName(name)
    if not name or name == "" then return false end
    if HARD_CC[name] then return true end
    -- Rank / variant: known base name is a prefix of the combat name only
    -- (never the reverse — that matched fragments like "on" inside "Blackout").
    local k, v
    for k, v in pairs(HARD_CC) do
        if string.sub(name, 1, string.len(k)) == k then
            return true
        end
    end
    return false
end

local function HardCCDuration(name)
    if not name or name == "" then return 0 end
    if HARD_CC[name] then return HARD_CC[name] end
    local k, v
    for k, v in pairs(HARD_CC) do
        if string.sub(name, 1, string.len(k)) == k then
            return v
        end
    end
    return 0
end

local function NameFromGuid(guid)
    if not guid or guid == "" then return nil end
    if Parser.NameFromGuid then
        local n = Parser:NameFromGuid(guid)
        if n and n ~= "" then return n end
    end
    if type(UnitGUID) ~= "function" then return nil end
    local ok, my = pcall(UnitGUID, "player")
    if ok and my and my == guid then
        return UnitName("player")
    end
    local units = {
        "player", "pet", "target", "targettarget", "mouseover",
        "party1", "party2", "party3", "party4",
        "partypet1", "partypet2", "partypet3", "partypet4",
    }
    local i
    for i = 1, table.getn(units) do
        local u = units[i]
        if UnitExists and UnitExists(u) then
            local ok2, g = pcall(UnitGUID, u)
            if ok2 and g and g == guid then
                local n = UnitName(u)
                if n and n ~= "" then
                    return n
                end
            end
        end
    end
    if UnitInRaid and UnitInRaid("player") then
        for i = 1, 40 do
            local u = "raid" .. i
            if UnitExists(u) then
                local ok2, g = pcall(UnitGUID, u)
                if ok2 and g and g == guid then
                    local n = UnitName(u)
                    if n and n ~= "" then return n end
                end
            end
            local pu = "raidpet" .. i
            if UnitExists(pu) then
                local ok2, g = pcall(UnitGUID, pu)
                if ok2 and g and g == guid then
                    local n = UnitName(pu)
                    if n and n ~= "" then return n end
                end
            end
        end
    end
    return nil
end

local function CachePair(guid, name)
    if not guid or not name then return end
    if Parser.CacheGuid then
        Parser:CacheGuid(name, guid)
    end
end

-- When GUID→name fails for our own outgoing hit, prefer current target if GUID matches.
local function ResolveTargetName(targetGuid, isOutgoingSelf)
    local tgt = NameFromGuid(targetGuid)
    if tgt then return tgt end
    if not isOutgoingSelf then return nil end
    if not (UnitExists and UnitExists("target")) then return nil end
    local tname = UnitName("target")
    if not tname or tname == "" then return nil end
    if type(UnitGUID) == "function" and targetGuid then
        local ok, g = pcall(UnitGUID, "target")
        if ok and g then
            if g == targetGuid then
                CachePair(targetGuid, tname)
                return tname
            end
            -- GUID known but different unit — do not guess
            return nil
        end
    end
    -- No UnitGUID API: best-effort for solo dummy testing
    if targetGuid then CachePair(targetGuid, tname) end
    return tname
end

-- ============================================================
-- GUID roster (CombatLedger-style): track player/party/pets by GUID
-- SuperWoW: UnitExists(unit) returns exists, guid as 2nd value.
-- ============================================================
local trackedGuids = {}       -- [guid] = true
local lastGuidRefresh = 0
local petGuidToOwner = {}     -- [petGuid] = ownerName
local guidToUnitName = {}     -- [guid] = unit name (pet or player)

local function NormGuid(g)
    if not g then return nil end
    g = string.lower(tostring(g))
    local _, _, rest = string.find(g, "^0x(.+)$")
    if rest then return rest end
    return g
end

local function GetUnitGuid(unit)
    if not unit then return nil end
    if type(UnitGUID) == "function" then
        local ok, g = pcall(UnitGUID, unit)
        if ok and g and g ~= "" then return g end
    end
    -- SuperWoW / OctoWoW: second return of UnitExists is the GUID
    if UnitExists then
        local exists, g = UnitExists(unit)
        if exists and type(g) == "string" and string.len(g) > 4 then
            return g
        end
    end
    return nil
end

local function RegisterGuid(guid, name, ownerName)
    if not guid then return end
    local key = NormGuid(guid)
    if not key then return end
    trackedGuids[key] = true
    trackedGuids[guid] = true -- also raw form from events
    if name and name ~= "" then
        guidToUnitName[key] = name
        guidToUnitName[guid] = name
        CachePair(guid, name)
    end
    if ownerName and ownerName ~= "" then
        petGuidToOwner[key] = ownerName
        petGuidToOwner[guid] = ownerName
        if name and name ~= "" then
            OM.heuristicPets = OM.heuristicPets or {}
            OM.heuristicPets[name] = ownerName
        end
    end
end

local function RefreshTrackedGuids()
    trackedGuids = {}
    petGuidToOwner = {}
    guidToUnitName = {}
    lastGuidRefresh = GetTime()

    local function add(unit, ownerUnit)
        if not UnitExists or not UnitExists(unit) then return end
        local guid = GetUnitGuid(unit)
        local name = UnitName(unit)
        local ownerName = nil
        if ownerUnit and UnitExists(ownerUnit) then
            ownerName = UnitName(ownerUnit)
        end
        RegisterGuid(guid, name, ownerName)
    end

    add("player", nil)
    add("pet", "player")

    local i
    if GetNumRaidMembers and GetNumRaidMembers() > 0 then
        for i = 1, 40 do
            add("raid" .. i, nil)
            add("raidpet" .. i, "raid" .. i)
            -- Some clients use raidNpet form
            add("raid" .. i .. "pet", "raid" .. i)
        end
    else
        for i = 1, 4 do
            add("party" .. i, nil)
            add("partypet" .. i, "party" .. i)
        end
    end
end

local function IsTrackedGuid(guid)
    if not guid then return false end
    if trackedGuids[guid] then return true end
    local n = NormGuid(guid)
    return n and trackedGuids[n] and true or false
end

local function OwnerNameForGuid(guid)
    if not guid then return nil end
    local o = petGuidToOwner[guid] or petGuidToOwner[NormGuid(guid)]
    return o
end

local function NameFromGuidOrPet(guid)
    if not guid then return nil end
    local n = NameFromGuid(guid)
    if n then return n end
    n = guidToUnitName[guid] or guidToUnitName[NormGuid(guid)]
    if n then return n end
    -- Live pet match
    if UnitExists and UnitExists("pet") then
        local pg = GetUnitGuid("pet")
        if pg and (pg == guid or NormGuid(pg) == NormGuid(guid)) then
            local pname = UnitName("pet")
            if pname then
                RegisterGuid(guid, pname, UnitName("player"))
                return pname
            end
        end
    end
    return nil
end

-- Resolve event attacker to a name suitable for AddDamage (pet name if pet,
-- so isPet + ResolveSource still run). Refresh GUID roster every event is cheap enough.
local function ResolveAttacker(guid, isSelf)
    local now = GetTime()
    if (now - (lastGuidRefresh or 0)) > 1.0 then
        RefreshTrackedGuids()
        lastGuidRefresh = now
    elseif UnitExists and UnitExists("pet") and not next(petGuidToOwner) then
        RefreshTrackedGuids()
        lastGuidRefresh = now
    end
    if isSelf and (not guid or guid == "") then
        return UnitName("player")
    end
    local name = NameFromGuidOrPet(guid)
    if name then return name end
    -- Tracked pet GUID but name unknown → use owner name with pet tag via heuristic
    local owner = OwnerNameForGuid(guid)
    if owner then
        -- Synthetic pet label so AddDamage marks isPet and merges to owner
        local label = "Pet"
        if UnitExists("pet") and OwnerNameForGuid(guid) == UnitName("player") then
            label = UnitName("pet") or "Pet"
        end
        OM.heuristicPets = OM.heuristicPets or {}
        OM.heuristicPets[label] = owner
        return label
    end
    if isSelf then return UnitName("player") end
    return nil
end

local function IsTrackedName(name)
    if not name then return false end
    if OM.players and OM.players[name] then return true end
    if name == UnitName("player") then return true end
    if OM.ResolvePetOwner and OM:ResolvePetOwner(name) then return true end
    if OM.GetPetOwner and OM:GetPetOwner(name) then return true end
    if OM.heuristicPets and OM.heuristicPets[name] then return true end
    if UnitExists and UnitExists("pet") and UnitName("pet") == name then return true end
    return false
end

local function IsTrackedAttacker(guid, name)
    if IsTrackedGuid(guid) then return true end
    if IsTrackedName(name) then return true end
    return false
end

local function PrunePendingAuras(now)
    local k, v
    for k, v in pairs(pendingAuraCasts) do
        if not v.time or (now - v.time) > PENDING_AURA_WINDOW then
            pendingAuraCasts[k] = nil
        end
    end
end

-- ---------- combat handlers ----------

local function OnAutoAttack(isSelf)
    local attackerGuid, targetGuid = arg1, arg2
    local totalDamage = tonumber(arg3) or 0
    local hitInfo = tonumber(arg4) or 0
    local victimState = tonumber(arg5)

    local src = ResolveAttacker(attackerGuid, isSelf)
    local tgt = ResolveTargetName(targetGuid, isSelf and true or false)
    if src and attackerGuid then CachePair(attackerGuid, src) end
    if tgt and targetGuid then CachePair(targetGuid, tgt) end

    local srcTracked = IsTrackedAttacker(attackerGuid, src)
    local tgtTracked = IsTrackedName(tgt)

    if totalDamage > 0 then
        local hitType = "hit"
        if HasBit(hitInfo, AA_CRIT) then
            hitType = "crit"
        elseif HasBit(hitInfo, AA_GLANCING) then
            hitType = "glance"
        elseif HasBit(hitInfo, AA_CRUSHING) then
            hitType = "crush"
        end
        if srcTracked then
            Parser:AddDamage(src, totalDamage, "Auto Attack", tgt, hitType)
        end
        if tgtTracked then
            Parser:AddDamageTaken(tgt, totalDamage, src or "Unknown", "Auto Attack", hitType)
        end
    else
        local avoid = "miss"
        if victimState == VICTIM_DODGE then
            avoid = "dodge"
        elseif victimState == VICTIM_PARRY then
            avoid = "parry"
        elseif victimState == VICTIM_BLOCK then
            avoid = "block"
        end
        if srcTracked then
            Parser:AddMiss(src, "Auto Attack", tgt, avoid)
        end
        if tgtTracked then
            Parser:AddTakenAvoid(tgt, "Auto Attack", src or "Unknown", avoid)
        end
    end
end

local function OnSpellDamage(isSelf)
    local targetGuid, casterGuid = arg1, arg2
    local spellId, amount = arg3, tonumber(arg4) or 0
    local mitigation, hitInfo = arg5, tonumber(arg6) or 0
    -- arg7 = spellSchool, arg8 = effectAuraStr "effect1,effect2,effect3,auraType"
    local effectAuraStr = arg8

    local src = ResolveAttacker(casterGuid, isSelf)
    local tgt = ResolveTargetName(targetGuid, isSelf and true or false)
    if src and casterGuid then CachePair(casterGuid, src) end
    if tgt and targetGuid then CachePair(targetGuid, tgt) end

    local spell = SpellName(spellId) or "Unknown"
    local hitType = "hit"
    if HasBit(hitInfo, SPELL_CRIT) then hitType = "crit" end

    local partial = false
    if mitigation and type(mitigation) == "string" then
        local _, _, ab, bl, rs = string.find(mitigation, "(%d+),(%d+),(%d+)")
        if ab and ((tonumber(bl) or 0) > 0 or (tonumber(rs) or 0) > 0) then
            partial = true
        end
    end

    -- DoT tick vs upfront hit (CombatLedger-style):
    -- effectAuraStr is "effect1,effect2,effect3[,auraType]".
    -- Upfront Immolate/Rake hits have 3 fields; ticks add auraType as a 4th field.
    -- Only the 4th field identifies periodic (never treat a 3-field effect code as a DoT).
    -- SPELL_AURA_PERIODIC_DAMAGE=3, PERIODIC_LEECH=53, PERIODIC_DAMAGE_PERCENT=89
    local isPeriodic = false
    if effectAuraStr and type(effectAuraStr) == "string" and effectAuraStr ~= "" then
        local fields = {}
        local from = 1
        while true do
            local pos = string.find(effectAuraStr, ",", from, true)
            if not pos then
                table.insert(fields, string.sub(effectAuraStr, from))
                break
            end
            table.insert(fields, string.sub(effectAuraStr, from, pos - 1))
            from = pos + 1
        end
        if table.getn(fields) >= 4 then
            local aura = tonumber(fields[4])
            if aura == 3 or aura == 53 or aura == 89 then
                isPeriodic = true
            end
        end
    end
    -- Siphon Life etc. always tick-shaped when no aura type is present
    if not isPeriodic and spellId then
        local sid = tonumber(spellId)
        if sid == 18881 then
            isPeriodic = true
        end
    end

    if amount > 0 then
        if IsTrackedAttacker(casterGuid, src) then
            Parser:AddDamage(src, amount, spell, tgt, hitType, partial, isPeriodic)
        end
        if IsTrackedName(tgt) then
            Parser:AddDamageTaken(tgt, amount, src or "Unknown", spell, hitType, partial, isPeriodic)
        end
    end
end

local function OnSpellMiss(isSelf)
    -- Nampower SPELL_MISS_*: arg1=casterGuid, arg2=targetGuid, arg3=spellId, arg4=missInfo
    -- (Documented opposite of SPELL_DAMAGE_EVENT which is target, caster.)
    local casterGuid, targetGuid, spellId, missType = arg1, arg2, arg3, arg4
    local src = ResolveAttacker(casterGuid, isSelf)
    -- isSelf here means player is the caster (outgoing miss), not the target
    local tgt = ResolveTargetName(targetGuid, isSelf and true or false)
    if src then CachePair(casterGuid, src) end
    if tgt and targetGuid then CachePair(targetGuid, tgt) end

    local spell = SpellName(spellId) or "Unknown"
    local avoid = "miss"
    local lower = string.lower(tostring(missType or ""))
    if string.find(lower, "dodge", 1, true) or tostring(missType) == "2" then
        avoid = "dodge"
    elseif string.find(lower, "parry", 1, true) or tostring(missType) == "3" then
        avoid = "parry"
    elseif string.find(lower, "block", 1, true) or tostring(missType) == "5" then
        avoid = "block"
    elseif string.find(lower, "resist", 1, true) then
        if IsTrackedAttacker(casterGuid, src) then
            Parser:AddResist(src, spell, tgt)
        end
        return
    end

    if IsTrackedAttacker(casterGuid, src) then
        Parser:AddMiss(src, spell, tgt, avoid)
    end
    if IsTrackedName(tgt) then
        Parser:AddTakenAvoid(tgt, spell, src or "Unknown", avoid)
    end
end

local function OnSpellHeal()
    local targetGuid, casterGuid = arg1, arg2
    local spellId, amount = arg3, tonumber(arg4) or 0
    local critFlag = arg5
    local src = NameFromGuid(casterGuid)
    local tgt = NameFromGuid(targetGuid)
    if src then CachePair(casterGuid, src) end
    if tgt then CachePair(targetGuid, tgt) end
    if amount <= 0 or not IsTrackedName(src) then return end
    local spell = SpellName(spellId) or "Unknown"
    local hitType = "hit"
    if critFlag == 1 or critFlag == "1" or critFlag == true then hitType = "crit" end
    Parser:AddHealing(src, amount, spell, false, tgt, hitType)
end

local function OnDispel()
    local casterGuid, targetGuid, spellId = arg1, arg2, arg3
    local src = NameFromGuid(casterGuid)
    local tgt = NameFromGuid(targetGuid)
    if src then CachePair(casterGuid, src) end
    if tgt then CachePair(targetGuid, tgt) end
    if not src or not IsTrackedName(src) then return end
    local spell = SpellName(spellId) or "Dispel"
    Parser:AddDispel(src, spell, tgt)
end

-- AURA_CAST: spellId, casterGuid, targetGuid [, effect, ...]
-- Used for hard-CC correlation and for non-damaging threat apps (Sunder,
-- Growl, Torment, Demo Shout, …) so estimates work without falling back
-- to chat while Nampower owns combat.
local function OnAuraCast()
    local spellId, casterGuid, targetGuid = arg1, arg2, arg3
    spellId = tonumber(spellId)
    if not spellId then return end
    local name = SpellName(spellId)
    if not name or name == "" then return end

    local src = nil
    if casterGuid then
        src = NameFromGuid(casterGuid)
        if src then CachePair(casterGuid, src) end
    end

    -- Flat threat casts: pet Growl / VW Torment / player Sunder, etc.
    -- AddThreatCast resolves pets → owner and filters to known abilities.
    if src and Parser.AddThreatCast then
        Parser:AddThreatCast(src, name)
    end

    -- Hard CC path (unchanged)
    if not IsHardCCName(name) then return end

    local now = GetTime()
    PrunePendingAuras(now)
    local key = tostring(targetGuid or "") .. "|" .. tostring(spellId)
    pendingAuraCasts[key] = {
        casterGuid = casterGuid,
        time = now,
        spellName = name,
        duration = HardCCDuration(name),
    }
end

-- DEBUFF_ADDED: guid, slot, spellId, stacks, ...
local function OnDebuffAdded()
    local guid, spellId = arg1, arg3
    spellId = tonumber(spellId) or tonumber(arg2)
    if not guid or not spellId then return end
    local name = SpellName(spellId)
    if not IsHardCCName(name) then return end

    local now = GetTime()
    PrunePendingAuras(now)
    local key = tostring(guid) .. "|" .. tostring(spellId)
    local pending = pendingAuraCasts[key]
    -- Also try match by spellId only if unique enough (AOE CC)
    if not pending then
        local k, v
        for k, v in pairs(pendingAuraCasts) do
            if v.spellName and name and (v.spellName == name or string.find(name, v.spellName, 1, true)) then
                if v.time and (now - v.time) <= PENDING_AURA_WINDOW then
                    pending = v
                    pendingAuraCasts[k] = nil
                    break
                end
            end
        end
    else
        pendingAuraCasts[key] = nil
    end

    local targetName = NameFromGuid(guid)
    if not targetName then return end
    CachePair(guid, targetName)

    -- Only track enemy CC (AddEnemyCC ignores group members)
    local dur = HardCCDuration(name)
    if pending and pending.duration and pending.duration > 0 then
        dur = pending.duration
    end
    Parser:AddEnemyCC(name, targetName, dur)
end

-- DEBUFF_REMOVED: guid, slot, spellId, ...
local function OnDebuffRemoved()
    local guid, spellId = arg1, arg3
    spellId = tonumber(spellId) or tonumber(arg2)
    local name = SpellName(spellId)
    if not IsHardCCName(name) then return end
    local targetName = NameFromGuid(guid)
    if targetName and Parser.FinishCC then
        Parser:FinishCC(targetName, name)
    end
end

local function OnUnitDied()
    local guid = arg1
    local name = NameFromGuid(guid) or arg2
    if name and IsTrackedName(name) then
        Parser:AddDeath(name, nil)
    end
end

local function OnEnvironmental(isSelf)
    local unitGuid, dmgType, damage = arg1, arg2, tonumber(arg3) or 0
    if damage <= 0 then return end
    local name = NameFromGuid(unitGuid)
    if isSelf and not name then name = UnitName("player") end
    if not name or not IsTrackedName(name) then return end
    Parser:AddDamageTaken(name, damage, "Environment", tostring(dmgType or "Environmental"), "hit")
end

-- ---------- enable / detect ----------

local CVARS = {
    "NP_EnableAutoAttackEvents",
    "NP_EnableSpellHealEvents",
    "NP_EnableSpellEnergizeEvents",
    "NP_EnableAuraCastEvents",
    "NP_EnableSpellStartEvents",
    "NP_EnableSpellGoEvents",
}

function NP.Available()
    if type(WriteCustomFile) == "function" then return true end
    if type(GetSpellRecField) == "function" then return true end
    if type(GetUnitData) == "function" then return true end
    local ok = pcall(GetCVar, "NP_EnableAutoAttackEvents")
    if ok then return true end
    return false
end

function NP.Enable()
    local i
    for i = 1, table.getn(CVARS) do
        pcall(SetCVar, CVARS[i], "1")
    end

    pendingAuraCasts = {}
    if RefreshTrackedGuids then RefreshTrackedGuids() end

    local f = NP.frame
    if not f then
        f = CreateFrame("Frame", "GreedMeterNampowerFrame")
        NP.frame = f
    end

    f:UnregisterAllEvents()
    -- Damage / miss / heal
    f:RegisterEvent("AUTO_ATTACK_SELF")
    f:RegisterEvent("AUTO_ATTACK_OTHER")
    f:RegisterEvent("SPELL_DAMAGE_EVENT_SELF")
    f:RegisterEvent("SPELL_DAMAGE_EVENT_OTHER")
    f:RegisterEvent("SPELL_MISS_SELF")
    f:RegisterEvent("SPELL_MISS_OTHER")
    -- BY_* only: ON_SELF also fires for the same heal and would double-count
    f:RegisterEvent("SPELL_HEAL_BY_SELF")
    f:RegisterEvent("SPELL_HEAL_BY_OTHER")
    -- Dispel
    f:RegisterEvent("SPELL_DISPEL_BY_SELF")
    f:RegisterEvent("SPELL_DISPEL_BY_OTHER")
    -- CC (aura correlation)
    f:RegisterEvent("AURA_CAST_ON_SELF")
    f:RegisterEvent("AURA_CAST_ON_OTHER")
    f:RegisterEvent("DEBUFF_ADDED_SELF")
    f:RegisterEvent("DEBUFF_ADDED_OTHER")
    f:RegisterEvent("DEBUFF_REMOVED_SELF")
    f:RegisterEvent("DEBUFF_REMOVED_OTHER")
    -- Misc
    f:RegisterEvent("ENVIRONMENTAL_DMG_SELF")
    f:RegisterEvent("ENVIRONMENTAL_DMG_OTHER")
    f:RegisterEvent("UNIT_DIED")
    f:RegisterEvent("UNIT_PET")
    f:RegisterEvent("PLAYER_ENTERING_WORLD")
    f:RegisterEvent("PARTY_MEMBERS_CHANGED")
    f:RegisterEvent("RAID_ROSTER_UPDATE")

    f:SetScript("OnEvent", function()
        local ev = event
        if ev == "AUTO_ATTACK_SELF" then
            OnAutoAttack(true)
        elseif ev == "AUTO_ATTACK_OTHER" then
            OnAutoAttack(false)
        elseif ev == "SPELL_DAMAGE_EVENT_SELF" then
            OnSpellDamage(true)
        elseif ev == "SPELL_DAMAGE_EVENT_OTHER" then
            OnSpellDamage(false)
        elseif ev == "SPELL_MISS_SELF" then
            OnSpellMiss(true)
        elseif ev == "SPELL_MISS_OTHER" then
            OnSpellMiss(false)
        elseif ev == "SPELL_HEAL_BY_SELF" or ev == "SPELL_HEAL_BY_OTHER" then
            OnSpellHeal()
        elseif ev == "SPELL_DISPEL_BY_SELF" or ev == "SPELL_DISPEL_BY_OTHER" then
            OnDispel()
        elseif ev == "AURA_CAST_ON_SELF" or ev == "AURA_CAST_ON_OTHER" then
            OnAuraCast()
        elseif ev == "DEBUFF_ADDED_SELF" or ev == "DEBUFF_ADDED_OTHER" then
            OnDebuffAdded()
        elseif ev == "DEBUFF_REMOVED_SELF" or ev == "DEBUFF_REMOVED_OTHER" then
            OnDebuffRemoved()
        elseif ev == "ENVIRONMENTAL_DMG_SELF" then
            OnEnvironmental(true)
        elseif ev == "ENVIRONMENTAL_DMG_OTHER" then
            OnEnvironmental(false)
        elseif ev == "UNIT_DIED" then
            OnUnitDied()
        elseif ev == "UNIT_PET" or ev == "PLAYER_ENTERING_WORLD"
            or ev == "PARTY_MEMBERS_CHANGED" or ev == "RAID_ROSTER_UPDATE" then
            RefreshTrackedGuids()
        end
    end)

    NS.useNampowerCombat = true
    NS.useNampowerDispel = true
    NS.useNampowerCC = true
    NS.combatBackend = "nampower"
    return true
end

function NP.Disable()
    if NP.frame then
        NP.frame:UnregisterAllEvents()
        NP.frame:SetScript("OnEvent", nil)
    end
    NS.useNampowerCombat = false
    NS.useNampowerDispel = false
    NS.useNampowerCC = false
    pendingAuraCasts = {}
end
