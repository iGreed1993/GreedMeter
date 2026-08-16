--[[
    GreedMeter - Core / Settings
    Account-wide settings (GreedMeterDB) + per-character layout (GreedMeterCharDB).
]]

local OM = GreedMeter

-- Account-wide defaults
OM.defaults = {
    classColors = true,
    showClassIcons = false,
    buttonsColorWithMode = false, -- tint header buttons with the window's mode color
    barStyle = "Default",   -- status bar texture style
    barFont = "Friz",       -- bar text font
    barHeight = 16,
    fontSize = 11,
    lockFrames = false,
    showTotal = false,
    hideTitle = false,          -- Compact Header
    keepTitleInCompact = false, -- title row above the compact 1-line controls
    mergePetDamage = false, -- merge all pet ability damage into a single "Pet: Damage" entry
    announceChannel = "AUTO",
    announceLines = 5,
    numberFormat = "100k", -- when to abbreviate: "1k", "10k", "100k", "never"
    superwowPromptShown = false, -- first-load SuperWoW popup
    minimapAngle = 220,
    testMode = false,
    combatLogRangeSetting = 200,
    frameOpacity = 100,
    confirmReset = false,
    partyReset = false, -- auto-reset on join/leave party or party→raid
    confirmAnnounce = false,
    accountWideLayout = false, -- when true, window size/pos/count is shared across characters
    abbreviateNames = false,
    -- columnConfig, modeColors, modeEnabled are created on demand by Customization
    customBarStyles = {}, -- user-imported bar textures { key, label, texture }
    customBarFonts = {},  -- user-imported fonts { key, label, path }
    showPetThreat = false, -- threat mode: show local pet as its own row
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
    if self.db and self.db[key] ~= nil then
        return self.db[key]
    end
    return self.defaults[key]
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
    if not self:HasSuperWoW() then
        return "Standard (install SuperWoW for better accuracy)"
    end
    local ver = tostring(SUPERWOW_VERSION or SUPERWOW_STRING or "detected")
    return "SuperWoW active (" .. ver .. ")"
end

function OM:ShowSuperWoWPromptIfNeeded()
    if self:HasSuperWoW() then
        return
    end
    if self:GetSetting("superwowPromptShown") then
        return
    end

    StaticPopupDialogs["GREEDMETER_SUPERWOW"] = {
        text = "GreedMeter works without SuperWoW, but runs with better accuracy and features when SuperWoW is installed.\n\nWe recommend SuperWoW for the best experience.",
        button1 = "OK",
        OnAccept = function()
            OM:SetSetting("superwowPromptShown", true)
        end,
        OnShow = function()
            -- ensure flag is set if they only press escape with hideOnEscape
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
