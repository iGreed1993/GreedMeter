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
    f:SetHeight(340)
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

    -- Left column: checkboxes (display/appearance options live in Customization)
    local y = -48
    AddCheckbox(f, "Lock frame position", 16, y, "lockFrames", "Prevent dragging and resizing")
    y = y - 24
    local layoutCb = AddCheckbox(f, "Account-wide layout", 16, y, "accountWideLayout",
        "Share window size, position, and number of open windows across all characters on this account. Uncheck for per-character layouts.")
    layoutCb.onToggle = function(checked)
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
    AddCheckbox(f, "Merge pet damage", 16, y, "mergePetDamage",
        "Combine all pet ability damage into a single \"Pet: Damage\" entry on tooltips")
    y = y - 28

    -- Right column: combat log range first, then announce channel + lines together
    local rightX = 250
    local ry = -48

    local rangeLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    rangeLabel:SetPoint("TOPLEFT", f, "TOPLEFT", rightX, ry)
    rangeLabel:SetText("Combat log range:")
    ry = ry - 18

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

    -- Leave room under the dropdown button (UIDropDownMenu is tall)
    ry = ry - 42

    local annLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    annLabel:SetPoint("TOPLEFT", f, "TOPLEFT", rightX, ry)
    annLabel:SetText("Announce channel:")
    ry = ry - 18

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

    -- Extra gap so the slider sits clearly below the channel dropdown
    ry = ry - 44
    AddSlider(f, "Announce lines", rightX, ry, "announceLines", 1, 20, 1, 160)

    -- Bottom buttons: Customization (left) + Close (right)
    -- Reserve ~36px at the bottom for these; Threat extras sit above.
    local cust = CreateButton(f, "Customization", 110, 20, function()
        local fn = nil
        if GreedMeter and GreedMeter.UI then
            fn = GreedMeter.UI.ToggleCustomization or GreedMeter.UI.ToggleAdvanced
        end
        if not fn then
            fn = UI.ToggleCustomization or UI.ToggleAdvanced
        end
        if fn then
            fn(GreedMeter.UI or UI)
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cffff5555GreedMeter:|r Customization handler missing.")
        end
    end)
    cust:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 12, 12)
    f.customizationBtn = cust
    f._greedCustomizationBtn = true

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
        -- Keep Current / Overall selection; only drop recent/boss segments
        -- (those fight entries were wiped with the data).
        local seg = f.segment or "current"
        if seg ~= "current" and seg ~= "overall" then
            f.segment = "current"
        end
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

-- ============================================================
-- Customization (merged into Settings so it always loads)
-- ============================================================

local MODE_COLUMN_OPTIONS = {
    {
        mode = "damage",
        label = "Damage",
        columns = {
            { key = "amount", label = "Damage" },
            { key = "share",  label = "Share %" },
            { key = "rate",   label = "DPS" },
        },
    },
    {
        mode = "healing",
        label = "Healing",
        columns = {
            { key = "amount", label = "Healing" },
            { key = "share",  label = "Share %" },
            { key = "rate",   label = "HPS" },
        },
    },
    {
        mode = "taken",
        label = "Dmg Taken",
        columns = {
            { key = "amount", label = "Taken" },
            { key = "share",  label = "Share %" },
        },
    },
    {
        mode = "interrupts",
        label = "Interrupts",
        columns = nil,
    },
    {
        mode = "dispels",
        label = "Dispels",
        columns = nil,
    },
    {
        mode = "cc",
        label = "CC",
        columns = {
            { key = "amount",   label = "Count" },
            { key = "duration", label = "Duration" },
        },
    },
    {
        mode = "ccbreak",
        label = "CC Breaks",
        columns = nil,
    },
    {
        mode = "deaths",
        label = "Deaths",
        columns = nil,
    },
    {
        mode = "threat",
        label = "Threat",
        columns = {
            { key = "amount", label = "Threat" },
            { key = "share",  label = "Share %" },
            { key = "rate",   label = "TPS" },
        },
        threatOnly = true,
    },
    {
        mode = "tank",
        label = "Tank",
        columns = nil,
        threatOnly = true,
    },
    {
        mode = "overall",
        label = "Overall Threat",
        columns = {
            { key = "amount",   label = "Threat" },
            { key = "share",    label = "Share %" },
            { key = "rate",     label = "TPS" },
            { key = "targeted", label = "Targeted by" },
        },
        threatOnly = true,
    },
}

-- ============================================================
-- Defaults / storage
-- ============================================================

local function CopyColor(c)
    if not c then return { 0.6, 0.6, 0.6 } end
    return { c[1] or 0.6, c[2] or 0.6, c[3] or 0.6 }
end

local function EnsureDefaults()
    OM.defaults = OM.defaults or {}

    if OM.defaults.abbreviateNames == nil then
        OM.defaults.abbreviateNames = false
    end

    if OM.defaults.modeEnabled == nil then
        local src = UI.MODE_ENABLED_DEFAULTS or {}
        local copy = {}
        local mode, v
        for mode, v in pairs(src) do
            copy[mode] = v and true or false
        end
        OM.defaults.modeEnabled = copy
    end

    if OM.defaults.columnConfig == nil then
        local src = UI.COLUMN_DEFAULTS or {}
        local copy = {}
        local mode, cols
        for mode, cols in pairs(src) do
            copy[mode] = {}
            local k, v
            for k, v in pairs(cols) do
                copy[mode][k] = v
            end
        end
        OM.defaults.columnConfig = copy
    end

    if OM.defaults.modeColors == nil then
        local src = UI.MODE_COLOR_DEFAULTS or {}
        local copy = {}
        local mode, col
        for mode, col in pairs(src) do
            copy[mode] = CopyColor(col)
        end
        OM.defaults.modeColors = copy
    end
end

local function GetColumnConfig()
    EnsureDefaults()
    local cfg = OM:GetSetting("columnConfig")
    if type(cfg) ~= "table" then
        cfg = {}
        OM:SetSetting("columnConfig", cfg)
    end
    return cfg
end

local function SetColumnValue(mode, key, value)
    local cfg = GetColumnConfig()
    if not cfg[mode] then
        cfg[mode] = {}
    end
    cfg[mode][key] = value and true or false
    OM:SetSetting("columnConfig", cfg)
end

local function GetModeEnabledTable()
    EnsureDefaults()
    local t = OM:GetSetting("modeEnabled")
    if type(t) ~= "table" then
        t = {}
        local src = UI.MODE_ENABLED_DEFAULTS or {}
        local mode, v
        for mode, v in pairs(src) do
            t[mode] = v and true or false
        end
        OM:SetSetting("modeEnabled", t)
    end
    return t
end

local function SetModeEnabled(mode, value)
    local t = GetModeEnabledTable()
    if not value then
        local anyOther = false
        local k, v
        for k, v in pairs(t) do
            if k ~= mode and v then
                anyOther = true
                break
            end
        end
        if not anyOther then
            local src = UI.MODE_ENABLED_DEFAULTS or {}
            for k, v in pairs(src) do
                if k ~= mode then
                    local cur = t[k]
                    if cur == nil then cur = v end
                    if cur then
                        anyOther = true
                        break
                    end
                end
            end
        end
        if not anyOther then
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00GreedMeter:|r At least one mode must stay enabled.")
            return false
        end
    end
    t[mode] = value and true or false
    OM:SetSetting("modeEnabled", t)
    return true
end

local function ApplyModeEnabledToFrames()
    if not UI.frames then return end
    local _, f
    for _, f in ipairs(UI.frames) do
        if f.mode and UI.IsModeEnabled and not UI.IsModeEnabled(f.mode) then
            local nextMode = (UI.FirstEnabledMode and UI.FirstEnabledMode()) or "damage"
            f.mode = nextMode
            if f.title and UI.MODE_LABELS then
                f.title:SetText(UI.MODE_LABELS[nextMode] or nextMode)
            end
        end
        if UI.RefreshFrame then
            UI:RefreshFrame(f)
        end
    end
    if UI.SaveAllFrameLayouts then
        UI:SaveAllFrameLayouts()
    end
end

local function GetModeColorsTable()
    EnsureDefaults()
    local t = OM:GetSetting("modeColors")
    if type(t) ~= "table" then
        t = {}
        local src = UI.MODE_COLOR_DEFAULTS or {}
        local mode, col
        for mode, col in pairs(src) do
            t[mode] = CopyColor(col)
        end
        OM:SetSetting("modeColors", t)
    end
    return t
end

local function SetModeColor(mode, r, g, b)
    local t = GetModeColorsTable()
    t[mode] = { r, g, b }
    OM:SetSetting("modeColors", t)
end

-- ============================================================
-- Shared UI helpers
-- ============================================================

local function MakeCheckbox(parent, label, x, y, checked, onToggle, size, tooltip)
    size = size or 20
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetWidth(size)
    cb:SetHeight(size)
    cb:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    cb:SetChecked(checked and 1 or nil)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("LEFT", cb, "RIGHT", 1, 0)
    fs:SetText(label)
    cb.label = fs
    cb:SetScript("OnClick", function()
        local isChecked = this:GetChecked() and true or false
        if onToggle then onToggle(isChecked) end
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

local function MakeSettingCheckbox(parent, label, x, y, settingKey, tooltip, size)
    -- Declare first so the OnClick closure captures the local, not a global
    local cb
    cb = MakeCheckbox(parent, label, x, y, OM:GetSetting(settingKey) == true, function(checked)
        OM:SetSetting(settingKey, checked)
        if UI.ApplySettingsToFrames then UI:ApplySettingsToFrames() end
        if cb.onToggle then cb.onToggle(checked) end
    end, size or 22, tooltip)
    return cb
end

local function MakeSlider(parent, label, x, y, settingKey, minV, maxV, step, width)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    fs:SetText(label)

    local slider = CreateFrame("Slider", nil, parent)
    slider:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y - 14)
    slider:SetWidth(width or 140)
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
        if step and step >= 1 then
            v = math.floor(v / step + 0.5) * step
        end
        OM:SetSetting(settingKey, v)
        valText:SetText(tostring(math.floor(v + 0.5)))
        if UI.ApplySettingsToFrames then UI:ApplySettingsToFrames() end
    end)
    return slider
end

local function MakeDivider(parent, y, width)
    local line = parent:CreateTexture(nil, "ARTWORK")
    line:SetTexture(0.45, 0.45, 0.40, 0.7)
    line:SetPoint("TOPLEFT", parent, "TOPLEFT", 4, y)
    line:SetWidth(width or 680)
    line:SetHeight(1)
    return line
end

local function MakeColorSwatch(parent, width, height)
    local f = CreateFrame("Button", nil, parent)
    f:SetWidth(width or 18)
    f:SetHeight(height or 14)
    f:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 8, edgeSize = 8,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    f:SetBackdropBorderColor(0.35, 0.35, 0.35, 1)
    local fill = f:CreateTexture(nil, "BACKGROUND")
    fill:SetPoint("TOPLEFT", f, "TOPLEFT", 2, -2)
    fill:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -2, 2)
    f.fill = fill
    f.SetColor = function(self, r, g, b)
        self._r, self._g, self._b = r, g, b
        self.fill:SetTexture(r or 0.5, g or 0.5, b or 0.5, 1)
        self:SetBackdropColor(0, 0, 0, 0.4)
    end
    f:SetColor(0.5, 0.5, 0.5)
    return f
end

-- ============================================================
-- Color palette popup
-- ============================================================

local paletteFrame = nil
local paletteBlocker = nil
local paletteTargetMode = nil
local paletteOnPick = nil

local function HidePalette()
    if paletteFrame then paletteFrame:Hide() end
    if paletteBlocker then paletteBlocker:Hide() end
    paletteTargetMode = nil
    paletteOnPick = nil
end

local function ShowPalette(anchor, mode, onPick)
    local parent = UI.customizationFrame or UIParent
    local base = 50
    if parent.GetFrameLevel then
        base = parent:GetFrameLevel() or 50
    end

    if not paletteFrame then
        -- Click-away covers only the customization window (not the whole UI)
        local blocker = CreateFrame("Button", "GreedMeterColorPaletteBlocker", parent)
        blocker:SetAllPoints(parent)
        blocker:SetFrameLevel(base + 40)
        blocker:EnableMouse(true)
        blocker:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        blocker:SetScript("OnClick", function()
            HidePalette()
        end)
        blocker:Hide()
        paletteBlocker = blocker

        local pf = CreateFrame("Frame", "GreedMeterColorPalette", parent)
        -- Level BEFORE backdrop/children so swatches stay clickable on 1.12
        pf:SetFrameLevel(base + 50)
        pf:SetWidth(148)
        pf:SetHeight(92)
        pf:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        pf:SetBackdropColor(0.08, 0.08, 0.08, 0.96)
        pf:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)
        pf:EnableMouse(true)
        pf:SetClampedToScreen(true)

        local title = pf:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        title:SetPoint("TOP", pf, "TOP", 0, -6)
        title:SetText("Mode Color")

        -- Sub-frame above the palette backdrop for the actual color buttons
        local holder = CreateFrame("Frame", nil, pf)
        holder:SetFrameLevel(pf:GetFrameLevel() + 5)
        holder:EnableMouse(false)
        holder:SetAllPoints(pf)
        pf.holder = holder

        pf.swatches = {}
        local palette = UI.MODE_COLOR_PALETTE or {}
        local i
        local x, y = 10, -24
        for i = 1, table.getn(palette) do
            local c = palette[i]
            local sw = MakeColorSwatch(holder, 22, 16)
            sw:SetFrameLevel(holder:GetFrameLevel() + 1)
            sw:SetPoint("TOPLEFT", holder, "TOPLEFT", x, y)
            sw:SetColor(c[1], c[2], c[3])
            sw:SetScript("OnClick", function()
                if paletteTargetMode and paletteOnPick then
                    paletteOnPick(this._r, this._g, this._b)
                end
                HidePalette()
            end)
            table.insert(pf.swatches, sw)
            x = x + 26
            if x > 130 then
                x = 10
                y = y - 20
            end
        end

        pf:SetScript("OnHide", function()
            if paletteBlocker then paletteBlocker:Hide() end
            paletteTargetMode = nil
            paletteOnPick = nil
        end)

        paletteFrame = pf
    end

    paletteTargetMode = mode
    paletteOnPick = onPick
    paletteFrame:ClearAllPoints()
    paletteFrame:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)

    -- Show only — do not re-SetFrameLevel (that puts the backdrop above swatches)
    if paletteBlocker then
        paletteBlocker:Show()
    end
    paletteFrame:Show()
end

-- ============================================================
-- Dropdown helper (named frames required for UIDropDownMenu)
-- ============================================================

local dropSeq = 0
local function MakeLabeledDropDown(parent, label, x, y, width, options, settingKey, onChange)
    dropSeq = dropSeq + 1
    local name = "GreedMeterCustDD" .. dropSeq

    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    fs:SetText(label)

    local dd = CreateFrame("Frame", name, parent, "UIDropDownMenuTemplate")
    dd:SetPoint("TOPLEFT", parent, "TOPLEFT", x - 16, y - 14)
    UIDropDownMenu_SetWidth(width or 110, dd)
    UIDropDownMenu_SetButtonWidth(width or 110, dd)

    local function OnClick()
        local id = this:GetID()
        local entry = options[id]
        if not entry then return end
        OM:SetSetting(settingKey, entry.key)
        UIDropDownMenu_SetSelectedID(dd, id)
        UIDropDownMenu_SetText(entry.label, dd)
        if onChange then onChange(entry) end
        if UI.ApplySettingsToFrames then UI:ApplySettingsToFrames() end
        if UI.Refresh then UI:Refresh() end
    end

    local function Init()
        local cur = OM:GetSetting(settingKey)
        local i
        for i = 1, table.getn(options) do
            local info = {}
            info.text = options[i].label
            info.func = OnClick
            info.checked = (options[i].key == cur)
            UIDropDownMenu_AddButton(info)
        end
    end

    UIDropDownMenu_Initialize(dd, Init)
    local cur = OM:GetSetting(settingKey)
    local sel = 1
    local i
    for i = 1, table.getn(options) do
        if options[i].key == cur then
            sel = i
            UIDropDownMenu_SetText(options[i].label, dd)
            break
        end
    end
    UIDropDownMenu_SetSelectedID(dd, sel)
    return dd
end

-- ============================================================
-- Customization window
-- ============================================================

local function CreateCustomizationFrame()
    if UI.customizationFrame then return UI.customizationFrame end

    local f = CreateFrame("Frame", "GreedMeterCustomization", UIParent)
    f:SetWidth(720)
    f:SetHeight(560)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 20)
    -- Strata/level BEFORE children so widgets stay above the backdrop
    f:SetFrameStrata("DIALOG")
    f:SetFrameLevel(50)
    f:SetClampedToScreen(true)
    f:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    f:SetBackdropColor(0, 0, 0, 0.94)
    f:SetBackdropBorderColor(0.55, 0.55, 0.45, 1)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function() this:StartMoving() end)
    f:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", f, "TOP", 0, -10)
    title:SetText("Customization")

    -- Content sits above the parent backdrop (critical on 1.12)
    local content = CreateFrame("Frame", nil, f)
    content:SetFrameLevel(f:GetFrameLevel() + 10)
    content:EnableMouse(false)
    content:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -32)
    content:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -14, 40)
    f.content = content

    local y = 0
    local contentW = 690

    -- ========== Global display options ==========
    local sec = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sec:SetPoint("TOPLEFT", content, "TOPLEFT", 2, y)
    sec:SetText("Display")
    sec:SetTextColor(1, 0.85, 0.4)
    y = y - 18

    local abvCb = MakeCheckbox(content, "Abbreviated Names", 4, y,
        OM:GetSetting("abbreviateNames") == true,
        function(checked)
            OM:SetSetting("abbreviateNames", checked)
            if UI.Refresh then UI:Refresh() end
        end, 22,
        "Single-word: first 4 letters. Multi-word: first 3 of each word. Applies to all modes.")
    f.abvCb = abvCb
    y = y - 22

    MakeSettingCheckbox(content, "Class colors", 4, y, "classColors", "Color bars by player class")
    MakeSettingCheckbox(content, "Mode Colors", 150, y, "buttonsColorWithMode",
        "Tint header buttons and Total bar with each mode's color")
    MakeSettingCheckbox(content, "Class icons", 300, y, "showClassIcons",
        "Show a class icon before each player name on the bars")
    y = y - 22

    local compactCb = MakeSettingCheckbox(content, "Compact Header", 4, y, "hideTitle",
        "One-line header with abbreviated button labels (Re, An, Na, Mo, ...)")
    y = y - 20
    local keepTitleCb = MakeSettingCheckbox(content, "Keep Title in compact", 24, y, "keepTitleInCompact",
        "Show the mode title above the compact one-line controls.", 18)
    f.keepTitleCb = keepTitleCb
    local function SyncKeepTitleEnabled()
        local parentOn = OM:GetSetting("hideTitle") == true
        if parentOn then
            keepTitleCb:Enable()
            if keepTitleCb.label then keepTitleCb.label:SetTextColor(1, 1, 1) end
        else
            keepTitleCb:Disable()
            if keepTitleCb.label then keepTitleCb.label:SetTextColor(0.5, 0.5, 0.5) end
        end
    end
    compactCb.onToggle = function()
        SyncKeepTitleEnabled()
    end
    SyncKeepTitleEnabled()
    y = y - 24

    MakeDivider(content, y, contentW)
    y = y - 10

    -- ========== Appearance ==========
    sec = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sec:SetPoint("TOPLEFT", content, "TOPLEFT", 2, y)
    sec:SetText("Appearance")
    sec:SetTextColor(1, 0.85, 0.4)
    y = y - 16

    local BAR_STYLES = UI.BAR_STYLES or {
        { key = "Default", label = "Default" },
        { key = "Smooth",  label = "Smooth" },
        { key = "Flat",    label = "Flat" },
    }
    local BAR_FONTS = UI.BAR_FONTS or {
        { key = "Friz",     label = "Friz Quadrata" },
        { key = "Arial",    label = "Arial Narrow" },
        { key = "Morpheus", label = "Morpheus" },
        { key = "Skurri",   label = "Skurri" },
    }
    local NUM_FORMATS = {
        { key = "1k",    label = "1k" },
        { key = "10k",   label = "10k" },
        { key = "100k",  label = "100k" },
        { key = "never", label = "Never" },
    }

    MakeLabeledDropDown(content, "Bar style:", 4, y, 110, BAR_STYLES, "barStyle")
    MakeLabeledDropDown(content, "Bar font:", 160, y, 120, BAR_FONTS, "barFont")
    MakeLabeledDropDown(content, "Number format:", 330, y, 90, NUM_FORMATS, "numberFormat")
    y = y - 48

    MakeSlider(content, "Bar height", 4, y, "barHeight", 10, 28, 1, 140)
    MakeSlider(content, "Font size", 200, y, "fontSize", 8, 18, 1, 140)
    MakeSlider(content, "Frame opacity", 400, y, "frameOpacity", 30, 100, 5, 140)
    y = y - 40

    MakeDivider(content, y, contentW)
    y = y - 12

    -- ========== Modes (two columns) ==========
    sec = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sec:SetPoint("TOPLEFT", content, "TOPLEFT", 2, y)
    sec:SetText("Modes")
    sec:SetTextColor(1, 0.85, 0.4)
    y = y - 18

    local colWidth = 340
    local leftX = 0
    local rightX = 350
    local leftY = y
    local rightY = y
    local rowH = 18
    local cbSize = 18

    f.modeRows = {}

    local function BuildModeBlock(entry, baseX, startY)
        local yy = startY

        local header = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        header:SetPoint("TOPLEFT", content, "TOPLEFT", baseX + 4, yy)
        header:SetText(entry.label)
        header:SetTextColor(1, 0.85, 0.4)

        local colorBtn = MakeColorSwatch(content, 20, 13)
        colorBtn:SetPoint("LEFT", header, "RIGHT", 8, 0)
        local cur = (UI.GetModeColor and UI.GetModeColor(entry.mode)) or { 0.5, 0.5, 0.5 }
        colorBtn:SetColor(cur[1], cur[2], cur[3])

        local modeKey = entry.mode
        colorBtn:SetScript("OnClick", function()
            ShowPalette(this, modeKey, function(r, g, b)
                SetModeColor(modeKey, r, g, b)
                colorBtn:SetColor(r, g, b)
                if UI.ApplySettingsToFrames then
                    UI:ApplySettingsToFrames()
                elseif UI.Refresh then
                    UI:Refresh()
                end
            end)
        end)

        yy = yy - 16

        local row = {
            mode = entry.mode,
            threatOnly = entry.threatOnly,
            header = header,
            colorBtn = colorBtn,
            checkboxes = {},
        }

        local x = baseX + 6
        -- Enabled first (non-threat)
        if not entry.threatOnly then
            local en = true
            if UI.IsModeEnabled then
                en = UI.IsModeEnabled(entry.mode)
            end
            local enCb
            enCb = MakeCheckbox(content, "Enabled", x, yy, en, function(checked)
                local ok = SetModeEnabled(modeKey, checked)
                if not ok then
                    enCb:SetChecked(1)
                    return
                end
                ApplyModeEnabledToFrames()
            end, cbSize)
            row.enabledCb = enCb
            x = x + cbSize + 58
        end

        if entry.columns then
            local c
            for c = 1, table.getn(entry.columns) do
                local col = entry.columns[c]
                local current = true
                if UI.GetColumnSetting then
                    current = UI.GetColumnSetting(entry.mode, col.key)
                end
                local colKey = col.key
                local cb = MakeCheckbox(content, col.label, x, yy, current, function(checked)
                    SetColumnValue(modeKey, colKey, checked)
                    if UI.Refresh then UI:Refresh() end
                end, cbSize)
                table.insert(row.checkboxes, cb)

                local labelW = 48
                if col.label == "Share %" then labelW = 52
                elseif col.label == "Duration" then labelW = 56
                elseif col.label == "Healing" then labelW = 50
                elseif col.label == "Damage" then labelW = 50
                elseif col.label == "Threat" then labelW = 46
                elseif col.label == "Targeted by" then labelW = 72
                end
                x = x + cbSize + labelW
            end
        end

        yy = yy - rowH - 6
        table.insert(f.modeRows, row)
        return yy
    end

    local i
    local mid = math.floor((table.getn(MODE_COLUMN_OPTIONS) + 1) / 2)
    for i = 1, table.getn(MODE_COLUMN_OPTIONS) do
        local entry = MODE_COLUMN_OPTIONS[i]
        if i <= mid then
            leftY = BuildModeBlock(entry, leftX, leftY)
        else
            rightY = BuildModeBlock(entry, rightX, rightY)
        end
    end

    local bottomY = leftY
    if rightY < bottomY then bottomY = rightY end

    local needed = 32 + (-bottomY) + 52
    if needed < 480 then needed = 480 end
    if needed > 700 then needed = 700 end
    f:SetHeight(needed)

    local close = (UI.CreateButton and UI.CreateButton(f, "Close", 70, 20, function()
        HidePalette()
        f:Hide()
    end)) or CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    if not UI.CreateButton then
        close:SetWidth(70)
        close:SetHeight(20)
        close:SetText("Close")
        close:SetScript("OnClick", function()
            HidePalette()
            f:Hide()
        end)
    end
    close:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 12)

    local reset = UI.CreateButton and UI.CreateButton(f, "Reset Defaults", 110, 20, function()
        OM:SetSetting("columnConfig", nil)
        OM:SetSetting("modeColors", nil)
        OM:SetSetting("modeEnabled", nil)
        OM:SetSetting("abbreviateNames", false)
        if f.abvCb then f.abvCb:SetChecked(nil) end

        local r
        for r = 1, table.getn(f.modeRows) do
            local row = f.modeRows[r]
            local entry
            local j
            for j = 1, table.getn(MODE_COLUMN_OPTIONS) do
                if MODE_COLUMN_OPTIONS[j].mode == row.mode then
                    entry = MODE_COLUMN_OPTIONS[j]
                    break
                end
            end
            local defCol = (UI.MODE_COLOR_DEFAULTS and UI.MODE_COLOR_DEFAULTS[row.mode])
                or { 0.6, 0.6, 0.6 }
            if row.colorBtn then
                row.colorBtn:SetColor(defCol[1], defCol[2], defCol[3])
            end
            if entry and entry.columns then
                local c
                for c = 1, table.getn(entry.columns) do
                    local col = entry.columns[c]
                    local on = true
                    if UI.COLUMN_DEFAULTS and UI.COLUMN_DEFAULTS[row.mode]
                        and UI.COLUMN_DEFAULTS[row.mode][col.key] ~= nil then
                        on = UI.COLUMN_DEFAULTS[row.mode][col.key]
                    end
                    if row.checkboxes[c] then
                        row.checkboxes[c]:SetChecked(on and 1 or nil)
                    end
                end
            end
            if row.enabledCb then
                row.enabledCb:SetChecked(1)
            end
        end
        ApplyModeEnabledToFrames()
        if UI.ApplySettingsToFrames then UI:ApplySettingsToFrames() end
        if UI.Refresh then UI:Refresh() end
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00GreedMeter:|r Customization settings reset to defaults.")
    end)
    if reset then
        reset:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 12, 12)
    end

    f:SetScript("OnHide", function()
        HidePalette()
    end)

    f:Hide()
    UI.customizationFrame = f
    return f
end

local function RefreshThreatVisibility(f)
    if not f or not f.modeRows then return end
    local threatOn = OM.GetSetting and OM:GetSetting("enableThreatMode") == true
    local r
    for r = 1, table.getn(f.modeRows) do
        local row = f.modeRows[r]
        if row.threatOnly then
            if row.header then
                if threatOn then
                    row.header:SetTextColor(1, 0.85, 0.4)
                else
                    row.header:SetTextColor(0.5, 0.5, 0.5)
                end
            end
            if row.colorBtn then
                if threatOn then
                    row.colorBtn:Enable()
                    row.colorBtn:EnableMouse(true)
                else
                    row.colorBtn:Disable()
                    row.colorBtn:EnableMouse(false)
                end
            end
            local c
            for c = 1, table.getn(row.checkboxes) do
                local cb = row.checkboxes[c]
                if threatOn then
                    cb:Enable()
                    if cb.label then cb.label:SetTextColor(1, 1, 1) end
                else
                    cb:Disable()
                    if cb.label then cb.label:SetTextColor(0.5, 0.5, 0.5) end
                end
            end
        end
    end
end

function UI:ToggleCustomization()
    EnsureDefaults()
    if not OM.db and OM.InitDB then
        OM:InitDB()
    end

    local ok, f = pcall(CreateCustomizationFrame)
    if not ok then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff5555GreedMeter:|r Customization failed: " .. tostring(f))
        return
    end
    if not f then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff5555GreedMeter:|r Customization frame missing.")
        return
    end

    if f:IsShown() then
        HidePalette()
        f:Hide()
        return
    end

    if f.abvCb then
        f.abvCb:SetChecked((OM:GetSetting("abbreviateNames") == true) and 1 or nil)
    end
    local r
    for r = 1, table.getn(f.modeRows or {}) do
        local row = f.modeRows[r]
        if row.colorBtn and UI.GetModeColor then
            local col = UI.GetModeColor(row.mode)
            row.colorBtn:SetColor(col[1], col[2], col[3])
        end
        if row.enabledCb and UI.IsModeEnabled then
            row.enabledCb:SetChecked(UI.IsModeEnabled(row.mode) and 1 or nil)
        end
    end
    RefreshThreatVisibility(f)

    -- Close anything that might sit on top / eat clicks
    HidePalette()
    if UI.CloseDropdown then UI.CloseDropdown() end
    if UI.dropdownCloser then UI.dropdownCloser:Hide() end

    -- Do NOT SetFrameLevel here — raising the parent after children exist
    -- puts the backdrop above the checkboxes on 1.12.
    f:SetFrameStrata("DIALOG")
    f:ClearAllPoints()
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 20)
    f:Show()
end

-- Backward-compatible alias + explicit global registration
UI.ToggleAdvanced = UI.ToggleCustomization
GreedMeter.UI = UI
GreedMeter.UI.ToggleCustomization = UI.ToggleCustomization
GreedMeter.UI.ToggleAdvanced = UI.ToggleCustomization
GreedMeter._customizationLoaded = true


OM:RegisterModule("UI", UI)
