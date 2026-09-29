---@class FocusSuperTrack
local FocusSuperTrack = QuestieLoader:CreateModule("FocusSuperTrack")

---@type TrackerUtils
local TrackerUtils = QuestieLoader:ImportModule("TrackerUtils")
---@type QuestieQuest
local QuestieQuest = QuestieLoader:ImportModule("QuestieQuest")
---@type QuestiePlayer
local QuestiePlayer = QuestieLoader:ImportModule("QuestiePlayer")
---@type ThreadLib
local ThreadLib = QuestieLoader:ImportModule("ThreadLib")

-- Two-way bridge between Questie's Focus and Blizzard's super-tracking.
--   FORWARD (focusToSuperTrack): focusing a quest/objective also super-tracks it, so the native
--     waypoint arrow (and WaypointUI's flare, which reads the super-tracked quest) point to it, in
--     addition to Questie dimming the other map icons.
--   REVERSE (superTrackToFocus): when the super-tracked quest changes (e.g. clicking a Blizzard POI
--     pin) that quest is Focused in Questie; deselecting clears the focus the reverse path created.
-- The client exposes the full C_SuperTrack namespace; guard so this no-ops where it's absent.
local hasSuperTrack = C_SuperTrack ~= nil and type(C_SuperTrack.SetSuperTrackedQuestID) == "function"

-- The quest id we last super-tracked ourselves, so UnFocus only clears OUR super-track (never the
-- user's own POI-pin selection); and the quest the REVERSE path focused, so a deselect only
-- unfocuses what the reverse path created, not a manual right-click focus.
local lastSynced
local lastReverseFocused

---@return number? @The focused quest id (number focus == quest, "id idx" string == objective), or nil
local function FocusedQuestId()
    local focus = Questie.db.char.TrackerFocus
    if type(focus) == "number" then
        return focus
    elseif type(focus) == "string" then
        return tonumber((strsplit(" ", focus)))
    end
    return nil
end

-- Redraw the map icons to match the current focus/fade state. Uses HideQuestIcons for BOTH focus and
-- unfocus on purpose: it iterates EVERY quest icon and reapplies the FadeIcons flags that
-- FocusQuest/FocusObjective/UnFocus just set, without touching townsfolk/manual icons (ToggleNotes
-- toggles those and floods them back). Must run inside a coroutine (HideQuestIcons asserts one).
local function RedrawFocus()
    if not (QuestieQuest and ThreadLib and ThreadLib.ThreadInstant) then
        return
    end
    ThreadLib.ThreadInstant(function()
        QuestieQuest:HideQuestIcons()
    end)
end

-- FORWARD: mirror a Questie focus onto Blizzard super-tracking. Idempotent (compares the current
-- super-tracked id first) so it can't bounce against the reverse handler.
local function SyncSuperTrack(questId)
    if not (hasSuperTrack and questId and Questie.db.profile.focusToSuperTrack) then
        return
    end
    if C_SuperTrack.GetSuperTrackedQuestID() == questId then
        return
    end
    C_SuperTrack.SetSuperTrackedQuestID(questId)
    lastSynced = questId
end

local function ClearSuperTrackIfOurs()
    if not hasSuperTrack then
        return
    end
    if lastSynced and C_SuperTrack.GetSuperTrackedQuestID() == lastSynced then
        C_SuperTrack.SetSuperTrackedQuestID(0)
    end
    lastSynced = nil
end

-- REVERSE: mirror a Blizzard super-track change onto Questie's focus ("focus selected quests").
local function OnSuperTrackingChanged()
    if not Questie.db.profile.superTrackToFocus then
        return
    end
    local questId = C_SuperTrack.GetSuperTrackedQuestID()
    if questId and questId > 0 then
        if not (QuestiePlayer.currentQuestlog and QuestiePlayer.currentQuestlog[questId]) then
            return -- only focus quests the player actually has
        end
        if FocusedQuestId() == questId then
            return -- already focused (e.g. the forward path just set this)
        end
        TrackerUtils:FocusQuest(questId)
        lastReverseFocused = questId
    else
        -- Deselected: only clear a focus the reverse path created, not a manual focus.
        if lastReverseFocused and FocusedQuestId() == lastReverseFocused then
            TrackerUtils:UnFocus()
        end
        lastReverseFocused = nil
    end
end

function FocusSuperTrack.Initialize()
    if not (TrackerUtils and TrackerUtils.FocusQuest) then
        return
    end

    -- Single redraw choke point for every focus path (right-click menu, ctrl-click, reverse). The
    -- redraw always runs (it replaces the menu's old ToggleNotes redraw); the super-track sync is
    -- gated by the focusToSuperTrack option. hooksecurefunc runs after the original, so the
    -- FadeIcons flags are already set when we redraw.
    hooksecurefunc(TrackerUtils, "FocusQuest", function(_, questId)
        RedrawFocus()
        SyncSuperTrack(questId)
    end)
    hooksecurefunc(TrackerUtils, "FocusObjective", function(_, questId)
        RedrawFocus()
        SyncSuperTrack(questId)
    end)
    hooksecurefunc(TrackerUtils, "UnFocus", function()
        RedrawFocus()
        ClearSuperTrackIfOurs()
    end)

    if hasSuperTrack then
        Questie:RegisterEvent("SUPER_TRACKING_CHANGED", OnSuperTrackingChanged)
        -- Restore the native arrow for a persisted focus shortly after login (let the state settle).
        C_Timer.After(1, function()
            if Questie.db.profile.focusToSuperTrack then
                local focused = FocusedQuestId()
                if focused then
                    SyncSuperTrack(focused)
                end
            end
        end)
    end
end
