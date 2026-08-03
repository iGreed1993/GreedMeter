--[[
    GreedMeter - Core / Commands
    Slash commands and test data.
]]

local OM = GreedMeter

SLASH_GREEDMETER1 = "/gdm"
SLASH_GREEDMETER2 = "/greedmeter"
SlashCmdList["GREEDMETER"] = function(msg)
    msg = string.lower(string.gsub(msg or "", "^%s+", ""))
    -- string.match is Lua 5.1+; use string.find captures (Lua 5.0)
    local _, _, cmd, arg = string.find(msg, "^(%S+)%s*(.*)$")
    cmd = cmd or ""
    arg = arg or ""

    if cmd == "reset" then
        -- Clear data before module handlers (Fire order via pairs is undefined)
        if OM.data then
            OM.data.current = { players = {}, startTime = 0, endTime = 0, label = "Current", isBoss = false, duration = 0 }
            OM.data.overall = { players = {}, startTime = 0, endTime = 0, label = "Overall", isBoss = false, duration = 0 }
            OM.data.recentFights = {}
            OM.data.bossFights = {}
        end
        OM:UpdateGroupRoster()
        OM:Fire("OnReset")
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00GreedMeter:|r Data reset.")
    elseif cmd == "test" then
        OM:LoadTestData()
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00GreedMeter:|r Loaded test data (40 players).")
        if OM.modules and OM.modules.UI then
            local ui = OM.modules.UI
            if not ui.mainFrame then
                ui:CreateMeterFrame(true)
            end
            ui.mainFrame:Show()
            if ui.LayoutBars then ui:LayoutBars(ui.mainFrame) end
            if ui.Refresh then ui:Refresh() end
        end
    elseif cmd == "range" then
        if arg == "" or arg == "status" then
            local current = OM:GetCombatLogRange()
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00GreedMeter:|r Combat log range is |cffffffff" .. current .. "y|r (target " .. OM.combatLogRange .. "y).")
        else
            local n = tonumber(arg)
            if not n then
                DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00GreedMeter:|r Usage: /gdm range [40-200]")
            else
                OM:ApplyCombatLogRange(n)
                DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00GreedMeter:|r Combat log range set to |cffffffff" .. OM.combatLogRange .. "y|r.")
            end
        end
    elseif cmd == "show" or cmd == "" then
        OM:Fire("OnToggleUI")
    elseif cmd == "set" or cmd == "settings" then
        if OM.modules and OM.modules.UI and OM.modules.UI.ToggleSettings then
            OM.modules.UI:ToggleSettings()
        end
    elseif cmd == "help" then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00GreedMeter commands:|r")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffffffff/gdm|r or |cffffffff/gdm show|r - show/hide meters")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffffffff/gdm set|r or |cffffffff/gdm settings|r - open settings")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffffffff/gdm reset|r - clear all recorded data")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffffffff/gdm range|r - show combat log range")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffffffff/gdm range 200|r - set range to 200 yards")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffffffff/gdm range 40|r - restore default range")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffffffff/gdm test|r - load fake 40-player raid data")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffffffff/gdm help|r - show this help")
    else
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00GreedMeter:|r Unknown command. Type |cffffffff/gdm help|r")
    end
end

-- Fake 40-player raid for UI testing
function OM:LoadTestData()
    local classes = {
        "WARRIOR", "MAGE", "ROGUE", "DRUID", "HUNTER",
        "SHAMAN", "PRIEST", "WARLOCK", "PALADIN",
    }
    local names = {
        "Grommash", "Jaina", "Valeera", "Malfurion", "Rexxar",
        "Thrall", "Anduin", "Guldan", "Uther", "Garrosh",
        "Khadgar", "Garona", "Cenarius", "Alleria", "Voljin",
        "Velen", "Medivh", "Liadrin", "Saurfang", "Aegwynn",
        "Sylvanas", "Illidan", "Tyrande", "Cairne", "Varok",
        "Kaelthas", "Maiev", "Arthas", "Kelthuzad", "Anubarak",
        "Muradin", "Bolvar", "Alexstrasza", "Ysera", "Nozdormu",
        "Malygos", "Neltharion", "Ragnaros", "Nefarian", "Onyxia",
    }

    self.players = {}
    local i
    for i = 1, 40 do
        local n = names[i] or ("Player"..i)
        local c = classes[((i - 1) - math.floor((i - 1) / 9) * 9) + 1]
        self.players[n] = { class = c, pets = {}, isPlayer = true }
    end

    local function fillList(count, options)
        local list = {}
        local j
        for j = 1, count do
            local idx = math.mod(j - 1, table.getn(options)) + 1
            table.insert(list, options[idx])
        end
        return list
    end

    local function makePlayer(i, class)
        -- math.mod: Lua 5.0 has no % operator
        local dmg = math.floor(80000 / i + math.random(0, 3000))
        local heal = math.floor(60000 / (math.mod(i, 7) + 1) + math.random(0, 2000))
        local oh = math.floor(heal * (0.05 + math.mod(i, 10) * 0.02))
        local dispelCount = math.floor(20 / (math.mod(i, 8) + 1))
        local interruptCount = math.floor(12 / (math.mod(i, 6) + 1))
        if dispelCount < 1 then dispelCount = 1 end
        if interruptCount < 1 then interruptCount = 1 end

        return {
            damage = dmg,
            healing = heal,
            overhealing = oh,
            rawHealing = heal + oh,
            absorbs = math.floor(heal * 0.1),
            damageTaken = math.floor(40000 / (math.mod(i, 5) + 1) + math.random(0, 1500)),
            dispels = {
                count = dispelCount,
                list = fillList(dispelCount, { "Shadow Word: Pain", "Curse of Weakness", "Serpent Sting", "Corruption" }),
            },
            interrupts = {
                count = interruptCount,
                list = fillList(interruptCount, { "Kick", "Pummel", "Counterspell", "Earth Shock" }),
            },
            ccBreaks = {
                count = math.floor(3 / (math.mod(i, 4) + 1)) + 1,
                list = fillList(math.floor(3 / (math.mod(i, 4) + 1)) + 1, {
                    { spell = "Polymorph", target = "Sheep" },
                    { spell = "Sap", target = "RogueTarget" },
                    { spell = "Blind", target = "BlindTarget" },
                }),
            },
            deaths = {
                count = math.mod(i, 3) == 0 and 1 or 0,
                list = math.mod(i, 3) == 0 and { { killer = "Boss", spell = "Shadow Bolt", amount = 2500 } } or {},
            },
            damageTakenBy = { ["Boss"] = 5000, ["Add"] = 2000 },
            damageSpells = { ["Heroic Strike"] = dmg * 0.3, ["Bloodthirst"] = dmg * 0.25, ["Whirlwind"] = dmg * 0.2 },
            healSpells = { ["Holy Light"] = heal * 0.5, ["Flash of Light"] = heal * 0.3 },
            class = class,
        }
    end

    local players = {}
    for i = 1, 40 do
        local n = names[i] or ("Player"..i)
        local c = classes[((i - 1) - math.floor((i - 1) / 9) * 9) + 1]
        players[n] = makePlayer(i, c)
    end

    local duration = 180
    local now = GetTime()
    OM.data = OM.data or {}
    -- Enemy-centric CC test data
    local ccTargets = {
        ["Onyxia"] = { count = 3, duration = 90, list = {
            { spell = "Polymorph", duration = 50 },
            { spell = "Sap", duration = 30 },
            { spell = "Blind", duration = 10 },
        }},
        ["Onyxian Whelp"] = { count = 5, duration = 40, list = {
            { spell = "Sap", duration = 20 },
            { spell = "Gouge", duration = 4 },
            { spell = "Polymorph", duration = 16 },
        }},
        ["Onyxian Warder"] = { count = 2, duration = 56, list = {
            { spell = "Freezing Trap Effect", duration = 20 },
            { spell = "Hibernate", duration = 36 },
        }},
    }

    OM.data.current = {
        players = players,
        ccTargets = ccTargets,
        startTime = now - duration,
        endTime = now,
        duration = duration,
        label = "Test Raid",
        isBoss = true,
    }
    OM.data.overall = {
        players = players,
        ccTargets = ccTargets,
        startTime = now - duration,
        endTime = now,
        duration = duration,
        label = "Overall",
    }
    OM.data.recentFights = OM.data.recentFights or {}
    OM.data.bossFights = OM.data.bossFights or {}
end

DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00GreedMeter|r v1.0.4 loaded. Type /gdm")
