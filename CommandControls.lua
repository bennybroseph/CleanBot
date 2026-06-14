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
---@return table                            The deepest widget built (for section Finalize / anchor chains).
NS.CB_BuildPartyRaidCommands = function(parent, tag, send, describeTarget, formationGet, formationSet, passiveGet, passiveSet)
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

    -- Title-cases a formation token for display ("arrow" → "Arrow"); the lowercase
    -- token is what gets sent.
    local function titleCase(s) return strupper(strsub(s, 1, 1)) .. strsub(s, 2) end
    local ICON_PATH = "Interface\\AddOns\\CleanBot\\icons\\formation_"
    local ICON_SIZE = 48   -- inline tooltip icon size (px); independent of the text font

    -- Formation (top of the section): pick a formation → send "formation <name>".
    local formationLabel = NS.CB_CreateLabel(parent, "Formation")
    formationLabel:SetPoint("TOPLEFT", parent, "TOPLEFT",
        (parent.paddingLeft or 0) + (formationLabel.marginLeft or 0),
      -((parent.paddingTop  or 0) + (formationLabel.marginTop  or 0)))

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
    -- Column 1: Summon / Maintenance / Auto Gear.
    local summonBtn = mkBtn("Summon", "Summon", "summon")
    NS.CB_AnchorBelow(summonBtn, formationDD)

    local maintenanceBtn = mkBtn("Maintenance", "Maintenance", "maintenance")
    NS.CB_AnchorBelow(maintenanceBtn, summonBtn)

    -- Auto Gear (col 1, row 3): auto-equip a fresh gear set ("autogear"). Destructive
    -- (replaces all equipment), so it's gated behind a Yes/No confirmation naming the target.
    local autoGearBtn = NS.CB_CreateButton(parent, "CleanBotCmdAutoGearBtn_" .. tag,
        "Auto Gear", 120, 24, function()
            StaticPopup_Show("CLEANBOT_AUTO_GEAR",
                (describeTarget and describeTarget()) or "this bot's", nil,
                { onConfirm = function() send("autogear") end })
        end)
    NS.CB_AnchorBelow(autoGearBtn, maintenanceBtn)

    -- Column 2: Revive / Release / Eat-Drink.
    local reviveBtn = mkBtn("Revive", "Revive", "revive")
    NS.CB_AnchorAhead(reviveBtn, summonBtn)

    local releaseBtn = mkBtn("Release", "Release", "release")
    NS.CB_AnchorAhead(releaseBtn, maintenanceBtn)

    local eatDrinkBtn = mkBtn("EatDrink", "Eat/Drink", "drink")
    NS.CB_AnchorAhead(eatDrinkBtn, autoGearBtn)

    -- Passive (last item): a combat-strategy toggle surfaced here as a command. Sends
    -- "co +passive"/"co -passive" to the host's scope and reflects the host's current state
    -- (true / false / NS.MIXED → " (?)"). When passiveGet is nil (Manage is action-only) the
    -- checkbox just reflects its last click. Refreshed via NS.commandRefreshers like formation.
    local passiveCB = NS.CB_CreateCheckBox(parent, "CleanBotCmdPassiveCB_" .. tag)
    passiveCB:SetSize(20, 20)
    NS.CB_AnchorBelow(passiveCB, autoGearBtn)

    local passiveLbl = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    passiveLbl:SetPoint("LEFT", passiveCB, "RIGHT", 4, 0)
    passiveLbl:SetText("Passive")

    passiveCB:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Passive", 1, 1, 1)
        GameTooltip:AddLine("Stand down — do nothing in combat", 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    passiveCB:SetScript("OnLeave", function() GameTooltip:Hide() end)

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
