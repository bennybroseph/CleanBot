-- ============================================================
-- CommandControls.lua
-- Shared "command set" controls — Summon / Maintenance / Eat-Drink / Revive /
-- Release buttons + a Formation dropdown — used by the Manage tab's Party/Raid
-- section and the Individual/Group "Commands" inner tab. One builder keeps the
-- three in sync; each host supplies a `send(cmd)` that routes to its natural
-- scope (whole party/raid, the open bot, or the selected group's members).
-- ============================================================
local NS = CleanBotNS

-- Formation options for the dropdown. `token` is the lowercase value sent to the
-- bot's `formation <name>` command (SetFormationAction, src/Ai/Base/Value/Formations.cpp);
-- `desc` is the hover-tooltip behavior summary (drawn from each formation's source
-- positioning logic); `icon` flags a matching icons/formation_<token>.blp (false where
-- no icon ships yet — the tooltip then omits the icon).
NS.FORMATIONS = {
    { token = "chaos",  icon = true,  desc = "Loose, randomized spread around the leader (the default)." },
    { token = "near",   icon = true,  desc = "Hold a short, fixed distance behind the leader." },
    { token = "queue",  icon = true,  desc = "Single file, lined up directly behind the leader." },
    { token = "circle", icon = true,  desc = "Ring around the current target — casters spaced out, tanks in close." },
    { token = "line",   icon = true,  desc = "Abreast in a horizontal line beside the leader." },
    { token = "shield", icon = true,  desc = "Tanks hold a front line; DPS and healers form a back line." },
    { token = "arrow",  icon = true,  desc = "Wedge / V shape trailing behind the leader." },
    { token = "melee",  icon = true,  desc = "Packed in close, at melee range of the leader." },
    { token = "far",    icon = true,  desc = "Hold at a long distance from the leader." },
}

--- Broadcasts a command to the whole party/raid via chat (every bot reacts).
--- Used by the Manage tab, which has no single selection.
---@param cmd string  The bot command to broadcast.
NS.CB_SendGroupCommand = function(cmd)
    if GetNumRaidMembers() > 0 then
        SendChatMessage(cmd, "RAID")
    elseif GetNumPartyMembers() > 0 then
        SendChatMessage(cmd, "PARTY")
    else
        NS.CB_Print("You are not in a party or raid.")
        return
    end
    -- The broadcast reaches every bot and each may whisper a reply (e.g. formation's
    -- "Formation: ..."). Open a reply window per managed bot so ChatFilter hides those
    -- replies — the per-bot whisper path does this automatically via CB_SendBotCommandRaw.
    if NS.CB_MarkExpectReply and NS.CB_ForEachGroupMember then
        NS.CB_ForEachGroupMember(function(_, name)
            if name and CleanBot_PartyBots[strlower(name)] then NS.CB_MarkExpectReply(name) end
        end)
    end
end

-- Group-wide Passive state, broadcast-style (shared by the Manage tab's Passive checkbox and the
-- action bar's Passive toggle). Read is an OR: "any bot passive" → on, so toggling off is the
-- easy common case. Set is a blanket flip: cache every known member's state + broadcast the toggle.

--- True when ANY group member is cached as passive.
---@return boolean
NS.CB_GetGroupPassive = function()
    local any = false
    if NS.CB_ForEachGroupMember then
        NS.CB_ForEachGroupMember(function(_, name)
            local e = name and CleanBot_PartyBots[strlower(name)]
            if e and e.combat and e.combat.passive == true then any = true end
        end)
    end
    return any
end

--- Sets every group member passive on/off: optimistically caches the state, then broadcasts.
---@param on boolean
NS.CB_SetGroupPassive = function(on)
    if NS.CB_ForEachGroupMember then
        NS.CB_ForEachGroupMember(function(_, name)
            local e = name and CleanBot_PartyBots[strlower(name)]
            if e then e.combat = e.combat or {}; e.combat.passive = on end
        end)
    end
    NS.CB_SendGroupCommand("co " .. (on and "+passive" or "-passive"))
end

-- Group-wide movement mode, broadcast-style (shared by the action bar's Follow/Flee/Stay flyout). The
-- five movement strategies are mutually exclusive, so a "value" is the single active one per state
-- (combat = entry.combat, non-combat = entry.nonCombat). NS.MOVEMENT_STRATEGIES (Strategies.lua) is
-- read at call time — it loads after this file.

--- Builds the exclusive "+sel,-others" toggle body that selects one movement field (nil = Free Roam,
--- clears all five).
---@param selField string?  The chosen strategy's field (e.g. "mFollow"), or nil to clear.
---@return string           Comma-joined toggle body (no "co"/"nc" prefix).
NS.CB_MovementToggleString = function(selField)
    local parts = {}
    for _, m in ipairs(NS.MOVEMENT_STRATEGIES or {}) do
        parts[#parts + 1] = (m.field == selField and "+" or "-") .. m.cmd
    end
    return table.concat(parts, ",")
end

--- True when ANY group member has `field` as its active movement in `section` ("combat"/"nonCombat").
---@param section string  "combat" or "nonCombat".
---@param field   string  Movement field (e.g. "mFollow").
---@return boolean
NS.CB_GroupMovementActive = function(section, field)
    local any = false
    if NS.CB_ForEachGroupMember then
        NS.CB_ForEachGroupMember(function(_, name)
            local e = name and CleanBot_PartyBots[strlower(name)]
            if e and e[section] and e[section][field] then any = true end
        end)
    end
    return any
end

--- Sets every group member's movement in `section` to `selField` (nil = Free Roam): optimistically
--- caches the exclusive state, then broadcasts the matching co/nc toggle.
---@param section   string   "combat" (→ "co") or "nonCombat" (→ "nc").
---@param selField  string?  Movement field to select, or nil to clear all five.
NS.CB_SetGroupMovement = function(section, selField)
    if NS.CB_ForEachGroupMember then
        NS.CB_ForEachGroupMember(function(_, name)
            local e = name and CleanBot_PartyBots[strlower(name)]
            if e then
                e[section] = e[section] or {}
                for _, m in ipairs(NS.MOVEMENT_STRATEGIES or {}) do e[section][m.field] = (m.field == selField) end
            end
        end)
    end
    local prefix = (section == "combat") and "co" or "nc"
    NS.CB_SendGroupCommand(prefix .. " " .. NS.CB_MovementToggleString(selField))
end

-- Refreshes every Commands-tab control (formation dropdowns + passive checkboxes) from its
-- host's getter. Called when a relevant reply lands, on bot/group selection, and on
-- combat-data updates (mirrors how the bot-frame registries are repainted on data updates).
NS.commandRefreshers = NS.commandRefreshers or {}
NS.CB_RefreshCommands = function()
    for _, fn in ipairs(NS.commandRefreshers) do fn() end
end

-- Builds the command buttons + Formation dropdown into `parent`, anchored to its
-- top-left. Every control composes its command and calls send(cmd); the caller
-- decides delivery (broadcast / open bot / selected members). The collapsible
-- section box (if any) is owned by the caller, not here — so this lays out cleanly
-- inside both a Manage section bg and a bare inner-tab content frame.
--
-- describeTarget() returns a possessive phrase naming the host's target ("Thrall's",
-- "the selected bots'", "your party/raid bots'") for the Auto Equip confirmation.
-- formationGet/Set make the dropdown reflect the host's CURRENT formation:
--   formationGet() → a token | NS.MIXED (→ "Mixed") | nil (→ "Select…"). nil getter
--     means "action-only" (Manage): the dropdown just shows the last picked value.
--   formationSet(token) → optimistically cache the pick on the host's bot(s) so the
--     display stays stable until the (suppressed) confirming reply arrives.
---@param parent         table              Container the controls anchor into.
---@param tag            string             Disambiguates this instance's global frame names.
---@param send           fun(cmd:string)    Delivers a composed command to the host's target scope.
---@param describeTarget fun():string       Possessive phrase naming the target (Auto Equip confirm).
---@param formationGet   fun():any|nil      Returns the current formation token / NS.MIXED / nil.
---@param formationSet   fun(token:string)? Optimistically caches a picked formation.
---@param passiveGet     fun():boolean|nil  Current passive state: true/false, or NS.MIXED. Individual
---                                          = the open bot; Group = all-agree-or-MIXED; Manage = OR
---                                          ("any bot passive" → on, a global toggle). nil = no getter.
---@param passiveSet     fun(on:boolean)?   Optimistically caches the picked passive state on the host's bot(s).
---@param scopeBots      fun():table?       Returns the bots this host's commands target (each has a
---                                          `.key`). Used to refetch equipment after the gear commands.
---@return table                            The deepest widget built (for section Finalize / anchor chains).
NS.CB_BuildPartyRaidCommands = function(parent, tag, send, describeTarget, formationGet, formationSet, passiveGet, passiveSet, scopeBots)
    -- Register the Auto Equip confirmation popup once (lazily — CB_RegisterConfirmPopup
    -- is defined in a file that loads after this one, but the builder only runs at
    -- event time, by which point it exists). Context (which bots to gear) is passed
    -- per-click via StaticPopup_Show's data arg and read back in OnAccept.
    if not StaticPopupDialogs["CLEANBOT_AUTO_GEAR"] and NS.CB_RegisterConfirmPopup then
        NS.CB_RegisterConfirmPopup("CLEANBOT_AUTO_GEAR",
            "Replace all of %s equipment with auto-selected gear?",
            function(_, data) if data and data.onConfirm then data.onConfirm() end end)
    end

    local function mkBtn(suffix, label, cmd)
        return NS.CB_CreateButton(parent, "CleanBotCmd" .. suffix .. "Btn_" .. tag,
            label, 120, 24, function() send(cmd) end)
    end

    -- After a gear-changing command (equip upgrade / autogear), the bot's equipment may have changed
    -- server-side. Refetch it for any targeted bot that has a bound model/paperdoll (NS.tabList — the
    -- only bots whose gear is on screen), after a delay so the server has applied the change. The live
    -- unit comes from the slot; CB_RefreshEquipSlots then re-snapshots the model only if gear changed.
    local function queueEquipRefresh()
        if not (scopeBots and NS.CB_QueueEquipRefresh) then return end
        local affected = {}
        for _, b in ipairs(scopeBots() or {}) do affected[b.key] = true end
        NS.CB_After(1.5, function()
            local toRefresh = {}
            for _, slot in ipairs(NS.tabList or {}) do
                if affected[slot.key] and slot.unit and UnitExists(slot.unit) then
                    toRefresh[#toRefresh + 1] = { key = slot.key, unit = slot.unit }
                end
            end
            if #toRefresh > 0 then NS.CB_QueueEquipRefresh(toRefresh) end
        end)
    end

    -- Title-cases a formation token for display ("arrow" → "Arrow"); the lowercase
    -- token is what gets sent.
    local function titleCase(s) return strupper(strsub(s, 1, 1)) .. strsub(s, 2) end
    local ICON_PATH = "Interface\\AddOns\\CleanBot\\icons\\formation_"
    local ICON_SIZE = 48   -- inline tooltip icon size (px); independent of the text font

    -- Formation (top of the section): pick a formation → send "formation <name>".
    local formationLabel = NS.CB_CreateLabel(parent, "Formation")
    NS.CB_AnchorWall(formationLabel, parent, "TOPLEFT")

    local formationDD = NS.CB_CreateDropdown(parent, "CleanBotCmdFormation_" .. tag, 140)
    NS.CB_AnchorBelow(formationDD, formationLabel)
    UIDropDownMenu_SetText(formationDD, "Select\226\128\166")  -- "Select…"
    UIDropDownMenu_Initialize(formationDD, function()
        for _, f in ipairs(NS.FORMATIONS) do
            local label       = titleCase(f.token)
            local info        = UIDropDownMenu_CreateInfo()
            info.text         = label
            info.value        = f.token
            info.notCheckable = 1
            -- Hover tooltip: behavior summary titled with the formation's icon (inline
            -- texture markup) when one ships in icons/, anchored to the menu item.
            info.tooltipOnButton = 1
            info.tooltipTitle    = f.icon
                and ("|T" .. ICON_PATH .. f.token .. ":" .. ICON_SIZE .. "|t " .. label) or label
            info.tooltipText     = f.desc
            info.func            = function()
                UIDropDownMenu_SetText(formationDD, label)       -- immediate feedback
                if formationSet then formationSet(f.token) end   -- optimistic cache
                send("formation " .. f.token)                    -- server expects the lowercase token
                NS.CB_RefreshCommands()
            end
            UIDropDownMenu_AddButton(info)
        end
    end)

    -- Reflect the host's current formation. No-op when there's no getter (Manage is
    -- action-only), so a pick's label survives.
    local function refresh()
        if not formationGet then return end
        local cur = formationGet()
        if cur == NS.MIXED then
            UIDropDownMenu_SetText(formationDD, "Mixed")
        elseif cur then
            UIDropDownMenu_SetText(formationDD, titleCase(cur))
        else
            UIDropDownMenu_SetText(formationDD, "Select\226\128\166")  -- "Select…"
        end
    end
    refresh()
    NS.commandRefreshers[#NS.commandRefreshers + 1] = refresh

    -- Command grid below the formation row.
    -- Column 1: Summon / Maintenance / Auto-Equip / Auto Gear.
    local summonBtn = mkBtn("Summon", "Summon", "summon")
    NS.CB_AnchorBelow(summonBtn, formationDD)

    -- Maintenance ("maintenance" → AutoMaintenanceOnLevelupAction): brings the bot up to date for
    -- its level — re-trains talents, learns class/trainer spells and professions, and restocks
    -- consumables (food/water/reagents/ammo/potions). Does not repair or sell; only teleports if
    -- the server's autoTeleportForLevel is on (off by default).
    local maintenanceBtn = mkBtn("Maintenance", "Maintenance", "maintenance")
    NS.CB_SetTooltip(maintenanceBtn, "Maintenance",
        "Brings the bot up to date for its level: re-trains talents, learns class/trainer spells and professions, and restocks consumables (food, water, reagents, ammo, potions). Doesn't repair or sell anything.")
    NS.CB_AnchorBelow(maintenanceBtn, summonBtn)

    -- Equip Upgrades ("equip upgrade"): equips stat upgrades found in the bot's bags. Non-destructive
    -- (only swaps in improvements), so no confirmation — unlike Auto Gear which re-gears wholesale.
    -- Changes gear, so refetch equipment afterward (queueEquipRefresh) to update the paperdoll/model.
    local autoEquipBtn = NS.CB_CreateButton(parent, "CleanBotCmdAutoEquipBtn_" .. tag,
        "Equip Upgrades", 120, 24, function() send("equip upgrade"); queueEquipRefresh() end)
    NS.CB_SetTooltip(autoEquipBtn, "Equip Upgrades",
        "Equips stat upgrades found in the bot's bags. Only swaps in improvements — never downgrades or unequips, so it's safe to use any time.")
    NS.CB_AnchorBelow(autoEquipBtn, maintenanceBtn)

    -- Auto Gear (col 1): auto-equip a fresh gear set ("autogear"). Destructive (replaces all
    -- equipment), so it's gated behind a Yes/No confirmation naming the target.
    local autoGearBtn = NS.CB_CreateButton(parent, "CleanBotCmdAutoGearBtn_" .. tag,
        "Auto Gear", 120, 24, function()
            StaticPopup_Show("CLEANBOT_AUTO_GEAR",
                (describeTarget and describeTarget()) or "this bot's", nil,
                { onConfirm = function() send("autogear"); queueEquipRefresh() end })
        end)
    NS.CB_SetTooltip(autoGearBtn, "Auto Gear",
        "Replaces the bot's entire equipment with an auto-selected gear set, re-gearing from scratch. Destructive — you'll be asked to confirm first.")
    NS.CB_AnchorBelow(autoGearBtn, autoEquipBtn)

    -- Column 2: Roll / Revive / Release / Eat-Drink.
    local rollBtn = mkBtn("Roll", "Roll", "roll")   -- bot does a /random 0-100
    NS.CB_AnchorAhead(rollBtn, summonBtn)

    local reviveBtn = mkBtn("Revive", "Revive", "revive")
    NS.CB_AnchorAhead(reviveBtn, maintenanceBtn)

    local releaseBtn = mkBtn("Release", "Release", "release")
    NS.CB_AnchorAhead(releaseBtn, autoEquipBtn)

    local eatDrinkBtn = mkBtn("EatDrink", "Eat/Drink", "drink")
    NS.CB_AnchorAhead(eatDrinkBtn, autoGearBtn)

    -- Passive (last item): a combat-strategy toggle surfaced here as a command. Sends
    -- "co +passive"/"co -passive" to the host's scope and reflects the host's current state
    -- (true / false / NS.MIXED → " (?)"). When passiveGet is nil (Manage is action-only) the
    -- checkbox just reflects its last click. Refreshed via NS.commandRefreshers like formation.
    local passiveCB, passiveLbl = NS.CB_CreateLabeledCheckBox(parent, "CleanBotCmdPassiveCB_" .. tag,
        "Passive", "Stand down — do nothing in combat")
    NS.CB_AnchorBelow(passiveCB, autoGearBtn)

    passiveCB:SetScript("OnClick", function(self)
        local checked = self:GetChecked() and true or false
        if passiveSet then passiveSet(checked) end
        send("co " .. (checked and "+passive" or "-passive"))
        NS.CB_RefreshCommands()
    end)

    -- Reflect the host's current passive state. No-op without a getter (Manage is action-only).
    local function refreshPassive()
        if not passiveGet then return end
        local v = passiveGet()
        passiveCB:SetChecked(v == true)
        passiveLbl:SetText(v == NS.MIXED and "Passive (?)" or "Passive")
    end
    refreshPassive()
    NS.commandRefreshers[#NS.commandRefreshers + 1] = refreshPassive

    return passiveCB
end
