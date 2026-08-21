--[[
    GreedMeter - Parser / Main
    Backend selection and load orchestration.

    Settings (test toggles — no need to uninstall client mods):
      useNampower — allow Nampower structured events when the DLL is present
      useSuperWoW — allow SuperWoW RAW + GUID helpers when SuperWoW is present

    Priority when both allowed: Nampower combat events > SuperWoW RAW > pure chat.
    Interrupts always use chat.
]]

local OM = GreedMeter
local NS = GreedMeter.ParserNS
local Parser = NS.Parser

local function SettingOn(key, default)
    if OM.GetSetting then
        local v = OM:GetSetting(key)
        if v == nil then
            return default
        end
        return v and true or false
    end
    return default
end

local function SuperWoWPresent()
    if NS.SuperWoWAvailable and NS.SuperWoWAvailable() then
        return true
    end
    if OM.HasSuperWoW and OM:HasSuperWoW() then
        return true
    end
    return false
end

--- Re-apply combat backends from current settings + installed mods.
--- Safe to call from settings checkboxes (no /reload required).
function Parser:SelectBackends()
    local playerName = UnitName("player")
    if NS.ST then
        NS.ST.playerName = playerName
    end

    local np = NS.Backends and NS.Backends.Nampower
    local chat = NS.Backends and NS.Backends.Chat

    -- Always enable detected mods (no user toggle)
    local wantNP = true
    local wantSW = true

    local usedNampower = false
    local useRaw = false

    -- Nampower
    if wantNP and np and np.Available and np.Available() then
        if np.Enable and np.Enable() then
            usedNampower = true
        end
    else
        if np and np.Disable then
            np.Disable()
        end
        NS.useNampowerCombat = false
        NS.useNampowerDispel = false
        NS.useNampowerCC = false
    end

    -- SuperWoW helpers + optional RAW
    local swPresent = SuperWoWPresent()
    if wantSW and swPresent then
        NS.superwowHelpers = true
        if not Parser._guidTicker and NS.RefreshGuidCacheFromUnits then
            local tick = CreateFrame("Frame")
            local elapsed = 0
            tick:SetScript("OnUpdate", function()
                elapsed = elapsed + arg1
                if elapsed >= 2 then
                    elapsed = 0
                    NS.RefreshGuidCacheFromUnits()
                end
            end)
            Parser._guidTicker = tick
        end
        if Parser._guidTicker then
            Parser._guidTicker:Show()
        end
        if NS.RefreshGuidCacheFromUnits then
            NS.RefreshGuidCacheFromUnits()
        end
        if not usedNampower then
            useRaw = true
        end
    else
        NS.superwowHelpers = false
        if Parser._guidTicker then
            Parser._guidTicker:Hide()
        end
    end

    if usedNampower then
        NS.combatBackend = "nampower"
    elseif useRaw then
        NS.combatBackend = "superwow"
    else
        NS.combatBackend = "chat"
    end

    -- Chat always on (interrupts; full parse when nampower combat is off)
    if chat and chat.Enable then
        chat.Enable(chat.frame, { useRaw = useRaw })
    end

    -- Status line (quiet when both present)
    if usedNampower and swPresent then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00GreedMeter:|r Nampower + SuperWoW active.")
    elseif usedNampower then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00GreedMeter:|r Nampower active. Works best with SuperWoW too — some features are less accurate without it.")
    elseif useRaw then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00GreedMeter:|r SuperWoW active. Works best with Nampower too — structured combat events are less accurate without it.")
    else
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00GreedMeter:|r GreedMeter works best with Nampower and SuperWoW. Features that rely on them are less accurate without them.")
    end
end

function Parser:OnLoad()
    self:SelectBackends()
end
