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

-- Default summon names shared by many hunters/warlocks (and wild mobs).
-- A name-only map cannot tell two "Bear" pets apart.
local GENERIC_PET_NAMES = {
    Wolf=true, Cat=true, Spider=true, Bear=true, Boar=true,
    Crocolisk=true, Crab=true, Gorilla=true, Hyena=true, Owl=true,
    Raptor=true, Tallstrider=true, Turtle=true, Bat=true, Scorpid=true,
    Imp=true, Voidwalker=true, Succubus=true, Felhunter=true,
    Infernal=true, Doomguard=true,
    ["Carrion Bird"]=true, ["Wind Serpent"]=true, ["Void Walker"]=true,
    ["Fel Hunter"]=true, ["Felguard"]=true,
}

local function IsGenericPetName(name)
    if not name then return false end
    if GENERIC_PET_NAMES[name] then return true end
    return false
end

-- All current unit-token owners of this pet name.
local function FindLivePetOwners(petName)
    local owners = {}
    local seen = {}
    local function add(owner)
        if owner and owner ~= "" and not seen[owner] then
            seen[owner] = true
            table.insert(owners, owner)
        end
    end
    if not petName then return owners end
    if UnitExists("pet") and UnitName("pet") == petName then
        add(UnitName("player"))
    end
    local i
    for i = 1, 4 do
        if UnitExists("partypet" .. i) and UnitName("partypet" .. i) == petName then
            add(UnitName("party" .. i))
        end
    end
    if GetNumRaidMembers() > 0 then
        for i = 1, 40 do
            if UnitExists("raidpet" .. i) and UnitName("raidpet" .. i) == petName then
                add(UnitName("raid" .. i))
            end
        end
    end
    return owners
end

local function FindLivePetOwner(petName)
    local owners = FindLivePetOwners(petName)
    if table.getn(owners) == 1 then
        return owners[1]
    end
    return nil
end

local function RosterOwnersOfPet(self, petName)
    local owners = {}
    local seen = {}
    local owner, data
    if not self.players then return owners end
    for owner, data in pairs(self.players) do
        if data and data.pets and data.pets[petName] and not seen[owner] then
            seen[owner] = true
            table.insert(owners, owner)
        end
    end
    return owners
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
    -- Keep totem / SuperWoW "(Owner)" binds; unit-token rebuild drops them.
    if self.stickyPets then
        local pet, owner
        for pet, owner in pairs(self.stickyPets) do
            -- Default family names are not unique; unit tokens already bound them.
            if owner and self.players[owner] and not IsGenericPetName(pet) then
                AssignPet(self, pet, owner, fresh)
            end
        end
    end
    self.heuristicPets = fresh
end

-- ============================================================
-- Pet ownership queries
-- ============================================================

-- Roster + heuristic map only (no live unit scan).
function OM:GetPetOwner(petName)
    if not petName then return nil end
    -- Group members are never pets
    if self.players and self.players[petName] then
        return nil
    end

    local live = FindLivePetOwners(petName)
    local nLive = table.getn(live)
    if nLive == 1 then
        return live[1]
    end
    if nLive > 1 then
        return nil
    end

    local roster = RosterOwnersOfPet(self, petName)
    local nRoster = table.getn(roster)
    if nRoster == 1 then
        return roster[1]
    end
    if nRoster > 1 then
        return nil
    end

    if IsGenericPetName(petName) then
        return nil
    end

    local heuristic = self.heuristicPets and self.heuristicPets[petName]
    if heuristic and self.players and self.players[heuristic] then
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
    if self.players and self.players[petName] then return nil end

    local owner = self:GetPetOwner(petName)
    if owner then return owner end

    owner = FindLivePetOwner(petName)
    if owner and self.players and self.players[owner] then
        if not IsGenericPetName(petName) then
            self.heuristicPets = self.heuristicPets or {}
            AssignPet(self, petName, owner, self.heuristicPets)
        end
        return owner
    end

    return nil
end

function OM:SetPetOwner(petName, ownerName)
    if not petName or not ownerName or petName == "" or ownerName == "" then
        return
    end
    if self.players and self.players[petName] then
        return
    end
    -- Default names like Bear/Wolf/Cat are reused; a sticky name→owner
    -- bind would steal damage from every other hunter with that pet.
    if not IsGenericPetName(petName) then
        self.stickyPets = self.stickyPets or {}
        self.stickyPets[petName] = ownerName
        self.heuristicPets = self.heuristicPets or {}
        AssignPet(self, petName, ownerName, self.heuristicPets)
    else
        AssignPet(self, petName, ownerName, nil)
    end
end

function OM:IsTotemName(name)
    if not name or type(name) ~= "string" then return false end
    if string.find(name, "Totem") then return true end
    return false
end

function OM:NoteTotemCast(caster, spell)
    if not caster or not spell then return end
    if not string.find(spell, "Totem") then return end
    caster = string.gsub(caster, "^%s+", "")
    caster = string.gsub(caster, "%s+$", "")
    if caster == "You" or caster == "you" then
        caster = UnitName("player")
    end
    self:SetPetOwner(spell, caster)
end
