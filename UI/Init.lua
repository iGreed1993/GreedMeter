--[[
    GreedMeter - UI / Init
    UI module table, constants, helpers, dropdowns, tooltips.
]]

local OM = GreedMeter
local UI = {}
GreedMeter.UI = UI

-- ============================================================
-- Constants / State
-- ============================================================

local MAX_BARS = 40          -- full raid
local BAR_GAP = 1
local HEADER_HEIGHT = 44
local FOOTER_HEIGHT = 10
local MAX_FRAMES = 6
local MIN_FRAME_WIDTH = 160
local MAX_FRAME_WIDTH = 500
local MIN_FRAME_HEIGHT = 120
local MAX_FRAME_HEIGHT = 800

local MODE_ORDER = { "damage", "healing", "dispels", "taken", "interrupts", "cc", "ccbreak", "deaths" }
local MODE_LABELS = {
    damage = "Damage",
    healing = "Healing",
    dispels = "Dispels",
    taken = "Dmg Taken",
    interrupts = "Interrupts",
    cc = "CC",
    ccbreak = "CC Breaks",
    deaths = "Deaths",
}

local CLASS_COLORS = {
    WARRIOR = { 0.78, 0.61, 0.43 },
    MAGE = { 0.41, 0.80, 0.94 },
    ROGUE = { 1.00, 0.96, 0.41 },
    DRUID = { 1.00, 0.49, 0.04 },
    HUNTER = { 0.67, 0.83, 0.45 },
    SHAMAN = { 0.00, 0.44, 0.87 },
    PRIEST = { 1.00, 1.00, 1.00 },
    WARLOCK = { 0.58, 0.51, 0.79 },
    PALADIN = { 0.96, 0.55, 0.73 },
}

-- TexCoords for Interface\Glues\CharacterCreate\UI-CharacterCreate-Classes
local CLASS_ICON_TCOORDS = {
    WARRIOR     = { 0.00, 0.25, 0.00, 0.25 },
    MAGE        = { 0.25, 0.50, 0.00, 0.25 },
    ROGUE       = { 0.50, 0.75, 0.00, 0.25 },
    DRUID       = { 0.75, 1.00, 0.00, 0.25 },
    HUNTER      = { 0.00, 0.25, 0.25, 0.50 },
    SHAMAN      = { 0.25, 0.50, 0.25, 0.50 },
    PRIEST      = { 0.50, 0.75, 0.25, 0.50 },
    WARLOCK     = { 0.75, 1.00, 0.25, 0.50 },
    PALADIN     = { 0.00, 0.25, 0.50, 0.75 },
}

UI.frames = {}
UI.nextFrameId = 1
UI.activeDropdown = nil

-- ============================================================
-- Helpers
-- ============================================================

local function GetClassColor(name, entryData)
    if OM.GetSetting and OM:GetSetting("classColors") == false then
        return 0.55, 0.55, 0.55
    end
    local class = nil
    if entryData and entryData.class then
        class = entryData.class
    elseif OM.players and OM.players[name] then
        class = OM.players[name].class
    end
    if class and CLASS_COLORS[class] then
        return CLASS_COLORS[class][1], CLASS_COLORS[class][2], CLASS_COLORS[class][3]
    end
    return 0.6, 0.6, 0.6
end

local function GetBarHeight()
    local h = OM.GetSetting and OM:GetSetting("barHeight") or 16
    h = tonumber(h) or 16
    if h < 10 then h = 10 end
    if h > 28 then h = 28 end
    return h
end

local function GetFontSize()
    local s = OM.GetSetting and OM:GetSetting("fontSize") or 11
    s = tonumber(s) or 11
    if s < 8 then s = 8 end
    if s > 18 then s = 18 end
    return s
end

-- Built-in Vanilla 1.12 status bar textures (no custom media required)
local BAR_STYLES = {
    { key = "Default", label = "Default",  texture = "Interface\\TargetingFrame\\UI-StatusBar" },
    { key = "Smooth",  label = "Smooth",   texture = "Interface\\PaperDollInfoFrame\\UI-Character-Skills-Bar" },
    { key = "Flat",    label = "Flat",     texture = "Interface\\Tooltips\\UI-Tooltip-Background" },
}

-- Built-in client fonts shipped with Vanilla
local BAR_FONTS = {
    { key = "Friz",     label = "Friz Quadrata", path = "Fonts\\FRIZQT__.TTF" },
    { key = "Arial",    label = "Arial Narrow",  path = "Fonts\\ARIALN.TTF" },
    { key = "Morpheus", label = "Morpheus",      path = "Fonts\\MORPHEUS.TTF" },
    { key = "Skurri",   label = "Skurri",        path = "Fonts\\skurri.TTF" },
}

local function GetBarTexture()
    local key = OM.GetSetting and OM:GetSetting("barStyle") or "Default"
    local i
    for i = 1, table.getn(BAR_STYLES) do
        if BAR_STYLES[i].key == key then
            return BAR_STYLES[i].texture
        end
    end
    return BAR_STYLES[1].texture
end

local function GetBarFontPath()
    local key = OM.GetSetting and OM:GetSetting("barFont") or "Friz"
    local i
    for i = 1, table.getn(BAR_FONTS) do
        if BAR_FONTS[i].key == key then
            return BAR_FONTS[i].path
        end
    end
    return BAR_FONTS[1].path
end

local function FramesLocked()
    return OM.GetSetting and OM:GetSetting("lockFrames") == true
end

-- Insert commas for integer display (e.g. 1234567 → "1,234,567")
local function CommaNumber(n)
    n = math.floor((tonumber(n) or 0) + 0.5)
    if n < 0 then
        return "-" .. CommaNumber(-n)
    end
    local s = tostring(n)
    if string.len(s) <= 3 then
        return s
    end
    local out = ""
    while string.len(s) > 3 do
        out = "," .. string.sub(s, -3) .. out
        s = string.sub(s, 1, -4)
    end
    return s .. out
end

local function FormatNumber(n)
    n = tonumber(n) or 0
    local fmt = "100k"
    if OM.GetSetting then
        fmt = OM:GetSetting("numberFormat") or "100k"
    end

    -- Full numbers with thousands separators, no k/M abbreviation
    if fmt == "never" then
        return CommaNumber(n)
    end

    local threshold = 100000
    if fmt == "1k" then
        threshold = 1000
    elseif fmt == "10k" then
        threshold = 10000
    elseif fmt == "100k" then
        threshold = 100000
    end

    if n >= 1000000 then
        return string.format("%.2fM", n / 1000000)
    elseif n >= threshold then
        return string.format("%.1fk", n / 1000)
    end
    -- Below threshold: full number with commas when long enough (4+ digits)
    return CommaNumber(n)
end

local function CreateButton(parent, text, width, height, onClick)
    local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    btn:SetWidth(width or 60)
    btn:SetHeight(height or 18)
    btn:SetText(text)
    btn:SetScript("OnClick", onClick)
    return btn
end

local function GetSegmentData(key)
    if OM.modules and OM.modules.Parser and OM.modules.Parser.GetSegment then
        return OM.modules.Parser:GetSegment(key)
    end
    if OM.data then
        return OM.data[key]
    end
    return nil
end

function UI:GetSegmentList()
    local list = {
        { key = "current", label = "Current" },
        { key = "overall", label = "Overall" },
    }
    if OM.data and OM.data.recentFights then
        for i, fight in ipairs(OM.data.recentFights) do
            local name = fight.label or ("Fight "..i)
            local tag = fight.isBoss and " (Boss)" or ""
            table.insert(list, { key = "recent"..i, label = name .. tag })
        end
    end
    if OM.data and OM.data.bossFights then
        for i, fight in ipairs(OM.data.bossFights) do
            local name = fight.label or ("Boss "..i)
            table.insert(list, { key = "boss"..i, label = "Boss: " .. name })
        end
    end
    return list
end

-- Short label for the meter header (saves space in compact mode)
function UI:SegmentLabel(key)
    key = key or "current"
    if key == "current" then return "Current" end
    if key == "overall" then return "Overall" end
    local _, _, n = string.find(key, "^recent(%d+)$")
    if n then return "Recent " .. n end
    local _, _, n2 = string.find(key, "^boss(%d+)$")
    if n2 then return "Boss " .. n2 end
    return key
end

-- Full label for dropdown menus (includes fight name)
function UI:SegmentMenuLabel(key)
    local list = self:GetSegmentList()
    for _, entry in ipairs(list) do
        if entry.key == key then return entry.label end
    end
    return self:SegmentLabel(key)
end

-- Seconds until >= 60, then MM:SS
function UI:FormatDuration(seconds)
    if not seconds or seconds <= 0 then return "" end
    seconds = math.floor(seconds + 0.5)
    if seconds < 60 then
        return tostring(seconds) .. "s"
    end
    local m = math.floor(seconds / 60)
    local s = math.mod(seconds, 60)
    return string.format("%d:%02d", m, s)
end

-- Metric extraction for sorting / display
local function GetMetric(data, mode)
    if not data then return 0 end
    if mode == "damage" then
        return data.damage or 0
    elseif mode == "healing" then
        return data.healing or 0
    elseif mode == "dispels" then
        return (data.dispels and data.dispels.count) or 0
    elseif mode == "taken" then
        return data.damageTaken or 0
    elseif mode == "interrupts" then
        return (data.interrupts and data.interrupts.count) or 0
    elseif mode == "cc" then
        -- Enemy-centric: data is a ccTargets entry
        return data.count or 0
    elseif mode == "ccbreak" then
        return (data.ccBreaks and data.ccBreaks.count) or 0
    elseif mode == "deaths" then
        return (data.deaths and data.deaths.count) or 0
    end
    return 0
end

-- Active combat duration for a segment (trimmed when possible)
local function GetSegmentDuration(segment, segmentKey)
    if not segment then return 0 end
    if segment.duration and segment.duration > 0 then
        return segment.duration
    end
    local startT = segment.startTime or 0
    if startT <= 0 then return 0 end

    if OM.inCombat and (not segmentKey or segmentKey == "current") then
        return GetTime() - startT
    end

    -- Combat ended: prefer last activity, then endTime
    local last = segment.lastActivityTime
    if last and last > startT then
        return last - startT
    end
    local endT = segment.endTime or 0
    if endT > startT then
        return endT - startT
    end
    return 0
end

-- total is optional: overall sum for share %
-- Format for damage/healing: Amount (share%)(dps/hps)
local function GetSecondaryText(data, mode, duration, total)
    if mode == "damage" then
        local dmg = data.damage or 0
        local text = FormatNumber(dmg)
        if total and total > 0 then
            local share = (dmg / total) * 100
            text = text .. " (" .. string.format("%.1f", share) .. "%)"
        end
        -- Prefer average segment DPS (overall) when samples exist
        local dps = nil
        if data.dpsSamples and data.dpsSamples > 0 and data.dpsSum then
            dps = data.dpsSum / data.dpsSamples
        elseif duration and duration > 0 then
            dps = dmg / duration
        end
        if dps then
            text = text .. "(" .. FormatNumber(dps) .. ")"
        end
        return text
    elseif mode == "healing" then
        local eh = data.healing or 0
        local text = FormatNumber(eh)
        if total and total > 0 then
            local share = (eh / total) * 100
            text = text .. " (" .. string.format("%.1f", share) .. "%)"
        end
        local hps = nil
        if data.hpsSamples and data.hpsSamples > 0 and data.hpsSum then
            hps = data.hpsSum / data.hpsSamples
        elseif duration and duration > 0 then
            hps = eh / duration
        end
        if hps then
            text = text .. "(" .. FormatNumber(hps) .. ")"
        end
        -- Overheal only in tooltip, not on the bar
        return text
    elseif mode == "cc" then
        local c = data.count or 0
        local d = data.duration or 0
        return c .. " (" .. string.format("%.1f", d) .. "s)"
    else
        return FormatNumber(GetMetric(data, mode))
    end
end

local function BuildSortedList(segment, mode, hiddenNames)
    local list = {}
    if not segment then return list end

    -- Build the full ranking first, then hide names without renumbering.
    if mode == "cc" then
        local targets = segment.ccTargets or {}
        for name, data in pairs(targets) do
            local value = data.count or 0
            if value > 0 then
                table.insert(list, { name = name, data = data, value = value, isEnemy = true })
            end
        end
        table.sort(list, function(a, b)
            if a.value == b.value then
                local da = a.data.duration or 0
                local db = b.data.duration or 0
                if da ~= db then return da > db end
                return a.name < b.name
            end
            return a.value > b.value
        end)
    else
        if not segment.players then return list end
        for name, data in pairs(segment.players) do
            local value = GetMetric(data, mode)
            if value > 0 then
                table.insert(list, { name = name, data = data, value = value })
            end
        end
        table.sort(list, function(a, b)
            if a.value == b.value then
                return a.name < b.name
            end
            return a.value > b.value
        end)
    end

    -- Absolute ranks from the full (unfiltered) order
    local i
    for i = 1, table.getn(list) do
        list[i].rank = i
    end

    -- Drop hidden names; rank stays on each remaining entry
    if hiddenNames then
        local filtered = {}
        for i = 1, table.getn(list) do
            local entry = list[i]
            if not hiddenNames[entry.name] then
                table.insert(filtered, entry)
            end
        end
        return filtered
    end
    return list
end

-- ============================================================
-- Dropdown popup
-- ============================================================

local function CloseDropdown()
    if UI.activeDropdown then
        UI.activeDropdown:Hide()
        UI.activeDropdown = nil
    end
    if UI.dropdownCloser then
        UI.dropdownCloser:Hide()
    end
end

-- openUpward: anchor menu above the button
-- maxRows: wrap into extra columns after this many rows (default: no wrap)
-- colWidth / rowH: optional compact sizing (defaults 140 / 18)
local function ShowDropdown(anchor, options, onSelect, openUpward, maxRows, colWidth, rowH)
    -- Toggle closed if already open for this anchor
    if UI.activeDropdown and UI.activeDropdown:IsShown() and UI.dropdownAnchor == anchor then
        CloseDropdown()
        return
    end
    CloseDropdown()

    local count = table.getn(options)
    if count == 0 then return end

    local dd = UI.dropdownFrame
    if not dd then
        dd = CreateFrame("Frame", "GreedMeterDropDownFrame", UIParent)
        dd:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 12,
            insets = { left = 2, right = 2, top = 2, bottom = 2 },
        })
        dd:SetBackdropColor(0, 0, 0, 0.95)
        dd:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)
        dd:EnableMouse(true)
        dd.buttons = {}
        UI.dropdownFrame = dd
    end

    colWidth = colWidth or 140
    rowH = rowH or 18
    local cols = 1
    local rows = count
    if maxRows and maxRows > 0 and count > maxRows then
        cols = math.ceil(count / maxRows)
        rows = maxRows
    end

    dd:SetFrameStrata("TOOLTIP")
    local menuW = cols * colWidth + 6
    local menuH = rows * rowH + 4
    dd:SetWidth(menuW)
    dd:SetHeight(menuH)
    dd:ClearAllPoints()

    -- Smart placement: open toward screen center so the menu stays visible.
    -- Top-left of screen  → down + right
    -- Top-right           → down + left
    -- Bottom-left         → up   + right
    -- Bottom-right        → up   + left
    local screenW = UIParent:GetWidth() or 1024
    local screenH = UIParent:GetHeight() or 768
    local aLeft = anchor:GetLeft() or 0
    local aBottom = anchor:GetBottom() or 0
    local aCenterX = aLeft + ((anchor:GetWidth() or 0) / 2)
    local aCenterY = aBottom + ((anchor:GetHeight() or 0) / 2)

    local openUp = openUpward
    if openUp == nil then
        -- Prefer opening away from the nearest vertical edge / toward center
        openUp = (aCenterY < (screenH / 2))
    end
    local openLeft = (aCenterX > (screenW / 2))

    if openUp then
        if openLeft then
            dd:SetPoint("BOTTOMRIGHT", anchor, "TOPRIGHT", 0, 2)
        else
            dd:SetPoint("BOTTOMLEFT", anchor, "TOPLEFT", 0, 2)
        end
    else
        if openLeft then
            dd:SetPoint("TOPRIGHT", anchor, "BOTTOMRIGHT", 0, -2)
        else
            dd:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
        end
    end
    dd:SetFrameLevel(1000)

    local i, btn
    for i, btn in ipairs(dd.buttons) do
        btn:Hide()
    end

    for i, opt in ipairs(options) do
        btn = dd.buttons[i]
        if not btn then
            btn = CreateFrame("Button", nil, dd)
            local fs = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            fs:SetPoint("LEFT", btn, "LEFT", 2, 0)
            fs:SetJustifyH("LEFT")
            btn.label = fs
            local hl = btn:CreateTexture(nil, "HIGHLIGHT")
            hl:SetAllPoints(btn)
            hl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
            hl:SetBlendMode("ADD")
            dd.buttons[i] = btn
        end
        btn:SetHeight(rowH)
        btn:SetWidth(colWidth - 2)
        local col = 0
        local row = i - 1
        if maxRows and maxRows > 0 then
            col = math.floor((i - 1) / maxRows)
            row = math.mod(i - 1, maxRows)
        end
        btn:ClearAllPoints()
        btn:SetPoint("TOPLEFT", dd, "TOPLEFT", 3 + col * colWidth, -2 - row * rowH)
        btn.label:SetText(opt.label)
        btn:Show()

        local value = opt.value
        local label = opt.label
        btn:SetScript("OnClick", function()
            -- Name-filter toggles keep the menu open via re-open in onSelect;
            -- for normal menus close first.
            if not UI.dropdownKeepOpen then
                CloseDropdown()
            end
            if onSelect then onSelect(value, label) end
        end)
    end

    dd:Show()
    UI.activeDropdown = dd
    UI.dropdownAnchor = anchor

    -- Click-away closer (ignore the same click that opened the menu)
    if not UI.dropdownCloser then
        local closer = CreateFrame("Button", "GreedMeterDropdownCloser", UIParent)
        closer:SetFrameStrata("DIALOG")
        closer:SetAllPoints(UIParent)
        closer:EnableMouse(true)
        closer:SetScript("OnClick", function()
            if UI.dropdownIgnoreClicks and GetTime() < UI.dropdownIgnoreClicks then
                return
            end
            CloseDropdown()
        end)
        closer:Hide()
        UI.dropdownCloser = closer
    end
    UI.dropdownIgnoreClicks = GetTime() + 0.25
    UI.dropdownCloser:Show()
    UI.dropdownCloser:SetFrameLevel(1)
    dd:SetFrameLevel(UI.dropdownCloser:GetFrameLevel() + 10)
end

-- ============================================================
-- Tooltips
-- ============================================================

local function ShowBarTooltip(bar)
    local entry = bar.entry
    if not entry then return end
    local data = entry.data
    local mode = bar.mode
    local name = entry.name

    GameTooltip:SetOwner(bar, "ANCHOR_RIGHT")
    GameTooltip:ClearLines()
    GameTooltip:AddLine(name, 1, 0.82, 0)

    if mode == "damage" then
        local dmg = data.damage or 0
        GameTooltip:AddLine("Damage: " .. FormatNumber(dmg), 1, 1, 1)
        local dur = bar.duration or 0
        if dur > 0 then
            GameTooltip:AddLine("DPS: " .. FormatNumber(dmg / dur), 0.8, 0.8, 0.8)
            GameTooltip:AddLine("Duration: " .. string.format("%.1fs", dur), 0.6, 0.6, 0.6)
        end
        if data.damageTo then
            local targets = {}
            local tgt, amt
            for tgt, amt in pairs(data.damageTo) do
                table.insert(targets, { name = tgt, amt = amt })
            end
            table.sort(targets, function(a, b) return a.amt > b.amt end)
            if table.getn(targets) > 0 then
                GameTooltip:AddLine("By target:", 1, 0.82, 0)
                local shown = 0
                for _, t in ipairs(targets) do
                    shown = shown + 1
                    if shown > 3 then break end
                    GameTooltip:AddDoubleLine(t.name, FormatNumber(t.amt), 0.8, 0.8, 0.8, 1, 1, 1)
                end
            end
        end
        local dmgSpells = data.damageSpells
        if dmgSpells then
            local spells = {}
            for spell, amt in pairs(dmgSpells) do
                table.insert(spells, { spell = spell, amt = amt })
            end
            table.sort(spells, function(a, b) return a.amt > b.amt end)
            if table.getn(spells) > 0 then
                GameTooltip:AddLine("By spell:", 1, 0.82, 0)
            end
            local shown = 0
            for _, s in ipairs(spells) do
                shown = shown + 1
                if shown > 8 then break end
                local right = FormatNumber(s.amt)
                if dmg > 0 then
                    right = right .. " (" .. string.format("%.1f", (s.amt / dmg) * 100) .. "%)"
                end
                GameTooltip:AddDoubleLine(s.spell, right, 0.8, 0.8, 0.8, 1, 1, 1)
            end
        end
    elseif mode == "healing" then
        local eh = data.healing or 0
        local oh = data.overhealing or 0
        local raw = data.rawHealing or (eh + oh)
        local abs = data.absorbs or 0
        local pct = 0
        if raw > 0 then pct = math.floor((oh / raw) * 100 + 0.5) end
        GameTooltip:AddLine("Effective: " .. FormatNumber(eh), 0.4, 1, 0.4)
        local dur = bar.duration or 0
        if dur > 0 then
            GameTooltip:AddLine("HPS: " .. FormatNumber(eh / dur), 0.8, 0.8, 0.8)
            GameTooltip:AddLine("Duration: " .. string.format("%.1fs", dur), 0.6, 0.6, 0.6)
        end
        GameTooltip:AddLine("Overheal: " .. FormatNumber(oh) .. " (" .. pct .. "%)", 1, 0.6, 0.6)
        GameTooltip:AddLine("Raw: " .. FormatNumber(raw), 0.8, 0.8, 0.8)
        if abs > 0 then
            GameTooltip:AddLine("Absorbs: " .. FormatNumber(abs), 0.5, 0.8, 1)
        end
        if data.healingTo then
            local targets = {}
            local tgt, amt
            for tgt, amt in pairs(data.healingTo) do
                table.insert(targets, { name = tgt, amt = amt })
            end
            table.sort(targets, function(a, b) return a.amt > b.amt end)
            if table.getn(targets) > 0 then
                GameTooltip:AddLine("Healed:", 1, 0.82, 0)
                local shown = 0
                for _, t in ipairs(targets) do
                    shown = shown + 1
                    if shown > 3 then break end
                    GameTooltip:AddDoubleLine(t.name, FormatNumber(t.amt), 0.8, 0.8, 0.8, 1, 1, 1)
                end
            end
        end
        local healSpells = data.healSpells
        if healSpells then
            local spells = {}
            for spell, amt in pairs(healSpells) do
                table.insert(spells, { spell = spell, amt = amt })
            end
            table.sort(spells, function(a, b) return a.amt > b.amt end)
            if table.getn(spells) > 0 then
                GameTooltip:AddLine("By spell:", 1, 0.82, 0)
            end
            local shown = 0
            for _, s in ipairs(spells) do
                shown = shown + 1
                if shown > 8 then break end
                local right = FormatNumber(s.amt)
                if eh > 0 then
                    right = right .. " (" .. string.format("%.1f", (s.amt / eh) * 100) .. "%)"
                end
                GameTooltip:AddDoubleLine(s.spell, right, 0.8, 0.8, 0.8, 1, 1, 1)
            end
        end
    elseif mode == "taken" then
        GameTooltip:AddLine("Damage taken: " .. FormatNumber(data.damageTaken or 0), 1, 1, 1)
        if data.damageTakenBy then
            local srcs = {}
            for src, amt in pairs(data.damageTakenBy) do
                table.insert(srcs, { src = src, amt = amt })
            end
            table.sort(srcs, function(a, b) return a.amt > b.amt end)
            local shown = 0
            for _, s in ipairs(srcs) do
                shown = shown + 1
                if shown > 10 then break end
                GameTooltip:AddDoubleLine(s.src, FormatNumber(s.amt), 0.8, 0.8, 0.8, 1, 1, 1)
            end
        end
    elseif mode == "dispels" then
        local list = (data.dispels and data.dispels.list) or {}
        local c = table.getn(list)
        if (data.dispels and data.dispels.count or 0) > c then
            c = data.dispels.count
        end
        GameTooltip:AddLine("Dispels: " .. c, 1, 1, 1)
        -- Spell names removed (and counts)
        local counts = {}
        local _, what
        for _, what in ipairs(list) do
            counts[what] = (counts[what] or 0) + 1
        end
        local ordered = {}
        for what, n in pairs(counts) do
            table.insert(ordered, { name = what, n = n })
        end
        table.sort(ordered, function(a, b)
            if a.n ~= b.n then return a.n > b.n end
            return a.name < b.name
        end)
        local shown = 0
        for _, entry in ipairs(ordered) do
            shown = shown + 1
            if shown > 12 then break end
            GameTooltip:AddDoubleLine(entry.name, tostring(entry.n), 0.8, 0.8, 0.8, 1, 1, 1)
        end
    elseif mode == "interrupts" then
        local list = (data.interrupts and data.interrupts.list) or {}
        local c = table.getn(list)
        if (data.interrupts and data.interrupts.count or 0) > c then
            c = data.interrupts.count
        end
        GameTooltip:AddLine("Interrupts: " .. c, 1, 1, 1)
        local counts = {}
        local _, what
        for _, what in ipairs(list) do
            counts[what] = (counts[what] or 0) + 1
        end
        for what, n in pairs(counts) do
            GameTooltip:AddDoubleLine(what, tostring(n), 0.8, 0.8, 0.8, 1, 1, 1)
        end
    elseif mode == "cc" then
        -- Enemy-centric entry: data.count / data.duration / data.list
        local list = data.list or {}
        local c = data.count or table.getn(list)
        local d = data.duration or 0
        GameTooltip:AddLine("Times CC'd: " .. c, 1, 1, 1)
        GameTooltip:AddLine("Est. duration: " .. string.format("%.1fs", d), 0.8, 0.8, 0.8)
        local spellCounts = {}
        local _, entry
        for _, entry in ipairs(list) do
            if type(entry) == "table" then
                local sp = entry.spell or "?"
                if not spellCounts[sp] then
                    spellCounts[sp] = { n = 0, dur = 0 }
                end
                spellCounts[sp].n = spellCounts[sp].n + 1
                spellCounts[sp].dur = spellCounts[sp].dur + (entry.duration or 0)
            end
        end
        for sp, info in pairs(spellCounts) do
            GameTooltip:AddDoubleLine(sp .. " x"..info.n, string.format("%.1fs", info.dur), 0.8, 0.8, 0.8, 1, 1, 1)
        end
    elseif mode == "ccbreak" then
        local list = (data.ccBreaks and data.ccBreaks.list) or {}
        local c = (data.ccBreaks and data.ccBreaks.count) or table.getn(list)
        GameTooltip:AddLine("CC breaks: " .. c, 1, 1, 1)
        local counts = {}
        local _, entry
        for _, entry in ipairs(list) do
            if type(entry) == "table" then
                local sp = entry.spell or "?"
                counts[sp] = (counts[sp] or 0) + 1
            elseif type(entry) == "string" then
                counts[entry] = (counts[entry] or 0) + 1
            end
        end
        for sp, n in pairs(counts) do
            GameTooltip:AddDoubleLine(sp, tostring(n), 0.8, 0.8, 0.8, 1, 1, 1)
        end
    elseif mode == "deaths" then
        local list = (data.deaths and data.deaths.list) or {}
        local c = (data.deaths and data.deaths.count) or table.getn(list)
        GameTooltip:AddLine("Deaths: " .. c, 1, 1, 1)
        local _, entry
        for _, entry in ipairs(list) do
            if type(entry) == "table" then
                local killer = entry.killer or "?"
                local spell = entry.spell or "?"
                local amt = entry.amount or 0
                local right = spell
                if amt and amt > 0 then
                    right = spell .. " (" .. FormatNumber(amt) .. ")"
                end
                GameTooltip:AddDoubleLine("by " .. killer, right, 0.8, 0.8, 0.8, 1, 1, 1)
            end
        end
    end

    GameTooltip:Show()
end


-- Shared with other UI files (Lua 5.0 has no cross-file locals)
UI.MODE_ORDER = MODE_ORDER
UI.MODE_LABELS = MODE_LABELS
UI.CLASS_COLORS = CLASS_COLORS
UI.CLASS_ICON_TCOORDS = CLASS_ICON_TCOORDS
UI.MAX_BARS = MAX_BARS
UI.BAR_GAP = BAR_GAP
UI.HEADER_HEIGHT = HEADER_HEIGHT
UI.FOOTER_HEIGHT = FOOTER_HEIGHT
UI.MAX_FRAMES = MAX_FRAMES
UI.MIN_FRAME_WIDTH = MIN_FRAME_WIDTH
UI.MAX_FRAME_WIDTH = MAX_FRAME_WIDTH
UI.MIN_FRAME_HEIGHT = MIN_FRAME_HEIGHT
UI.MAX_FRAME_HEIGHT = MAX_FRAME_HEIGHT
UI.GetClassColor = GetClassColor
UI.GetBarHeight = GetBarHeight
UI.GetFontSize = GetFontSize
UI.GetBarTexture = GetBarTexture
UI.GetBarFontPath = GetBarFontPath
UI.BAR_STYLES = BAR_STYLES
UI.BAR_FONTS = BAR_FONTS
UI.FramesLocked = FramesLocked
UI.FormatNumber = FormatNumber
UI.CreateButton = CreateButton
UI.GetSegmentData = GetSegmentData
UI.GetMetric = GetMetric
UI.GetSecondaryText = GetSecondaryText
UI.GetSegmentDuration = GetSegmentDuration
UI.BuildSortedList = BuildSortedList
UI.CloseDropdown = CloseDropdown
UI.ShowDropdown = ShowDropdown
UI.ShowBarTooltip = ShowBarTooltip
