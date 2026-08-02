--[[
    GreedMeter - UI / Settings
    Settings panel, announce, module lifecycle.
]]

local OM = GreedMeter
local UI = GreedMeter.UI

local MODE_LABELS = UI.MODE_LABELS
local FormatNumber = UI.FormatNumber
local CreateButton = UI.CreateButton
local GetSegmentData = UI.GetSegmentData
local GetSecondaryText = UI.GetSecondaryText
local BuildSortedList = UI.BuildSortedList
local CloseDropdown = UI.CloseDropdown
local ShowDropdown = UI.ShowDropdown

-- ============================================================
-- Announce (simple)
-- ============================================================

function UI:AnnounceFrame(f)
    local segment = GetSegmentData(f.segment)
    local mode = f.mode or "damage"
    local list = BuildSortedList(segment, mode, f.hiddenNames)
    if table.getn(list) == 0 then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00GreedMeter:|r Nothing to announce.")
        return
    end

    local duration = 0
    if UI.GetSegmentDuration then
        duration = UI.GetSegmentDuration(segment, f.segment)
    elseif segment then
        if segment.duration and segment.duration > 0 then
            duration = segment.duration
        elseif segment.startTime and segment.startTime > 0 then
            local endT = segment.endTime or 0
            if endT > segment.startTime then
                duration = endT - segment.startTime
            elseif OM.inCombat and f.segment == "current" then
                duration = GetTime() - segment.startTime
            end
        end
    end

    local pref = (OM.GetSetting and OM:GetSetting("announceChannel")) or "AUTO"
    local channel = "SAY"
    if pref == "SAY" or pref == "PARTY" or pref == "RAID" then
        channel = pref
    else
        -- AUTO
        if GetNumRaidMembers() > 0 then
            channel = "RAID"
        elseif GetNumPartyMembers() > 0 then
            channel = "PARTY"
        else
            channel = "SAY"
        end
    end

    local label = MODE_LABELS[mode] or mode
    local segLabel = self:SegmentLabel(f.segment)
    local fmtHint = ""
    if mode == "damage" then
        fmtHint = " (%) (DPS)"
    elseif mode == "healing" then
        fmtHint = " (%) (HPS)"
    end
    SendChatMessage("GreedMeter: " .. segLabel .. " " .. label .. fmtHint, channel)

    local limit = (OM.GetSetting and OM:GetSetting("announceLines")) or 5
    limit = tonumber(limit) or 5
    if limit < 1 then limit = 1 end
    if limit > 40 then limit = 40 end

    -- Total for share % (exclude a Total row if present)
    local metricTotal = 0
    local _, entry
    for _, entry in ipairs(list) do
        if not entry.isTotal then
            metricTotal = metricTotal + (entry.value or 0)
        end
    end

    local i
    for i, entry in ipairs(list) do
        if i > limit then break end
        local line = i .. ". " .. entry.name .. " - " .. GetSecondaryText(entry.data, mode, duration, metricTotal)
        SendChatMessage(line, channel)
    end
end

-- ============================================================
-- Settings panel
-- ============================================================

local function AddCheckbox(parent, label, x, y, settingKey, tooltip, size)
    size = size or 24
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetWidth(size)
    cb:SetHeight(size)
    cb:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("LEFT", cb, "RIGHT", 2, 0)
    fs:SetText(label)
    cb.label = fs
    cb:SetChecked(OM:GetSetting(settingKey) and 1 or nil)
    cb:SetScript("OnClick", function()
        local checked = this:GetChecked() and true or false
        OM:SetSetting(settingKey, checked)
        UI:ApplySettingsToFrames()
        if this.onToggle then this.onToggle(checked) end
    end)
    if tooltip then
        cb:SetScript("OnEnter", function()
            GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
            GameTooltip:SetText(tooltip, nil, nil, nil, nil, 1)
            GameTooltip:Show()
        end)
        cb:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    return cb
end

local function AddSlider(parent, label, x, y, settingKey, minV, maxV, step, width)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    fs:SetText(label)

    local slider = CreateFrame("Slider", nil, parent)
    slider:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y - 14)
    slider:SetWidth(width or 200)
    slider:SetHeight(16)
    slider:SetOrientation("HORIZONTAL")
    slider:SetMinMaxValues(minV, maxV)
    slider:SetValueStep(step or 1)
    slider:SetValue(OM:GetSetting(settingKey) or minV)

    local bg = slider:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(slider)
    bg:SetTexture(0.2, 0.2, 0.2, 0.8)

    local thumb = slider:CreateTexture(nil, "OVERLAY")
    thumb:SetTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
    thumb:SetWidth(32)
    thumb:SetHeight(32)
    slider:SetThumbTexture(thumb)

    local valText = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    valText:SetPoint("LEFT", slider, "RIGHT", 6, 0)
    valText:SetText(tostring(math.floor((OM:GetSetting(settingKey) or minV) + 0.5)))

    slider:SetScript("OnValueChanged", function()
        local v = this:GetValue()
        -- snap to step
        if step and step >= 1 then
            v = math.floor(v / step + 0.5) * step
        end
        OM:SetSetting(settingKey, v)
        valText:SetText(tostring(math.floor(v + 0.5)))
        UI:ApplySettingsToFrames()
    end)
    return slider
end

function UI:CreateSettingsFrame()
    if self.settingsFrame then return self.settingsFrame end

    local f = CreateFrame("Frame", "GreedMeterSettings", UIParent)
    f:SetWidth(460)
    f:SetHeight(470)
    f:SetPoint("CENTER", UIParent, "CENTER", 120, 40)
    f:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    f:SetBackdropColor(0, 0, 0, 0.92)
    f:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function() this:StartMoving() end)
    f:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)
    f:SetFrameStrata("DIALOG")
    f:SetClampedToScreen(true)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", f, "TOP", 0, -10)
    title:SetText("GreedMeter Settings")

    local sw = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    sw:SetPoint("TOP", title, "BOTTOM", 0, -2)
    if OM.GetSuperWoWStatusText then
        sw:SetText(OM:GetSuperWoWStatusText())
    else
        sw:SetText("")
    end
    if OM.HasSuperWoW and OM:HasSuperWoW() then
        sw:SetTextColor(0.4, 1, 0.4)
    else
        sw:SetTextColor(1, 0.8, 0.3)
    end

    -- Left column: checkboxes
    local y = -48
    AddCheckbox(f, "Class colors", 16, y, "classColors", "Color bars by player class")
    y = y - 24
    AddCheckbox(f, "Lock frame position", 16, y, "lockFrames", "Prevent dragging and resizing")
    y = y - 24
    local layoutCb = AddCheckbox(f, "Account-wide layout", 16, y, "accountWideLayout",
        "Share window size, position, and number of open windows across all characters on this account. Uncheck for per-character layouts.")
    layoutCb.onToggle = function(checked)
        -- Copy current layout into the newly selected store so nothing is lost
        if UI.SaveAllFrameLayouts then
            UI:SaveAllFrameLayouts()
        end
        if checked then
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00GreedMeter:|r Layout is now account-wide.")
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00GreedMeter:|r Layout is now per-character.")
        end
    end
    y = y - 24
    AddCheckbox(f, "Confirm before reset", 16, y, "confirmReset", "Show a confirmation popup when pressing Reset")
    y = y - 24
    AddCheckbox(f, "Confirm before announce", 16, y, "confirmAnnounce", "Show a confirmation popup when pressing Announce")
    y = y - 24
    AddCheckbox(f, "Show total bar", 16, y, "showTotal", "Add a Total row summing all players")
    y = y - 24
    AddCheckbox(f, "Hide title (compact header)", 16, y, "hideTitle",
        "Hide the GreedMeter title and use a tighter two-row header")
    y = y - 24
    local testCb = AddCheckbox(f, "Test mode", 16, y, "testMode",
        "Fill the meter with fake 40-player raid data. Uncheck to clear it.")
    testCb.onToggle = function(checked)
        if checked then
            if OM.LoadTestData then OM:LoadTestData() end
            if UI.Refresh then UI:Refresh() end
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00GreedMeter:|r Test mode ON")
        else
            if OM.data then
                OM.data.current = { players = {}, startTime = 0, endTime = 0, label = "Current", isBoss = false, duration = 0 }
                OM.data.overall = { players = {}, startTime = 0, endTime = 0, label = "Overall", isBoss = false, duration = 0 }
                OM.data.recentFights = {}
                OM.data.bossFights = {}
            end
            if OM.UpdateGroupRoster then OM:UpdateGroupRoster() end
            OM:Fire("OnReset")
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00GreedMeter:|r Test mode OFF")
        end
    end
    y = y - 24
    AddCheckbox(f, "Show class icons", 16, y, "showClassIcons",
        "Show a class icon before each player name on the meter bars")
    y = y - 24
    AddCheckbox(f, "Merge pet damage", 16, y, "mergePetDamage",
        "Combine all pet ability damage into a single \"Pet: Damage\" entry on tooltips")
    y = y - 28

    -- Right column: dropdowns (top-aligned with checkboxes)
    local rightX = 250
    local ry = -48

    local annLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    annLabel:SetPoint("TOPLEFT", f, "TOPLEFT", rightX, ry)
    annLabel:SetText("Announce channel:")
    ry = ry - 20

    local CHANNELS = { "AUTO", "SAY", "PARTY", "RAID" }

    local function ChannelDropDown_OnClick()
        local id = this:GetID()
        local ch = CHANNELS[id]
        if not ch then return end
        OM:SetSetting("announceChannel", ch)
        UIDropDownMenu_SetSelectedID(f.channelDropDown, id)
        UIDropDownMenu_SetText(ch, f.channelDropDown)
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00GreedMeter:|r Announce channel: " .. ch)
    end

    local function ChannelDropDown_Init()
        local cur = OM:GetSetting("announceChannel") or "AUTO"
        local i
        for i = 1, table.getn(CHANNELS) do
            local info = {}
            info.text = CHANNELS[i]
            info.func = ChannelDropDown_OnClick
            info.checked = (CHANNELS[i] == cur)
            UIDropDownMenu_AddButton(info)
        end
    end

    local dd = CreateFrame("Frame", "GreedMeterChannelDropDown", f, "UIDropDownMenuTemplate")
    dd:SetPoint("TOPLEFT", f, "TOPLEFT", rightX - 16, ry)
    UIDropDownMenu_Initialize(dd, ChannelDropDown_Init)
    UIDropDownMenu_SetWidth(120, dd)
    UIDropDownMenu_SetButtonWidth(120, dd)
    local cur = OM:GetSetting("announceChannel") or "AUTO"
    UIDropDownMenu_SetText(cur, dd)
    local sel = 1
    local i
    for i = 1, table.getn(CHANNELS) do
        if CHANNELS[i] == cur then sel = i break end
    end
    UIDropDownMenu_SetSelectedID(dd, sel)
    f.channelDropDown = dd

    ry = ry - 40
    local rangeLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    rangeLabel:SetPoint("TOPLEFT", f, "TOPLEFT", rightX, ry)
    rangeLabel:SetText("Combat log range:")
    ry = ry - 20

    local RANGES = { 40, 100, 200 }

    local function RangeDropDown_OnClick()
        local id = this:GetID()
        local r = RANGES[id]
        if not r then return end
        OM:SetSetting("combatLogRangeSetting", r)
        if OM.ApplyCombatLogRange then
            OM:ApplyCombatLogRange(r)
        end
        UIDropDownMenu_SetSelectedID(f.rangeDropDown, id)
        UIDropDownMenu_SetText(tostring(r) .. "y", f.rangeDropDown)
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00GreedMeter:|r Combat log range: " .. r .. "y")
    end

    local function RangeDropDown_Init()
        local cur = OM:GetSetting("combatLogRangeSetting") or OM.combatLogRange or 200
        local i
        for i = 1, table.getn(RANGES) do
            local info = {}
            info.text = tostring(RANGES[i]) .. "y"
            info.func = RangeDropDown_OnClick
            info.checked = (RANGES[i] == cur)
            UIDropDownMenu_AddButton(info)
        end
    end

    local rdd = CreateFrame("Frame", "GreedMeterRangeDropDown", f, "UIDropDownMenuTemplate")
    rdd:SetPoint("TOPLEFT", f, "TOPLEFT", rightX - 16, ry)
    UIDropDownMenu_Initialize(rdd, RangeDropDown_Init)
    UIDropDownMenu_SetWidth(120, rdd)
    UIDropDownMenu_SetButtonWidth(120, rdd)
    local rcur = OM:GetSetting("combatLogRangeSetting") or OM.combatLogRange or 200
    UIDropDownMenu_SetText(tostring(rcur) .. "y", rdd)
    local rsel = 3
    local ri
    for ri = 1, table.getn(RANGES) do
        if RANGES[ri] == rcur then rsel = ri break end
    end
    UIDropDownMenu_SetSelectedID(rdd, rsel)
    f.rangeDropDown = rdd

    -- Bar style
    ry = ry - 40
    local styleLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    styleLabel:SetPoint("TOPLEFT", f, "TOPLEFT", rightX, ry)
    styleLabel:SetText("Bar style:")
    ry = ry - 20

    local BAR_STYLES = UI.BAR_STYLES or {
        { key = "Default", label = "Default" },
        { key = "Smooth", label = "Smooth" },
        { key = "Flat", label = "Flat" },
    }

    local function StyleDropDown_OnClick()
        local id = this:GetID()
        local entry = BAR_STYLES[id]
        if not entry then return end
        OM:SetSetting("barStyle", entry.key)
        UIDropDownMenu_SetSelectedID(f.styleDropDown, id)
        UIDropDownMenu_SetText(entry.label, f.styleDropDown)
        if UI.ApplySettingsToFrames then
            UI:ApplySettingsToFrames()
        end
    end

    local function StyleDropDown_Init()
        local cur = OM:GetSetting("barStyle") or "Default"
        local i
        for i = 1, table.getn(BAR_STYLES) do
            local info = {}
            info.text = BAR_STYLES[i].label
            info.func = StyleDropDown_OnClick
            info.checked = (BAR_STYLES[i].key == cur)
            UIDropDownMenu_AddButton(info)
        end
    end

    local sdd = CreateFrame("Frame", "GreedMeterStyleDropDown", f, "UIDropDownMenuTemplate")
    sdd:SetPoint("TOPLEFT", f, "TOPLEFT", rightX - 16, ry)
    UIDropDownMenu_Initialize(sdd, StyleDropDown_Init)
    UIDropDownMenu_SetWidth(120, sdd)
    UIDropDownMenu_SetButtonWidth(120, sdd)
    local scur = OM:GetSetting("barStyle") or "Default"
    local ssel = 1
    local si
    for si = 1, table.getn(BAR_STYLES) do
        if BAR_STYLES[si].key == scur then
            ssel = si
            UIDropDownMenu_SetText(BAR_STYLES[si].label, sdd)
            break
        end
    end
    UIDropDownMenu_SetSelectedID(sdd, ssel)
    f.styleDropDown = sdd

    -- Bar font
    ry = ry - 40
    local fontLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fontLabel:SetPoint("TOPLEFT", f, "TOPLEFT", rightX, ry)
    fontLabel:SetText("Bar font:")
    ry = ry - 20

    local BAR_FONTS = UI.BAR_FONTS or {
        { key = "Friz", label = "Friz Quadrata" },
        { key = "Arial", label = "Arial Narrow" },
        { key = "Morpheus", label = "Morpheus" },
        { key = "Skurri", label = "Skurri" },
    }

    local function FontDropDown_OnClick()
        local id = this:GetID()
        local entry = BAR_FONTS[id]
        if not entry then return end
        OM:SetSetting("barFont", entry.key)
        UIDropDownMenu_SetSelectedID(f.fontDropDown, id)
        UIDropDownMenu_SetText(entry.label, f.fontDropDown)
        if UI.ApplySettingsToFrames then
            UI:ApplySettingsToFrames()
        end
    end

    local function FontDropDown_Init()
        local cur = OM:GetSetting("barFont") or "Friz"
        local i
        for i = 1, table.getn(BAR_FONTS) do
            local info = {}
            info.text = BAR_FONTS[i].label
            info.func = FontDropDown_OnClick
            info.checked = (BAR_FONTS[i].key == cur)
            UIDropDownMenu_AddButton(info)
        end
    end

    local fdd = CreateFrame("Frame", "GreedMeterFontDropDown", f, "UIDropDownMenuTemplate")
    fdd:SetPoint("TOPLEFT", f, "TOPLEFT", rightX - 16, ry)
    UIDropDownMenu_Initialize(fdd, FontDropDown_Init)
    UIDropDownMenu_SetWidth(120, fdd)
    UIDropDownMenu_SetButtonWidth(120, fdd)
    local fcur = OM:GetSetting("barFont") or "Friz"
    local fsel = 1
    local fi
    for fi = 1, table.getn(BAR_FONTS) do
        if BAR_FONTS[fi].key == fcur then
            fsel = fi
            UIDropDownMenu_SetText(BAR_FONTS[fi].label, fdd)
            break
        end
    end
    UIDropDownMenu_SetSelectedID(fdd, fsel)
    f.fontDropDown = fdd

    -- Sliders below the checkbox column
    AddSlider(f, "Bar height", 16, y, "barHeight", 10, 28, 1, 200)
    y = y - 36
    AddSlider(f, "Font size", 16, y, "fontSize", 8, 18, 1, 200)
    y = y - 36
    AddSlider(f, "Frame opacity", 16, y, "frameOpacity", 30, 100, 5, 200)
    y = y - 36
    AddSlider(f, "Announce lines", 16, y, "announceLines", 1, 20, 1, 200)

    local close = CreateButton(f, "Close", 70, 20, function()
        f:Hide()
    end)
    close:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 12)

    f:Hide()
    self.settingsFrame = f
    return f
end


function UI:ToggleSettings()
    if not OM.db then OM:InitDB() end
    local f = self:CreateSettingsFrame()
    if f:IsShown() then
        f:Hide()
    else
        f:Show()
    end
end

-- ============================================================
-- Module events
-- ============================================================

function UI:OnLoad()
    if not OM.db then
        OM:InitDB()
    end
    if not self.mainFrame then
        self:CreateMeterFrame(true)
    end
    self:LayoutBars(self.mainFrame)
    -- Restore primary layout (position/size/mode) if saved
    if self.ApplySavedLayout then
        self:ApplySavedLayout(self.mainFrame, 1)
    end
    if self.RestoreSavedFrames then
        self:RestoreSavedFrames()
    end
    -- Show meters on login by default (respect saved shown state from layout DB)
    local layoutDB = OM.GetLayoutDB and OM:GetLayoutDB()
    local primarySaved = layoutDB and layoutDB.frames and layoutDB.frames[1]
    if not primarySaved or primarySaved.shown ~= false then
        if self.mainFrame then
            self.mainFrame:Show()
            self:RefreshFrame(self.mainFrame)
        end
    end
    if self.CreateMinimapButton then
        self:CreateMinimapButton()
    end
    -- Periodic refresh while shown
    if not self.ticker then
        local t = CreateFrame("Frame")
        local elapsed = 0
        t:SetScript("OnUpdate", function()
            elapsed = elapsed + arg1
            if elapsed >= 0.5 then
                elapsed = 0
                if OM.inCombat then
                    UI:Refresh()
                end
            end
        end)
        self.ticker = t
    end
end

function UI:OnCombatStart()
    self:Refresh()
end

function UI:OnCombatEnd()
    self:Refresh()
end

function UI:OnReset()
    local _, f
    for _, f in ipairs(self.frames) do
        f.scrollOffset = 0
        f.maxScroll = 0
        f.hiddenNames = {}
        f.segment = "current"
        if f.segLabel then f.segLabel:SetText("Current") end
        -- Clear bar state so nothing stale remains
        if f.bars then
            local i, bar
            for i, bar in ipairs(f.bars) do
                bar:Hide()
                bar.entry = nil
                bar:SetValue(0)
                if bar.nameText then bar.nameText:SetText("") end
                if bar.valueText then bar.valueText:SetText("") end
            end
        end
        if f.emptyLabel then
            f.emptyLabel:Show()
            f.emptyLabel:SetText("No data yet")
        end
    end
    self:Refresh()
end

function UI:ShowNameFilterMenu(f, anchor)
    local segment = GetSegmentData(f.segment)
    if not segment or not segment.players then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00GreedMeter:|r No players to filter.")
        return
    end
    if not f.hiddenNames then f.hiddenNames = {} end

    local names = {}
    local name
    for name, _ in pairs(segment.players) do
        table.insert(names, name)
    end
    table.sort(names, function(a, b) return a < b end)

    local function ShortName(n)
        if not n then return "?" end
        if string.len(n) > 7 then
            return string.sub(n, 1, 7)
        end
        return n
    end

    local opts = {}
    table.insert(opts, { value = "__ALL__", label = "[+] All" })
    table.insert(opts, { value = "__NONE__", label = "[-] None" })
    local i
    for i = 1, table.getn(names) do
        local n = names[i]
        local mark = f.hiddenNames[n] and "[ ]" or "[x]"
        table.insert(opts, { value = n, label = mark .. ShortName(n) })
    end

    -- Compact: 8 rows, ~60px columns, 14px row height; direction is auto (smart)
    UI.dropdownKeepOpen = true
    UI.dropdownAnchor = nil
    ShowDropdown(anchor, opts, function(value, label)
        if value == "__ALL__" then
            f.hiddenNames = {}
        elseif value == "__NONE__" then
            local _, n2
            for _, n2 in ipairs(names) do
                f.hiddenNames[n2] = true
            end
        else
            if f.hiddenNames[value] then
                f.hiddenNames[value] = nil
            else
                f.hiddenNames[value] = true
            end
        end
        UI:RefreshFrame(f)
        UI.dropdownKeepOpen = true
        UI.dropdownAnchor = nil
        UI:ShowNameFilterMenu(f, anchor)
    end, nil, 8, 62, 14)
    UI.dropdownKeepOpen = false
end

function UI:OnToggleUI()
    if not self.mainFrame then
        self:CreateMeterFrame(true)
    end
    if CloseDropdown then CloseDropdown() end
    self:ToggleAllFrames()
end

function UI:OnRosterUpdate()
    self:Refresh()
end


-- ============================================================
-- Minimap button (OctoSpec-style angle drag)
-- ============================================================

function UI:ToggleAllFrames()
    local anyShown = false
    local _, f
    for _, f in ipairs(self.frames) do
        if f:IsShown() then
            anyShown = true
            break
        end
    end
    if anyShown then
        for _, f in ipairs(self.frames) do
            f:Hide()
        end
    else
        for _, f in ipairs(self.frames) do
            f:Show()
            self:RefreshFrame(f)
        end
        if self.mainFrame and not self.mainFrame:IsShown() then
            self.mainFrame:Show()
            self:RefreshFrame(self.mainFrame)
        end
    end
    -- Persist shown state so login default respects last toggle
    if self.SaveAllFrameLayouts then
        self:SaveAllFrameLayouts()
    end
end

function UI:CreateMinimapButton()
    if self.minimapButton then return self.minimapButton end
    if not Minimap then return end

    local btn = CreateFrame("Button", "GreedMeterMinimapButton", Minimap)
    btn:SetWidth(32)
    btn:SetHeight(32)
    btn:SetFrameStrata("MEDIUM")
    btn:SetFrameLevel(Minimap:GetFrameLevel() + 8)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:RegisterForDrag("LeftButton")
    btn:SetMovable(true)

    -- Icon (Deep Wounds) - use normal texture path so it always draws
    btn:SetNormalTexture("Interface\\Icons\\Ability_BackStab")
    local nt = btn:GetNormalTexture()
    if nt then
        nt:SetWidth(20)
        nt:SetHeight(20)
        nt:ClearAllPoints()
        nt:SetPoint("CENTER", btn, "CENTER", 0, 1)
        nt:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    end

    btn:SetPushedTexture("Interface\\Icons\\Ability_BackStab")
    local pt = btn:GetPushedTexture()
    if pt then
        pt:SetWidth(20)
        pt:SetHeight(20)
        pt:ClearAllPoints()
        pt:SetPoint("CENTER", btn, "CENTER", 1, 0)
        pt:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    end

    btn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    local ht = btn:GetHighlightTexture()
    if ht then
        ht:SetBlendMode("ADD")
    end

    -- Tracking border ring
    local overlay = btn:CreateTexture(nil, "OVERLAY")
    overlay:SetWidth(53)
    overlay:SetHeight(53)
    overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    overlay:SetPoint("TOPLEFT", btn, "TOPLEFT", 0, 0)

    local function UpdatePosition()
        local angleDeg = 220
        if OM.GetSetting then
            angleDeg = OM:GetSetting("minimapAngle") or 220
        end
        local angle = math.rad(angleDeg)
        local radius = 80
        local x = math.cos(angle) * radius
        local y = math.sin(angle) * radius
        btn:ClearAllPoints()
        btn:SetPoint("CENTER", Minimap, "CENTER", x, y)
    end
    btn.UpdatePosition = UpdatePosition

    btn:SetScript("OnClick", function()
        if arg1 == "LeftButton" then
            UI:ToggleAllFrames()
        elseif arg1 == "RightButton" then
            UI:ToggleSettings()
        end
    end)
    btn:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_LEFT")
        GameTooltip:AddLine("GreedMeter")
        GameTooltip:AddLine("Left-click: Show / hide meters", 1, 1, 1)
        GameTooltip:AddLine("Right-click: Settings", 1, 1, 1)
        GameTooltip:AddLine("Drag: Move around minimap", 0.7, 0.7, 0.7)
        GameTooltip:AddLine("/gdm help for commands", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    btn:SetScript("OnDragStart", function()
        this:LockHighlight()
        this:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local cx, cy = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            cx, cy = cx / scale, cy / scale
            local angle = math.deg(math.atan2(cy - my, cx - mx))
            if angle < 0 then angle = angle + 360 end
            if OM.SetSetting then
                OM:SetSetting("minimapAngle", angle)
            end
            this.UpdatePosition()
        end)
    end)
    btn:SetScript("OnDragStop", function()
        this:SetScript("OnUpdate", nil)
        this:UnlockHighlight()
    end)

    UpdatePosition()
    btn:Show()
    self.minimapButton = btn
    return btn
end


-- ============================================================
-- Register
-- ============================================================

OM:RegisterModule("UI", UI)
