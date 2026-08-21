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


-- ============================================================
-- Position clamping (no clamp-during-drag)
--
-- Some modded 1.12 clients (notably 4K + SuperWoW/Nampower) native-crash
-- with ACCESS_VIOLATION #132 when StartMoving() runs on a frame that has
-- SetClampedToScreen(true). Meter frames never use SetClampedToScreen.
--
-- We clamp in Lua after drag, after layout restore, and before saving so
-- positions stay on-screen across resolution/scale changes too.
-- ============================================================

-- Clamp using real on-screen edges (GetLeft/Right/Top/Bottom).
-- Avoid GetWidth/GetHeight vs UIParent:GetWidth — those mix local size with
-- screen coords and over-push on top/right under many UI scales.
local function ClampFrameToScreen(f)
    if not f or not f.GetLeft then return end
    local left = f:GetLeft()
    local right = f:GetRight()
    local top = f:GetTop()
    local bottom = f:GetBottom()
    if not left or not right or not top or not bottom then return end

    local parent = UIParent
    local screenLeft = parent:GetLeft() or 0
    local screenBottom = parent:GetBottom() or 0
    local screenRight = parent:GetRight()
    local screenTop = parent:GetTop()
    if not screenRight or not screenTop then return end

    -- Tiny pad so the border is not flush against the very edge (0 = flush OK)
    local pad = 0
    local dx, dy = 0, 0

    if left < screenLeft + pad then
        dx = (screenLeft + pad) - left
    elseif right > screenRight - pad then
        dx = (screenRight - pad) - right
    end

    if bottom < screenBottom + pad then
        dy = (screenBottom + pad) - bottom
    elseif top > screenTop - pad then
        dy = (screenTop - pad) - top
    end

    if dx ~= 0 or dy ~= 0 then
        f:ClearAllPoints()
        f:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", left + dx, bottom + dy)
    end
end
UI.ClampFrameToScreen = ClampFrameToScreen

-- Background-only opacity: header, bars, and text stay fully visible.
-- frameOpacity 0–100 maps to backdrop alpha 0–0.80 (matches default look at 100).
local BACKDROP_ALPHA_MAX = 0.80
local function ApplyFrameBackgroundOpacity(f)
    if not f or not f.SetBackdropColor then return end
    local pct = 100
    if OM.GetSetting then
        pct = OM:GetSetting("frameOpacity")
    end
    pct = tonumber(pct) or 100
    if pct < 0 then pct = 0 end
    if pct > 100 then pct = 100 end
    local a = BACKDROP_ALPHA_MAX * (pct / 100)
    -- Whole-frame alpha stays 1 so header/bars never dim with the background
    f:SetAlpha(1)
    f:SetBackdropColor(0, 0, 0, a)
    local borderA = 1
    if pct <= 0 then
        borderA = 0
    elseif pct < 30 then
        borderA = pct / 30
    end
    f:SetBackdropBorderColor(0.35, 0.35, 0.35, borderA)
    f._gmBgOpacityPct = pct
end
UI.ApplyFrameBackgroundOpacity = ApplyFrameBackgroundOpacity

local function SafeStartMoving(f)
    if not f then return end
    if f.SetClampedToScreen then
        f:SetClampedToScreen(false)
    end
    f._greedMeterDragging = true
    f:StartMoving()
end

local function SafeStopMoving(f)
    if not f then return end
    if f.IsMoving and f:IsMoving() then
        f:StopMovingOrSizing()
    else
        -- Still stop in case IsMoving is unavailable on some clients
        f:StopMovingOrSizing()
    end
    f._greedMeterDragging = nil
    ClampFrameToScreen(f)
end

function UI:SaveAllFrameLayouts()
    if not OM.GetLayoutDB then return end
    local layoutDB = OM:GetLayoutDB()
    if not layoutDB then return end
    layoutDB.frames = {}
    local i, f
    for i = 1, table.getn(self.frames) do local f = self.frames[i]
        if f and f:GetLeft() then
            -- Sanitize before persist (resolution changes, partial off-screen, etc.)
            ClampFrameToScreen(f)
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
    ClampFrameToScreen(f)
    return true
end

-- Restore all meter windows to a centered cascade (and center settings/customization).
-- Useful when a window ends up off-screen after resolution/scale changes.
function UI:ResetFramePositions()
    local i, f
    if self.frames then
        for i = 1, table.getn(self.frames) do local f = self.frames[i]
            if f then
                f:ClearAllPoints()
                local offset = (i - 1) * 30
                f:SetPoint("CENTER", UIParent, "CENTER", offset, offset)
                if ClampFrameToScreen then
                    ClampFrameToScreen(f)
                end
                f:Show()
            end
        end
    end

    if self.settingsFrame then
        self.settingsFrame:ClearAllPoints()
        self.settingsFrame:SetPoint("CENTER", UIParent, "CENTER", 120, 40)
    end

    if self.customizationFrame then
        self.customizationFrame:ClearAllPoints()
        self.customizationFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end

    if self.SaveAllFrameLayouts then
        self:SaveAllFrameLayouts()
    end
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

-- Shared header-button tooltip (title + optional subtitle).
local function SetHeaderBtnTooltip(btn, title, subtitle)
    if not btn then return end
    btn:SetScript("OnEnter", function()
        GameTooltip:SetOwner(btn, "ANCHOR_BOTTOM")
        GameTooltip:SetText(title or "", 1, 1, 1)
        if subtitle and subtitle ~= "" then
            GameTooltip:AddLine(subtitle, 0.7, 0.7, 0.7)
        end
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
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

-- First two letters of the first word (for compact header labels)
local function TwoLetter(text)
    if not text or text == "" then return "" end
    local word = text
    local _, _, w = string.find(text, "^(%S+)")
    if w then word = w end
    if string.len(word) <= 2 then return word end
    return string.sub(word, 1, 2)
end

local function IsCompactHeader()
    return OM.GetSetting and OM:GetSetting("hideTitle") == true
end

local function KeepTitleInCompact()
    return OM.GetSetting and OM:GetSetting("keepTitleInCompact") == true
end

local function CompactTitleAlign()
    local a = OM.GetSetting and OM:GetSetting("compactTitleAlign")
    if a == "LEFT" or a == "RIGHT" or a == "CENTER" then
        return a
    end
    return "CENTER"
end

local function HideBarBackgrounds()
    return OM.GetSetting and OM:GetSetting("hideBarBackgrounds") == true
end

local function EffectiveFooterHeight()
    -- Locked frames hide the resize grip; keep only a tight 1px bottom gap
    if FramesLocked and FramesLocked() then
        return 1
    end
    return FOOTER_HEIGHT or 10
end

-- Compact mode abbreviations when title is hidden
local MODE_COMPACT = {
    damage = "Da",
    healing = "He",
    dispels = "Di",
    taken = "DT",
    interrupts = "In",
    cc = "CC",
    ccbreak = "CCb",
    deaths = "De",
    threat = "Th",
    tank = "Tnk",
    overall = "ThO",
}

-- Mode tint colors come from Advanced Customization (UI.GetModeColor).
-- Fallback table only used if Advanced/Init helpers are not loaded yet.
local MODE_BTN_COLORS_FALLBACK = {
    damage     = { 1.00, 0.55, 0.10 },
    healing    = { 0.20, 0.85, 0.30 },
    interrupts = { 1.00, 0.90, 0.20 },
    dispels    = { 1.00, 0.40, 0.75 },
    cc         = { 0.30, 0.55, 1.00 },
    ccbreak    = { 0.70, 0.35, 0.95 },
    deaths     = { 0.95, 0.20, 0.20 },
    taken      = { 0.15, 0.85, 0.85 },
    threat     = { 0.95, 0.88, 0.55 },
    tank       = { 0.95, 0.88, 0.55 },
    overall    = { 0.95, 0.88, 0.55 },
}

local function ResolveModeColor(mode)
    if UI.GetModeColor then
        return UI.GetModeColor(mode)
    end
    return MODE_BTN_COLORS_FALLBACK[mode or "damage"]
end

local DEFAULT_BTN_BG = { 0.15, 0.15, 0.15, 0.75 }
local DEFAULT_BTN_BORDER = { 0.55, 0.55, 0.55, 1 }

local function ApplyHeaderButtonColors(f)
    if not f then return end
    local enabled = OM.GetSetting and OM:GetSetting("buttonsColorWithMode") == true
    local mode = f.mode or "damage"
    local col = ResolveModeColor(mode)

    local function tint(btn)
        if not btn then return end
        if enabled and col then
            -- Soft fill + stronger border reads as a colored glow behind the label
            btn:SetBackdropColor(col[1], col[2], col[3], 0.40)
            btn:SetBackdropBorderColor(col[1], col[2], col[3], 0.95)
        else
            btn:SetBackdropColor(DEFAULT_BTN_BG[1], DEFAULT_BTN_BG[2], DEFAULT_BTN_BG[3], DEFAULT_BTN_BG[4])
            btn:SetBackdropBorderColor(DEFAULT_BTN_BORDER[1], DEFAULT_BTN_BORDER[2], DEFAULT_BTN_BORDER[3], DEFAULT_BTN_BORDER[4])
        end
    end

    -- All header controls take the mode glow
    tint(f.resetBtn)
    tint(f.nameBtn)
    tint(f.announceBtn)
    tint(f.addBtn)
    tint(f.removeBtn)
    tint(f.segBtn)
    tint(f.modeBtn)
end

local function ApplyHeaderButtonLabels(f)
    if not f then return end
    local compact = IsCompactHeader()
    local keepTitle = compact and KeepTitleInCompact()

    if f.resetLabel then
        f.resetLabel:SetText(compact and "Re" or "Reset")
    end
    if f.announceLabel then
        f.announceLabel:SetText(compact and "An" or "Announce")
    end
    if f.nameLabel then
        f.nameLabel:SetText(compact and "Na" or "Name")
    end
    if f.modeLabel then
        if compact and not keepTitle then
            local mode = f.mode or "damage"
            f.modeLabel:SetText(MODE_COMPACT[mode] or TwoLetter(MODE_LABELS[mode] or mode))
        else
            -- Normal header, or compact with title kept: always "Mode"
            f.modeLabel:SetText("Mode")
        end
    end
    if f.segLabel then
        local full = UI:SegmentLabel(f.segment)
        if compact then
            f.segLabel:SetText(TwoLetter(full))
        else
            f.segLabel:SetText(full)
        end
    end
    -- + / - stay as-is
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
    -- Opacity applied from saved setting (not hard-coded 0.80)
    ApplyFrameBackgroundOpacity(f)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function()
        if FramesLocked() then return end
        CloseDropdown()
        SafeStartMoving(this)
    end)
    f:SetScript("OnDragStop", function()
        SafeStopMoving(this)
        UI:SaveAllFrameLayouts()
    end)
    -- If the frame is hidden mid-drag (party change, etc.), finish the move cleanly
    f:SetScript("OnHide", function()
        if this._greedMeterDragging then
            SafeStopMoving(this)
        end
    end)
    -- SetClampedToScreen avoided (unsafe with StartMoving on some clients)

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
        -- Min height: header + one bar + footer padding
        local headerH = f.headerHeight or HEADER_HEIGHT
        local barH = (GetBarHeight and GetBarHeight()) or 16
        local footer = EffectiveFooterHeight()
        local minH = headerH + barH + footer + 4
        if minH < 40 then minH = 40 end
        if newH < minH then newH = minH end
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
        if OM.ResetData then
            OM:ResetData()
        else
            OM:Fire("OnReset")
        end
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
    SetHeaderBtnTooltip(resetBtn, "Reset", "Clear all recorded combat data")

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
        local segList = UI:GetSegmentList()
        for _gi = 1, table.getn(segList) do local entry = segList[_gi]
            table.insert(opts, { value = entry.key, label = entry.label })
        end
        ShowDropdown(segBtn, opts, function(value, label)
            f.segment = value
            segLabel:SetText(UI:SegmentLabel(value))
            UI:RefreshFrame(f)
            UI:SaveAllFrameLayouts()
        end)
    end)
    SetHeaderBtnTooltip(segBtn, "Segment", "Click to change segment")
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
        for _gi = 1, table.getn(MODE_ORDER) do local key = MODE_ORDER[_gi]
            -- Hide modes the user disabled in Advanced Customization
            if UI.IsModeEnabled and not UI.IsModeEnabled(key) then
                -- skip
            else
                table.insert(opts, { value = key, label = MODE_LABELS[key] or key })
            end
        end
        if table.getn(opts) == 0 then
            table.insert(opts, { value = "damage", label = MODE_LABELS.damage or "Damage" })
        end
        ShowDropdown(modeBtn, opts, function(value, label)
            f.mode = value
            if f.title then
                f.title:SetText(label)
            end
            -- Labels (including compact abbreviations) refreshed in ApplyHeaderLayout
            UI:RefreshFrame(f)
            UI:SaveAllFrameLayouts()
        end)
    end)
    SetHeaderBtnTooltip(modeBtn, "Mode", "Click to change mode")
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
    SetHeaderBtnTooltip(nameBtn, "Name filter", "Click to show/hide players")
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
        SafeStartMoving(f)
    end)
    barParent:SetScript("OnDragStop", function()
        SafeStopMoving(f)
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
        if OM.GetSetting and OM:GetSetting("hideBarBackgrounds") == true then
            bg:Hide()
        end

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
            this._gmDragged = true
            if FramesLocked() then return end
            CloseDropdown()
            SafeStartMoving(f)
        end)
        bar:SetScript("OnDragStop", function()
            SafeStopMoving(f)
            UI:SaveAllFrameLayouts()
        end)
        bar:SetScript("OnEnter", function()
            ShowBarTooltip(bar)
        end)
        bar:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)
        bar:SetScript("OnMouseDown", function()
            this._gmClickX, this._gmClickY = GetCursorPosition()
            this._gmDragged = nil
        end)
        bar:SetScript("OnMouseUp", function()
            if arg1 ~= "LeftButton" then return end
            -- Real drag (window move) — do not open detail
            if this._gmDragged then
                this._gmDragged = nil
                return
            end
            local x, y = GetCursorPosition()
            local ox, oy = this._gmClickX, this._gmClickY
            if ox and oy and x and y then
                local dx = x - ox
                local dy = y - oy
                if dx < 0 then dx = -dx end
                if dy < 0 then dy = -dy end
                -- Cursor coords are screen pixels; keep threshold scale-aware so
                -- high-res clients are not treated as drags on tiny jitter
                local scale = 1
                if UIParent and UIParent.GetEffectiveScale then
                    scale = UIParent:GetEffectiveScale() or 1
                end
                if scale < 0.5 then scale = 0.5 end
                local thresh = 24 * scale
                if thresh < 16 then thresh = 16 end
                if dx > thresh or dy > thresh then return end
            end
            if not this.entry or this.entry.isTotal or this.isDurationRow then
                return
            end
            if not OM.GetSetting or not OM:GetSetting("detailedDamage") then
                if not UI._detailHintShown then
                    UI._detailHintShown = true
                    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00GreedMeter:|r Enable |cffffffffDetailed damage/healing|r in Customization, then click a player bar.")
                end
                return
            end
            if UI.ShowPlayerDetail then
                UI:ShowPlayerDetail(this.entry, f.segment, f.mode or "damage")
            end
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
    SetHeaderBtnTooltip(announceBtn, "Announce", "Report this window to chat")

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
        SetHeaderBtnTooltip(addBtn, "Add window", "Open another meter window")
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
        SetHeaderBtnTooltip(removeBtn, "Remove window")
    end

    ApplyFrameBackgroundOpacity(f)

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
    local compact = hideTitle and true or false
    local keepTitle = compact and KeepTitleInCompact()
    local COMPACT_ROW = 20
    local TITLE_ROW = 18
    local headerH
    if compact then
        if keepTitle then
            headerH = TITLE_ROW + COMPACT_ROW
        else
            headerH = COMPACT_ROW
        end
    else
        headerH = HEADER_HEIGHT
    end

    if f.durationLabel then
        f.durationLabel:Hide()
    end

    ApplyHeaderButtonLabels(f)

    if f.title then
        local mode = f.mode or "damage"
        f.title:SetText(MODE_LABELS[mode] or mode)
        if compact and not keepTitle then
            f.title:Hide()
        else
            f.title:Show()
        end
    end

    local footer = EffectiveFooterHeight()

    if compact then
        -- One control row (optionally under a title row)
        local rowY = keepTitle and -(TITLE_ROW + 1) or -2

        if keepTitle and f.title then
            f.title:ClearAllPoints()
            local align = CompactTitleAlign()
            if align == "LEFT" then
                f.title:SetPoint("TOPLEFT", f, "TOPLEFT", 6, -2)
                f.title:SetJustifyH("LEFT")
            elseif align == "RIGHT" then
                f.title:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -2)
                f.title:SetJustifyH("RIGHT")
            else
                f.title:SetPoint("TOP", f, "TOP", 0, -2)
                f.title:SetJustifyH("CENTER")
            end
            f.title:Show()
        end

        -- Left cluster: Re  An  +  Na
        if f.resetBtn then
            f.resetBtn:ClearAllPoints()
            f.resetBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 4, rowY)
            f.resetBtn:Show()
        end
        if f.announceBtn then
            f.announceBtn:ClearAllPoints()
            f.announceBtn:SetPoint("LEFT", f.resetBtn, "RIGHT", 3, 0)
            f.announceBtn:Show()
        end
        local midBtn = f.addBtn or f.removeBtn
        if midBtn then
            midBtn:ClearAllPoints()
            if f.announceBtn then
                midBtn:SetPoint("LEFT", f.announceBtn, "RIGHT", 3, 0)
            else
                midBtn:SetPoint("LEFT", f.resetBtn, "RIGHT", 3, 0)
            end
            midBtn:Show()
        end
        if f.nameBtn then
            f.nameBtn:ClearAllPoints()
            if midBtn then
                f.nameBtn:SetPoint("LEFT", midBtn, "RIGHT", 3, 0)
            else
                f.nameBtn:SetPoint("LEFT", f.announceBtn or f.resetBtn, "RIGHT", 3, 0)
            end
            if f.nameLabel then f.nameLabel:SetJustifyH("CENTER") end
        end

        -- Right cluster: Se  Mo
        if f.modeBtn then
            f.modeBtn:ClearAllPoints()
            f.modeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, rowY)
            if f.modeLabel then f.modeLabel:SetJustifyH("CENTER") end
        end
        if f.segBtn then
            f.segBtn:ClearAllPoints()
            f.segBtn:SetPoint("RIGHT", f.modeBtn, "LEFT", -3, 0)
            if f.segLabel then f.segLabel:SetJustifyH("CENTER") end
        end
    else
        -- Default two-row header
        -- Row 1: Reset | Title | Segment
        -- Row 2: Name | Announce | + | Mode
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
                f.modeLabel:SetText("Mode")
            end
        end
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
    ApplyHeaderButtonColors(f)

    if f.barParent then
        f.barParent:ClearAllPoints()
        f.barParent:SetPoint("TOPLEFT", f, "TOPLEFT", 6, -headerH)
        f.barParent:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -6, footer)
    end

    -- Resize grip visibility follows lock
    if f.resizeGrip then
        if FramesLocked and FramesLocked() then
            f.resizeGrip:Hide()
        else
            f.resizeGrip:Show()
        end
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
    local footer = EffectiveFooterHeight()
    local avail = f:GetHeight() - headerH - footer - 4
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
            if HideBarBackgrounds() then
                bar.bg:Hide()
            else
                bar.bg:Show()
            end
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
    if f then
        ApplyFrameBackgroundOpacity(f)
    end
    if f and f.mode and UI.IsModeEnabled and not UI.IsModeEnabled(f.mode) then
        local nextMode = (UI.FirstEnabledMode and UI.FirstEnabledMode()) or "damage"
        f.mode = nextMode
        if f.title and MODE_LABELS then
            f.title:SetText(MODE_LABELS[nextMode] or nextMode)
        end
    end
    if not f then return end
    if not f.visibleBars then
        self:LayoutBars(f)
    end

    local barH = GetBarHeight and GetBarHeight() or 16
    local segment = GetSegmentData(f.segment)
    local mode = f.mode or "damage"

    -- Title / compact abbreviations applied in ApplyHeaderLayout
    if f.title then
        f.title:SetText(MODE_LABELS[mode] or mode)
    end

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
        for _gi = 1, table.getn(list) do local entry = list[_gi]
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
        for _gi = 1, table.getn(list) do local entry = list[_gi]
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
    for _gi = 1, table.getn(list) do local e = list[_gi]
        if e.isTotal then
            hasTotal = true
            totalEntry = e
        else
            table.insert(playerList, e)
        end
    end

    local showDuration = OM.GetSetting and OM:GetSetting("showFightDuration") == true
    -- Duration row only when we have a meaningful fight time
    if showDuration and (not duration or duration <= 0) then
        showDuration = false
    end

    -- Reserve first slot for Duration, last slot for Total when enabled
    local playerSlots = fit
    if showDuration then
        playerSlots = playerSlots - 1
    end
    if hasTotal then
        playerSlots = playerSlots - 1
    end
    if playerSlots < 0 then playerSlots = 0 end

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
    if mode == "damage" or mode == "healing" or mode == "taken" then
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
    local durationSlot = showDuration and 1 or 0
    for i = 1, MAX_BARS do
        local bar = f.bars[i]
        local entry = nil
        local isDurationRow = false

        if showDuration and i == 1 then
            isDurationRow = true
        elseif i <= (durationSlot + playerSlots) then
            local playerIndex = i - durationSlot
            entry = playerList[playerIndex + scroll]
        elseif hasTotal and i == (durationSlot + playerSlots + 1) then
            entry = totalEntry
        end

        if isDurationRow and i <= fit then
            shown = shown + 1
            bar:Show()
            bar:SetValue(1)
            local modeCol = ResolveModeColor(mode)
            if OM.GetSetting and OM:GetSetting("buttonsColorWithMode") == true and modeCol then
                bar:SetStatusBarColor(modeCol[1], modeCol[2], modeCol[3], 0.55)
            else
                -- Match the dark window background
                bar:SetStatusBarColor(0.08, 0.08, 0.08, 0.95)
            end
            if bar.classIcon then bar.classIcon:Hide() end
            if bar.nameText then
                bar.nameText:ClearAllPoints()
                bar.nameText:SetPoint("LEFT", bar, "LEFT", 4, 0)
                bar.nameText:SetText("")
            end
            if bar.valueText then
                bar.valueText:ClearAllPoints()
                bar.valueText:SetPoint("CENTER", bar, "CENTER", 0, 0)
                bar.valueText:SetJustifyH("CENTER")
                if UI.FormatDuration then
                    bar.valueText:SetText(UI:FormatDuration(duration) or "")
                else
                    bar.valueText:SetText(tostring(math.floor((duration or 0) + 0.5)) .. "s")
                end
            end
            bar.entry = nil
            bar.mode = mode
            bar.duration = duration
            bar.isDurationRow = true
        elseif entry and i <= fit then
            shown = shown + 1
            local pct = entry.value / maxVal
            if pct > 1 then pct = 1 end
            if pct < 0 then pct = 0 end

            bar:Show()
            bar:SetValue(pct)
            bar.isDurationRow = nil
            -- Restore value text to the right edge (duration row may have centered it)
            if bar.valueText then
                bar.valueText:ClearAllPoints()
                bar.valueText:SetPoint("RIGHT", bar, "RIGHT", -4, 0)
                bar.valueText:SetJustifyH("RIGHT")
            end
            if entry.isTotal then
                local modeCol = ResolveModeColor(mode)
                if OM.GetSetting and OM:GetSetting("buttonsColorWithMode") == true and modeCol then
                    bar:SetStatusBarColor(modeCol[1], modeCol[2], modeCol[3], 0.90)
                else
                    bar:SetStatusBarColor(0.9, 0.9, 0.9, 0.85)
                end
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
                local rank = entry.rank or ((i - durationSlot) + scroll)
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
                if UI.FormatBarName then
                    bar.nameText:SetText(UI.FormatBarName(rank, entry.name, mode))
                else
                    bar.nameText:SetText(rank .. ". " .. entry.name)
                end
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
    local _, f
    for _gi = 1, table.getn(self.frames) do local f = self.frames[_gi]
        ApplyFrameBackgroundOpacity(f)
        if f:IsShown() then
            self:RefreshFrame(f)
        else
            -- Still update layout/grip when hidden
            local hideTitle = OM.GetSetting and OM:GetSetting("hideTitle") == true
            self:ApplyHeaderLayout(f, hideTitle, 0)
        end
    end
end

function UI:Refresh()
    for _gi = 1, table.getn(self.frames) do local f = self.frames[_gi]
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
    for _gi = 1, table.getn(self.frames) do local fr = self.frames[_gi]
        used[fr.mode] = true
    end
    for _gi = 1, table.getn(MODE_ORDER) do local key = MODE_ORDER[_gi]
        if not used[key] and (not UI.IsModeEnabled or UI.IsModeEnabled(key)) then
            f.mode = key
            break
        end
    end
    -- If chosen mode ended up disabled, snap to first enabled
    if UI.IsModeEnabled and not UI.IsModeEnabled(f.mode) then
        f.mode = (UI.FirstEnabledMode and UI.FirstEnabledMode()) or "damage"
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
    for _gi = 1, table.getn(self.frames) do local fr = self.frames[_gi]
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

