--[[
    GreedMeter - Core / Settings
    Account-wide settings (GreedMeterDB) + per-character layout (GreedMeterCharDB).
]]

local OM = GreedMeter

-- Account-wide defaults
OM.defaults = {
    classColors = true,
    showClassIcons = false,
    circularClassIcons = false, -- round class icons (minimap-style ring)
    buttonsColorWithMode = false, -- tint header buttons with the window's mode color
    barStyle = "Default",   -- status bar texture style
    barFont = "Friz",       -- bar text font
    barHeight = 16,
    fontSize = 11,
    lockFrames = false,
    showTotal = false,
    showFightDuration = false, -- duration row at top of meter bars
    detailedDamage = false, -- click bars for ability breakdown
    hideTitle = false,          -- Compact Header
    keepTitleInCompact = false, -- title row above the compact 1-line controls
    compactTitleAlign = "CENTER", -- LEFT / CENTER / RIGHT when keep title is on
    hideBarBackgrounds = false, -- hide dark empty track behind bar fill
    hideOutOfCombat = false, -- fade-hide meter windows shortly after combat ends
    hideHeaderReset = false,
    hideHeaderAnnounce = false,
    hideHeaderName = false,
    hideHeaderSegment = false,
    hideHeaderMode = false,
    hideHeaderWindows = false, -- hide + / - window buttons
    mergePetDamage = false, -- tooltip only: one "Pet: Damage" line vs per-ability; pets always merge to owner on meter
    announceChannel = "AUTO",
    announceLines = 5,
    numberFormat = "100k", -- when to abbreviate: "1k", "10k", "100k", "never"
    superwowPromptShown = false, -- first-load SuperWoW popup
    minimapAngle = 220,
    testMode = false,
    combatLogRangeSetting = 200,
    frameOpacity = 100,
    confirmReset = false,
    partyJoinReset = false, -- reset when joining a party or raid
    partyLeaveReset = false, -- reset when leaving a party or raid
    -- Test toggles: allow forcing backends off while the client mods stay installed
    useSuperWoW = true,  -- when false, skip SuperWoW RAW + GUID helpers even if present
    confirmAnnounce = false,
    accountWideLayout = false, -- when true, window size/pos/count is shared across characters
    abbreviateNames = false,
    -- columnConfig, modeColors, modeEnabled are created on demand by Customization
    customBarStyles = {}, -- user-imported bar textures { key, label, texture }
    customBarFonts = {},  -- user-imported fonts { key, label, path }
    showPetThreat = false, -- threat mode: show local pet as its own row
    threatWarnSound = true, -- single-target threat: play sound at threshold
    threatWarnGlow = true, -- single-target threat: full-screen edge glow
    threatWarnPercent = 90, -- warn when your threat % reaches this
    threatWarnSoundFile = "raidwarning", -- key into sound list
    petAsTank = false,    -- tank mode: score aggro from pet instead of player
}

-- Per-character layout defaults
OM.charDefaults = {
    frames = {}, -- [index] = { point, relativeTo, relativePoint, x, y, width, height, mode, shown }
}

function OM:InitDB()
    if not GreedMeterDB then
        GreedMeterDB = {}
    end
    local k, v
    for k, v in pairs(self.defaults) do
        if GreedMeterDB[k] == nil then
            GreedMeterDB[k] = v
        end
    end
    -- Split older combined partyReset into join/leave
    if GreedMeterDB.partyReset ~= nil then
        if GreedMeterDB.partyJoinReset == nil then
            GreedMeterDB.partyJoinReset = GreedMeterDB.partyReset and true or false
        end
        if GreedMeterDB.partyLeaveReset == nil then
            GreedMeterDB.partyLeaveReset = GreedMeterDB.partyReset and true or false
        end
        GreedMeterDB.partyReset = nil
    end
    -- Migrate old account-wide size keys out of the way
    GreedMeterDB.frameWidth = nil
    GreedMeterDB.frameHeight = nil
    if not GreedMeterDB.frames then
        GreedMeterDB.frames = {}
    end
    self.db = GreedMeterDB

    if not GreedMeterCharDB then
        GreedMeterCharDB = {}
    end
    for k, v in pairs(self.charDefaults) do
        if GreedMeterCharDB[k] == nil then
            if type(v) == "table" then
                GreedMeterCharDB[k] = {}
            else
                GreedMeterCharDB[k] = v
            end
        end
    end
    if not GreedMeterCharDB.frames then
        GreedMeterCharDB.frames = {}
    end
    self.chardb = GreedMeterCharDB
end

function OM:GetSetting(key)
    local v
    if self.db and self.db[key] ~= nil then
        v = self.db[key]
    else
        v = self.defaults[key]
    end
    -- Numeric settings can occasionally be stored as strings via the slider
    if key == "frameOpacity" or key == "barHeight" or key == "fontSize" or key == "announceLines" then
        local n = tonumber(v)
        if n ~= nil then return n end
    end
    return v
end

function OM:SetSetting(key, value)
    if not self.db then
        self.db = GreedMeterDB or {}
        GreedMeterDB = self.db
    end
    self.db[key] = value
end

function OM:GetCharDB()
    if not self.chardb then
        self:InitDB()
    end
    return self.chardb
end

-- Layout storage: account-wide (GreedMeterDB) or per-character (GreedMeterCharDB)
function OM:GetLayoutDB()
    if not self.db or not self.chardb then
        self:InitDB()
    end
    if self:GetSetting("accountWideLayout") then
        if not self.db.frames then
            self.db.frames = {}
        end
        return self.db
    end
    if not self.chardb.frames then
        self.chardb.frames = {}
    end
    return self.chardb
end

-- Detect SuperWoW via global SUPERWOW_VERSION

function OM:HasNampower()
    local NS = GreedMeter.ParserNS
    local np = NS and NS.Backends and NS.Backends.Nampower
    if np and np.Available then
        return np.Available()
    end
    return false
end

function OM:GetCombatBackendStatusText()
    local NS = GreedMeter.ParserNS
    local backend = NS and NS.combatBackend or "chat"
    if backend == "nampower" then
        local extra = ""
        if self:HasSuperWoW() then
            extra = " + SuperWoW helpers"
        end
        return "Nampower structured events" .. extra
    elseif backend == "superwow" then
        return "SuperWoW RAW combat log"
    end
    return "Standard chat log"
end

function OM:HasSuperWoW()
    -- Explicit SuperWoW markers only (avoid false positives that break parsing)
    if SUPERWOW_VERSION or SUPERWOW_STRING then
        return true
    end
    if SuperWoW then
        return true
    end
    return false
end

function OM:GetSuperWoWStatusText()
    local hasNP = self.HasNampower and self:HasNampower()
    local hasSW = self.HasSuperWoW and self:HasSuperWoW()
    if hasNP and hasSW then
        local ver = tostring(SUPERWOW_VERSION or SUPERWOW_STRING or "detected")
        return "Nampower + SuperWoW active (" .. ver .. ")"
    end
    if hasNP then
        return "Nampower active (SuperWoW not detected)"
    end
    if hasSW then
        local ver = tostring(SUPERWOW_VERSION or SUPERWOW_STRING or "detected")
        return "SuperWoW active (" .. ver .. ") — Nampower not detected"
    end
    return "GreedMeter works best with Nampower and SuperWoW"
end

function OM:ShowSuperWoWPromptIfNeeded()
    local hasNP = self.HasNampower and self:HasNampower()
    local hasSW = self.HasSuperWoW and self:HasSuperWoW()
    if hasNP and hasSW then
        return
    end
    if self:GetSetting("superwowPromptShown") then
        return
    end

    StaticPopupDialogs["GREEDMETER_SUPERWOW"] = {
        text = "GreedMeter works best with Nampower and SuperWoW. Features that rely on them (structured combat events, pet ownership, GUID tracking, and more accurate threat) are less accurate without them.",
        button1 = "OK",
        OnAccept = function()
            OM:SetSetting("superwowPromptShown", true)
        end,
        OnShow = function()
        end,
        timeout = 0,
        whileDead = 1,
        hideOnEscape = 1,
        exclusive = 1,
    }
    StaticPopup_Show("GREEDMETER_SUPERWOW")

    -- Mark shown so it only appears once even if they ESC out
    self:SetSetting("superwowPromptShown", true)
end
