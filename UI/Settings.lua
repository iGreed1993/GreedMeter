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
    for _gi = 1, table.getn(list) do local entry = list[_gi]
        if not entry.isTotal then
            metricTotal = metricTotal + (entry.value or 0)
        end
    end

    -- Chat order is always true rank. Self-on-top only changes the meter window.
    table.sort(list, function(a, b)
        local ra = a.rank or 9999
        local rb = b.rank or 9999
        if ra == rb then
            return (a.name or "") < (b.name or "")
        end
        return ra < rb
    end)

    local i
    local sent = 0
    for i = 1, table.getn(list) do
        local entry = list[i]
        if not entry.isTotal then
            sent = sent + 1
            if sent > limit then break end
            local place = entry.rank or sent
            local line = place .. ". " .. entry.name .. " - " .. GetSecondaryText(entry.data, mode, duration, metricTotal)
            SendChatMessage(line, channel)
        end
    end
end

-- ============================================================
-- Settings panel
-- ============================================================

UI._setWidgets = UI._setWidgets or {}
local function TrackSettingWidget(widget, kind, key)
    if not widget or not key then return widget end
    widget._sk = key
    widget._skind = kind
    table.insert(UI._setWidgets, widget)
    return widget
end

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
    TrackSettingWidget(cb, "cb", settingKey)
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
    TrackSettingWidget(slider, "slider", settingKey)

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
    slider._valText = valText

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
    f:SetWidth(720)
    f:SetHeight(400)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 20)
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
    f:SetScript("OnDragStart", function()
        if this.SetClampedToScreen then this:SetClampedToScreen(false) end
        this:StartMoving()
    end)
    f:SetScript("OnDragStop", function()
        this:StopMovingOrSizing()
        if UI.ClampFrameToScreen then
            UI.ClampFrameToScreen(this)
        end
    end)
    f:SetFrameStrata("DIALOG")

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
    local hasNP = OM.HasNampower and OM:HasNampower()
    local hasSW = OM.HasSuperWoW and OM:HasSuperWoW()
    if hasNP and hasSW then
        sw:SetTextColor(0.4, 1, 0.4)
    else
        sw:SetTextColor(1, 0.8, 0.3)
    end

    f:SetFrameLevel(50)

    local content = CreateFrame("Frame", nil, f)
    content:SetFrameLevel(f:GetFrameLevel() + 10)
    content:EnableMouse(false)
    content:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -42)
    content:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -14, 40)
    f.content = content
    UI.settingsScope = 0

    local RAIL_W = 128
    local rail = CreateFrame("Frame", nil, f)
    rail:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -42)
    rail:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 8, 40)
    rail:SetWidth(RAIL_W)
    rail:SetFrameLevel(f:GetFrameLevel() + 12)
    rail:Hide()
    f.windowRail = rail
    f.railWidth = RAIL_W
    f.baseWidth = 720

    local railTitle = rail:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    railTitle:SetPoint("TOPLEFT", rail, "TOPLEFT", 2, 0)
    railTitle:SetText("Windows")
    f.windowRailBtns = {}

    local function RefreshSettingWidgets()
        local scope = UI.settingsScope or 0
        OM._readIndex = scope
        local i, w
        if UI._setWidgets then
            for i = 1, table.getn(UI._setWidgets) do
                w = UI._setWidgets[i]
                if w and w._sk then
                    local val = OM:GetSetting(w._sk)
                    if w._skind == "cb" and w.SetChecked then
                        w:SetChecked(val and 1 or nil)
                    elseif w._skind == "slider" and w.SetValue then
                        if val ~= nil then
                            w:SetValue(val)
                        end
                        if w._valText then
                            w._valText:SetText(tostring(math.floor((tonumber(val) or 0) + 0.5)))
                        end
                    end
                end
            end
        end
        if f.renameBox and scope >= 1 then
            f.renameBox:SetText(OM.GetWindowLabel and OM:GetWindowLabel(scope) or ("Window " .. scope))
        end
        OM._readIndex = nil
    end
    f.RefreshSettingWidgets = RefreshSettingWidgets

    local function ApplyWindowMode()
        local specOn = OM.GetSetting and OM:GetSetting("windowSpecificSettings") == true
        local scope = UI.settingsScope or 0
        local per = specOn and scope >= 1
        f.perWindowMode = per
        if specOn then
            if f.windowRail then f.windowRail:Show() end
            content:ClearAllPoints()
            content:SetPoint("TOPLEFT", f, "TOPLEFT", 14 + (f.railWidth or 128), -42)
            content:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -14, 40)
        else
            UI.settingsScope = 0
            f.perWindowMode = false
            per = false
            if f.windowRail then f.windowRail:Hide() end
            content:ClearAllPoints()
            content:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -42)
            content:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -14, 40)
        end
        local tabY = per and -22 or 0
        if f.tabGeneral then
            if per then
                f.tabGeneral:Hide()
            else
                f.tabGeneral:Show()
                f.tabGeneral:ClearAllPoints()
                f.tabGeneral:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
            end
        end
        if f.tabModes then
            if per then
                f.tabModes:Hide()
            else
                f.tabModes:Show()
                f.tabModes:ClearAllPoints()
                f.tabModes:SetPoint("TOPLEFT", content, "TOPLEFT", 300, 0)
            end
        end
        if f.tabDisplay then
            f.tabDisplay:ClearAllPoints()
            f.tabDisplay:SetPoint("TOPLEFT", content, "TOPLEFT", per and 0 or 100, tabY)
        end
        if f.tabAppearance then
            f.tabAppearance:ClearAllPoints()
            f.tabAppearance:SetPoint("TOPLEFT", content, "TOPLEFT", per and 100 or 200, tabY)
        end
        local pageY = per and -48 or -26
        local pages = { f.pageGeneral, f.pageDisplay, f.pageAppearance, f.pageModes }
        local pi
        for pi = 1, 4 do
            pg = pages[pi]
            if pg then
                pg:ClearAllPoints()
                pg:SetPoint("TOPLEFT", content, "TOPLEFT", 0, pageY)
                pg:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", 0, 0)
            end
        end
        if f.renameRow then
            if per then f.renameRow:Show() else f.renameRow:Hide() end
        end
    end
    f.ApplyWindowMode = ApplyWindowMode
    f.LayoutSettingsChrome = ApplyWindowMode

    local function SelectWindowScope(scope)
        local prev = UI.settingsScope or 0
        UI.settingsScope = tonumber(scope) or 0
        local b, i
        if f.windowRailBtns then
            for i = 0, 6 do
                b = f.windowRailBtns[i]
                if b then
                    if i == UI.settingsScope then
                        b:Disable()
                    else
                        b:Enable()
                    end
                end
            end
        end
        ApplyWindowMode()
        local tab = f.activeTab or "general"
        if UI.settingsScope >= 1 then
            if tab == "general" or tab == "modes" then tab = "display" end
        elseif prev >= 1 then
            tab = "general"
        end
        if f.SelectTab then
            f.SelectTab(tab)
        end
        RefreshSettingWidgets()
        if UI.ApplySettingsToFrames then UI:ApplySettingsToFrames() end
    end
    f.SelectWindowScope = SelectWindowScope

    local function RebuildWindowRail()
        local i, btn
        if f.windowRailBtns then
            for i = 0, 6 do
                btn = f.windowRailBtns[i]
                if btn then btn:Hide() end
            end
        end
        f.windowRailBtns = {}
        local function MakeRailBtn(idx, y, text)
            local b = CreateFrame("Button", nil, rail, "UIPanelButtonTemplate")
            b:SetWidth(120)
            b:SetHeight(18)
            b:SetPoint("TOPLEFT", rail, "TOPLEFT", 2, y)
            b:SetText(text)
            b:SetScript("OnClick", function()
                SelectWindowScope(idx)
            end)
            f.windowRailBtns[idx] = b
            return b
        end
        MakeRailBtn(0, -18, "All windows")
        for i = 1, 6 do
            local label = (OM.GetWindowLabel and OM:GetWindowLabel(i)) or ("Window " .. i)
            MakeRailBtn(i, -18 - (i * 32), label)
        end
        SelectWindowScope(UI.settingsScope or 0)
    end
    f.RebuildWindowRail = RebuildWindowRail
    RebuildWindowRail()
    ApplyWindowMode()

    local HEADER_PAD = 70
    local FOOTER_PAD = 40
    f.tabHeights = { general = 320, display = 260, appearance = 340, modes = 560 }
    f.tabWidths = { general = 560, display = 620, appearance = 720, modes = 700 }

    local function MakeTabButton(label, x)
        local b = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
        b:SetWidth(96)
        b:SetHeight(20)
        b:SetPoint("TOPLEFT", content, "TOPLEFT", x, 0)
        b:SetText(label)
        return b
    end
    local tabGeneral = MakeTabButton("General", 0)
    local tabDisplay = MakeTabButton("Display", 100)
    local tabAppearance = MakeTabButton("Appearance", 200)
    local tabModes = MakeTabButton("Modes", 300)
    f.tabGeneral = tabGeneral
    f.tabDisplay = tabDisplay
    f.tabAppearance = tabAppearance
    f.tabModes = tabModes

    local renameRow = CreateFrame("Frame", nil, content)
    renameRow:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
    renameRow:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, 0)
    renameRow:SetHeight(20)
    renameRow:Hide()
    local renameFs = renameRow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    renameFs:SetPoint("LEFT", renameRow, "LEFT", 0, 0)
    renameFs:SetText("Rename window")
    local renameBox = CreateFrame("EditBox", "GreedMeterRenameWindowBox", renameRow)
    renameBox:SetPoint("LEFT", renameFs, "RIGHT", 8, 0)
    renameBox:SetWidth(160)
    renameBox:SetHeight(18)
    renameBox:SetAutoFocus(false)
    renameBox:SetFontObject(GameFontHighlightSmall)
    renameBox:SetMaxLetters(24)
    renameBox:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 8, edgeSize = 8,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    renameBox:SetBackdropColor(0, 0, 0, 0.8)
    renameBox:SetTextInsets(4, 4, 0, 0)
    renameBox:SetScript("OnEscapePressed", function() this:ClearFocus() end)
    renameBox:SetScript("OnEnterPressed", function()
        local scope = UI.settingsScope or 0
        if scope >= 1 and OM.SetWindowLabel then
            OM:SetWindowLabel(scope, this:GetText())
        end
        this:ClearFocus()
        if f.RebuildWindowRail then f.RebuildWindowRail() end
    end)
    f.renameRow = renameRow
    f.renameBox = renameBox

    local function StyleTab(btn, active)
        local fs = btn.GetFontString and btn:GetFontString() or nil
        if active then
            btn:Disable()
            if fs then fs:SetTextColor(1, 0.85, 0.2) end
        else
            btn:Enable()
            if fs then fs:SetTextColor(1, 1, 1) end
        end
    end

    local function MakePage()
        local page = CreateFrame("Frame", nil, content)
        page:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -26)
        page:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", 0, 0)
        page:SetFrameLevel(content:GetFrameLevel() + 1)
        page:EnableMouse(false)
        page:Hide()
        return page
    end
    local pageGeneral = MakePage()
    local pageDisplay = MakePage()
    local pageAppearance = MakePage()
    local pageModes = MakePage()
    f.pageGeneral = pageGeneral
    f.pageDisplay = pageDisplay
    f.pageAppearance = pageAppearance
    f.pageModes = pageModes

    local function SelectTab(name)
        local per = f.perWindowMode and true or false
        if per and (name == "general" or name == "modes") then
            name = "display"
        end
        f.activeTab = name
        pageGeneral:Hide()
        pageDisplay:Hide()
        pageAppearance:Hide()
        pageModes:Hide()
        StyleTab(tabGeneral, name == "general")
        StyleTab(tabDisplay, name == "display")
        StyleTab(tabAppearance, name == "appearance")
        StyleTab(tabModes, name == "modes")
        if name == "general" then
            pageGeneral:Show()
        elseif name == "display" then
            pageDisplay:Show()
        elseif name == "appearance" then
            pageAppearance:Show()
        else
            pageModes:Show()
            if UI.RefreshThreatVisibility then
                UI.RefreshThreatVisibility(f)
            end
        end
        local body = (f.tabHeights and f.tabHeights[name]) or 280
        local extra = per and 24 or 0
        local h = HEADER_PAD + extra + body + FOOTER_PAD
        if h < 220 then h = 220 end
        if h > 920 then h = 920 end
        f:SetHeight(h)
        local w = (f.tabWidths and f.tabWidths[name]) or (f.baseWidth or 720)
        local specOn = OM.GetSetting and OM:GetSetting("windowSpecificSettings") == true
        if specOn then
            w = w + (f.railWidth or 128) + 8
        end
        if w < 420 then w = 420 end
        if w > 900 then w = 900 end
        f:SetWidth(w)
    end
    f.SelectTab = SelectTab
    tabGeneral:SetScript("OnClick", function() SelectTab("general") end)
    tabDisplay:SetScript("OnClick", function() SelectTab("display") end)
    tabAppearance:SetScript("OnClick", function() SelectTab("appearance") end)
    tabModes:SetScript("OnClick", function() SelectTab("modes") end)

    -- ========== General page ==========
    local y = 0
    AddCheckbox(pageGeneral, "Lock frame position", 16, y, "lockFrames", "Prevent dragging and resizing")
    y = y - 24
    local layoutCb = AddCheckbox(pageGeneral, "Account-wide layout", 16, y, "accountWideLayout",
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
    local specCb = AddCheckbox(pageGeneral, "Window specific settings", 16, y, "windowSpecificSettings",
        "Show a window list. All windows edits every meter. Window 1-6 edits only that meter.")
    specCb.onToggle = function(checked)
        if not checked then
            UI.settingsScope = 0
        end
        if f.ApplyWindowMode then f.ApplyWindowMode() end
        if f.RebuildWindowRail then f.RebuildWindowRail() end
        if f.SelectTab then
            f.SelectTab((not checked and "general") or (f.activeTab or "general"))
        end
    end
    y = y - 24

    AddCheckbox(pageGeneral, "Confirm before reset", 16, y, "confirmReset", "Show a confirmation popup when pressing Reset")
    y = y - 24
    AddCheckbox(pageGeneral, "Party Join Reset", 16, y, "partyJoinReset",
        "Reset meter data after joining a party or raid. Follows Confirm before reset.")
    y = y - 24
    AddCheckbox(pageGeneral, "Party Leave Reset", 16, y, "partyLeaveReset",
        "Reset meter data after leaving a party or raid. Follows Confirm before reset.")
    y = y - 24
    AddCheckbox(pageGeneral, "Confirm before announce", 16, y, "confirmAnnounce", "Show a confirmation popup when pressing Announce")
    y = y - 24
    local testCb = AddCheckbox(pageGeneral, "Test mode", 16, y, "testMode",
        "Fill the meter with fake 40-player raid data. Uncheck to clear it.")
    f.testModeCb = testCb
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
            if UI.Refresh then UI:Refresh() end
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00GreedMeter:|r Test mode OFF")
        end
    end
    y = y - 24
    AddCheckbox(pageGeneral, "Merge pet abilities", 16, y, "mergePetDamage",
        "Pets always count toward their owner on the meter.\nWhen enabled, all pet ability damage is shown as one \"Pet: Damage\" line in tooltips.\nWhen disabled, tooltips list each pet ability (Pet: Bite, Pet: Claw, …).")
    y = y - 28

    -- Threat mode (built into General so it always shows)
    local threatCb = AddCheckbox(pageGeneral, "Add threat mode", 16, y, "enableThreatMode",
        "Enables threat metering on meter windows.\nUse the Threat view dropdown to choose Single target, Tank, Overall, or All.")
    f.threatModeCb = threatCb
    y = y - 24

    local THREAT_VIEW_OPTS = {
        { key = "single",  label = "Single target" },
        { key = "tank",    label = "Tank" },
        { key = "overall", label = "Overall" },
        { key = "all",     label = "All" },
    }
    local viewLabel = pageGeneral:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    viewLabel:SetPoint("TOPLEFT", pageGeneral, "TOPLEFT", 36, y)
    viewLabel:SetText("Threat view:")
    f.threatViewLabel = viewLabel

    local viewDD = CreateFrame("Frame", "GreedMeterThreatViewDropDown", pageGeneral, "UIDropDownMenuTemplate")
    viewDD:SetPoint("TOPLEFT", pageGeneral, "TOPLEFT", 100, y + 6)
    UIDropDownMenu_SetWidth(120, viewDD)
    UIDropDownMenu_SetButtonWidth(120, viewDD)

    local function ThreatView_OnClick()
        local id = this:GetID()
        local opt = THREAT_VIEW_OPTS[id]
        if not opt then return end
        OM:SetSetting("threatView", opt.key)
        UIDropDownMenu_SetSelectedID(viewDD, id)
        UIDropDownMenu_SetText(opt.label, viewDD)
        if OM.extraSettingsCheckboxes then
            local ei
            for ei = 1, table.getn(OM.extraSettingsCheckboxes) do
                local e = OM.extraSettingsCheckboxes[ei]
                if e and e.childDropdown and e.childDropdown.onChange then
                    e.childDropdown.onChange(opt.key)
                    break
                end
            end
        end
        if UI.Refresh then UI:Refresh() end
    end
    local function ThreatView_Init()
        local cur = OM:GetSetting("threatView") or "single"
        local oi
        for oi = 1, table.getn(THREAT_VIEW_OPTS) do
            local info = {}
            info.text = THREAT_VIEW_OPTS[oi].label
            info.func = ThreatView_OnClick
            info.checked = (THREAT_VIEW_OPTS[oi].key == cur)
            UIDropDownMenu_AddButton(info)
        end
    end
    UIDropDownMenu_Initialize(viewDD, ThreatView_Init)
    local curView = OM:GetSetting("threatView") or "single"
    local sel = 1
    local oi
    for oi = 1, table.getn(THREAT_VIEW_OPTS) do
        if THREAT_VIEW_OPTS[oi].key == curView then sel = oi break end
    end
    UIDropDownMenu_SetSelectedID(viewDD, sel)
    UIDropDownMenu_SetText(THREAT_VIEW_OPTS[sel].label, viewDD)
    f.threatViewDD = viewDD
    y = y - 36

    local function SyncThreatGeneralEnabled()
        local on = OM:GetSetting("enableThreatMode") == true
        if viewLabel then
            if on then viewLabel:SetTextColor(1, 1, 1) else viewLabel:SetTextColor(0.5, 0.5, 0.5) end
        end
        local btn = getglobal("GreedMeterThreatViewDropDownButton")
        if on then
            if UIDropDownMenu_EnableDropDown then UIDropDownMenu_EnableDropDown(viewDD) end
            if btn then btn:Enable(); btn:EnableMouse(true) end
        else
            if UIDropDownMenu_DisableDropDown then UIDropDownMenu_DisableDropDown(viewDD) end
            if btn then btn:Disable(); btn:EnableMouse(false) end
        end
        if UI.RefreshThreatVisibility then
            pcall(UI.RefreshThreatVisibility, f)
        end
    end
    f.SyncThreatGeneralEnabled = SyncThreatGeneralEnabled

    if threatCb then
        threatCb:SetScript("OnClick", function()
            local checked = this:GetChecked() and true or false
            OM:SetSetting("enableThreatMode", checked)
            if OM.extraSettingsCheckboxes then
                local ei
                for ei = 1, table.getn(OM.extraSettingsCheckboxes) do
                    local e = OM.extraSettingsCheckboxes[ei]
                    if e and e.key == "enableThreatMode" and e.onToggle then
                        e.onToggle(checked)
                        break
                    end
                end
            end
            SyncThreatGeneralEnabled()
            if UI.Refresh then UI:Refresh() end
        end)
    end
    SyncThreatGeneralEnabled()

    -- Right column: combat log range first, then announce channel + lines together

    local rightX = 250
    local ry = 0

    local rangeLabel = pageGeneral:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    rangeLabel:SetPoint("TOPLEFT", pageGeneral, "TOPLEFT", rightX, ry)
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

    local rdd = CreateFrame("Frame", "GreedMeterRangeDropDown", pageGeneral, "UIDropDownMenuTemplate")
    rdd:SetPoint("TOPLEFT", pageGeneral, "TOPLEFT", rightX - 16, ry)
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

    local annLabel = pageGeneral:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    annLabel:SetPoint("TOPLEFT", pageGeneral, "TOPLEFT", rightX, ry)
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

    local dd = CreateFrame("Frame", "GreedMeterChannelDropDown", pageGeneral, "UIDropDownMenuTemplate")
    dd:SetPoint("TOPLEFT", pageGeneral, "TOPLEFT", rightX - 16, ry)
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
    AddSlider(pageGeneral, "Announce lines", rightX, ry, "announceLines", 1, 20, 1, 160)

    -- Dynamic height for General from content depth
    local generalBottom = y or 0
    if ry and ry < generalBottom then generalBottom = ry end
    f._threatExtrasY = generalBottom - 28
    f.tabHeights.general = math.max(140, (-generalBottom) + 36)

    local close = CreateButton(f, "Close", 70, 20, function()
        f:Hide()
    end)
    close:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 12)

    -- Display / Appearance / Modes pages
    if UI.BuildSettingsExtraPages then
        UI.BuildSettingsExtraPages(f, pageDisplay, pageAppearance, pageModes)
    end
    if f.RebuildWindowRail then f.RebuildWindowRail() end
    if f.LayoutSettingsChrome then f.LayoutSettingsChrome() end

    SelectTab("general")

    f:Hide()
    self.settingsFrame = f
    return f
end

function UI:ToggleSettings()
    if not OM.db then OM:InitDB() end
    local f = self:CreateSettingsFrame()
    if f:IsShown() then
        HidePalette()
        f:Hide()
    else
        if f.SelectTab then f.SelectTab(f.activeTab or "general") end
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
    if self.RestoreSavedFrames then
        self:RestoreSavedFrames()
    end
    self._onloadCount = (self._onloadCount or 0) + 1
    if not self._skipReanchor then
        if self.ApplySavedLayout then
            self:ApplySavedLayout(self.mainFrame, 1)
        end
        if self._onloadCount >= 2 then
            self._skipReanchor = true
        end
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
    -- Re-apply background opacity after restore (login / reload / zone-in)
    if self.ApplySettingsToFrames then
        self:ApplySettingsToFrames()
    end
    if UI.ApplySoloVisibility then
        UI.ApplySoloVisibility()
    end
    -- If Hide out of combat is on and combat is over, begin the delayed hide
    if UI.AnyFrameHidesOOC and UI.AnyFrameHidesOOC() then
        if not OM.inCombat then
            self.oocForceVisible = false
            if UI.StartOOCFadeOut then
                UI.StartOOCFadeOut()
            end
        end
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

-- Out-of-combat hide: forced visible via minimap until combat or second click
UI.oocForceVisible = false
UI._oocFadeElapsed = nil
UI._oocPendingHide = false

local function CancelOOCHide()
    UI._oocPendingHide = false
    UI._oocFadeElapsed = nil
    if UI._oocFadeFrame then
        UI._oocFadeFrame:Hide()
        UI._oocFadeFrame:SetScript("OnUpdate", nil)
    end
end

local function PlayerInGroup()
    local nRaid = GetNumRaidMembers and GetNumRaidMembers() or 0
    if nRaid and nRaid > 0 then return true end
    local nParty = GetNumPartyMembers and GetNumPartyMembers() or 0
    if nParty and nParty > 0 then return true end
    return false
end

local function FrameSettingOn(f, key)
    local prev = OM._readIndex
    if f and f.layoutIndex then
        OM._readIndex = f.layoutIndex
    end
    local on = OM.GetSetting and OM:GetSetting(key) == true
    OM._readIndex = prev
    return on
end

local function FrameHidesWhenSolo(f)
    return FrameSettingOn(f, "hideWhenSolo")
end

local function FrameHidesOOC(f)
    return FrameSettingOn(f, "hideOutOfCombat")
end

local function AnyFrameHidesOOC()
    if UI.frames then
        local i, f
        for i = 1, table.getn(UI.frames) do
            f = UI.frames[i]
            if f and FrameHidesOOC(f) then
                return true
            end
        end
    end
    return OM.GetSetting and OM:GetSetting("hideOutOfCombat") == true
end

local function ApplySoloVisibility()
    if not UI.frames then return end
    local grouped = PlayerInGroup()
    local i, f
    for i = 1, table.getn(UI.frames) do
        f = UI.frames[i]
        if f then
            if FrameHidesWhenSolo(f) and not grouped then
                f._soloHidden = true
                f:SetAlpha(1)
                f:Hide()
            elseif f._soloHidden then
                f._soloHidden = nil
                if not (FrameHidesOOC(f) and not OM.inCombat and not UI.oocForceVisible) then
                    f:SetAlpha(1)
                    f:Show()
                    if UI.RefreshFrame then UI:RefreshFrame(f) end
                end
            end
        end
    end
end
UI.ApplySoloVisibility = ApplySoloVisibility

local function ShowAllMeterFrames()
    local i, f
    if not UI.frames then return end
    local grouped = PlayerInGroup()
    for i = 1, table.getn(UI.frames) do
        f = UI.frames[i]
        if f then
            if FrameHidesWhenSolo(f) and not grouped then
                f._soloHidden = true
                f:SetAlpha(1)
                f:Hide()
            else
                f._soloHidden = nil
                f:SetAlpha(1)
                f:Show()
                if UI.RefreshFrame then UI:RefreshFrame(f) end
            end
        end
    end
end

local function HideAllMeterFrames()
    local i, f
    if not UI.frames then return end
    for i = 1, table.getn(UI.frames) do
        f = UI.frames[i]
        if f then
            f:SetAlpha(1)
            f:Hide()
        end
    end
end

local function HideOOCMeterFrames()
    local i, f
    if not UI.frames then return end
    for i = 1, table.getn(UI.frames) do
        f = UI.frames[i]
        if f and FrameHidesOOC(f) then
            f._oocHidden = true
            f:SetAlpha(1)
            f:Hide()
        end
    end
end

local function ShowOOCMeterFrames()
    local i, f
    if not UI.frames then return end
    local grouped = PlayerInGroup()
    for i = 1, table.getn(UI.frames) do
        f = UI.frames[i]
        if f and (f._oocHidden or FrameHidesOOC(f)) then
            if FrameHidesWhenSolo(f) and not grouped then
                f._soloHidden = true
                f._oocHidden = nil
                f:SetAlpha(1)
                f:Hide()
            else
                f._oocHidden = nil
                f:SetAlpha(1)
                f:Show()
                if UI.RefreshFrame then UI:RefreshFrame(f) end
            end
        end
    end
end

local function StartOOCFadeOut()
    if not AnyFrameHidesOOC() then return end
    CancelOOCHide()
    if not UI._oocFadeFrame then
        UI._oocFadeFrame = CreateFrame("Frame")
    end
    UI._oocPendingHide = true
    UI._oocFadeElapsed = 0
    local DELAY = 5
    local FADE = 0.6
    UI._oocFadeFrame:SetScript("OnUpdate", function()
        if not UI._oocPendingHide then
            this:SetScript("OnUpdate", nil)
            return
        end
        if OM.inCombat or UI.oocForceVisible then
            CancelOOCHide()
            ShowOOCMeterFrames()
            return
        end
        if not AnyFrameHidesOOC() then
            CancelOOCHide()
            return
        end
        UI._oocFadeElapsed = (UI._oocFadeElapsed or 0) + arg1
        if UI._oocFadeElapsed < DELAY then
            return
        end
        local t = UI._oocFadeElapsed - DELAY
        if t >= FADE then
            HideOOCMeterFrames()
            CancelOOCHide()
            return
        end
        local a = 1 - (t / FADE)
        if a < 0 then a = 0 end
        local i, f
        for i = 1, table.getn(UI.frames) do
            f = UI.frames[i]
            if f and f:IsShown() and FrameHidesOOC(f) then
                f:SetAlpha(a)
            end
        end
    end)
    UI._oocFadeFrame:Show()
end

UI.AnyFrameHidesOOC = AnyFrameHidesOOC
UI.StartOOCFadeOut = StartOOCFadeOut
UI.ShowOOCMeterFrames = ShowOOCMeterFrames

function UI:OnCombatStart()
    CancelOOCHide()
    UI.oocForceVisible = false
    if AnyFrameHidesOOC() then
        ShowOOCMeterFrames()
    end
    self:Refresh()
end

function UI:OnCombatEnd()
    self:Refresh()
    if AnyFrameHidesOOC() then
        if not UI.oocForceVisible then
            StartOOCFadeOut()
        end
    end
end

function UI:SyncTestModeCheckbox()
    local sf = self.settingsFrame
    if sf and sf.testModeCb then
        local on = OM.GetSetting and OM:GetSetting("testMode") == true
        sf.testModeCb:SetChecked(on and 1 or nil)
    end
end

function UI:OnReset()
    if self.SyncTestModeCheckbox then
        self:SyncTestModeCheckbox()
    end
    local _, f
    for _gi = 1, table.getn(self.frames) do local f = self.frames[_gi]
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
            for i = 1, table.getn(f.bars) do local bar = f.bars[i]
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
            for _gi = 1, table.getn(names) do local n2 = names[_gi]
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
    if UI.ApplySoloVisibility then
        UI.ApplySoloVisibility()
    end
end

-- ============================================================
-- Minimap button (OctoSpec-style angle drag)
-- ============================================================

function UI:ToggleAllFrames()
    local hideOOC = AnyFrameHidesOOC and AnyFrameHidesOOC()
    local inCombat = OM.inCombat and true or false

    -- With Hide out of combat: minimap forces show/hide outside combat.
    -- First click while hidden → force show; second click → clear force and hide
    -- (returns to automatic hide-out-of-combat behavior).
    if hideOOC and not inCombat then
        CancelOOCHide()
        if self.oocForceVisible then
            self.oocForceVisible = false
            HideOOCMeterFrames()
        else
            local anyShown = false
            local i, f
            for i = 1, table.getn(self.frames) do
                f = self.frames[i]
                if f and f:IsShown() and FrameHidesOOC(f) then anyShown = true break end
            end
            if anyShown then
                self.oocForceVisible = false
                HideOOCMeterFrames()
            else
                self.oocForceVisible = true
                ShowOOCMeterFrames()
            end
        end
        if self.SaveAllFrameLayouts then
            self:SaveAllFrameLayouts()
        end
        return
    end

    local anyShown = false
    local _, f
    for _gi = 1, table.getn(self.frames) do local f = self.frames[_gi]
        if f:IsShown() then
            anyShown = true
            break
        end
    end
    if anyShown then
        for _gi = 1, table.getn(self.frames) do local f = self.frames[_gi]
            f:Hide()
        end
        self.oocForceVisible = false
    else
        for _gi = 1, table.getn(self.frames) do local f = self.frames[_gi]
            f:Show()
            f:SetAlpha(1)
            self:RefreshFrame(f)
        end
        if self.mainFrame and not self.mainFrame:IsShown() then
            self.mainFrame:Show()
            self.mainFrame:SetAlpha(1)
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
        if OM.GetSetting and OM:GetSetting("hideOutOfCombat") == true then
            GameTooltip:AddLine("  (forces show while out of combat; click again to resume auto-hide)", 0.75, 0.75, 0.75)
        end
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
    for _gi = 1, table.getn(UI.frames) do local f = UI.frames[_gi]
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
    TrackSettingWidget(cb, "cb", settingKey)
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
    TrackSettingWidget(slider, "slider", settingKey)

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
    slider._valText = valText

    slider:SetScript("OnValueChanged", function()
        local v = this:GetValue()
        if step and step >= 1 then
            v = math.floor(v / step + 0.5) * step
        end
        v = tonumber(v) or minV
        OM:SetSetting(settingKey, v)
        valText:SetText(tostring(math.floor(v + 0.5)))
        if UI.ApplySettingsToFrames then UI:ApplySettingsToFrames() end
    end)
    return slider
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
    local parent = UI.settingsFrame or UIParent
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
        title:SetText("Color")
        pf.title = title

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
    local titles = {
        textOutline = "Outline Color",
        barTextColor = "Text Color",
        titleColor = "Title Color",
        windowBgColor = "Background Color",
    }
    if paletteFrame.title then
        paletteFrame.title:SetText(titles[mode] or "Mode Color")
    end
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

    local function ApplySelection()
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
        if not options[sel] then
            UIDropDownMenu_SetText(options[1] and options[1].label or "", dd)
            sel = 1
        elseif OM:GetSetting(settingKey) ~= options[sel].key then
            -- keep text from loop; if no match, show first
            local found = false
            for i = 1, table.getn(options) do
                if options[i].key == cur then found = true break end
            end
            if not found and options[1] then
                UIDropDownMenu_SetText(options[1].label, dd)
            end
        end
        UIDropDownMenu_SetSelectedID(dd, sel)
    end

    UIDropDownMenu_Initialize(dd, Init)
    ApplySelection()

    -- Allow callers to mutate `options` and refresh the menu text
    dd.RefreshOptions = function()
        UIDropDownMenu_Initialize(dd, Init)
        ApplySelection()
    end
    dd._options = options
    return dd
end

-- ============================================================
-- Customization window
-- ============================================================

-- Build Display / Appearance / Modes into the main Settings window pages.

local function SafeSetEnabled(widget, enabled)
    if not widget then return end
    if enabled then
        if widget.Enable then widget:Enable() end
        if widget.EnableMouse then widget:EnableMouse(true) end
        if widget.SetAlpha then widget:SetAlpha(1) end
        if widget.label and widget.label.SetTextColor then
            widget.label:SetTextColor(1, 1, 1)
        end
    else
        if widget.Disable then widget:Disable() end
        if widget.EnableMouse then widget:EnableMouse(false) end
        if widget.SetAlpha then widget:SetAlpha(0.5) end
        if widget.label and widget.label.SetTextColor then
            widget.label:SetTextColor(0.5, 0.5, 0.5)
        end
    end
end

local function SyncDropDownEnabled(dd, enabled)
    if not dd then return end
    local btn = nil
    if dd.GetName then
        local n = dd:GetName()
        if n then btn = getglobal(n .. "Button") end
    end
    if enabled then
        if UIDropDownMenu_EnableDropDown then UIDropDownMenu_EnableDropDown(dd) end
        if btn then btn:Enable(); btn:EnableMouse(true) end
        dd:EnableMouse(true)
    else
        if UIDropDownMenu_DisableDropDown then UIDropDownMenu_DisableDropDown(dd) end
        if btn then btn:Disable(); btn:EnableMouse(false) end
        dd:EnableMouse(false)
        if CloseDropDownMenus then CloseDropDownMenus() end
    end
end

local function BuildSettingsExtraPages(f, pageDisplay, pageAppearance, pageModes)
    if not f or not pageDisplay or not pageAppearance or not pageModes then return end
    if f._extraPagesBuilt then return end
    f._extraPagesBuilt = true

    local contentW = 690

    -- ========== Display page ==========
    local y = 0

    local abvCb = MakeCheckbox(pageDisplay, "Abbreviated Names", 4, y,
        OM:GetSetting("abbreviateNames") == true,
        function(checked)
            OM:SetSetting("abbreviateNames", checked)
            if UI.Refresh then UI:Refresh() end
        end, 22,
        "Single-word: first 4 letters. Multi-word: first 3 of each word. Applies to all modes.")
    f.abvCb = abvCb
    y = y - 22

    MakeSettingCheckbox(pageDisplay, "Show fight duration", 4, y, "showFightDuration",
        "Show fight time as the first bar (centered, not ranked). Uses mode color when Mode Colors is on.")
    MakeSettingCheckbox(pageDisplay, "Show total bar", 200, y, "showTotal",
        "Add a Total row summing all players")
    y = y - 22
    MakeSettingCheckbox(pageDisplay, "Hide ranking numbers", 4, y, "hideRankNumbers",
        "Hide the N. rank prefix on meter bars. Announce still lists true ranks.")
    y = y - 22

    MakeSettingCheckbox(pageDisplay, "Detailed damage/healing", 4, y, "detailedDamage",
        "OFF by default. When enabled, left-click anywhere on a player bar (not Total/Duration) to open ability details.")
    y = y - 22

    MakeSettingCheckbox(pageDisplay, "Class colors", 4, y, "classColors", "Color bars by player class")
    MakeSettingCheckbox(pageDisplay, "Mode Colors", 118, y, "buttonsColorWithMode",
        "Tint header buttons and Total bar with each mode's color")
    local classIconCb = MakeSettingCheckbox(pageDisplay, "Class icons", 228, y, "showClassIcons",
        "Show a class icon before each player name on the bars")
    y = y - 22

    local circularCb = MakeSettingCheckbox(pageDisplay, "Circular icons", 248, y, "circularClassIcons",
        "Draw class icons with a circular ring (same method as the minimap button).", 18)
    local function SyncCircularEnabled()
        local parentOn = OM:GetSetting("showClassIcons") == true
        if parentOn then
            circularCb:Enable()
            if circularCb.label then circularCb.label:SetTextColor(1, 1, 1) end
        else
            circularCb:Disable()
            if circularCb.label then circularCb.label:SetTextColor(0.5, 0.5, 0.5) end
        end
    end
    classIconCb.onToggle = function()
        SyncCircularEnabled()
    end
    SyncCircularEnabled()

    local compactCb = MakeSettingCheckbox(pageDisplay, "Compact Header", 4, y, "hideTitle",
        "One-line header with abbreviated button labels (Re, An, Na, Mo, ...)")
    y = y - 20
    local keepTitleCb = MakeSettingCheckbox(pageDisplay, "Keep Title in compact", 24, y, "keepTitleInCompact",
        "Show the mode title above the compact one-line controls.", 18)
    f.keepTitleCb = keepTitleCb

    -- Title align: Left / Center / Right (enabled only when Keep Title is on)
    local function MakeAlignBtn(label, alignKey, x)
        local b = CreateFrame("Button", nil, pageDisplay, "UIPanelButtonTemplate")
        b:SetWidth(48)
        b:SetHeight(18)
        b:SetPoint("TOPLEFT", pageDisplay, "TOPLEFT", x, y)
        b:SetText(label)
        b.alignKey = alignKey
        b:SetScript("OnClick", function()
            OM:SetSetting("compactTitleAlign", this.alignKey)
            if UI.Refresh then UI:Refresh() end
            if f.SyncAlignButtons then f.SyncAlignButtons() end
        end)
        return b
    end
    -- Sit to the right of "Keep Title in compact" on the same row
    local alignLeft = MakeAlignBtn("Left", "LEFT", 188)
    local alignCenter = MakeAlignBtn("Center", "CENTER", 238)
    local alignRight = MakeAlignBtn("Right", "RIGHT", 288)
    f.alignBtns = { alignLeft, alignCenter, alignRight }

    local function SyncAlignButtons()
        local keepOn = OM:GetSetting("hideTitle") == true and OM:GetSetting("keepTitleInCompact") == true
        local cur = OM:GetSetting("compactTitleAlign") or "CENTER"
        local i, b
        for i = 1, table.getn(f.alignBtns) do
            b = f.alignBtns[i]
            local fs = b.GetFontString and b:GetFontString() or nil
            if keepOn then
                b:Enable()
                if fs then
                    if b.alignKey == cur then
                        fs:SetTextColor(1, 0.85, 0.2)
                    else
                        fs:SetTextColor(1, 1, 1)
                    end
                end
            else
                b:Disable()
                if fs then
                    fs:SetTextColor(0.5, 0.5, 0.5)
                end
            end
        end
    end
    f.SyncAlignButtons = SyncAlignButtons

    local function SyncKeepTitleEnabled()
        local parentOn = OM:GetSetting("hideTitle") == true
        if parentOn then
            keepTitleCb:Enable()
            if keepTitleCb.label then keepTitleCb.label:SetTextColor(1, 1, 1) end
        else
            keepTitleCb:Disable()
            if keepTitleCb.label then keepTitleCb.label:SetTextColor(0.5, 0.5, 0.5) end
        end
        SyncAlignButtons()
    end
    compactCb.onToggle = function()
        SyncKeepTitleEnabled()
    end
    keepTitleCb.onToggle = function()
        SyncAlignButtons()
        if UI.Refresh then UI:Refresh() end
    end
    SyncKeepTitleEnabled()
    y = y - 24

    MakeSettingCheckbox(pageDisplay, "Hide bar backgrounds", 4, y, "hideBarBackgrounds",
        "Hide the dark empty track behind each bar; only the filled portion is visible.")
    y = y - 22

    local hideOOCCb = MakeSettingCheckbox(pageDisplay, "Hide out of combat", 4, y, "hideOutOfCombat",
        "Hide this meter ~5 seconds after combat ends (short fade). It reappears instantly when combat starts. Minimap button can force show/hide while this is on.")
    hideOOCCb.onToggle = function(checked)
        if checked then
            UI.oocForceVisible = false
            if not OM.inCombat and StartOOCFadeOut then
                StartOOCFadeOut()
            end
        else
            if not AnyFrameHidesOOC() and CancelOOCHide then
                CancelOOCHide()
            end
            if ShowOOCMeterFrames then
                ShowOOCMeterFrames()
            end
            local scope = UI.settingsScope or 0
            local fr = (scope >= 1 and UI.frames and UI.frames[scope]) or nil
            if fr and fr._oocHidden then
                fr._oocHidden = nil
                if not (FrameHidesWhenSolo(fr) and not PlayerInGroup()) then
                    fr:SetAlpha(1)
                    fr:Show()
                    if UI.RefreshFrame then UI:RefreshFrame(fr) end
                end
            end
        end
    end
    y = y - 22
    local soloCb = MakeSettingCheckbox(pageDisplay, "Hide when solo", 4, y, "hideWhenSolo",
        "Hide this meter while you are not in a party or raid.")
    soloCb.onToggle = function()
        if UI.ApplySoloVisibility then UI.ApplySoloVisibility() end
    end
    y = y - 22
    MakeSettingCheckbox(pageDisplay, "Self on top", 4, y, "selfOnTop",
        "Always show your bar first. Rank number stays your real place in the meter.")
    y = y - 24

    -- Right column: hide individual header buttons
    local hideX = 400
    local hy = 0
    local hideHdr = pageDisplay:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hideHdr:SetPoint("TOPLEFT", pageDisplay, "TOPLEFT", hideX, hy)
    hideHdr:SetText("Hide buttons")
    hideHdr:SetTextColor(1, 0.85, 0.4)
    hy = hy - 20
    MakeSettingCheckbox(pageDisplay, "Reset", hideX, hy, "hideHeaderReset",
        "Hide the Reset button on meter windows.")
    hy = hy - 20
    MakeSettingCheckbox(pageDisplay, "Announce", hideX, hy, "hideHeaderAnnounce",
        "Hide the Announce button on meter windows.")
    hy = hy - 20
    MakeSettingCheckbox(pageDisplay, "Name", hideX, hy, "hideHeaderName",
        "Hide the Name filter button on meter windows.")
    hy = hy - 20
    MakeSettingCheckbox(pageDisplay, "Segment", hideX, hy, "hideHeaderSegment",
        "Hide the Segment button on meter windows.")
    hy = hy - 20
    MakeSettingCheckbox(pageDisplay, "Mode", hideX, hy, "hideHeaderMode",
        "Hide the Mode button on meter windows.")
    hy = hy - 20
    MakeSettingCheckbox(pageDisplay, "+ / - windows", hideX, hy, "hideHeaderWindows",
        "Hide the add/remove window buttons on meter windows.")
    hy = hy - 8
    if hy < y then y = hy end

    if f.tabHeights then
        f.tabHeights.display = math.max(100, (-y) + 16)
    end

    -- ========== Appearance page ==========
    y = 0


    local styleOpts = (UI.GetMergedBarStyles and UI.GetMergedBarStyles()) or (UI.BAR_STYLES or {
        { key = "Default", label = "Default" },
    })
    local fontOpts = (UI.GetMergedBarFonts and UI.GetMergedBarFonts()) or (UI.BAR_FONTS or {
        { key = "Friz", label = "Friz Quadrata" },
    })
    local NUM_FORMATS = {
        { key = "1k",    label = "1k" },
        { key = "10k",   label = "10k" },
        { key = "100k",  label = "100k" },
        { key = "never", label = "Never" },
    }

    local styleDD = MakeLabeledDropDown(pageAppearance, "Bar style:", 4, y, 110, styleOpts, "barStyle")
    local fontDD = MakeLabeledDropDown(pageAppearance, "Bar font:", 160, y, 120, fontOpts, "barFont")
    MakeLabeledDropDown(pageAppearance, "Number format:", 330, y, 90, NUM_FORMATS, "numberFormat")
    y = y - 42

    local outlineCb = MakeSettingCheckbox(pageAppearance, "Text outline", 4, y - 2, "textOutline",
        "Draw a colored outline around bar name and value text.")
    local outlineCol = (OM:GetSetting("textOutlineColor")) or { 0, 0, 0 }
    local outlineSw = MakeColorSwatch(pageAppearance, 20, 14)
    outlineSw:SetPoint("LEFT", outlineCb.label or outlineCb, "RIGHT", 8, 0)
    outlineSw:SetColor(outlineCol[1] or 0, outlineCol[2] or 0, outlineCol[3] or 0)
    local function SyncOutlineSwatch()
        local on = OM:GetSetting("textOutline") == true
        if on then
            outlineSw:Enable()
            outlineSw:EnableMouse(true)
            outlineSw:SetAlpha(1)
        else
            outlineSw:Disable()
            outlineSw:EnableMouse(false)
            outlineSw:SetAlpha(0.4)
        end
    end
    outlineCb.onToggle = function()
        SyncOutlineSwatch()
    end
    outlineSw:SetScript("OnClick", function()
        if OM:GetSetting("textOutline") ~= true then return end
        ShowPalette(outlineSw, "textOutline", function(r, g, b)
            OM:SetSetting("textOutlineColor", { r, g, b })
            outlineSw:SetColor(r, g, b)
            if UI.ApplySettingsToFrames then UI:ApplySettingsToFrames() end
            if UI.Refresh then UI:Refresh() end
        end)
    end)
    SyncOutlineSwatch()

    local function MakeLabeledSwatch(label, x, settingKey, def)
        local fs = pageAppearance:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetPoint("LEFT", outlineCb, "LEFT", x - 4, 0)
        fs:SetText(label)
        local sw = MakeColorSwatch(pageAppearance, 20, 14)
        sw:SetPoint("LEFT", fs, "RIGHT", 6, 0)
        local col = OM:GetSetting(settingKey) or def
        sw:SetColor(col[1] or def[1], col[2] or def[2], col[3] or def[3])
        sw:SetScript("OnClick", function()
            ShowPalette(sw, settingKey, function(r, g, b)
                OM:SetSetting(settingKey, { r, g, b })
                sw:SetColor(r, g, b)
                if UI.ApplySettingsToFrames then UI:ApplySettingsToFrames() end
                if UI.Refresh then UI:Refresh() end
            end)
        end)
        return sw
    end
    MakeLabeledSwatch("Text color", 200, "barTextColor", { 1.00, 1.00, 1.00 })
    MakeLabeledSwatch("Title color", 340, "titleColor", { 1.00, 0.82, 0.00 })
    MakeLabeledSwatch("Background color", 500, "windowBgColor", { 0, 0, 0 })
    y = y - 36

    -- ---- Custom media import ----
    local importHdr = pageAppearance:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    importHdr:SetPoint("TOPLEFT", pageAppearance, "TOPLEFT", 4, y)
    importHdr:SetText("Import bar / font from another addon")
    importHdr:SetTextColor(1, 0.85, 0.4)
    y = y - 16

    local exampleFs = pageAppearance:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    exampleFs:SetPoint("TOPLEFT", pageAppearance, "TOPLEFT", 4, y)
    exampleFs:SetText("Example: C:\\OctoWoW\\Interface\\AddOns\\SomeAddon\\media\\bar.tga")
    exampleFs:SetTextColor(0.65, 0.65, 0.65)
    y = y - 16

    -- Type: Bar texture | Font
    local importKind = "bar"  -- or "font"
    local kindBar = CreateFrame("Button", nil, pageAppearance, "UIPanelButtonTemplate")
    kindBar:SetWidth(70)
    kindBar:SetHeight(18)
    kindBar:SetPoint("TOPLEFT", pageAppearance, "TOPLEFT", 4, y)
    kindBar:SetText("Bar")
    local kindFont = CreateFrame("Button", nil, pageAppearance, "UIPanelButtonTemplate")
    kindFont:SetWidth(70)
    kindFont:SetHeight(18)
    kindFont:SetPoint("LEFT", kindBar, "RIGHT", 4, 0)
    kindFont:SetText("Font")

    local function UpdateKindButtons()
        if importKind == "bar" then
            kindBar:Disable()
            kindFont:Enable()
            exampleFs:SetText("Example: C:\\OctoWoW\\Interface\\AddOns\\SomeAddon\\media\\bar.tga")
        else
            kindBar:Enable()
            kindFont:Disable()
            exampleFs:SetText("Example: Interface\\AddOns\\SomeAddon\\fonts\\MyFont.ttf")
        end
    end
    kindBar:SetScript("OnClick", function()
        importKind = "bar"
        UpdateKindButtons()
    end)
    kindFont:SetScript("OnClick", function()
        importKind = "font"
        UpdateKindButtons()
    end)
    UpdateKindButtons()
    y = y - 22

    local pathLabel = pageAppearance:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    pathLabel:SetPoint("TOPLEFT", pageAppearance, "TOPLEFT", 4, y)
    pathLabel:SetText("Path:")

    local pathBox = CreateFrame("EditBox", "GreedMeterMediaPathBox", pageAppearance)
    pathBox:SetPoint("TOPLEFT", pageAppearance, "TOPLEFT", 40, y + 4)
    pathBox:SetWidth(360)
    pathBox:SetHeight(18)
    pathBox:SetAutoFocus(false)
    pathBox:SetFontObject(GameFontHighlightSmall)
    pathBox:SetText("")
    pathBox:SetMaxLetters(400)
    pathBox:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 8, edgeSize = 8,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    pathBox:SetBackdropColor(0, 0, 0, 0.8)
    pathBox:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
    pathBox:SetTextInsets(4, 4, 0, 0)
    pathBox:SetScript("OnEscapePressed", function() this:ClearFocus() end)
    pathBox:SetScript("OnEnterPressed", function() this:ClearFocus() end)

    local importBtn = CreateFrame("Button", nil, pageAppearance, "UIPanelButtonTemplate")
    importBtn:SetWidth(70)
    importBtn:SetHeight(20)
    importBtn:SetPoint("LEFT", pathBox, "RIGHT", 6, 0)
    importBtn:SetText("Import")

    y = y - 24

    -- Import status line
    local customListFS = pageAppearance:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    customListFS:SetPoint("TOPLEFT", pageAppearance, "TOPLEFT", 4, y)
    customListFS:SetJustifyH("LEFT")
    customListFS:SetWidth(500)
    y = y - 36

    local removeBtns = {}

    -- Normalize a pasted texture/font path to a WoW-loadable Interface\\ or Fonts\\ path.
    local function NormalizePath(p)
        if not p then return "" end
        p = string.gsub(p, "^%s+", "")
        p = string.gsub(p, "%s+$", "")
        p = string.gsub(p, "^\"(.*)\"$", "%1")
        p = string.gsub(p, "^'(.*)'$", "%1")
        p = string.gsub(p, "/", "\\")
        while string.find(p, "\\\\", 1, true) do
            p = string.gsub(p, "\\\\", "\\")
        end

        local lower = string.lower(p)
        local s = string.find(lower, "interface\\", 1, true)
        if s then
            return "Interface" .. string.sub(p, s + 9)
        end
        s = string.find(lower, "fonts\\", 1, true)
        if s then
            return "Fonts" .. string.sub(p, s + 5)
        end

        -- Path starts at AddOns\\
        s = string.find(lower, "addons\\", 1, true)
        if s then
            return "Interface\\AddOns" .. string.sub(p, s + 6)
        end

        -- Addon-relative path (folder\\file.tga)
        if string.find(lower, "%.tga") or string.find(lower, "%.blp")
            or string.find(lower, "%.png") or string.find(lower, "%.ttf")
            or string.find(lower, "%.otf") then
            if string.sub(lower, 1, 10) ~= "interface\\" and string.sub(lower, 1, 6) ~= "fonts\\" then
                return "Interface\\AddOns\\" .. p
            end
        end
        return p
    end

    local function LabelFromPath(p)
        local name = p
        local s, e, cap = string.find(p, "([^\\]+)$")
        if cap then name = cap end
        name = string.gsub(name, "%.[Tt][Gg][Aa]$", "")
        name = string.gsub(name, "%.[Bb][Ll][Pp]$", "")
        name = string.gsub(name, "%.[Tt][Tt][Ff]$", "")
        if name == "" then name = "Custom" end
        return name
    end

    local function KeyFromPath(kind, p)
        return "custom:" .. kind .. ":" .. string.lower(p)
    end

    local function RefreshCustomList()
        local bars = OM:GetSetting("customBarStyles") or {}
        local fonts = OM:GetSetting("customBarFonts") or {}
        local nBars = type(bars) == "table" and table.getn(bars) or 0
        local nFonts = type(fonts) == "table" and table.getn(fonts) or 0
        if nBars == 0 and nFonts == 0 then
            customListFS:SetText("|cff888888No custom bars/fonts imported yet.|r")
        else
            customListFS:SetText("|cffaaaaaaCheck Bar style / Bar font dropdowns for imported entries.|r")
        end

        -- Rebuild dropdown option tables in place so closures see updates
        local function refill(dst, src)
            local n = table.getn(dst)
            local j
            for j = n, 1, -1 do
                table.remove(dst, j)
            end
            for j = 1, table.getn(src) do
                table.insert(dst, src[j])
            end
        end
        if UI.GetMergedBarStyles then
            refill(styleOpts, UI.GetMergedBarStyles())
        end
        if UI.GetMergedBarFonts then
            refill(fontOpts, UI.GetMergedBarFonts())
        end
        if styleDD and styleDD.RefreshOptions then styleDD.RefreshOptions() end
        if fontDD and fontDD.RefreshOptions then fontDD.RefreshOptions() end
    end

    importBtn:SetScript("OnClick", function()
        local path = NormalizePath(pathBox:GetText())
        if path == "" then
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00GreedMeter:|r Enter a file path first.")
            return
        end
        local pl = string.lower(path)
        if string.sub(pl, 1, 10) ~= "interface\\" and string.sub(pl, 1, 6) ~= "fonts\\" then
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00GreedMeter:|r Path must include Interface\\ or Fonts\\ (full paths like C:\\OctoWoW\\Interface\\... are OK — the prefix is stripped automatically).")
            return
        end

        -- Prefer explicit Bar/Font button; file extension overrides when obvious
        local kind = importKind or "bar"
        local lower = string.lower(path)
        if string.find(lower, "%.ttf") or string.find(lower, "%.otf") then
            kind = "font"
            importKind = "font"
            UpdateKindButtons()
        elseif string.find(lower, "%.tga") or string.find(lower, "%.blp") or string.find(lower, "%.png") then
            kind = "bar"
            importKind = "bar"
            UpdateKindButtons()
        end

        local label = LabelFromPath(path)
        if kind == "font" then
            local list = OM:GetSetting("customBarFonts")
            if type(list) ~= "table" then list = {} end
            local key = KeyFromPath("font", path)
            local i
            for i = 1, table.getn(list) do
                if list[i].key == key or list[i].path == path then
                    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00GreedMeter:|r That font path is already imported.")
                    return
                end
            end
            table.insert(list, { key = key, label = label, path = path })
            OM:SetSetting("customBarFonts", list)
            OM:SetSetting("barFont", key)
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00GreedMeter:|r Imported font: " .. label .. " (selected)")
        else
            local list = OM:GetSetting("customBarStyles")
            if type(list) ~= "table" then list = {} end
            local key = KeyFromPath("bar", path)
            local i
            for i = 1, table.getn(list) do
                if list[i].key == key or list[i].texture == path then
                    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00GreedMeter:|r That bar path is already imported.")
                    return
                end
            end
            table.insert(list, { key = key, label = label, texture = path })
            OM:SetSetting("customBarStyles", list)
            OM:SetSetting("barStyle", key)
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00GreedMeter:|r Imported bar style: " .. label .. " (selected)")
        end
        pathBox:SetText("")
        pathBox:ClearFocus()
        RefreshCustomList()
        if UI.ApplySettingsToFrames then UI:ApplySettingsToFrames() end
        if UI.Refresh then UI:Refresh() end
    end)

    local clearBtn = CreateFrame("Button", nil, pageAppearance, "UIPanelButtonTemplate")
    clearBtn:SetWidth(110)
    clearBtn:SetHeight(20)
    clearBtn:SetPoint("LEFT", importBtn, "RIGHT", 6, 0)
    clearBtn:SetText("Clear Imports")
    clearBtn:SetScript("OnClick", function()
        OM:SetSetting("customBarStyles", {})
        OM:SetSetting("customBarFonts", {})
        -- Fall back to built-ins if current selection was custom
        local bs = OM:GetSetting("barStyle") or ""
        local bf = OM:GetSetting("barFont") or ""
        if string.find(bs, "custom:", 1, true) then
            OM:SetSetting("barStyle", "Default")
        end
        if string.find(bf, "custom:", 1, true) then
            OM:SetSetting("barFont", "Friz")
        end
        RefreshCustomList()
        if UI.ApplySettingsToFrames then UI:ApplySettingsToFrames() end
        if UI.Refresh then UI:Refresh() end
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00GreedMeter:|r Custom bars/fonts cleared.")
    end)

    RefreshCustomList()
    y = y - 8

    MakeSlider(pageAppearance, "Bar height", 4, y, "barHeight", 10, 28, 1, 140)
    MakeSlider(pageAppearance, "Font size", 200, y, "fontSize", 8, 18, 1, 140)
    MakeSlider(pageAppearance, "Background opacity", 400, y, "frameOpacity", 0, 100, 5, 140)
    y = y - 40

    MakeSlider(pageAppearance, "Bar spacing", 4, y, "barSpacing", 0, 16, 1, 140)
    MakeSlider(pageAppearance, "Text spacing", 200, y, "textSpacing", -16, 16, 1, 140)
    MakeSlider(pageAppearance, "Class icon position", 400, y, "classIconOffset", -32, 32, 1, 140)
    y = y - 36
    MakeSlider(pageAppearance, "Class icon size", 4, y, "classIconSize", 8, 32, 1, 140)
    y = y - 40
    if f.tabHeights then
        f.tabHeights.appearance = math.max(120, (-y) + 16)
    end

    -- ========== Modes page ==========
    y = 0


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

        local header = pageModes:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        header:SetPoint("TOPLEFT", pageModes, "TOPLEFT", baseX + 4, yy)
        header:SetText(entry.label)
        header:SetTextColor(1, 0.85, 0.4)

        local colorBtn = MakeColorSwatch(pageModes, 20, 13)
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
            enCb = MakeCheckbox(pageModes, "Enabled", x, yy, en, function(checked)
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
                local cb = MakeCheckbox(pageModes, col.label, x, yy, current, function(checked)
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

        -- Extra threat options (pets)
        if entry.mode == "threat" then
            -- Threat has column checkboxes on the first option row; pet option goes under them
            yy = yy - rowH
            local petOn = OM.GetSetting and OM:GetSetting("showPetThreat") == true
            local petCb = MakeCheckbox(pageModes, "Show pets (SuperWoW recommended)", baseX + 6, yy, petOn, function(checked)
                if OM.SetSetting then OM:SetSetting("showPetThreat", checked) end
                if UI.Refresh then UI:Refresh() end
            end, cbSize, "Show your pet/minion as its own threat row (from Pet: damage in the meter).\nAlso enables solo threat estimates for questing.\nSuperWoW improves pet ownership detection.")
            row.petThreatCb = petCb

            -- Single-target threat warnings (never used in tank / overall views)
            yy = yy - rowH
            local sndOn = OM.GetSetting and OM:GetSetting("threatWarnSound") == true
            local sndCb = MakeCheckbox(pageModes, "Threat warning sound", baseX + 6, yy, sndOn, function(checked)
                if OM.SetSetting then OM:SetSetting("threatWarnSound", checked) end
                if row.threatWarnSoundDD then
                    local on = checked and (OM:GetSetting("enableThreatMode") == true)
                    SyncDropDownEnabled(row.threatWarnSoundDD, on)
                end
            end, cbSize, "Play a sound when your threat on the current target reaches the warning threshold.\nOnly active in single-target Threat mode (not Tank or Overall).")
            row.threatWarnSoundCb = sndCb

            local soundOpts = {
                { key = "raidwarning", label = "Raid Warning" },
                { key = "questfail",   label = "Quest Failed" },
                { key = "mapping",     label = "Map Ping" },
                { key = "bellally",    label = "Alliance Bell" },
                { key = "bellhorde",   label = "Horde Bell" },
                { key = "bellne",      label = "Night Elf Bell" },
                { key = "auction",     label = "Auction Open" },
            }
            -- Dropdown beside the checkbox (no extra row)
            local sndDD = MakeLabeledDropDown(pageModes, "", baseX + 175, yy + 16, 130, soundOpts, "threatWarnSoundFile", function(entry)
                -- Preview selection
                local paths = {
                    raidwarning = "Sound\\Interface\\RaidWarning.wav",
                    questfail   = "Sound\\Interface\\igQuestFailed.wav",
                    mapping     = "Sound\\Interface\\MapPing.wav",
                    bellally    = "Sound\\Doodad\\BellTollAlliance.wav",
                    bellhorde   = "Sound\\Doodad\\BellTollHorde.wav",
                    bellne      = "Sound\\Doodad\\BellTollNightElf.wav",
                    auction     = "Sound\\Interface\\AuctionWindowOpen.wav",
                }
                if entry and entry.key and paths[entry.key] then
                    pcall(PlaySoundFile, paths[entry.key])
                end
            end)
            row.threatWarnSoundDD = sndDD

            yy = yy - rowH
            local glowOn = OM.GetSetting and OM:GetSetting("threatWarnGlow") == true
            local glowCb = MakeCheckbox(pageModes, "Threat warning glow", baseX + 6, yy, glowOn, function(checked)
                if OM.SetSetting then OM:SetSetting("threatWarnGlow", checked) end
            end, cbSize, "Red screen-edge glow while your threat is at or above the warning threshold.\nOnly active in single-target Threat mode (not Tank or Overall).")
            row.threatWarnGlowCb = glowCb

            yy = yy - rowH
            local warnPct = tonumber(OM.GetSetting and OM:GetSetting("threatWarnPercent")) or 90
            local warnSlider = MakeSlider(pageModes, "Warn at threat %", baseX + 6, yy, "threatWarnPercent", 50, 100, 1, 160)
            row.threatWarnSlider = warnSlider
            yy = yy - 28
        elseif entry.mode == "tank" then
            -- Tank has no column checkboxes; put pet option on the first option row (no empty gap)
            local petTankOn = OM.GetSetting and OM:GetSetting("petAsTank") == true
            local petTankCb = MakeCheckbox(pageModes, "Use pet as Tank (SuperWoW recommended)", baseX + 6, yy, petTankOn, function(checked)
                if OM.SetSetting then OM:SetSetting("petAsTank", checked) end
                if UI.Refresh then UI:Refresh() end
            end, cbSize, "Score tank-mode aggro from your pet/minion instead of you.\nTracks pettarget and whether the pet holds aggro.\nServer tank API is still player-based — this is estimate + unit scan.\nSuperWoW recommended for stable enemy IDs.")
            row.petAsTankCb = petTankCb
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

    local needed = (-bottomY) + 20
    if needed < 160 then needed = 160 end
    if needed > 900 then needed = 900 end
    if f.tabHeights then
        f.tabHeights.modes = needed
    end

    local reset = UI.CreateButton and UI.CreateButton(f, "Reset Defaults", 110, 20, function()
        local scope = UI.settingsScope or 0
        if scope >= 1 then
            if OM.ClearWindowSettings then OM:ClearWindowSettings(scope) end
            local fr = UI.frames and UI.frames[scope]
            if fr then
                fr:ClearAllPoints()
                fr:SetPoint("CENTER", UIParent, "CENTER", (scope - 1) * 30, (scope - 1) * 30)
            end
            if f.RebuildWindowRail then f.RebuildWindowRail() end
            if f.RefreshSettingWidgets then f.RefreshSettingWidgets() end
            if UI.ApplySettingsToFrames then UI:ApplySettingsToFrames() end
            if UI.Refresh then UI:Refresh() end
            return
        end
        if OM.ClearAllWindowSettings then OM:ClearAllWindowSettings() end
        OM:SetSetting("columnConfig", nil)
        OM:SetSetting("modeColors", nil)
        OM:SetSetting("modeEnabled", nil)
        OM:SetSetting("abbreviateNames", false)
        if f.abvCb then f.abvCb:SetChecked(nil) end

        -- Restore scalar defaults and window positions
        local hideKeys = {
            "hideHeaderReset", "hideHeaderAnnounce", "hideHeaderName",
            "hideHeaderSegment", "hideHeaderMode", "hideHeaderWindows",
            "partyJoinReset", "partyLeaveReset",
        }
        local hk
        for hk = 1, table.getn(hideKeys) do
            local key = hideKeys[hk]
            local def = OM.defaults and OM.defaults[key]
            OM:SetSetting(key, def and true or false)
        end
        if UI.ResetFramePositions then
            UI:ResetFramePositions()
        end

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
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00GreedMeter:|r Settings reset to defaults. Windows centered.")
    end)
    if reset then
        reset:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 12, 12)
    end

    f:SetScript("OnHide", function()
        HidePalette()
    end)

    if UI.RefreshThreatVisibility then
        UI.RefreshThreatVisibility(f)
    end
end

UI.BuildSettingsExtraPages = BuildSettingsExtraPages

-- After pages exist, apply threat grey state once


function UI.RefreshThreatVisibility(f)
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
            SafeSetEnabled(row.colorBtn, threatOn)
            SafeSetEnabled(row.enabledCb, threatOn)
            local c
            for c = 1, table.getn(row.checkboxes) do
                SafeSetEnabled(row.checkboxes[c], threatOn)
            end
            SafeSetEnabled(row.petThreatCb, threatOn)
            SafeSetEnabled(row.petAsTankCb, threatOn)
            SafeSetEnabled(row.threatWarnSoundCb, threatOn)
            SafeSetEnabled(row.threatWarnGlowCb, threatOn)
            SafeSetEnabled(row.threatWarnSlider, threatOn)
            if row.threatWarnSoundDD then
                local soundOn = threatOn and OM:GetSetting("threatWarnSound") == true
                SyncDropDownEnabled(row.threatWarnSoundDD, soundOn)
            end
        end
    end
end

function UI:ToggleCustomization()
    -- Opens Settings on the Display tab
    EnsureDefaults()
    if not OM.db and OM.InitDB then
        OM:InitDB()
    end
    local f = self:CreateSettingsFrame()
    if f:IsShown() and f.activeTab == "display" then
        HidePalette()
        f:Hide()
        return
    end
    if f.SelectTab then f.SelectTab("display") end
    HidePalette()
    if UI.CloseDropdown then UI.CloseDropdown() end
    f:Show()
end

GreedMeter.UI = UI


OM:RegisterModule("UI", UI)
