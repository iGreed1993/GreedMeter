--[[
    GreedMeter - UI / Detail
    Per-player ability breakdown window (damage / healing).
    Left column: targets (All + each target). Click to filter ability rows.
]]

local OM = GreedMeter
local UI = GreedMeter.UI

local COLS_DAMAGE_MELEE = {
    { key = "name",    label = "Ability",  width = 120 },
    { key = "hits",    label = "Hit",      width = 32 },
    { key = "crits",   label = "Crit",     width = 32 },
    { key = "misses",  label = "Miss",     width = 32 },
    { key = "glances", label = "Glance",   width = 40 },
    { key = "min",     label = "Min",      width = 40 },
    { key = "max",     label = "Max",      width = 40 },
    { key = "avg",     label = "Avg",      width = 40 },
    { key = "total",   label = "Total",    width = 48 },
}

local COLS_DAMAGE_CASTER = {
    { key = "name",     label = "Ability",  width = 120 },
    { key = "hits",     label = "Hit",      width = 32 },
    { key = "crits",    label = "Crit",     width = 32 },
    { key = "resists",  label = "Resist",   width = 40 },
    { key = "partials", label = "Partial",  width = 44 },
    { key = "min",      label = "Min",      width = 40 },
    { key = "max",      label = "Max",      width = 40 },
    { key = "avg",      label = "Avg",      width = 40 },
    { key = "total",    label = "Total",    width = 48 },
}

-- Physical / melee-style avoidances vs spell resists
local MELEE_CLASSES = {
    WARRIOR = true, ROGUE = true, HUNTER = true, PALADIN = true,
}

local COLS_HEAL = {
    { key = "name",  label = "Ability", width = 140 },
    { key = "hits",  label = "Count",   width = 40 },
    { key = "crits", label = "Crit",    width = 36 },
    { key = "min",   label = "Min",     width = 46 },
    { key = "max",   label = "Max",     width = 46 },
    { key = "avg",   label = "Avg",     width = 46 },
    { key = "total", label = "Total",   width = 52 },
}

local TARGET_COL_W = 110

local function FormatNum(n)
    n = tonumber(n) or 0
    n = math.floor(n + 0.5)
    if UI.FormatNumber then
        return UI.FormatNumber(n)
    end
    return tostring(n)
end

local function GetDetailLayout()
    if not OM.GetCharDB then return nil end
    local db = OM:GetCharDB()
    if not db then return nil end
    if not db.detailWindow then db.detailWindow = {} end
    return db.detailWindow
end

local function SaveDetailLayout(f)
    if not f or not f.GetLeft then return end
    local layout = GetDetailLayout()
    if not layout then return end
    local point, _, relativePoint, x, y = f:GetPoint(1)
    layout.point = point or "CENTER"
    layout.relativePoint = relativePoint or "CENTER"
    layout.x = x or 0
    layout.y = y or 0
end

local function ApplyDetailLayout(f)
    local layout = GetDetailLayout()
    f:ClearAllPoints()
    if layout and layout.point then
        f:SetPoint(layout.point, UIParent, layout.relativePoint or layout.point, layout.x or 0, layout.y or 0)
    else
        f:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
    end
end

local function IsMeleeClass(class)
    if not class then return true end
    return MELEE_CLASSES[class] and true or false
end

local function GetCols(isHeal, class)
    if isHeal then return COLS_HEAL end
    if IsMeleeClass(class) then
        return COLS_DAMAGE_MELEE
    end
    return COLS_DAMAGE_CASTER
end

local function CellText(row, key)
    if key == "name" then return row.name or "" end
    if key == "hits" or key == "crits" or key == "misses" or key == "glances"
        or key == "resists" or key == "partials" then
        return tostring(row[key] or 0)
    end
    return FormatNum(row[key] or 0)
end

local function StatsToRow(spell, d)
    if not d then return nil end
    local count = d.count or 0
    local avg = 0
    if count > 0 then
        avg = (d.total or 0) / count
    end
    return {
        name = spell,
        hits = d.hits or 0,
        crits = d.crits or 0,
        misses = d.misses or 0,
        glances = d.glances or 0,
        resists = d.resists or 0,
        partials = d.partials or 0,
        min = d.min or 0,
        max = d.max or 0,
        avg = avg,
        total = d.total or 0,
    }
end

-- targetFilter: nil or "All" = full spell totals; otherwise per-target bucket
local function BuildRows(playerData, preferHeal, targetFilter)
    local bag = nil
    if preferHeal and playerData.healSpellDetails and next(playerData.healSpellDetails) then
        bag = playerData.healSpellDetails
    elseif playerData.damageSpellDetails and next(playerData.damageSpellDetails) then
        bag = playerData.damageSpellDetails
    elseif playerData.healSpellDetails and next(playerData.healSpellDetails) then
        bag = playerData.healSpellDetails
    end
    if not bag then return {} end

    local filter = targetFilter
    if filter == "" or filter == "All" then filter = nil end

    local rows = {}
    local spell, d
    for spell, d in pairs(bag) do
        if type(d) == "table" then
            local src = d
            if filter then
                src = d.byTarget and d.byTarget[filter] or nil
            end
            if src then
                local row = StatsToRow(spell, src)
                if row and ((row.total or 0) > 0 or (row.hits or 0) > 0 or (row.crits or 0) > 0
                    or (row.misses or 0) > 0 or (row.glances or 0) > 0
                    or (row.resists or 0) > 0 or (row.partials or 0) > 0) then
                    table.insert(rows, row)
                end
            end
        end
    end
    table.sort(rows, function(a, b)
        if a.total == b.total then
            return a.name < b.name
        end
        return a.total > b.total
    end)
    return rows
end

local function BuildTargetList(playerData, preferHeal)
    local totals = {} -- [name] = amount
    local map = preferHeal and playerData.healingTo or playerData.damageTo
    if map then
        local n, v
        for n, v in pairs(map) do
            totals[n] = (totals[n] or 0) + (v or 0)
        end
    end
    -- Also collect from byTarget in spell details (covers misses with 0 damage)
    local bag = preferHeal and playerData.healSpellDetails or playerData.damageSpellDetails
    if bag then
        local spell, d
        for spell, d in pairs(bag) do
            if type(d) == "table" and d.byTarget then
                local tn, td
                for tn, td in pairs(d.byTarget) do
                    if not totals[tn] then
                        totals[tn] = (td and td.total) or 0
                    end
                end
            end
        end
    end
    local list = {}
    local n, v
    for n, v in pairs(totals) do
        table.insert(list, { name = n, total = v or 0 })
    end
    table.sort(list, function(a, b)
        if a.total == b.total then return a.name < b.name end
        return a.total > b.total
    end)
    return list
end

local function LayoutHeader(f, cols)
    if not f or not f.header then return end
    local i
    if f.headerLabels then
        for i = 1, table.getn(f.headerLabels) do
            f.headerLabels[i]:Hide()
        end
    else
        f.headerLabels = {}
    end
    local x = 0
    for i = 1, table.getn(cols) do
        local col = cols[i]
        local fs = f.headerLabels[i]
        if not fs then
            fs = f.header:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            f.headerLabels[i] = fs
        end
        fs:ClearAllPoints()
        fs:SetPoint("LEFT", f.header, "LEFT", x, 0)
        fs:SetWidth(col.width)
        fs:SetJustifyH(i == 1 and "LEFT" or "CENTER")
        fs:SetText(col.label)
        fs:Show()
        x = x + col.width
    end
end

local ROW_H = 14
local HEADER_BLOCK = 60   -- title + subtitle + column headers
local PAD_BOTTOM = 14
local PAD_SIDES = 24
local SCROLL_GUTTER = 18
local MIN_FRAME_H = 110
local MIN_FRAME_W = 420

local function AbilityTableWidth(cols)
    local w = 0
    local i
    for i = 1, table.getn(cols) do
        w = w + (cols[i].width or 0)
    end
    return w
end

local function ResizeDetailFrame(f, rowCount, targetCount)
    if not f then return end
    local cols = GetCols(f._isHeal, f._class)
    local tableW = AbilityTableWidth(cols)
    local width = PAD_SIDES + TARGET_COL_W + 8 + tableW + SCROLL_GUTTER
    if width < MIN_FRAME_W then width = MIN_FRAME_W end

    if not rowCount or rowCount < 1 then rowCount = 1 end
    if not targetCount or targetCount < 1 then targetCount = 1 end
    -- Include "All" in target count for height
    local bodyRows = rowCount
    if targetCount > bodyRows then bodyRows = targetCount end
    local bodyH = bodyRows * ROW_H
    local height = HEADER_BLOCK + bodyH + PAD_BOTTOM

    -- Cap to ~85% of screen so huge lists still scroll inside
    local screenH = (UIParent and UIParent.GetHeight and UIParent:GetHeight()) or 768
    local maxH = math.floor(screenH * 0.85)
    if maxH < 200 then maxH = 200 end
    local needsScroll = false
    if height > maxH then
        height = maxH
        needsScroll = true
    end
    if height < MIN_FRAME_H then height = MIN_FRAME_H end

    f:SetWidth(width)
    f:SetHeight(height)

    -- Ability content width matches columns
    if f.content then
        f.content:SetWidth(tableW + 4)
    end
    -- Scroll child heights already set by callers; ensure scroll area uses new space
    if f.scroll then
        -- re-anchor is already TOPLEFT/BOTTOMRIGHT; nothing else needed
    end

    -- If everything fits, keep scroll at top
    if f.scroll and not needsScroll then
        f.scroll:SetVerticalScroll(0)
    end
    if UI.ClampFrameToScreen then
        UI.ClampFrameToScreen(f)
    end
end

local function RefreshAbilityRows(f)
    if not f or not f._pdata then return end
    local cols = GetCols(f._isHeal, f._class)
    LayoutHeader(f, cols)
    local rows = BuildRows(f._pdata, f._isHeal, f._targetFilter)
    local content = f.content
    local i
    if not f.rowFrames then f.rowFrames = {} end
    for i = 1, table.getn(f.rowFrames) do
        f.rowFrames[i]:Hide()
    end
    local y = 0
    for i = 1, table.getn(rows) do
        local row = rows[i]
        local rf = f.rowFrames[i]
        if not rf then
            rf = CreateFrame("Frame", nil, content)
            rf:SetHeight(14)
            rf:SetWidth(480)
            rf.cols = {}
            f.rowFrames[i] = rf
        end
        local c
        for c = 1, table.getn(cols) do
            if not rf.cols[c] then
                rf.cols[c] = rf:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            end
        end
        for c = table.getn(cols) + 1, table.getn(rf.cols) do
            if rf.cols[c] then rf.cols[c]:Hide() end
        end
        local x = 0
        for c = 1, table.getn(cols) do
            local col = cols[c]
            local fs = rf.cols[c]
            fs:ClearAllPoints()
            fs:SetPoint("LEFT", rf, "LEFT", x, 0)
            fs:SetWidth(col.width)
            fs:SetJustifyH(c == 1 and "LEFT" or "CENTER")
            fs:SetText(CellText(row, col.key))
            fs:Show()
            x = x + col.width
        end
        rf:Show()
        rf:ClearAllPoints()
        rf:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
        y = y + 14
    end
    if table.getn(rows) == 0 then
        local rf = f.rowFrames[1]
        if not rf then
            rf = CreateFrame("Frame", nil, content)
            rf:SetHeight(14)
            rf:SetWidth(480)
            local fs = rf:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            fs:SetPoint("LEFT", rf, "LEFT", 0, 0)
            rf.empty = fs
            rf.cols = {}
            f.rowFrames[1] = rf
        end
        rf:Show()
        rf:ClearAllPoints()
        rf:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
        local msg = "No ability detail for this target."
        if not f._targetFilter or f._targetFilter == "All" then
            msg = "No ability detail yet (needs combat after enabling)."
        end
        if rf.empty then
            rf.empty:SetText(msg)
        elseif rf.cols[1] then
            rf.cols[1]:SetText(msg)
            for i = 2, table.getn(rf.cols) do rf.cols[i]:SetText("") end
        end
        y = 14
    end
    content:SetHeight(math.max(y, ROW_H))
    if f.scroll then f.scroll:SetVerticalScroll(0) end
    local rowCount = math.floor(y / ROW_H)
    if rowCount < 1 then rowCount = 1 end
    local tgtCount = f._targetCount or 1
    ResizeDetailFrame(f, rowCount, tgtCount)
end

local function HighlightTargetButtons(f)
    if not f or not f.targetButtons then return end
    local i
    for i = 1, table.getn(f.targetButtons) do
        local btn = f.targetButtons[i]
        local selected = (btn.targetName == (f._targetFilter or "All"))
        if selected then
            btn:SetTextColor(1, 0.85, 0.3)
        else
            btn:SetTextColor(1, 1, 1)
        end
    end
end


local function LayoutTargets(f, targets)
    if not f.targetList then return end
    if not f.targetButtons then f.targetButtons = {} end
    local i
    for i = 1, table.getn(f.targetButtons) do
        f.targetButtons[i]:Hide()
    end
    -- All first
    local entries = { { name = "All", total = 0 } }
    for i = 1, table.getn(targets) do
        table.insert(entries, targets[i])
    end
    local y = 0
    for i = 1, table.getn(entries) do
        local e = entries[i]
        local btn = f.targetButtons[i]
        if not btn then
            btn = CreateFrame("Button", nil, f.targetList)
            btn:SetHeight(14)
            btn:SetWidth(TARGET_COL_W - 4)
            local fs = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            fs:SetAllPoints(btn)
            fs:SetJustifyH("LEFT")
            btn.text = fs
            btn:SetFontString(fs)
            btn:SetScript("OnClick", function()
                local frame = f
                local name = this.targetName
                if name == "All" then
                    frame._targetFilter = nil
                else
                    frame._targetFilter = name
                end
                HighlightTargetButtons(frame)
                RefreshAbilityRows(frame)
            end)
            f.targetButtons[i] = btn
        end
        btn.targetName = e.name
        local label = e.name
        if e.name ~= "All" and e.total and e.total > 0 then
            label = e.name
        end
        btn.text:SetText(label)
        btn:ClearAllPoints()
        btn:SetPoint("TOPLEFT", f.targetList, "TOPLEFT", 2, -y)
        btn:Show()
        y = y + 14
    end
    f.targetList:SetHeight(math.max(y, ROW_H))
    f._targetCount = table.getn(entries)
    HighlightTargetButtons(f)
end

function UI:CreateDetailFrame()
    if self.detailFrame then return self.detailFrame end

    local f = CreateFrame("Frame", "GreedMeterDetail", UIParent)
    f:SetWidth(MIN_FRAME_W)
    f:SetHeight(MIN_FRAME_H)
    f:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    f:SetBackdropColor(0, 0, 0, 0.92)
    f:SetBackdropBorderColor(0.45, 0.45, 0.45, 1)
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function()
        if this.SetClampedToScreen then this:SetClampedToScreen(false) end
        this:StartMoving()
    end)
    f:SetScript("OnDragStop", function()
        this:StopMovingOrSizing()
        if UI.ClampFrameToScreen then UI.ClampFrameToScreen(this) end
        SaveDetailLayout(this)
    end)
    ApplyDetailLayout(f)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", f, "TOP", 0, -8)
    title:SetText("Ability Details")
    f.title = title

    local subtitle = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    subtitle:SetPoint("TOP", title, "BOTTOM", 0, -2)
    subtitle:SetText("")
    f.subtitle = subtitle

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)
    close:SetScript("OnClick", function() f:Hide() end)

    -- Targets header
    local tgtHdr = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    tgtHdr:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -42)
    tgtHdr:SetText("Targets")
    tgtHdr:SetTextColor(1, 0.85, 0.4)
    f.targetHeader = tgtHdr

    local targetScroll = CreateFrame("ScrollFrame", "GreedMeterDetailTargetScroll", f)
    targetScroll:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -56)
    targetScroll:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 10, 12)
    targetScroll:SetWidth(TARGET_COL_W)
    local targetList = CreateFrame("Frame", nil, targetScroll)
    targetList:SetWidth(TARGET_COL_W - 4)
    targetList:SetHeight(200)
    targetScroll:SetScrollChild(targetList)
    f.targetScroll = targetScroll
    f.targetList = targetList

    -- Ability header
    local header = CreateFrame("Frame", nil, f)
    header:SetPoint("TOPLEFT", f, "TOPLEFT", 14 + TARGET_COL_W, -42)
    header:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, -42)
    header:SetHeight(16)
    f.header = header
    f.headerLabels = {}

    local scroll = CreateFrame("ScrollFrame", "GreedMeterDetailScroll", f)
    scroll:SetPoint("TOPLEFT", f, "TOPLEFT", 14 + TARGET_COL_W, -60)
    scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -28, 12)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetWidth(480)
    content:SetHeight(200)
    scroll:SetScrollChild(content)
    f.scroll = scroll
    f.content = content
    f.rowFrames = {}
    f.targetButtons = {}

    f:EnableMouseWheel(true)
    f:SetScript("OnMouseWheel", function()
        local focusScroll = scroll
        local max = 0
        if content:GetHeight() > scroll:GetHeight() then
            max = content:GetHeight() - scroll:GetHeight()
        end
        local cur = scroll:GetVerticalScroll() or 0
        cur = cur - (arg1 * 20)
        if cur < 0 then cur = 0 end
        if cur > max then cur = max end
        scroll:SetVerticalScroll(cur)
    end)

    f:Hide()
    self.detailFrame = f
    return f
end

function UI:ShowPlayerDetail(entry, segmentKey, mode)
    if not OM.GetSetting or OM:GetSetting("detailedDamage") ~= true then
        return
    end
    if not entry or entry.isTotal or entry.isDurationRow then return end
    local name = entry.name
    if not name then return end

    local segment = nil
    if OM.modules and OM.modules.Parser and OM.modules.Parser.GetSegment then
        segment = OM.modules.Parser:GetSegment(segmentKey or "current")
    elseif OM.data then
        segment = OM.data[segmentKey or "current"]
    end
    local pdata = segment and segment.players and segment.players[name]
    if not pdata and entry.data then
        pdata = entry.data
    end
    if not pdata then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00GreedMeter:|r No detail data for " .. tostring(name))
        return
    end

    local preferHeal = (mode == "healing")
    local f = self:CreateDetailFrame()
    local kind = preferHeal and "Healing" or "Damage"
    if preferHeal and (not pdata.healSpellDetails or not next(pdata.healSpellDetails)) then
        kind = "Damage"
        preferHeal = false
    end

    f._pdata = pdata
    f._isHeal = (kind == "Healing")
    f._class = pdata.class or (entry.data and entry.data.class) or nil
    if not f._class and OM.players and OM.players[name] then
        f._class = OM.players[name].class
    end
    f._targetFilter = nil
    f.title:SetText(tostring(name) .. " — " .. kind)

    local segKey = segmentKey or "current"
    local segLabel = segKey
    if UI.SegmentMenuLabel then
        segLabel = UI:SegmentMenuLabel(segKey)
    elseif UI.SegmentLabel then
        segLabel = UI:SegmentLabel(segKey)
    end
    local duration = 0
    if UI.GetSegmentDuration then
        duration = UI.GetSegmentDuration(segment, segKey) or 0
    elseif segment then
        if segment.duration and segment.duration > 0 then
            duration = segment.duration
        elseif segment.startTime and segment.startTime > 0 then
            local endT = segment.endTime or 0
            if endT > segment.startTime then
                duration = endT - segment.startTime
            end
        end
    end
    local durText = ""
    if UI.FormatDuration then
        durText = UI:FormatDuration(duration) or ""
    elseif duration and duration > 0 then
        durText = tostring(math.floor(duration + 0.5)) .. "s"
    end
    if f.subtitle then
        if durText ~= "" then
            f.subtitle:SetText("Segment: " .. tostring(segLabel) .. "   Duration: " .. durText)
        else
            f.subtitle:SetText("Segment: " .. tostring(segLabel))
        end
    end

    local targets = BuildTargetList(pdata, f._isHeal)
    LayoutTargets(f, targets)
    RefreshAbilityRows(f)

    f:Show()
    f:Raise()
end
