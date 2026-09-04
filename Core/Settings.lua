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
    selfOnTop = false, -- pin local player as first visible bar; rank unchanged
    hideRankNumbers = false, -- hide N. on bars; announce still uses rank
    textOutline = false,
    textOutlineColor = { 0, 0, 0 },
    titleColor = { 1.00, 0.82, 0.00 },
    barTextColor = { 1.00, 1.00, 1.00 },
    windowBgColor = { 0, 0, 0 },
    barSpacing = 1, -- extra pixels between bars
    textSpacing = 0, -- vertical offset of bar text from bar center
    classIconOffset = 0, -- horizontal class icon shift
    classIconSize = 16, -- class icon pixel size (independent of bar height)
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
    hideWhenSolo = false,
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
    confirmAnnounce = false,
    accountWideLayout = false, -- when true, window size/pos/count is shared across characters
    windowSpecificSettings = false,
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
    GreedMeterDB.testMode = false
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

-- Keys that stay account-wide even when a single window is selected
OM.SETTINGS_GLOBAL_KEYS = {
    lockFrames = true,
    accountWideLayout = true,
    windowSpecificSettings = true,
    confirmReset = true,
    partyJoinReset = true,
    partyLeaveReset = true,
    confirmAnnounce = true,
    testMode = true,
    mergePetDamage = true,
    enableThreatMode = true,
    threatView = true,
    threatWarnSound = true,
    threatWarnGlow = true,
    threatWarnPercent = true,
    threatWarnSoundFile = true,
    combatLogRangeSetting = true,
    announceChannel = true,
    announceLines = true,
    customBarStyles = true,
    customBarFonts = true,
    showPetThreat = true,
    petAsTank = true,
}

local function IsGlobalSetting(key)
    return key and OM.SETTINGS_GLOBAL_KEYS and OM.SETTINGS_GLOBAL_KEYS[key] and true or false
end

function OM:GetSetting(key)
    local v
    local idx = tonumber(self._readIndex) or 0
    if idx >= 1 and key and not IsGlobalSetting(key) then
        local opts = self:GetWindowOpts(idx)
        if opts and opts.settings and opts.settings[key] ~= nil then
            v = opts.settings[key]
        end
    end
    if v == nil then
        if self.db and self.db[key] ~= nil then
            v = self.db[key]
        else
            v = self.defaults[key]
        end
    end
    if key == "frameOpacity" or key == "barHeight" or key == "fontSize" or key == "announceLines"
        or key == "classIconSize" or key == "classIconOffset" or key == "barSpacing" or key == "textSpacing" then
        local n = tonumber(v)
        if n ~= nil then return n end
    end
    return v
end

function OM:GetWindowOpts(index)
    index = tonumber(index) or 0
    if index < 1 then return nil end
    local db = self:GetLayoutDB()
    if not db then return nil end
    if type(db.windowOpts) ~= "table" then
        db.windowOpts = {}
    end
    if type(db.windowOpts[index]) ~= "table" then
        db.windowOpts[index] = { settings = {}, label = nil }
    end
    if type(db.windowOpts[index].settings) ~= "table" then
        db.windowOpts[index].settings = {}
    end
    return db.windowOpts[index]
end

function OM:GetWindowLabel(index)
    local opts = self:GetWindowOpts(index)
    if opts and opts.label and opts.label ~= "" then
        return opts.label
    end
    return "Window " .. tostring(index)
end

function OM:SetWindowLabel(index, label)
    local opts = self:GetWindowOpts(index)
    if not opts then return end
    if not label or label == "" then
        opts.label = nil
    else
        opts.label = label
    end
end

function OM:ClearWindowSettings(index)
    local opts = self:GetWindowOpts(index)
    if opts then
        opts.settings = {}
        opts.label = nil
    end
end

function OM:ClearAllWindowSettings()
    local db = self:GetLayoutDB()
    if db then
        db.windowOpts = {}
    end
end

function OM:SetSetting(key, value)
    if not self.db then
        self.db = GreedMeterDB or {}
        GreedMeterDB = self.db
    end
    local scope = 0
    local UI = GreedMeter.UI
    if UI and UI.settingsScope then
        scope = tonumber(UI.settingsScope) or 0
    end
    if scope >= 1 and key and not IsGlobalSetting(key) then
        local opts = self:GetWindowOpts(scope)
        if opts then
            opts.settings[key] = value
        end
        return
    end
    self.db[key] = value
    -- All-windows write clears per-window overrides for this key
    if scope == 0 and key and not IsGlobalSetting(key) then
        local db = self.GetLayoutDB and self:GetLayoutDB()
        local opts = db and db.windowOpts
        if type(opts) == "table" then
            local i
            for i = 1, 6 do
                if type(opts[i]) == "table" and type(opts[i].settings) == "table" then
                    opts[i].settings[key] = nil
                end
            end
        end
    end
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
