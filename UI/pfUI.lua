--[[
    GreedMeter - UI / pfUI Integration
    Optional dock + skin support for pfUI (brues-code / upstream).
    Supports both Damage and Threat meters side-by-side when the Threat module is present.
]]

local OM = GreedMeter
local UI = GreedMeter.UI

-- ============================================================
-- Defaults
-- ============================================================

OM.defaults.pfuiIntegration = true

-- ============================================================
-- State
-- ============================================================

local damageRegistered = false
local threatRegistered = false
local originalBackdrop = nil
local originalHeaderState = {}

-- ============================================================
-- Helpers
-- ============================================================

local function HasPfUI()
    return pfUI and pfUI.thirdparty and pfUI.thirdparty.meters and pfUI.thirdparty.meters.RegisterMeter
end

local function GetMainFrame()
    return UI.mainFrame or getglobal("GreedMeterFrame1")
end

local function HasThreatModule()
    if OM.modules and OM.modules.Threat then return true end
    if GreedMeterThreat or (OM.Threat and type(OM.Threat) == "table") then return true end
    -- Fallback: threat is a valid mode
    if UI.MODE_ORDER then
        local i
        for i = 1, table.getn(UI.MODE_ORDER) do
            if UI.MODE_ORDER[i] == "threat" then return true end
        end
    end
    return false
end

local function GetThreatFrame()
    -- 1. Prefer a frame already set to threat mode
    if UI.frames then
        local i, f
        for i, f in ipairs(UI.frames) do
            if f and f.mode == "threat" then
                return f
            end
        end
    end

    -- 2. If Threat module exists and we have a second window, use it
    if HasThreatModule() and UI.frames and UI.frames[2] then
        return UI.frames[2]
    end

    return nil
end

local function EnsurePfUIConfig(key)
    if not C or not C.thirdparty then return false end
    if not C.thirdparty[key] then
        C.thirdparty[key] = {
            dock = "1",
            skin = "1",
        }
    else
        C.thirdparty[key].dock = "1"
        if C.thirdparty[key].skin == nil then
            C.thirdparty[key].skin = "1"
        end
    end
    return true
end

-- ============================================================
-- Skinning
-- ============================================================

local function ApplyDockSkin(f)
    if not f or not HasPfUI() then return end

    local configKey = (f.mode == "threat") and "greedmeterthreat" or "greedmeter"
    if not (C and C.thirdparty and C.thirdparty[configKey] and C.thirdparty[configKey].skin == "1") then
        return
    end

    if not originalBackdrop then
        originalBackdrop = {
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 },
        }
    end

    if CreateBackdrop then
        local chat_border = 3
        if GetBorderSize then
            local _, b = GetBorderSize("chat")
            if b then chat_border = b end
        end
        CreateBackdrop(f, chat_border, nil, (C.thirdparty.chatbg == "1" and 0.8) or nil)
        if CreateBackdropShadow then
            CreateBackdropShadow(f)
        end
        if C.thirdparty.chatbg == "1" and C.chat and C.chat.global and C.chat.global.custombg == "1" and GetStringColor then
            local r, g, b, a = GetStringColor(C.chat.global.background)
            if f.backdrop then
                f.backdrop:SetBackdropColor(tonumber(r) or 0.1, tonumber(g) or 0.1, tonumber(b) or 0.1, tonumber(a) or 0.8)
            end
            r, g, b, a = GetStringColor(C.chat.global.border)
            if f.backdrop then
                f.backdrop:SetBackdropBorderColor(tonumber(r) or 0.4, tonumber(g) or 0.4, tonumber(b) or 0.4, tonumber(a) or 1)
            end
        end
    else
        f:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 12,
            insets = { left = 2, right = 2, top = 2, bottom = 2 },
        })
        f:SetBackdropColor(0.1, 0.1, 0.1, 0.85)
        f:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
    end

    -- Remember + force compact header while docked
    if not originalHeaderState[f] then
        originalHeaderState[f] = OM:GetSetting("hideTitle")
    end
    if UI.ApplyHeaderLayout then
        UI:ApplyHeaderLayout(f, true, 0)
    end
end

local function RestoreNormalSkin(f)
    if not f then return end
    if originalBackdrop then
        f:SetBackdrop(originalBackdrop)
        f:SetBackdropColor(0, 0, 0, 0.80)
        f:SetBackdropBorderColor(0.35, 0.35, 0.35, 1)
    end
    if originalHeaderState[f] ~= nil and UI.ApplyHeaderLayout then
        UI:ApplyHeaderLayout(f, originalHeaderState[f] == true, 0)
        originalHeaderState[f] = nil
    end
end

-- ============================================================
-- Damage dock callbacks
-- ============================================================

local function DamageSingle()
    local f = GetMainFrame()
    if not f or not pfUI or not pfUI.chat or not pfUI.chat.right then return end
    f:ClearAllPoints()
    f:SetAllPoints(pfUI.chat.right)
    f:SetWidth(pfUI.chat.right:GetWidth())
    if UI.LayoutBars then UI:LayoutBars(f) end
    if UI.RefreshFrame then UI:RefreshFrame(f) end
    ApplyDockSkin(f)
end

local function DamageDual()
    local f = GetMainFrame()
    if not f or not pfUI or not pfUI.chat or not pfUI.chat.right then return end
    -- Right half (standard pfUI damage position in dual mode)
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", pfUI.chat.right, "TOP", 0, 0)
    f:SetPoint("BOTTOMRIGHT", pfUI.chat.right, "BOTTOMRIGHT", 0, 0)
    f:SetWidth(pfUI.chat.right:GetWidth() / 2)
    if UI.LayoutBars then UI:LayoutBars(f) end
    if UI.RefreshFrame then UI:RefreshFrame(f) end
    ApplyDockSkin(f)
end

local function DamageShow()
    local f = GetMainFrame()
    if f then
        f:Show()
        if UI.RefreshFrame then UI:RefreshFrame(f) end
    end
end

local function DamageHide()
    local f = GetMainFrame()
    if f then f:Hide() end
end

-- ============================================================
-- Threat dock callbacks
-- ============================================================

local function ThreatSingle()
    local f = GetThreatFrame()
    if not f or not pfUI or not pfUI.chat or not pfUI.chat.right then return end

    -- Ensure it is in threat mode
    if f.mode ~= "threat" then
        f.mode = "threat"
    end

    f:ClearAllPoints()
    f:SetAllPoints(pfUI.chat.right)
    f:SetWidth(pfUI.chat.right:GetWidth())
    if UI.LayoutBars then UI:LayoutBars(f) end
    if UI.RefreshFrame then UI:RefreshFrame(f) end
    ApplyDockSkin(f)
end

local function ThreatDual()
    local f = GetThreatFrame()
    if not f or not pfUI or not pfUI.chat or not pfUI.chat.right then return end

    if f.mode ~= "threat" then
        f.mode = "threat"
    end

    -- Left half (standard pfUI threat position in dual mode)
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", pfUI.chat.right, "TOPLEFT", 0, 0)
    f:SetPoint("BOTTOMRIGHT", pfUI.chat.right, "BOTTOM", 0, 0)
    f:SetWidth(pfUI.chat.right:GetWidth() / 2)
    if UI.LayoutBars then UI:LayoutBars(f) end
    if UI.RefreshFrame then UI:RefreshFrame(f) end
    ApplyDockSkin(f)
end

local function ThreatShow()
    local f = GetThreatFrame()
    if f then
        if f.mode ~= "threat" then f.mode = "threat" end
        f:Show()
        if UI.RefreshFrame then UI:RefreshFrame(f) end
    end
end

local function ThreatHide()
    local f = GetThreatFrame()
    if f then f:Hide() end
end

-- ============================================================
-- Registration
-- ============================================================

local function TryRegisterDamage()
    if damageRegistered then return true end
    if not OM:GetSetting("pfuiIntegration") then return false end
    if not HasPfUI() then return false end
    if not EnsurePfUIConfig("greedmeter") then return false end

    if pfUI.thirdparty.meters.damage then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00GreedMeter:|r pfUI damage dock slot already taken.")
        return false
    end

    local docktable = {
        "greedmeter",
        "GreedMeter",
        "GreedMeterFrame1",
        DamageSingle,
        DamageDual,
        DamageShow,
        DamageHide,
    }

    pfUI.thirdparty.meters:RegisterMeter("damage", docktable)
    damageRegistered = true
    return true
end

local function TryRegisterThreat()
    if threatRegistered then return true end
    if not OM:GetSetting("pfuiIntegration") then return false end
    if not HasPfUI() then return false end
    if not HasThreatModule() then return false end
    if not EnsurePfUIConfig("greedmeterthreat") then return false end

    -- Make sure we actually have (or can get) a threat frame
    local threatFrame = GetThreatFrame()
    if not threatFrame then
        -- Try to open a second window automatically so dual works
        if UI.AddFrame and table.getn(UI.frames or {}) < (UI.MAX_FRAMES or 6) then
            UI:AddFrame(UI.mainFrame)
            threatFrame = UI.frames and UI.frames[2]
            if threatFrame then
                threatFrame.mode = "threat"
            end
        end
    end
    if not threatFrame then return false end

    if pfUI.thirdparty.meters.threat then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00GreedMeter:|r pfUI threat dock slot already taken.")
        return false
    end

    local docktable = {
        "greedmeterthreat",
        "GreedMeter",
        threatFrame:GetName() or "GreedMeterFrame2",
        ThreatSingle,
        ThreatDual,
        ThreatShow,
        ThreatHide,
    }

    pfUI.thirdparty.meters:RegisterMeter("threat", docktable)
    threatRegistered = true
    return true
end

local function TryRegisterAll()
    local dmgOk = TryRegisterDamage()
    local thrOk = TryRegisterThreat()

    if dmgOk and thrOk then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00GreedMeter:|r Registered Damage + Threat with pfUI dock. Use the > button on the right chat panel.")
    elseif dmgOk then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00GreedMeter:|r Registered Damage with pfUI dock.")
    end

    -- Force a resize so dual layout applies immediately if both are present
    if (dmgOk or thrOk) and pfUI and pfUI.thirdparty and pfUI.thirdparty.meters and pfUI.thirdparty.meters.Resize then
        pfUI.thirdparty.meters:Resize()
    end
end

local function UnregisterVisual()
    local f = GetMainFrame()
    if f then
        RestoreNormalSkin(f)
        f:Show()
    end
    local tf = GetThreatFrame()
    if tf and tf ~= f then
        RestoreNormalSkin(tf)
        tf:Show()
    end
end

-- ============================================================
-- Settings checkbox
-- ============================================================

local function AddPfUICheckbox(settingsFrame)
    if not settingsFrame or settingsFrame.pfuiCheckbox then return end

    local y = -340

    local cb = CreateFrame("CheckButton", nil, settingsFrame, "UICheckButtonTemplate")
    cb:SetWidth(24)
    cb:SetHeight(24)
    cb:SetPoint("TOPLEFT", settingsFrame, "TOPLEFT", 16, y)

    local fs = settingsFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("LEFT", cb, "RIGHT", 2, 0)
    fs:SetText("pfUI Integration")
    cb.label = fs

    cb:SetChecked(OM:GetSetting("pfuiIntegration") and 1 or nil)

    cb:SetScript("OnClick", function()
        local checked = this:GetChecked() and true or false
        OM:SetSetting("pfuiIntegration", checked)
        if checked then
            TryRegisterAll()
            if not HasPfUI() then
                DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00GreedMeter:|r pfUI not detected yet. Integration will activate when pfUI loads.")
            end
        else
            UnregisterVisual()
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00GreedMeter:|r pfUI integration disabled. /reload to fully clear dock slots.")
        end
        if UI.ApplySettingsToFrames then
            UI:ApplySettingsToFrames()
        end
    end)

    cb:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
        GameTooltip:SetText("Dock GreedMeter into pfUI's right chat panel.\n\nWhen the Threat module is present, both Damage and Threat meters are docked side-by-side and toggled with the > button.", nil, nil, nil, nil, 1)
        GameTooltip:Show()
    end)
    cb:SetScript("OnLeave", function() GameTooltip:Hide() end)

    settingsFrame.pfuiCheckbox = cb

    local h = settingsFrame:GetHeight() or 510
    if h < 560 then
        settingsFrame:SetHeight(560)
    end
end

-- Wrap CreateSettingsFrame
local _originalCreateSettingsFrame = UI.CreateSettingsFrame
function UI:CreateSettingsFrame()
    local f = _originalCreateSettingsFrame(self)
    AddPfUICheckbox(f)
    return f
end

-- ============================================================
-- Lifecycle
-- ============================================================

local function OnLoad()
    local delayFrame = CreateFrame("Frame")
    local elapsed = 0
    delayFrame:SetScript("OnUpdate", function()
        elapsed = elapsed + arg1
        if elapsed > 2.0 then
            delayFrame:SetScript("OnUpdate", nil)
            if OM:GetSetting("pfuiIntegration") then
                TryRegisterAll()
            end
        end
    end)
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:SetScript("OnEvent", function()
    if event == "PLAYER_ENTERING_WORLD" then
        if OM:GetSetting("pfuiIntegration") then
            TryRegisterAll()
        end
    end
end)

local oldUIOnLoad = UI.OnLoad
function UI:OnLoad()
    if oldUIOnLoad then
        oldUIOnLoad(self)
    end
    OnLoad()
end

if UI.mainFrame then
    OnLoad()
end