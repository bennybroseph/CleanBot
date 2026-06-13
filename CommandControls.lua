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

-- Builds the command buttons + Formation dropdown into `parent`, anchored to its
-- top-left. Every control composes its command and calls send(cmd); the caller
-- decides delivery (broadcast / open bot / selected members). The collapsible
-- section box (if any) is owned by the caller, not here — so this lays out cleanly
-- inside both a Manage section bg and a bare inner-tab content frame.
---@param parent table             Container the controls anchor into.
---@param tag    string            Disambiguates this instance's global frame names.
---@param send   fun(cmd:string)   Delivers a composed command to the host's target scope.
---@return table                   The deepest widget built (for section Finalize / anchor chains).
NS.CB_BuildPartyRaidCommands = function(parent, tag, send)
    local function mkBtn(suffix, label, cmd)
        return NS.CB_CreateButton(parent, "CleanBotCmd" .. suffix .. "Btn_" .. tag,
            label, 120, 24, function() send(cmd) end)
    end

    -- Column 1: Summon / Maintenance / Eat-Drink.
    local summonBtn = mkBtn("Summon", "Summon", "summon")
    summonBtn:SetPoint("TOPLEFT", parent, "TOPLEFT",
        (parent.paddingLeft or 0) + (summonBtn.marginLeft or 0),
      -((parent.paddingTop  or 0) + (summonBtn.marginTop  or 0)))

    local maintenanceBtn = mkBtn("Maintenance", "Maintenance", "maintenance")
    NS.CB_AnchorBelow(maintenanceBtn, summonBtn)

    local eatDrinkBtn = mkBtn("EatDrink", "Eat/Drink", "drink")
    NS.CB_AnchorBelow(eatDrinkBtn, maintenanceBtn)

    -- Column 2: Revive / Release.
    local reviveBtn = mkBtn("Revive", "Revive", "revive")
    NS.CB_AnchorAhead(reviveBtn, summonBtn)

    local releaseBtn = mkBtn("Release", "Release", "release")
    NS.CB_AnchorAhead(releaseBtn, maintenanceBtn)

    -- Formation: pick a formation → send "formation <name>".
    local formationLabel = NS.CB_CreateLabel(parent, "Formation")
    NS.CB_AnchorBelow(formationLabel, eatDrinkBtn)

    -- Title-cases a formation token for display ("arrow" → "Arrow"); the lowercase
    -- token is what gets sent.
    local function titleCase(s) return strupper(strsub(s, 1, 1)) .. strsub(s, 2) end
    local ICON_PATH = "Interface\\AddOns\\CleanBot\\icons\\formation_"
    local ICON_SIZE = 48   -- inline tooltip icon size (px); independent of the text font

    local formationDD = NS.CB_CreateDropdown(parent, "CleanBotCmdFormation_" .. tag, 120)
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
                UIDropDownMenu_SetText(formationDD, label)
                send("formation " .. f.token)  -- server expects the lowercase token
            end
            UIDropDownMenu_AddButton(info)
        end
    end)

    return formationDD
end
