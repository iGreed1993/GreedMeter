--[[
    GreedMeter - UI / Frames
    Meter windows, bars, refresh, multi-frame.
]]

local OM = GreedMeter
local UI = GreedMeter.UI

local MAX_BARS = UI.MAX_BARS
local BAR_GAP = UI.BAR_GAP
local HEADER_HEIGHT = UI.HEADER_HEIGHT
local FOOTER_HEIGHT = UI.FOOTER_HEIGHT
local MAX_FRAMES = UI.MAX_FRAMES
local MIN_FRAME_WIDTH = UI.MIN_FRAME_WIDTH
local MAX_FRAME_WIDTH = UI.MAX_FRAME_WIDTH
local MIN_FRAME_HEIGHT = UI.MIN_FRAME_HEIGHT
local MAX_FRAME_HEIGHT = UI.MAX_FRAME_HEIGHT
local MODE_ORDER = UI.MODE_ORDER
local MODE_LABELS = UI.MODE_LABELS

local GetClassColor = UI.GetClassColor
local GetBarHeight = UI.GetBarHeight
local GetBarTexture = UI.GetBarTexture
local GetBarFontPath = UI.GetBarFontPath
local GetFontSize = UI.GetFontSize
local FramesLocked = UI.FramesLocked
local FormatNumber = UI.FormatNumber
local CreateButton = UI.CreateButton
local GetSegmentData = UI.GetSegmentData
local GetMetric = UI.GetMetric
local GetSecondaryText = UI.GetSecondaryText
local GetSegmentDuration = UI.GetSegmentDuration
local BuildSortedList = UI.BuildSortedList
local CloseDropdown = UI.CloseDropdown
local ShowDropdown = UI.ShowDropdown
local ShowBarTooltip = UI.ShowBarTooltip

function UI:SaveAllFrameLayouts()
    if not OM.GetLayoutDB then return end
    local layoutDB = OM:GetLayoutDB()
    if not layoutDB then return end
    layoutDB.frames = {}
    local i, f
    for i, f in ipairs(self.frames) do
        if f and f:GetLeft() then
            local point, _, relativePoint, x, y = f:GetPoint(1)
            local entry = {
                point = point or "CENTER",
                relativePoint = relativePoint or "CENTER",
                x = x or 0,
                y = y or 0,
                width = f:GetWidth(),
                height = f:GetHeight(),
                mode = f.mode or "damage",
                shown = f:IsShown() and true or false,
            }
            -- Persist segment only for Current / Overall (fight segments are ephemeral)
            local seg = f.segment or "current"
            if seg == "current" or seg == "overall" then
                entry.segment = seg
            end
            layoutDB.frames[i] = entry
        end
    end
end

function UI:ApplySavedLayout(f, index)
    if not f or not OM.GetLayoutDB then return false end
    local layoutDB = OM:GetLayoutDB()
    local saved = layoutDB and layoutDB.frames and layoutDB.frames[index]
    if not saved then return false end
    if saved.width then f:SetWidth(saved.width) end
    if saved.height then f:SetHeight(saved.height) end
    if saved.mode then f.mode = saved.mode end
    if saved.segment == "current" or saved.segment == "overall" then
        f.segment = saved.segment
    end
    f:ClearAllPoints()
    f:SetPoint(saved.point or "CENTER", UIParent, saved.relativePoint or "CENTER", saved.x or 0, saved.y or 0)
    return true
end


local function StyleClickableHeaderBtn(btn)
    if not btn then return end
    btn:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 8, edgeSize = 8,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    btn:SetBackdropColor(0.15, 0.15, 0.15, 0.75)
    btn:SetBackdropBorderColor(0.55, 0.55, 0.55, 1)
    btn:SetHeight(16)
end

-- Size gray box to the text inside it
local function FitHeaderBtn(btn, label)
    if not btn or not label then return end
    local text = label:GetText() or ""
    local w = 0
    if label.GetStringWidth then
        w = label:GetStringWidth() or 0
    end
    if not w or w < 1 then
        w = string.len(text) * 6
    end
    local width = w + 10
    if width < 28 then width = 28 end
    if width > 120 then width = 120 end
    btn:SetWidth(width)
end

local function FitAllHeaderBtns(f)
    if not f then return end
    FitHeaderBtn(f.nameBtn, f.nameLabel)
    FitHeaderBtn(f.modeBtn, f.modeLabel)
    FitHeaderBtn(f.segBtn, f.segLabel)
    FitHeaderBtn(f.resetBtn, f.resetLabel)
    FitHeaderBtn(f.announceBtn, f.announceLabel)
    FitHeaderBtn(f.addBtn, f.addLabel)
    FitHeaderBtn(f.removeBtn, f.removeLabel)
end

function UI:CreateMeterFrame(isPrimary, copyFrom)
    local id = self.nextFrameId
    self.nextFrameId = self.nextFrameId + 1

    local layoutIndex = table.getn(self.frames) + 1
    local fw, fh = 240, 280
    -- Prefer dimensions of the frame that spawned us (+ button)
    if copyFrom then
        fw = copyFrom:GetWidth() or fw
        fh = copyFrom:GetHeight() or fh
    elseif OM.GetLayoutDB then
        local layoutDB = OM:GetLayoutDB()
        local saved = layoutDB and layoutDB.frames and layoutDB.frames[layoutIndex]
        if saved then
            fw = saved.width or fw
            fh = saved.height or fh
        end
    end

    local name = "GreedMeterFrame"..id
    local f = CreateFrame("Frame", name, UIParent)
    f:SetWidth(fw)
    f:SetHeight(fh)
    f:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    f:SetBackdropColor(0, 0, 0, 0.80)
    f:SetBackdropBorderColor(0.35, 0.35, 0.35, 1)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function()
        if FramesLocked() then return end
        CloseDropdown()
        this:StartMoving()
    end)
    f:SetScript("OnDragStop", function()
        this:StopMovingOrSizing()
        UI:SaveAllFrameLayouts()
    end)
    f:SetClampedToScreen(true)

    f.frameId = id
    f.layoutIndex = layoutIndex
    f.isPrimary = isPrimary and true or false
    f.mode = "damage"
    f.segment = "current"
    f.bars = {}
    f.scrollOffset = 0

    -- Position from char DB or default cascade
    if not self:ApplySavedLayout(f, layoutIndex) then
        local offset = (id - 1) * 30
        f:SetPoint("CENTER", UIParent, "CENTER", offset, offset)
    end

    -- Mouse wheel scroll through the list
    f:EnableMouseWheel(true)
    f:SetScript("OnMouseWheel", function()
        local delta = arg1 -- 1 = up, -1 = down
        if not delta then return end
        local maxOff = f.maxScroll or 0
        local off = f.scrollOffset or 0
        if delta > 0 then
            off = off - 1
        else
            off = off + 1
        end
        if off < 0 then off = 0 end
        if off > maxOff then off = maxOff end
        f.scrollOffset = off
        UI:RefreshFrame(f)
    end)

    f.hiddenNames = {}

    -- Resize grip (bottom-right) with dark square marker
    local grip = CreateFrame("Button", nil, f)
    grip:SetWidth(14)
    grip:SetHeight(14)
    grip:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -2, 2)
    grip:SetFrameLevel(f:GetFrameLevel() + 5)
    local gripBg = grip:CreateTexture(nil, "BACKGROUND")
    gripBg:SetAllPoints(grip)
    gripBg:SetTexture(0.1, 0.1, 0.1, 0.95)
    local gripTex = grip:CreateTexture(nil, "ARTWORK")
    gripTex:SetAllPoints(grip)
    gripTex:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetScript("OnMouseDown", function()
        if FramesLocked() then return end
        this.sizing = true
        this.startX, this.startY = GetCursorPosition()
        this.startW = f:GetWidth()
        this.startH = f:GetHeight()
        this.scale = f:GetEffectiveScale()
    end)
    grip:SetScript("OnMouseUp", function()
        this.sizing = nil
        UI:SaveAllFrameLayouts()
    end)
    grip:SetScript("OnUpdate", function()
        if not this.sizing then return end
        local x, y = GetCursorPosition()
        local scale = this.scale or 1
        local dx = (x - this.startX) / scale
        local dy = (y - this.startY) / scale
        -- bottom-right: right = wider, down = taller (screen y decreases downward)
        local newW = this.startW + dx
        local newH = this.startH - dy
        if newW < MIN_FRAME_WIDTH then newW = MIN_FRAME_WIDTH end
        if newW > MAX_FRAME_WIDTH then newW = MAX_FRAME_WIDTH end
        if newH < MIN_FRAME_HEIGHT then newH = MIN_FRAME_HEIGHT end
        if newH > MAX_FRAME_HEIGHT then newH = MAX_FRAME_HEIGHT end
        f:SetWidth(newW)
        f:SetHeight(newH)
        UI:LayoutBars(f)
        UI:RefreshFrame(f)
    end)
    f.resizeGrip = grip

    -- Title + duration underneath
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", f, "TOP", 0, -4)
    title:SetText("Damage")
    f.title = title

    -- Duration is tooltip-only now (no header display)
    local durationLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    durationLabel:SetText("")
    durationLabel:Hide()
    f.durationLabel = durationLabel

    -- Reset button (gray box like other header controls)
    local resetBtn = CreateFrame("Button", nil, f)
    resetBtn:SetWidth(40)
    resetBtn:SetHeight(16)
    resetBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 6, -4)
    local resetLabel = resetBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    resetLabel:SetAllPoints(resetBtn)
    resetLabel:SetJustifyH("CENTER")
    resetLabel:SetText("Reset")
    f.resetLabel = resetLabel
    f.resetBtn = resetBtn
    StyleClickableHeaderBtn(resetBtn)
    local function DoReset()
        if OM.data then
            OM.data.current = { players = {}, startTime = 0, endTime = 0, label = "Current", isBoss = false, duration = 0 }
            OM.data.overall = { players = {}, startTime = 0, endTime = 0, label = "Overall", isBoss = false, duration = 0 }
            OM.data.recentFights = {}
            OM.data.bossFights = {}
        end
        if OM.SetSetting then OM:SetSetting("testMode", false) end
        if OM.UpdateGroupRoster then OM:UpdateGroupRoster() end
        OM:Fire("OnReset")
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00GreedMeter:|r Data reset.")
    end
    resetBtn:SetScript("OnClick", function()
        if OM.GetSetting and OM:GetSetting("confirmReset") then
            StaticPopupDialogs["GREEDMETER_CONFIRM_RESET"] = {
                text = "Reset all GreedMeter data?",
                button1 = "Yes",
                button2 = "No",
                OnAccept = function()
                    DoReset()
                end,
                timeout = 0,
                whileDead = 1,
                hideOnEscape = 1,
                exclusive = 1,
            }
            StaticPopup_Show("GREEDMETER_CONFIRM_RESET")
        else
            DoReset()
        end
    end)
    resetBtn:SetScript("OnEnter", function()
        GameTooltip:SetOwner(resetBtn, "ANCHOR_BOTTOM")
        GameTooltip:SetText("Reset", 1, 1, 1)
        GameTooltip:AddLine("Clear all recorded combat data", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    resetBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Right side: Segment on top, Mode below
    local segBtn = CreateFrame("Button", nil, f)
    segBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -4)
    segBtn:SetWidth(110)
    segBtn:SetHeight(14)
    segBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    local segLabel = segBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    segLabel:SetAllPoints(segBtn)
    segLabel:SetJustifyH("CENTER")
    segLabel:SetText("Current")
    f.segLabel = segLabel
    segBtn:SetScript("OnClick", function()
        local opts = {}
        for _, entry in ipairs(UI:GetSegmentList()) do
            table.insert(opts, { value = entry.key, label = entry.label })
        end
        ShowDropdown(segBtn, opts, function(value, label)
            f.segment = value
            segLabel:SetText(UI:SegmentLabel(value))
            UI:RefreshFrame(f)
            UI:SaveAllFrameLayouts()
        end)
    end)
    segBtn:SetScript("OnEnter", function()
        GameTooltip:SetOwner(segBtn, "ANCHOR_BOTTOM")
        GameTooltip:SetText("Segment", 1, 1, 1)
        GameTooltip:AddLine("Click to change segment", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    segBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.segBtn = segBtn
    StyleClickableHeaderBtn(segBtn)

    local modeBtn = CreateFrame("Button", nil, f)
    modeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -18)
    modeBtn:SetWidth(110)
    modeBtn:SetHeight(14)
    modeBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    local modeLabel = modeBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    modeLabel:SetAllPoints(modeBtn)
    modeLabel:SetJustifyH("CENTER")
    modeLabel:SetText("Mode")
    f.modeLabel = modeLabel
    modeBtn:SetScript("OnClick", function()
        local opts = {}
        for _, key in ipairs(MODE_ORDER) do
            table.insert(opts, { value = key, label = MODE_LABELS[key] })
        end
        ShowDropdown(modeBtn, opts, function(value, label)
            f.mode = value
            local compact = OM.GetSetting and OM:GetSetting("hideTitle") == true
            if compact then
                modeLabel:SetText(label)
            else
                modeLabel:SetText("Mode")
                if f.title then
                    f.title:SetText(label)
                end
            end
            UI:RefreshFrame(f)
            UI:SaveAllFrameLayouts()
        end)
    end)
    modeBtn:SetScript("OnEnter", function()
        GameTooltip:SetOwner(modeBtn, "ANCHOR_BOTTOM")
        GameTooltip:SetText("Mode", 1, 1, 1)
        GameTooltip:AddLine("Click to change mode", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    modeBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.modeBtn = modeBtn
    StyleClickableHeaderBtn(modeBtn)

    -- Left side: Name filter
    local nameBtn = CreateFrame("Button", nil, f)
    nameBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 6, -18)
    nameBtn:SetWidth(110)
    nameBtn:SetHeight(14)
    nameBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    local nameLabel = nameBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    nameLabel:SetAllPoints(nameBtn)
    nameLabel:SetJustifyH("CENTER")
    nameLabel:SetText("Name")
    f.nameLabel = nameLabel
    f.nameBtn = nameBtn
    nameBtn:SetScript("OnClick", function()
        UI:ShowNameFilterMenu(f, nameBtn)
    end)
    nameBtn:SetScript("OnEnter", function()
        GameTooltip:SetOwner(nameBtn, "ANCHOR_BOTTOM")
        GameTooltip:SetText("Name filter", 1, 1, 1)
        GameTooltip:AddLine("Click to show/hide players", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    nameBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.nameBtn = nameBtn
    StyleClickableHeaderBtn(nameBtn)

    -- Status bars (up to 40 for full raid; layout decides how many fit)
    local barParent = CreateFrame("Frame", nil, f)
    barParent:SetPoint("TOPLEFT", f, "TOPLEFT", 6, -HEADER_HEIGHT)
    barParent:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -6, FOOTER_HEIGHT)
    f.barParent = barParent
    barParent:EnableMouse(true)
    barParent:EnableMouseWheel(true)
    -- Allow drag from the bar area (children otherwise steal mouse from the frame)
    barParent:RegisterForDrag("LeftButton")
    barParent:SetScript("OnDragStart", function()
        if FramesLocked() then return end
        CloseDropdown()
        f:StartMoving()
    end)
    barParent:SetScript("OnDragStop", function()
        f:StopMovingOrSizing()
        UI:SaveAllFrameLayouts()
    end)
    barParent:SetScript("OnMouseWheel", function()
        local delta = arg1
        if not delta then return end
        local maxOff = f.maxScroll or 0
        local off = f.scrollOffset or 0
        if delta > 0 then
            off = off - 1
        else
            off = off + 1
        end
        if off < 0 then off = 0 end
        if off > maxOff then off = maxOff end
        f.scrollOffset = off
        UI:RefreshFrame(f)
    end)

    local barH = GetBarHeight()
    for i = 1, MAX_BARS do
        local bar = CreateFrame("StatusBar", nil, barParent)
        bar:SetHeight(barH)
        bar:SetWidth(100)
        bar:SetPoint("TOPLEFT", barParent, "TOPLEFT", 0, -((i - 1) * (barH + BAR_GAP)))
        local tex = (GetBarTexture and GetBarTexture()) or "Interface\\TargetingFrame\\UI-StatusBar"
        bar:SetStatusBarTexture(tex)
        bar:SetMinMaxValues(0, 1)
        bar:SetValue(0)
        bar:SetStatusBarColor(0.6, 0.6, 0.6)

        local bg = bar:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints(bar)
        bg:SetTexture(tex)
        bg:SetVertexColor(0.15, 0.15, 0.15, 0.85)
        bar.bg = bg

        -- Optional class icon (size tracks bar height)
        local classIcon = bar:CreateTexture(nil, "OVERLAY")
        classIcon:SetWidth(barH)
        classIcon:SetHeight(barH)
        classIcon:SetPoint("LEFT", bar, "LEFT", 0, 0)
        classIcon:Hide()
        bar.classIcon = classIcon

        local nameText = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        nameText:SetPoint("LEFT", bar, "LEFT", 4, 0)
        nameText:SetJustifyH("LEFT")
        nameText:SetText("")
        bar.nameText = nameText

        local valueText = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        valueText:SetPoint("RIGHT", bar, "RIGHT", -4, 0)
        valueText:SetJustifyH("RIGHT")
        valueText:SetText("")
        bar.valueText = valueText

        bar:EnableMouse(true)
        bar:RegisterForDrag("LeftButton")
        bar:SetScript("OnDragStart", function()
            if FramesLocked() then return end
            CloseDropdown()
            f:StartMoving()
        end)
        bar:SetScript("OnDragStop", function()
            f:StopMovingOrSizing()
            UI:SaveAllFrameLayouts()
        end)
        bar:SetScript("OnEnter", function()
            ShowBarTooltip(bar)
        end)
        bar:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)

        bar:Hide()
        f.bars[i] = bar
    end

    -- Empty label
    local empty = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    empty:SetPoint("CENTER", barParent, "CENTER", 0, 0)
    empty:SetText("No data yet")
    f.emptyLabel = empty

    -- Header-style Announce (!!!)
    local announceBtn = CreateFrame("Button", nil, f)
    announceBtn:SetWidth(56)
    announceBtn:SetHeight(14)
    local announceLabel = announceBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    announceLabel:SetAllPoints(announceBtn)
    announceLabel:SetJustifyH("CENTER")
    announceLabel:SetText("Announce")
    f.announceLabel = announceLabel
    f.announceBtn = announceBtn
    StyleClickableHeaderBtn(announceBtn)
    announceBtn:SetScript("OnClick", function()
        if OM.GetSetting and OM:GetSetting("confirmAnnounce") then
            local modeName = (MODE_LABELS and MODE_LABELS[f.mode]) or f.mode or "meter"
            StaticPopupDialogs["GREEDMETER_CONFIRM_ANNOUNCE"] = {
                text = "Announce " .. modeName .. " to chat?",
                button1 = "Yes",
                button2 = "No",
                OnAccept = function()
                    UI:AnnounceFrame(f)
                end,
                timeout = 0,
                whileDead = 1,
                hideOnEscape = 1,
                exclusive = 1,
            }
            StaticPopup_Show("GREEDMETER_CONFIRM_ANNOUNCE")
        else
            UI:AnnounceFrame(f)
        end
    end)
    announceBtn:SetScript("OnEnter", function()
        GameTooltip:SetOwner(announceBtn, "ANCHOR_BOTTOM")
        GameTooltip:SetText("Announce", 1, 1, 1)
        GameTooltip:AddLine("Report this window to chat", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    announceBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Header-style + (primary) or - (extra windows)
    if isPrimary then
        local addBtn = CreateFrame("Button", nil, f)
        addBtn:SetWidth(22)
        addBtn:SetHeight(14)
        local addLabel = addBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        addLabel:SetAllPoints(addBtn)
        addLabel:SetJustifyH("CENTER")
        addLabel:SetText("+")
        f.addLabel = addLabel
        f.addBtn = addBtn
        StyleClickableHeaderBtn(addBtn)
        addBtn:SetScript("OnClick", function()
            UI:AddFrame(f)
        end)
        addBtn:SetScript("OnEnter", function()
            GameTooltip:SetOwner(addBtn, "ANCHOR_BOTTOM")
            GameTooltip:SetText("Add window", 1, 1, 1)
            GameTooltip:AddLine("Open another meter window", 0.7, 0.7, 0.7)
            GameTooltip:Show()
        end)
        addBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    else
        local removeBtn = CreateFrame("Button", nil, f)
        removeBtn:SetWidth(22)
        removeBtn:SetHeight(14)
        local removeLabel = removeBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        removeLabel:SetAllPoints(removeBtn)
        removeLabel:SetJustifyH("CENTER")
        removeLabel:SetText("-")
        f.removeLabel = removeLabel
        f.removeBtn = removeBtn
        StyleClickableHeaderBtn(removeBtn)
        removeBtn:SetScript("OnClick", function()
            UI:RemoveFrame(f)
        end)
        removeBtn:SetScript("OnEnter", function()
            GameTooltip:SetOwner(removeBtn, "ANCHOR_BOTTOM")
            GameTooltip:SetText("Remove window", 1, 1, 1)
            GameTooltip:Show()
        end)
        removeBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end

    local opacity = 1
    if OM.GetSetting then
        local pct = OM:GetSetting("frameOpacity") or 100
        opacity = pct / 100
        if opacity < 0.3 then opacity = 0.3 end
        if opacity > 1 then opacity = 1 end
    end
    f:SetAlpha(opacity)

    f:Hide()
    table.insert(self.frames, f)

    if isPrimary then
        self.mainFrame = f
    end

    return f
end

-- ============================================================
-- Layout / Refresh
-- ============================================================

-- Compact vs normal header (Hide Title setting)
function UI:ApplyHeaderLayout(f, hideTitle, duration)
    if not f then return end
    -- duration arg kept for API compat; no longer shown in header
    local headerH = hideTitle and 34 or HEADER_HEIGHT

    if f.durationLabel then
        f.durationLabel:Hide()
    end

    if f.title then
        local mode = f.mode or "damage"
        f.title:SetText(MODE_LABELS[mode] or mode)
        if hideTitle then
            f.title:Hide()
        else
            f.title:Show()
        end
    end

    -- Shared anchors
    if f.resetBtn then
        f.resetBtn:ClearAllPoints()
        f.resetBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 4, -3)
        f.resetBtn:Show()
    end
    if f.segBtn then
        f.segBtn:ClearAllPoints()
        f.segBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -3)
        if f.segLabel then f.segLabel:SetJustifyH("CENTER") end
    end
    if f.nameBtn then
        f.nameBtn:ClearAllPoints()
        f.nameBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 4, -18)
        if f.nameLabel then f.nameLabel:SetJustifyH("CENTER") end
    end
    if f.modeBtn then
        f.modeBtn:ClearAllPoints()
        f.modeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -18)
        if f.modeLabel then
            f.modeLabel:SetJustifyH("CENTER")
            if hideTitle then
                local mode = f.mode or "damage"
                f.modeLabel:SetText(MODE_LABELS[mode] or mode)
            else
                f.modeLabel:SetText("Mode")
            end
        end
    end

    if hideTitle then
        -- Compact:
        -- Row 1: Reset | Announce | Segment
        -- Row 2: Name | + | Mode
        if f.announceBtn then
            f.announceBtn:ClearAllPoints()
            f.announceBtn:SetPoint("TOP", f, "TOP", 0, -3)
            f.announceBtn:Show()
        end
        local midBtn = f.addBtn or f.removeBtn
        if midBtn then
            midBtn:ClearAllPoints()
            midBtn:SetPoint("TOP", f, "TOP", 0, -18)
            midBtn:Show()
        end
        if f.title then f.title:Hide() end
    else
        -- Default:
        -- Row 1: Reset | Title | Segment
        -- Row 2: Name | Announce | + | Mode
        if f.title then
            f.title:ClearAllPoints()
            f.title:SetPoint("TOP", f, "TOP", 0, -4)
            f.title:Show()
        end
        if f.announceBtn then
            f.announceBtn:ClearAllPoints()
            f.announceBtn:SetPoint("LEFT", f.nameBtn, "RIGHT", 4, 0)
            f.announceBtn:Show()
        end
        local midBtn = f.addBtn or f.removeBtn
        if midBtn then
            midBtn:ClearAllPoints()
            if f.announceBtn then
                midBtn:SetPoint("LEFT", f.announceBtn, "RIGHT", 4, 0)
            else
                midBtn:SetPoint("LEFT", f.nameBtn, "RIGHT", 4, 0)
            end
            midBtn:Show()
        end
    end

    FitAllHeaderBtns(f)

    if f.barParent then
        f.barParent:ClearAllPoints()
        f.barParent:SetPoint("TOPLEFT", f, "TOPLEFT", 6, -headerH)
        f.barParent:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -6, FOOTER_HEIGHT)
    end

    f.headerHeight = headerH
    self:LayoutBars(f)
end

function UI:LayoutBars(f)
    if not f or not f.bars then return end
    local barH = (GetBarHeight and GetBarHeight()) or 16
    local fontSize = (GetFontSize and GetFontSize()) or 11
    local width = (f:GetWidth() or 200) - 12
    if width < 40 then width = 40 end
    local headerH = f.headerHeight or HEADER_HEIGHT
    local avail = f:GetHeight() - headerH - FOOTER_HEIGHT - 4
    if avail < barH then avail = barH end
    local fit = math.floor(avail / (barH + BAR_GAP))
    if fit < 1 then fit = 1 end
    if fit > MAX_BARS then fit = MAX_BARS end
    f.visibleBars = fit

    local tex = (GetBarTexture and GetBarTexture()) or "Interface\\TargetingFrame\\UI-StatusBar"
    local fontPath = (GetBarFontPath and GetBarFontPath()) or STANDARD_TEXT_FONT

    local i
    for i = 1, MAX_BARS do
        local bar = f.bars[i]
        bar:SetHeight(barH)
        bar:SetWidth(width)
        bar:ClearAllPoints()
        bar:SetPoint("TOPLEFT", f.barParent, "TOPLEFT", 0, -((i - 1) * (barH + BAR_GAP)))
        bar:SetStatusBarTexture(tex)
        if bar.bg then
            bar.bg:SetTexture(tex)
            bar.bg:SetVertexColor(0.15, 0.15, 0.15, 0.85)
        end
        if bar.nameText then
            bar.nameText:SetFont(fontPath, fontSize)
        end
        if bar.valueText then
            bar.valueText:SetFont(fontPath, fontSize)
        end
    end
end

function UI:RefreshFrame(f)
    if not f then return end
    if not f.visibleBars then
        self:LayoutBars(f)
    end

    local barH = GetBarHeight and GetBarHeight() or 16
    local segment = GetSegmentData(f.segment)
    local mode = f.mode or "damage"

    local hideTitle = OM.GetSetting and OM:GetSetting("hideTitle") == true
    if f.modeLabel then
        if hideTitle then
            -- Compact: no title, so mode button shows the active mode name
            f.modeLabel:SetText(MODE_LABELS[mode] or mode)
        else
            f.modeLabel:SetText("Mode")
        end
    end
    if f.title and not hideTitle then
        f.title:SetText(MODE_LABELS[mode] or mode)
    end
    if f.segLabel then
        f.segLabel:SetText(self:SegmentLabel(f.segment))
    end
    FitAllHeaderBtns(f)

    local list = BuildSortedList(segment, mode, f.hiddenNames)

    -- Optional total bar (sum of all players)
    if OM.GetSetting and OM:GetSetting("showTotal") and table.getn(list) > 0 then
        local totalVal = 0
        local totalData = {
            damage = 0, healing = 0, overhealing = 0, rawHealing = 0,
            absorbs = 0, damageTaken = 0,
            dispels = { count = 0, list = {} },
            interrupts = { count = 0, list = {} },
            damageTakenBy = {},
        }
        local _, entry
        for _, entry in ipairs(list) do
            totalVal = totalVal + entry.value
            local d = entry.data
            totalData.damage = totalData.damage + (d.damage or 0)
            totalData.healing = totalData.healing + (d.healing or 0)
            totalData.overhealing = totalData.overhealing + (d.overhealing or 0)
            totalData.rawHealing = totalData.rawHealing + (d.rawHealing or 0)
            totalData.absorbs = totalData.absorbs + (d.absorbs or 0)
            totalData.damageTaken = totalData.damageTaken + (d.damageTaken or 0)
            totalData.dispels.count = totalData.dispels.count + ((d.dispels and d.dispels.count) or 0)
            totalData.interrupts.count = totalData.interrupts.count + ((d.interrupts and d.interrupts.count) or 0)
        end
        table.insert(list, {
            name = "Total",
            data = totalData,
            value = totalVal,
            isTotal = true,
        })
    end

    local maxVal = 0
    if table.getn(list) > 0 then
        -- max among non-total for bar scaling
        local _, entry
        for _, entry in ipairs(list) do
            if not entry.isTotal and entry.value > maxVal then
                maxVal = entry.value
            end
        end
        if maxVal <= 0 and list[1] then
            maxVal = list[1].value
        end
    end
    if maxVal <= 0 then maxVal = 1 end

    local duration = 0
    if GetSegmentDuration then
        duration = GetSegmentDuration(segment, f.segment)
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

    local hideTitle = OM.GetSetting and OM:GetSetting("hideTitle") == true
    self:ApplyHeaderLayout(f, hideTitle, duration)

    local fit = f.visibleBars or MAX_BARS
    local hasTotal = false
    local totalEntry = nil
    local playerList = {}
    local _, e
    for _, e in ipairs(list) do
        if e.isTotal then
            hasTotal = true
            totalEntry = e
        else
            table.insert(playerList, e)
        end
    end

    -- Reserve last visible slot for Total when enabled
    local playerSlots = fit
    if hasTotal and fit > 1 then
        playerSlots = fit - 1
    elseif hasTotal and fit == 1 then
        playerSlots = 0
    end

    -- Scroll: how far we can offset into the player list
    local playerCount = table.getn(playerList)
    local maxScroll = playerCount - playerSlots
    if maxScroll < 0 then maxScroll = 0 end
    f.maxScroll = maxScroll
    if not f.scrollOffset then f.scrollOffset = 0 end
    if f.scrollOffset > maxScroll then f.scrollOffset = maxScroll end
    if f.scrollOffset < 0 then f.scrollOffset = 0 end
    local scroll = f.scrollOffset

    -- Total for share %: full segment (including filtered names) so hiding
    -- someone does not inflate everyone else's percentage.
    local metricTotal = 0
    if mode == "damage" or mode == "healing" then
        if segment and segment.players then
            local n, d
            for n, d in pairs(segment.players) do
                metricTotal = metricTotal + (GetMetric(d, mode) or 0)
            end
        else
            local ti
            for ti = 1, table.getn(playerList) do
                metricTotal = metricTotal + (playerList[ti].value or 0)
            end
        end
    end

    local shown = 0
    local i
    for i = 1, MAX_BARS do
        local bar = f.bars[i]
        local entry = nil
        if i <= playerSlots then
            entry = playerList[i + scroll]
        elseif hasTotal and i == playerSlots + 1 then
            entry = totalEntry
        end

        if entry and i <= fit then
            shown = shown + 1
            local pct = entry.value / maxVal
            if pct > 1 then pct = 1 end
            if pct < 0 then pct = 0 end

            bar:Show()
            bar:SetValue(pct)
            if entry.isTotal then
                bar:SetStatusBarColor(0.9, 0.9, 0.9, 0.85)
                if bar.classIcon then bar.classIcon:Hide() end
                if bar.nameText then
                    bar.nameText:ClearAllPoints()
                    bar.nameText:SetPoint("LEFT", bar, "LEFT", 4, 0)
                    bar.nameText:SetText("Total")
                end
                -- Total row: no share %, still show amount and rate
                bar.valueText:SetText(GetSecondaryText(entry.data, mode, duration, nil))
            else
                local r, g, b = GetClassColor(entry.name, entry.data)
                bar:SetStatusBarColor(r, g, b, 0.9)
                local rank = entry.rank or (i + scroll)
                local showIcon = OM.GetSetting and OM:GetSetting("showClassIcons") and not entry.isEnemy
                if showIcon and bar.classIcon then
                    local class = nil
                    if entry.data and entry.data.class then
                        class = entry.data.class
                    elseif OM.players and OM.players[entry.name] then
                        class = OM.players[entry.name].class
                    end
                    local coords = UI.CLASS_ICON_TCOORDS and class and UI.CLASS_ICON_TCOORDS[class]
                    if coords then
                        bar.classIcon:SetWidth(barH)
                        bar.classIcon:SetHeight(barH)
                        bar.classIcon:SetTexture("Interface\\Glues\\CharacterCreate\\UI-CharacterCreate-Classes")
                        bar.classIcon:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
                        bar.classIcon:Show()
                        bar.nameText:ClearAllPoints()
                        bar.nameText:SetPoint("LEFT", bar.classIcon, "RIGHT", 2, 0)
                    else
                        bar.classIcon:Hide()
                        bar.nameText:ClearAllPoints()
                        bar.nameText:SetPoint("LEFT", bar, "LEFT", 4, 0)
                    end
                else
                    if bar.classIcon then bar.classIcon:Hide() end
                    bar.nameText:ClearAllPoints()
                    bar.nameText:SetPoint("LEFT", bar, "LEFT", 4, 0)
                end
                bar.nameText:SetText(rank .. ". " .. entry.name)
                bar.valueText:SetText(GetSecondaryText(entry.data, mode, duration, metricTotal))
            end
            bar.entry = entry
            bar.mode = mode
            bar.duration = duration
        else
            bar:Hide()
            bar.entry = nil
        end
    end

    if shown == 0 then
        f.emptyLabel:Show()
    else
        f.emptyLabel:Hide()
    end
end

function UI:ApplySettingsToFrames()
    local opacity = 1
    if OM.GetSetting then
        local pct = OM:GetSetting("frameOpacity") or 100
        opacity = pct / 100
        if opacity < 0.3 then opacity = 0.3 end
        if opacity > 1 then opacity = 1 end
    end
    local _, f
    for _, f in ipairs(self.frames) do
        f:SetAlpha(opacity)
        self:LayoutBars(f)
        if f:IsShown() then
            self:RefreshFrame(f)
        end
    end
end

function UI:Refresh()
    for _, f in ipairs(self.frames) do
        if f:IsShown() then
            self:RefreshFrame(f)
        end
    end
end

-- ============================================================
-- Multi-frame
-- ============================================================

function UI:AddFrame(sourceFrame)
    if table.getn(self.frames) >= MAX_FRAMES then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00GreedMeter:|r Maximum of " .. MAX_FRAMES .. " frames.")
        return
    end
    local copyFrom = sourceFrame or self.mainFrame
    local f = self:CreateMeterFrame(false, copyFrom)
    -- Default new frames to a different mode if possible
    local used = {}
    for _, fr in ipairs(self.frames) do
        used[fr.mode] = true
    end
    for _, key in ipairs(MODE_ORDER) do
        if not used[key] then
            f.mode = key
            break
        end
    end
    f:Show()
    self:RefreshFrame(f)
    self:SaveAllFrameLayouts()
end

function UI:RemoveFrame(f)
    if not f then return end
    if f.isPrimary then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00GreedMeter:|r Cannot remove the main frame.")
        return
    end
    CloseDropdown()
    f:Hide()
    local newList = {}
    for _, fr in ipairs(self.frames) do
        if fr ~= f then
            table.insert(newList, fr)
        end
    end
    self.frames = newList
    f:SetParent(nil)
    self:SaveAllFrameLayouts()
end

-- Restore extra frames from the active layout store (char or account-wide)
function UI:RestoreSavedFrames()
    if not OM.GetLayoutDB then return end
    local layoutDB = OM:GetLayoutDB()
    if not layoutDB or not layoutDB.frames then return end
    -- OnLoad fires on both PLAYER_LOGIN and PLAYER_ENTERING_WORLD; only restore once
    if table.getn(self.frames) > 1 then return end
    local i
    for i = 2, table.getn(layoutDB.frames) do
        if table.getn(self.frames) >= MAX_FRAMES then break end
        local saved = layoutDB.frames[i]
        if saved then
            local f = self:CreateMeterFrame(false)
            if saved.mode then f.mode = saved.mode end
            self:ApplySavedLayout(f, i)
            if saved.shown ~= false then
                f:Show()
            end
            self:RefreshFrame(f)
        end
    end
end

