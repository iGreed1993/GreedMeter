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
        OM:ResetData()
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
    elseif cmd == "cust" or cmd == "custom" or cmd == "customization" then
        local ui = (OM.modules and OM.modules.UI) or OM.UI
        if ui and ui.ToggleCustomization then
            ui:ToggleCustomization()
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cffff5555GreedMeter:|r Customization not loaded (UI/Customization.lua missing or failed).")
            DEFAULT_CHAT_FRAME:AddMessage("|cffff5555|r Loaded flag: " .. tostring(OM._customizationLoaded))
        end
    elseif cmd == "pause" then
        if OM.TogglePause then
            OM:TogglePause()
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cffff5555GreedMeter:|r Pause is unavailable.")
        end
    elseif cmd == "help" then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00GreedMeter commands:|r")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffffffff/gdm|r or |cffffffff/gdm show|r - show/hide meters")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffffffff/gdm set|r or |cffffffff/gdm settings|r - open settings")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffffffff/gdm cust|r - open customization")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffffffff/gdm pause|r - freeze meters on a Paused snapshot (toggle)")
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

    -- Class-flavored spell lists for detail-window testing
    local DMG_SPELLS = {
        WARRIOR = { "Heroic Strike", "Bloodthirst", "Whirlwind", "Execute", "Auto Attack" },
        MAGE    = { "Frostbolt", "Fireball", "Scorch", "Arcane Missiles", "Auto Attack" },
        ROGUE   = { "Sinister Strike", "Eviscerate", "Backstab", "Auto Attack" },
        DRUID   = { "Wrath", "Starfire", "Moonfire", "Shred", "Auto Attack" },
        HUNTER  = { "Aimed Shot", "Multi-Shot", "Arcane Shot", "Auto Shot" },
        SHAMAN  = { "Lightning Bolt", "Stormstrike", "Earth Shock", "Auto Attack" },
        PRIEST  = { "Mind Blast", "Shadow Word: Pain", "Smite", "Auto Attack" },
        WARLOCK = { "Shadow Bolt", "Corruption", "Searing Pain", "Auto Attack" },
        PALADIN = { "Crusader Strike", "Judgement", "Consecration", "Auto Attack" },
    }
    local HEAL_SPELLS = {
        PRIEST  = { "Flash Heal", "Greater Heal", "Renew", "Prayer of Healing" },
        DRUID   = { "Healing Touch", "Regrowth", "Rejuvenation", "Tranquility" },
        SHAMAN  = { "Healing Wave", "Lesser Healing Wave", "Chain Heal" },
        PALADIN = { "Holy Light", "Flash of Light", "Holy Shock" },
        -- non-healers still get a tiny heal sample for UI testing
        WARRIOR = { "Bandage" },
        MAGE    = { "Bandage" },
        ROGUE   = { "Bandage" },
        HUNTER  = { "Bandage" },
        WARLOCK = { "Health Funnel" },
    }
    local TEST_TARGETS = { "Onyxia", "Onyxian Warder", "Onyxian Whelp", "Guard" }
    local HEAL_TARGETS = { "Grommash", "Jaina", "Thrall", "Anduin", "Uther" }

    local function makeDetail(totalAmt, isHeal, seed, isMelee)
        seed = seed or 1
        local hits = 8 + math.mod(seed * 3, 20)
        local crits = 1 + math.mod(seed, 6)
        local misses, blocks, glances, resists, partials = 0, 0, 0, 0, 0
        if not isHeal then
            -- Everyone gets a mix so the unified table is easy to verify
            misses = math.mod(seed, 4)
            blocks = math.mod(seed + 3, 3)
            glances = math.mod(seed + 1, 3)
            resists = math.mod(seed, 5)
            partials = 1 + math.mod(seed + 2, 4)
        end
        local count = hits + crits + glances
        if count < 1 then count = 1 end
        local avg = totalAmt / count
        local minV = math.floor(avg * 0.55 + 0.5)
        local maxV = math.floor(avg * 1.55 + 0.5)
        if minV < 1 then minV = 1 end
        if maxV < minV then maxV = minV end
        return {
            hits = hits,
            crits = crits,
            misses = misses,
            blocks = blocks,
            glances = glances,
            resists = resists,
            partials = partials,
            total = totalAmt,
            count = count,
            min = minV,
            max = maxV,
            byTarget = {},
        }
    end

    local function splitAcrossTargets(detail, targets, seed)
        if not detail or not targets or table.getn(targets) == 0 then return end
        local n = table.getn(targets)
        local left = detail.total or 0
        local ti
        for ti = 1, n do
            local share
            if ti == n then
                share = left
            else
                share = math.floor((detail.total or 0) * (0.45 / ti) + math.mod(seed + ti, 7) * 30)
                if share > left then share = left end
                if share < 0 then share = 0 end
            end
            left = left - share
            local tHits = math.floor((detail.hits or 0) / n) + (math.mod(ti + seed, 2))
            local tCrits = math.floor((detail.crits or 0) / n)
            if ti == 1 then
                tHits = tHits + math.mod(detail.hits or 0, n)
                tCrits = tCrits + math.mod(detail.crits or 0, n)
            end
            local tGlances = 0
            if (detail.glances or 0) > 0 then
                tGlances = math.floor((detail.glances or 0) / n)
                if ti == 1 then tGlances = tGlances + math.mod(detail.glances or 0, n) end
            end
            tCount = tHits + tCrits + tGlances
            if tCount < 1 and share > 0 then tCount = 1 end
            local avg = 0
            if tCount > 0 then avg = share / tCount end
            local minV = math.floor(avg * 0.6 + 0.5)
            local maxV = math.floor(avg * 1.4 + 0.5)
            if minV < 1 and share > 0 then minV = 1 end
            if maxV < minV then maxV = minV end
            detail.byTarget[targets[ti]] = {
                hits = tHits,
                crits = tCrits,
                misses = (ti == 1) and (detail.misses or 0) or 0,
                blocks = (ti == 1) and (detail.blocks or 0) or 0,
                glances = tGlances,
                resists = (ti == 1) and (detail.resists or 0) or 0,
                partials = (ti == 1) and (detail.partials or 0) or 0,
                total = share,
                count = tCount,
                min = minV,
                max = maxV,
            }
        end
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

        local dmgNames = DMG_SPELLS[class] or DMG_SPELLS.WARRIOR
        local healNames = HEAL_SPELLS[class] or { "Bandage" }
        local weights = { 0.32, 0.24, 0.18, 0.14, 0.12 }
        local damageSpells = {}
        local damageSpellDetails = {}
        local damageTo = {}
        local si
        local assigned = 0
        for si = 1, table.getn(dmgNames) do
            local w = weights[si] or (0.08)
            local amt
            if si == table.getn(dmgNames) then
                amt = dmg - assigned
            else
                amt = math.floor(dmg * w + 0.5)
                assigned = assigned + amt
            end
            if amt < 0 then amt = 0 end
            damageSpells[dmgNames[si]] = amt
            local isMelee = (class == "WARRIOR" or class == "ROGUE" or class == "HUNTER" or class == "PALADIN")
            local det = makeDetail(amt, false, i + si, isMelee)
            splitAcrossTargets(det, TEST_TARGETS, i + si)
            damageSpellDetails[dmgNames[si]] = det
            -- aggregate damageTo from byTarget
            local tn, td
            for tn, td in pairs(det.byTarget) do
                damageTo[tn] = (damageTo[tn] or 0) + (td.total or 0)
            end
        end

        local healSpells = {}
        local healSpellDetails = {}
        local healingTo = {}
        assigned = 0
        for si = 1, table.getn(healNames) do
            local w = weights[si] or 0.15
            local amt
            if si == table.getn(healNames) then
                amt = heal - assigned
            else
                amt = math.floor(heal * w + 0.5)
                assigned = assigned + amt
            end
            if amt < 0 then amt = 0 end
            healSpells[healNames[si]] = amt
            local det = makeDetail(amt, true, i + si + 10, false)
            splitAcrossTargets(det, HEAL_TARGETS, i + si)
            healSpellDetails[healNames[si]] = det
            local tn, td
            for tn, td in pairs(det.byTarget) do
                healingTo[tn] = (healingTo[tn] or 0) + (td.total or 0)
            end
        end

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
            damageTakenBy = { ["Onyxia"] = 5000, ["Onyxian Warder"] = 2000, ["Guard"] = 800 },
            damageSpells = damageSpells,
            healSpells = healSpells,
            damageSpellDetails = damageSpellDetails,
            healSpellDetails = healSpellDetails,
            damageTo = damageTo,
            healingTo = healingTo,
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

DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00GreedMeter|r v1.2.1 loaded. Type /gdm")


-- ============================================================
-- Pause: one frozen snapshot segment ("paused")
-- Live parsing still fills current/overall; the Paused view does not change.
-- ============================================================
function OM:TogglePause()
    local UI = (self.modules and self.modules.UI) or self.UI
    local Parser = self.modules and self.modules.Parser

    if self.meterPaused then
        -- Resume previous segment on every window
        self.meterPaused = false
        if UI and UI.frames then
            local _, f
            for _, f in ipairs(UI.frames) do
                if f.segment == "paused" then
                    f.segment = f._segmentBeforePause or "current"
                end
                f._segmentBeforePause = nil
            end
            if UI.Refresh then UI:Refresh() end
        end
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00GreedMeter:|r Resumed — back to previous segment.")
        return
    end

    -- Build / overwrite the single paused snapshot from Current
    if Parser and Parser.CreatePausedSnapshot then
        Parser:CreatePausedSnapshot()
    else
        -- Fallback shallow freeze if parser helper missing
        if not self.data then return end
        self.data.paused = self.data.current
    end

    self.meterPaused = true
    if UI and UI.frames then
        local _, f
        for _, f in ipairs(UI.frames) do
            f._segmentBeforePause = f.segment or "current"
            f.segment = "paused"
        end
        if UI.Refresh then UI:Refresh() end
    end
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00GreedMeter:|r Paused — meters show frozen snapshot. /gdm pause again to resume.")
end
