--[[
    GreedMeter - Core / Roster
    Group roster and pet ownership.

    Pet ownership sources (in preference order):
      1. SuperWoW combat-log forms / GUID cache  → handled in Parser
      2. Unit tokens (pet / partypetN / raidpetN) → this file (works with or without SuperWoW)
      3. Live unit-token fallback for pets summoned between roster refreshes

    We never invent ownership for unknown combat-log names (that incorrectly
    credited mob hits as pet damage to hunters/warlocks).
]]

local OM = GreedMeter

local function GetPlayerClass(unit)
    local _, class = UnitClass(unit)
    return class
end

-- Stamp a known pet onto its owner in both the roster and the heuristic map.
local function AssignPet(self, petName, ownerName, heurMap)
    if not petName or not ownerName then return end
    if self.players[ownerName] then
        local pets = self.players[ownerName].pets
        if not pets then
            pets = {}
            self.players[ownerName].pets = pets
        end
        pets[petName] = true
    end
    if heurMap then
        heurMap[petName] = ownerName
    end
end

-- Single pass over standard unit tokens. Authoritative on both stock 1.12 and SuperWoW.
local function CollectUnitTokenPets(self, heurMap)
    local playerName = UnitName("player")
    if UnitExists("pet") then
        AssignPet(self, UnitName("pet"), playerName, heurMap)
    end
    local i
    for i = 1, 4 do
        if UnitExists("partypet" .. i) then
            AssignPet(self, UnitName("partypet" .. i), UnitName("party" .. i), heurMap)
        end
    end
    if GetNumRaidMembers() > 0 then
        for i = 1, 40 do
            if UnitExists("raidpet" .. i) then
                AssignPet(self, UnitName("raidpet" .. i), UnitName("raid" .. i), heurMap)
            end
        end
    end
end

-- Live lookup for a single pet name (used when roster may be stale).
-- Returns owner name or nil; does not invent ownership.
local function FindLivePetOwner(petName)
    if not petName then return nil end
    if UnitExists("pet") and UnitName("pet") == petName then
        return UnitName("player")
    end
    local i
    for i = 1, 4 do
        if UnitExists("partypet" .. i) and UnitName("partypet" .. i) == petName then
            return UnitName("party" .. i)
        end
    end
    if GetNumRaidMembers() > 0 then
        for i = 1, 40 do
            if UnitExists("raidpet" .. i) and UnitName("raidpet" .. i) == petName then
                return UnitName("raid" .. i)
            end
        end
    end
    return nil
end

-- ============================================================
-- Roster rebuild
-- ============================================================

function OM:UpdateGroupRoster()
    self.players = {}

    local playerName = UnitName("player")
    if playerName then
        self.players[playerName] = {
            class = GetPlayerClass("player"),
            pets = {},
            isPlayer = true,
        }
    end

    local i
    for i = 1, 4 do
        local unit = "party" .. i
        if UnitExists(unit) then
            local name = UnitName(unit)
            if name then
                self.players[name] = {
                    class = GetPlayerClass(unit),
                    pets = {},
                    isPlayer = true,
                }
            end
        end
    end

    if GetNumRaidMembers() > 0 then
        for i = 1, 40 do
            local unit = "raid" .. i
            if UnitExists(unit) then
                local name = UnitName(unit)
                if name then
                    self.players[name] = {
                        class = GetPlayerClass(unit),
                        pets = {},
                        isPlayer = true,
                    }
                end
            end
        end
    end

    -- One rebuild of pet ownership from unit tokens.
    -- Replacing the map drops stale binds (dismissed pets, players who left).
    local fresh = {}
    CollectUnitTokenPets(self, fresh)
    self.heuristicPets = fresh
end

-- ============================================================
-- Pet ownership queries
-- ============================================================

-- Roster + heuristic map only (no live unit scan).
function OM:GetPetOwner(petName)
    if not petName then return nil end

    local owner, data
    for owner, data in pairs(self.players) do
        if data.pets and data.pets[petName] then
            return owner
        end
    end

    local heuristic = self.heuristicPets and self.heuristicPets[petName]
    if heuristic and self.players[heuristic] then
        return heuristic
    end
    return nil
end

function OM:IsKnownPetName(petName)
    if not petName then return false end
    if self.heuristicPets and self.heuristicPets[petName] then
        return true
    end
    local _, data
    for _, data in pairs(self.players) do
        if data.pets and data.pets[petName] then
            return true
        end
    end
    return false
end

-- Resolve pet → owner for combat-log attribution.
-- Prefer roster/heuristic; fall back to a live unit-token check for pets
-- summoned between roster refreshes. Never invents ownership for unknown names.
function OM:ResolvePetOwner(petName)
    if not petName then return nil end
    -- Group players are not pets
    if self.players[petName] then return nil end

    local owner = self:GetPetOwner(petName)
    if owner then return owner end

    owner = FindLivePetOwner(petName)
    if owner and self.players[owner] then
        self.heuristicPets = self.heuristicPets or {}
        AssignPet(self, petName, owner, self.heuristicPets)
        return owner
    end

    return nil
end
