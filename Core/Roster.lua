--[[
    GreedMeter - Core / Roster
    Group roster and pet ownership.
]]

local OM = GreedMeter

local function GetPlayerClass(unit)
    local _, class = UnitClass(unit)
    return class
end

local function IsPetUnit(unit)
    return unit and (string.find(unit, "pet") or UnitPlayerControlled(unit) and not UnitIsPlayer(unit))
end

-- ============================================================
-- Player / Pet Detection
-- ============================================================

function OM:UpdateGroupRoster()
    self.players = {}

    -- Always track the player
    local playerName = UnitName("player")
    if playerName then
        self.players[playerName] = {
            class = GetPlayerClass("player"),
            pets = {},
            isPlayer = true,
        }
    end

    -- Party
    for i = 1, 4 do
        local unit = "party"..i
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

    -- Raid
    if GetNumRaidMembers() > 0 then
        for i = 1, 40 do
            local unit = "raid"..i
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

    -- Player pet
    if UnitExists("pet") then
        local petName = UnitName("pet")
        if petName and self.players[playerName] then
            self.players[playerName].pets[petName] = true
        end
    end

    -- Party/Raid pets (best effort without SuperWoW)
    for i = 1, 4 do
        local unit = "partypet"..i
        if UnitExists(unit) then
            local petName = UnitName(unit)
            local ownerUnit = "party"..i
            local ownerName = UnitName(ownerUnit)
            if petName and ownerName and self.players[ownerName] then
                self.players[ownerName].pets[petName] = true
            end
        end
    end

    if GetNumRaidMembers() > 0 then
        for i = 1, 40 do
            local unit = "raidpet"..i
            if UnitExists(unit) then
                local petName = UnitName(unit)
                local ownerUnit = "raid"..i
                local ownerName = UnitName(ownerUnit)
                if petName and ownerName and self.players[ownerName] then
                    self.players[ownerName].pets[petName] = true
                    -- Authoritative unit ownership overrides heuristic
                    self.heuristicPets[petName] = ownerName
                end
            end
        end
    end

    -- Also stamp party pet heuristics as authoritative when seen
    for i = 1, 4 do
        local unit = "partypet"..i
        if UnitExists(unit) then
            local petName = UnitName(unit)
            local ownerName = UnitName("party"..i)
            if petName and ownerName then
                self.heuristicPets[petName] = ownerName
            end
        end
    end
    if UnitExists("pet") then
        local petName = UnitName("pet")
        if petName and playerName then
            self.heuristicPets[petName] = playerName
        end
    end

    -- Rebuild heuristic map from unit tokens only (never keep stale orphan binds)
    local fresh = {}
    if UnitExists("pet") then
        local petName = UnitName("pet")
        if petName and playerName then
            fresh[petName] = playerName
        end
    end
    for i = 1, 4 do
        local unit = "partypet"..i
        if UnitExists(unit) then
            local petName = UnitName(unit)
            local ownerName = UnitName("party"..i)
            if petName and ownerName then
                fresh[petName] = ownerName
            end
        end
    end
    if GetNumRaidMembers() > 0 then
        for i = 1, 40 do
            local unit = "raidpet"..i
            if UnitExists(unit) then
                local petName = UnitName(unit)
                local ownerName = UnitName("raid"..i)
                if petName and ownerName then
                    fresh[petName] = ownerName
                end
            end
        end
    end
    self.heuristicPets = fresh

    -- Stamp pets onto owner records from the fresh map
    for pet, owner in pairs(self.heuristicPets) do
        if self.players[owner] then
            self.players[owner].pets = self.players[owner].pets or {}
            self.players[owner].pets[pet] = true
        end
    end
end

-- Classes that can own combat pets / minions in Vanilla
local PET_OWNER_CLASSES = {
    HUNTER = true,
    WARLOCK = true,
}

local function CountPets(data)
    if not data or not data.pets then return 0 end
    local n = 0
    for _ in pairs(data.pets) do n = n + 1 end
    return n
end

-- Count pets including heuristic assignments for this owner
function OM:CountOwnerPets(ownerName)
    local data = self.players[ownerName]
    local n = CountPets(data)
    for pet, owner in pairs(self.heuristicPets) do
        if owner == ownerName then
            -- Don't double-count if already in data.pets
            if not (data and data.pets and data.pets[pet]) then
                n = n + 1
            end
        end
    end
    return n
end

function OM:IsPetOwnerClass(class)
    return class and PET_OWNER_CLASSES[class] == true
end

-- Pet/minion names are random on this client — cannot infer Hunter vs Warlock from name.
function OM:GuessPetOwnerClass(petName)
    return nil
end

-- Find owner of a pet name (roster + heuristic)
function OM:GetPetOwner(petName)
    if not petName then return nil end

    for owner, data in pairs(self.players) do
        if data.pets and data.pets[petName] then
            return owner
        end
    end

    local heuristic = self.heuristicPets[petName]
    if heuristic and self.players[heuristic] then
        return heuristic
    end

    return nil
end

-- True if we've already treated this name as a pet (unit token or prior heuristic)
function OM:IsKnownPetName(petName)
    if not petName then return false end
    if self.heuristicPets[petName] then return true end
    for _, data in pairs(self.players) do
        if data.pets and data.pets[petName] then
            return true
        end
    end
    return false
end

-- Resolve pet ownership from known unit-token / roster data only.
-- Never invent ownership for unknown combat-log names (that was incorrectly
-- attributing mob hits as "Pet: Auto Attack" to petless hunters/warlocks).
function OM:ResolvePetOwner(petName)
    if not petName then return nil end
    if self.players[petName] then return nil end

    local owner = self:GetPetOwner(petName)
    if owner then return owner end

    -- Live unit-token fallback (covers a pet summoned between roster refreshes)
    local playerName = UnitName("player")
    if UnitExists("pet") and UnitName("pet") == petName then
        self.heuristicPets[petName] = playerName
        if self.players[playerName] then
            self.players[playerName].pets = self.players[playerName].pets or {}
            self.players[playerName].pets[petName] = true
        end
        return playerName
    end
    for i = 1, 4 do
        if UnitExists("partypet"..i) and UnitName("partypet"..i) == petName then
            local ownerName = UnitName("party"..i)
            if ownerName then
                self.heuristicPets[petName] = ownerName
                if self.players[ownerName] then
                    self.players[ownerName].pets = self.players[ownerName].pets or {}
                    self.players[ownerName].pets[petName] = true
                end
                return ownerName
            end
        end
    end
    if GetNumRaidMembers() > 0 then
        for i = 1, 40 do
            if UnitExists("raidpet"..i) and UnitName("raidpet"..i) == petName then
                local ownerName = UnitName("raid"..i)
                if ownerName then
                    self.heuristicPets[petName] = ownerName
                    if self.players[ownerName] then
                        self.players[ownerName].pets = self.players[ownerName].pets or {}
                        self.players[ownerName].pets[petName] = true
                    end
                    return ownerName
                end
            end
        end
    end

    return nil
end
