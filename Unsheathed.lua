-- Addon identity is used to ignore ADDON_LOADED events for other addons.
local ADDON_NAME = "Unsheathed"

-- Defaults are used for a character's first login or when a saved setting is
-- missing or invalid.
local DEFAULT_ENABLED = true
local DEFAULT_INCLUDE_ATTACKABLE_TARGETS = true
local DEFAULT_INCLUDE_COMBAT = true
local DEFAULT_SHEATHE = true
local DEFAULT_SHEATHE_DELAY = 3.0
local DEFAULT_USE_RANGED_WEAPON = false

-- These behavior switches are intentionally configured in this file rather
-- than exposed as per-character slash-command settings.
local DISABLE_POST_SHOOT_MAINHAND_IN_COMBAT = false
local INCLUDE_JUMPING_AND_FALLING = false
local WAIT_FOR_MOVEMENT_IN_COMBAT = true

-- Delay configuration:
-- COMBAT_DELAY is the normal delay before drawing a weapon.
-- ACTION_DELAY and CHAT_DELAY account for actions that may cause the client
-- to sheath weapons; SHEATHE_DELAY controls automatic sheathing after activity.
local ACTION_DELAY = 1.0
local CHAT_DELAY = 3.0
local COMBAT_DELAY = 0.5
local SHEATHE_DELAY = DEFAULT_SHEATHE_DELAY

-- Timings for polling, shoot handoff detection, and identifying sheaths caused
-- by the addon itself. These short windows help distinguish our own changes
-- from changes made by the game client.
local POLL_INTERVAL = 0.5
local SHOOT_HANDOFF_WINDOW = 1.5
local ADDON_SHEATHE_WINDOW = 1.0

-- Spell IDs used to recognize ranged Shoot activity and Auto Shot.
local SHOOT_SPELL_ID = 5019
local AUTO_SHOT_SPELL_ID = 75

-- Action-watch timings limit the amount of follow-up checking after a possible
-- client-triggered sheath, avoiding continuous polling while still catching
-- delayed state changes.
local ACTION_WATCH_FIRST_DELAY = 0.10
local ACTION_WATCH_REPEAT_DELAY = 0.20
local ACTION_WATCH_COUNT = 10
local ACTION_READY_GRACE = 2.5

-- ToggleSheath can cycle through multiple states. These retry timings let the
-- addon observe the result and continue toward its intended state when needed.
local TOGGLE_RETRY_DELAY = 0.20
local TOGGLE_UNCHANGED_RETRY_DELAY = 0.50

-- Aura IDs used to detect eating or drinking. Automatic weapon-state work is
-- paused while the player is sitting with one of these auras.
local EATING_DRINKING_AURA_IDS = {
    [430] = true,
    [431] = true,
    [432] = true,
    [2639] = true,
    [24005] = true,
}

-- Classes allowed to enable ranged-weapon preference through the slash command.
local RANGED_WEAPON_CLASSES = {
    HUNTER = true,
    MAGE = true,
    PRIEST = true,
    ROGUE = true,
    WARLOCK = true,
    WARRIOR = true,
}

-- The .toc declares this as a per-character saved variable.
UnsheathedDB = UnsheathedDB or {}

-- A single frame handles addon events and, only when needed, optional polling.
local frame = CreateFrame("Frame")

-- Runtime lifecycle and polling state.
local enabled = false
local initialized = false
local pollingEnabled = false
local pollElapsed = 0

-- These settings are loaded from UnsheathedDB when the addon initializes.
local USE_RANGED_WEAPON = DEFAULT_USE_RANGED_WEAPON
local INCLUDE_COMBAT = DEFAULT_INCLUDE_COMBAT
local INCLUDE_ATTACKABLE_TARGETS = DEFAULT_INCLUDE_ATTACKABLE_TARGETS
local SHEATHE = DEFAULT_SHEATHE

-- Cached gameplay conditions, refreshed by events and the optional poll.
local eventMoving = false
local moving = false
local inCombat = false
local attackableTarget = false
local autoRepeatActive = false

-- Aura and sitting state are cached so aura enumeration is not performed on
-- every state update.
local mealAuraActive = false
local playerSitting = false

-- Inventory slots and equipment-presence caches for both weapon types.
local mainHandSlot
local rangedSlot
local mainHandPresent = false
local rangedPresent = false

-- Previous observed state and short-lived markers used to identify expected
-- sheath transitions caused by the addon or by the player's chat action.
local lastObservedSheathState
local addonSheathePendingUntil = 0
local chatSheathePendingUntil = 0

-- Action timing state. The deadlines defer drawing after actions, while the
-- watcher chain catches a client sheath that occurs slightly later.
local actionDelayUntil = 0
local actionReadyUntil = 0
local actionTimer
local actionTimerGeneration = 0
local actionWatchPass = 0

-- Ranged-fire handoff state. A detected ranged sheath can trigger a main-hand
-- draw, or temporarily block that draw during combat when configured.
local lastShootActivityAt = -1000000
local postShootMainhand = false
local postShootCombatBlocked = false
local postShootBlockUntil = 0
local postShootBlockTimer
local postShootBlockGeneration = 0

-- Draw timer state and keys let repeated updates reuse an already-pending
-- request instead of continually replacing its timer.
local drawTimer
local drawTimerGeneration = 0
local drawTimerKey
local drawReadyKey

-- Delayed sheathing and the marker indicating that the delay has elapsed.
local sheatheTimer
local sheatheTimerGeneration = 0
local idleSheathing = false

-- Toggle retry state. The pending goal prevents multiple timers from pursuing
-- conflicting sheath states.
local toggleTimer
local toggleTimerGeneration = 0
local pendingToggleGoal

-- Forward declarations allow callbacks and helpers to refer to functions
-- defined later in the file.
local updateState
local onUpdateScript
local setEnabled

-- Safely test whether a client value is secret or otherwise unavailable.
-- Treat failures conservatively so protected values are not used in comparisons.
local function isSecret(value)
    if type(issecretvalue) ~= "function" then
        return false
    end

    local ok, result = pcall(issecretvalue, value)
    return not ok or result == true
end

-- Call a boolean-returning API defensively. Unsupported APIs, errors, and
-- secret values are treated as false.
local function safeBool(func, ...)
    if type(func) ~= "function" then
        return false
    end

    local ok, value = pcall(func, ...)
    if not ok or isSecret(value) then
        return false
    end

    return value == true or value == 1
end

-- Determine whether a casting API reports an active spell. Returning true for
-- secret values avoids drawing a weapon when the casting state cannot be read.
local function isFunctionCasting(func)
    if type(func) ~= "function" then
        return false
    end

    local ok, name = pcall(func, "player")
    if not ok then
        return false
    end

    if isSecret(name) then
        return true
    end

    return type(name) == "string" and name ~= ""
end

-- A weapon draw must wait while either a cast or a channel is active.
local function isCastingOrChanneling()
    return isFunctionCasting(UnitCastingInfo)
        or isFunctionCasting(UnitChannelInfo)
end

-- Read the current sheath state, returning nil if the API result is unavailable.
-- The client values are 1 = sheathed, 2 = melee, and 3 = ranged.
local function getSheathState()
    if type(GetSheathState) ~= "function" then
        return nil
    end

    local ok, state = pcall(GetSheathState)
    if not ok or isSecret(state) or type(state) ~= "number" then
        return nil
    end

    return state
end

-- Movement events are the primary movement signal. Falling is included only
-- when the file-level option is enabled.
local function isMovingNow()
    if eventMoving then
        return true
    end

    return INCLUDE_JUMPING_AND_FALLING and safeBool(IsFalling)
end

-- Combine the event cache with the game API so combat state remains accurate
-- if an event was missed or the cache has not yet refreshed.
local function isInCombatNow()
    return inCombat or safeBool(UnitAffectingCombat, "player")
end

-- Decide whether automatic sheath changes must pause during combat. Combat
-- behavior disabled means pause completely; ranged preference leaves combat
-- weapon changes to the client.
local function combatAutomationPaused()
    if not isInCombatNow() then
        return false
    end

    -- With combat behavior disabled, all automatic sheath changes pause.
    if not INCLUDE_COMBAT then
        return true
    end

    -- In ranged mode, combat weapon changes are left to the client.
    return USE_RANGED_WEAPON
end

-- A target only counts when it exists, is alive, and can be attacked by the
-- player. This deliberately excludes dead targets and ghosts.
local function hasAttackableTarget()
    if not safeBool(UnitExists, "target") then
        return false
    end

    if safeBool(UnitIsDeadOrGhost, "target") then
        return false
    end

    return safeBool(UnitCanAttack, "player", "target")
end

-- Read whether the player is sitting, using whichever supported API is present.
local function isPlayerSitting()
    if type(UnitIsSitting) == "function" then
        local ok, value = pcall(UnitIsSitting, "player")
        if ok and not isSecret(value) then
            return value == true or value == 1
        end
    end

    if type(IsSitting) == "function" then
        local ok, value = pcall(IsSitting)
        if ok and not isSecret(value) then
            return value == true or value == 1
        end
    end

    return false
end

-- Match an aura by known spell ID first, then by localized food/drink names
-- where those global strings are available.
local function isEatingOrDrinkingAura(auraName, spellID)
    if type(spellID) == "number"
        and EATING_DRINKING_AURA_IDS[spellID] then
        return true
    end

    if isSecret(auraName) or type(auraName) ~= "string" then
        return false
    end

    local normalizedName = string.lower(auraName)

    local foodName = type(FOOD) == "string"
        and string.lower(FOOD)
        or "food"

    local drinkName = type(DRINK) == "string"
        and string.lower(DRINK)
        or "drink"

    return normalizedName == foodName
        or normalizedName == drinkName
        or normalizedName == "food"
        or normalizedName == "drink"
end

-- Preserve the number of return values when wrapping UnitAura with pcall.
local function pack(...)
    return { n = select("#", ...), ... }
end

-- Refresh the meal/drink aura cache on login and UNIT_AURA, not on every
-- regular update. Prefer C_UnitAuras and fall back to the legacy UnitAura API.
local function refreshMealAuraCache()
    mealAuraActive = false

    local auraAPI = type(C_UnitAuras) == "table"
        and C_UnitAuras.GetAuraDataByIndex

    if type(auraAPI) == "function" then
        local auraAPIUsable = true

        for index = 1, 40 do
            local ok, auraData =
                pcall(auraAPI, "player", index, "HELPFUL")

            if not ok then
                auraAPIUsable = false
                break
            end

            if auraData == nil then
                break
            end

            if not isSecret(auraData) and type(auraData) == "table"
                and isEatingOrDrinkingAura(
                    auraData.name,
                    auraData.spellId or auraData.spellID
                ) then
                mealAuraActive = true
                return
            end
        end

        if auraAPIUsable then
            return
        end
    end

    if type(UnitAura) ~= "function" then
        return
    end

    for index = 1, 40 do
        local values = pack(
            pcall(UnitAura, "player", index, "HELPFUL")
        )

        if values[1] ~= true or values[2] == nil then
            break
        end

        local spellID = values[11]
        if type(spellID) ~= "number" then
            spellID = values[12]
        end

        if isEatingOrDrinkingAura(values[2], spellID) then
            mealAuraActive = true
            return
        end
    end
end

-- Pause automatic changes only when both conditions are true: the player is
-- sitting and the cached aura scan found food or drink.
local function isEatingOrDrinkingWhileSitting()
    playerSitting = isPlayerSitting()
    return playerSitting and mealAuraActive
end

-- Resolve an inventory slot by its client-defined name, falling back to the
-- known slot number if the lookup is unavailable.
local function getInventorySlotID(slotName, fallback)
    if type(GetInventorySlotInfo) == "function" then
        local ok, slotID = pcall(GetInventorySlotInfo, slotName)
        if ok and not isSecret(slotID)
            and type(slotID) == "number" and slotID > 0 then
            return slotID
        end
    end

    return fallback
end

-- Refresh the cached presence of main-hand and ranged equipment. Item IDs are
-- preferred; item links provide a fallback for clients where IDs are absent.
local function refreshEquipment()
    mainHandPresent = false
    rangedPresent = false

    if type(GetInventoryItemID) == "function" then
        if mainHandSlot then
            local ok, itemID =
                pcall(GetInventoryItemID, "player", mainHandSlot)

            if ok and not isSecret(itemID)
                and type(itemID) == "number" then
                mainHandPresent = itemID > 0
            end
        end

        if rangedSlot then
            local ok, itemID =
                pcall(GetInventoryItemID, "player", rangedSlot)

            if ok and not isSecret(itemID)
                and type(itemID) == "number" then
                rangedPresent = itemID > 0
            end
        end
    end

    if not mainHandPresent and mainHandSlot
        and type(GetInventoryItemLink) == "function" then
        local ok, link =
            pcall(GetInventoryItemLink, "player", mainHandSlot)

        if ok and not isSecret(link) then
            mainHandPresent = type(link) == "string" and link ~= ""
        end
    end

    if not rangedPresent and rangedSlot
        and type(GetInventoryItemLink) == "function" then
        local ok, link =
            pcall(GetInventoryItemLink, "player", rangedSlot)

        if ok and not isSecret(link) then
            rangedPresent = type(link) == "string" and link ~= ""
        end
    end
end

-- Validate whether ranged mode can be enabled for the current character.
-- The slot is initialized here too because slash commands can run before the
-- addon has otherwise initialized its equipment slots.
local function canEnableRangedMode()
    if type(UnitClass) ~= "function" then
        return false, "class"
    end

    local ok, _, classToken = pcall(UnitClass, "player")
    if not ok or type(classToken) ~= "string" then
        return false, "class"
    end

    if not RANGED_WEAPON_CLASSES[classToken] then
        return false, "class"
    end

    -- Set the slot here as well so validation works when the addon is
    -- currently disabled and has not initialized its equipment slots yet.
    if not rangedSlot then
        rangedSlot = getInventorySlotID("RangedSlot", 18)
    end

    refreshEquipment()

    if not rangedPresent then
        return false, "weapon"
    end

    return true
end

-- Check that the weapon selected by the current preference is equipped.
local function hasSelectedWeapon()
    if USE_RANGED_WEAPON then
        return rangedPresent
    end

    return mainHandPresent
end

-- Select the desired client sheath state. A pending post-shoot handoff always
-- targets melee, even when ranged preference is normally enabled.
local function selectedSheathState()
    if postShootMainhand then
        return 2
    end

    return USE_RANGED_WEAPON and 3 or 2
end

-- Detect active Shoot or auto-repeat fire so ToggleSheath does not interrupt it.
local function isShootActive()
    if autoRepeatActive then
        return true
    end

    if type(IsCurrentSpell) == "function" then
        local ok, current = pcall(IsCurrentSpell, SHOOT_SPELL_ID)
        if ok and not isSecret(current)
            and (current == true or current == 1) then
            return true
        end
    end

    return false
end

-- Cancel a pending sheathe callback and invalidate any callback that may
-- already be queued.
local function cancelSheatheTimer()
    sheatheTimerGeneration = sheatheTimerGeneration + 1

    if sheatheTimer then
        sheatheTimer:Cancel()
        sheatheTimer = nil
    end
end

-- Cancel a pending draw callback and clear its key so a later request can be
-- scheduled with the appropriate goal and delay.
local function cancelDrawTimer()
    drawTimerGeneration = drawTimerGeneration + 1

    if drawTimer then
        drawTimer:Cancel()
        drawTimer = nil
    end

    drawTimerKey = nil
end

-- Cancel a pending sheath-state retry and discard its requested goal.
local function cancelToggleTimer()
    toggleTimerGeneration = toggleTimerGeneration + 1

    if toggleTimer then
        toggleTimer:Cancel()
        toggleTimer = nil
    end

    pendingToggleGoal = nil
end

-- Invalidate the action-delay deadline and its follow-up watcher chain.
local function cancelActionTimer()
    actionTimerGeneration = actionTimerGeneration + 1

    if actionTimer then
        actionTimer:Cancel()
        actionTimer = nil
    end

    actionWatchPass = 0
end

-- Stop any scheduled wake-up for the post-shoot combat block.
local function cancelPostShootBlockTimer()
    postShootBlockGeneration = postShootBlockGeneration + 1

    if postShootBlockTimer then
        postShootBlockTimer:Cancel()
        postShootBlockTimer = nil
    end
end

-- Mark the next short-lived sheath transition as addon-initiated so it is not
-- mistaken for the player's own action.
local function markAddonSheathe()
    addonSheathePendingUntil = GetTime() + ADDON_SHEATHE_WINDOW
end

-- Return the next state in the client's normal sheath cycle.
local function nextSheathState(state)
    if state == 1 then
        return 2
    elseif state == 2 then
        return 3
    elseif state == 3 then
        return 1
    end

    return nil
end

-- Schedule a state recheck when the client does not immediately reach the
-- requested state. The generation token makes canceled callbacks harmless.
local function scheduleToggleCheck(goalState, delay)
    if not enabled
        or type(C_Timer) ~= "table"
        or type(C_Timer.NewTimer) ~= "function" then
        return
    end

    if pendingToggleGoal ~= goalState then
        cancelToggleTimer()
        pendingToggleGoal = goalState
    elseif toggleTimer then
        return
    end

    local generation = toggleTimerGeneration + 1
    toggleTimerGeneration = generation

    toggleTimer = C_Timer.NewTimer(delay, function()
        if generation ~= toggleTimerGeneration then
            return
        end

        toggleTimer = nil

        if enabled and updateState then
            updateState()
        end
    end)
end

-- Move toward a target sheath state by toggling and then observing the actual
-- result. Immediate ranged-to-melee transitions intentionally sheath ranged
-- first and draw melee immediately afterward, without the usual draw delay.
local function driveTowardState(goalState, shootActive, immediate)
    local state = getSheathState()
    if state == nil then
        return
    end

    if state == goalState then
        cancelToggleTimer()
        pendingToggleGoal = nil
        idleSheathing = false
        return
    end

    if shootActive == nil then
        shootActive = isShootActive()
    end

    if shootActive or type(ToggleSheath) ~= "function" then
        return
    end

    if pendingToggleGoal == goalState and toggleTimer then
        return
    end

    if pendingToggleGoal ~= goalState then
        cancelToggleTimer()
        pendingToggleGoal = goalState
    end

    local beforeState = state

    if goalState == 1
        or (immediate and goalState == 2 and beforeState == 3) then
        markAddonSheathe()
    end

    local ok = pcall(ToggleSheath)
    if not ok then
        scheduleToggleCheck(goalState, TOGGLE_UNCHANGED_RETRY_DELAY)
        return
    end

    local afterState = getSheathState()

    -- For an immediate ranged-to-main-hand transition, first sheath the
    -- ranged weapon, then draw the main-hand weapon without a delay.
    if immediate
        and goalState == 2
        and beforeState == 3
        and afterState == 1 then
        local secondOk = pcall(ToggleSheath)
        if not secondOk then
            scheduleToggleCheck(goalState, TOGGLE_UNCHANGED_RETRY_DELAY)
            return
        end

        afterState = getSheathState()
    end

    -- From melee, the client cycles to ranged before sheathed. When both
    -- weapons are equipped, toggle a second time immediately to sheath.
    if goalState == 1
        and beforeState == 2
        and mainHandPresent
        and rangedPresent then
        local secondOk = pcall(ToggleSheath)
        if not secondOk then
            scheduleToggleCheck(goalState, TOGGLE_UNCHANGED_RETRY_DELAY)
            return
        end

        afterState = getSheathState()
    end

    if afterState == goalState then
        cancelToggleTimer()
        pendingToggleGoal = nil
        idleSheathing = false
        return
    end

    if afterState ~= nil and afterState ~= beforeState then
        scheduleToggleCheck(goalState, TOGGLE_RETRY_DELAY)
    else
        scheduleToggleCheck(goalState, TOGGLE_UNCHANGED_RETRY_DELAY)
    end
end

-- Decide whether current gameplay conditions call for a drawn weapon.
-- Combat preference takes precedence; outside combat, movement or an enabled
-- attackable-target response can request a draw.
local function wantsUnsheathedState()
    if isInCombatNow() then
        return INCLUDE_COMBAT and not USE_RANGED_WEAPON
    end

    if not SHEATHE then
        return true
    end

    return moving
        or (INCLUDE_ATTACKABLE_TARGETS and attackableTarget)
end

-- Continue a short bounded sequence of checks after an action deadline. The
-- limited watcher catches delayed client sheath behavior without steady polling.
local function scheduleActionWatch(generation, pass, delay)
    if not enabled
        or generation ~= actionTimerGeneration
        or actionTimer
        or type(C_Timer) ~= "table"
        or type(C_Timer.NewTimer) ~= "function" then
        return
    end

    actionWatchPass = pass

    actionTimer = C_Timer.NewTimer(delay, function()
        if generation ~= actionTimerGeneration then
            return
        end

        actionTimer = nil

        if not enabled or isEatingOrDrinkingWhileSitting() then
            actionReadyUntil = 0
            actionWatchPass = 0
            return
        end

        updateState()

        if generation ~= actionTimerGeneration then
            return
        end

        if GetTime() < actionReadyUntil
            and pass < ACTION_WATCH_COUNT then
            scheduleActionWatch(
                generation,
                pass + 1,
                ACTION_WATCH_REPEAT_DELAY
            )
        else
            actionReadyUntil = 0
            actionWatchPass = 0
        end
    end)
end

-- Schedule the end of an action-induced pause. Once it expires, re-evaluate
-- weapon state and start the bounded watcher for any delayed client response.
local function scheduleActionDeadline(remaining)
    if not enabled
        or actionTimer
        or type(C_Timer) ~= "table"
        or type(C_Timer.NewTimer) ~= "function" then
        return
    end

    local generation = actionTimerGeneration

    actionTimer = C_Timer.NewTimer(math.max(remaining, 0), function()
        if generation ~= actionTimerGeneration then
            return
        end

        actionTimer = nil

        if not enabled or isEatingOrDrinkingWhileSitting() then
            actionDelayUntil = 0
            actionReadyUntil = 0
            actionWatchPass = 0
            return
        end

        actionDelayUntil = 0
        actionReadyUntil = GetTime() + ACTION_READY_GRACE
        actionWatchPass = 0

        -- Recheck once when the full action delay has elapsed.
        updateState()

        -- Start only one short watcher chain for a delayed client sheath.
        if generation == actionTimerGeneration
            and enabled
            and not isEatingOrDrinkingWhileSitting() then
            scheduleActionWatch(
                generation,
                1,
                ACTION_WATCH_FIRST_DELAY
            )
        end
    end)
end

-- Ensure an outstanding action deadline has a timer. The watcher is started
-- only by the deadline callback so duplicate update events cannot spawn chains.
local function ensureActionTimer()
    if not enabled or isEatingOrDrinkingWhileSitting() then
        return
    end

    -- A deadline or watcher is already pending.
    if actionTimer then
        return
    end

    local remaining = actionDelayUntil - GetTime()
    if remaining > 0 then
        scheduleActionDeadline(remaining)
    end

    -- Do not start a watcher here. The deadline callback owns that chain.
end

-- Start or restart the pause after an action that may cause the client to sheath.
local function startActionDelay(delay)
    cancelActionTimer()

    actionDelayUntil = GetTime() + (delay or ACTION_DELAY)
    actionReadyUntil = 0
    actionWatchPass = 0

    ensureActionTimer()
end

-- Select the applicable draw delay. Combat always uses COMBAT_DELAY, regardless
-- of an action delay; outside combat, a pending action delay takes precedence.
local function getDrawDelay()
    local now = GetTime()

    -- Combat always uses COMBAT_DELAY, including after an action.
    if isInCombatNow() then
        return COMBAT_DELAY, "combat"
    end

    local actionRemaining = actionDelayUntil - now
    if actionRemaining > 0 then
        return actionRemaining, "action"
    end

    if now <= actionReadyUntil then
        return 0, "action-ready"
    end

    return COMBAT_DELAY, "normal"
end

-- Schedule a delayed draw. The key identifies the goal and delay type so
-- repeated state updates do not reset an equivalent timer.
local function scheduleDraw(delay, key)
    if drawTimer and drawTimerKey == key then
        return
    end

    cancelDrawTimer()

    if type(C_Timer) ~= "table"
        or type(C_Timer.NewTimer) ~= "function" then
        return
    end

    local generation = drawTimerGeneration + 1
    drawTimerGeneration = generation
    drawTimerKey = key

    drawTimer = C_Timer.NewTimer(math.max(delay, 0), function()
        if generation ~= drawTimerGeneration then
            return
        end

        drawTimer = nil
        drawTimerKey = nil
        drawReadyKey = key

        if enabled then
            updateState()
        end
    end)
end

-- Begin the configured idle sheathe delay. The callback verifies that the
-- original conditions still apply before changing the weapon state.
local function scheduleSheathe()
    if sheatheTimer then
        return
    end

    if type(C_Timer) ~= "table"
        or type(C_Timer.NewTimer) ~= "function" then
        return
    end

    local generation = sheatheTimerGeneration + 1
    sheatheTimerGeneration = generation

    sheatheTimer = C_Timer.NewTimer(SHEATHE_DELAY, function()
        if generation ~= sheatheTimerGeneration then
            return
        end

        sheatheTimer = nil

        if enabled
            and SHEATHE
            and not isEatingOrDrinkingWhileSitting()
            and not combatAutomationPaused()
            and not wantsUnsheathedState() then
            idleSheathing = true
            updateState()
        end
    end)
end

-- Identify the player's own chat message. GUID is authoritative when available;
-- the character name is used as a fallback for clients without a GUID value.
local function isOwnChatMessage(author, senderGUID)
    if type(senderGUID) == "string"
        and senderGUID ~= ""
        and type(UnitGUID) == "function" then
        local ok, playerGUID = pcall(UnitGUID, "player")
        if ok and type(playerGUID) == "string"
            and playerGUID ~= "" then
            return senderGUID == playerGUID
        end
    end

    if type(author) ~= "string" or type(UnitName) ~= "function" then
        return false
    end

    local ok, playerName = pcall(UnitName, "player")
    if not ok or type(playerName) ~= "string" then
        return false
    end

    local shortAuthor = author:match("^([^-]+)") or author
    return string.lower(shortAuthor) == string.lower(playerName)
end

-- Record the latest sheath state and detect an unexpected ranged-to-sheathed
-- transition shortly after shooting. Such a transition can request the
-- post-shoot main-hand handoff unless it was caused by the addon or chat action.
local function updateObservedSheathState(now)
    local state = getSheathState()
    if state == nil then
        return nil
    end

    local isAddonSheathe = now <= addonSheathePendingUntil
    local isChatSheathe = now <= chatSheathePendingUntil

    if USE_RANGED_WEAPON
        and lastObservedSheathState == 3
        and state == 1
        and now - lastShootActivityAt <= SHOOT_HANDOFF_WINDOW
        and not isAddonSheathe
        and not isChatSheathe then
        postShootMainhand = true
        drawReadyKey = nil
        cancelDrawTimer()
    end

    if state == 1 and lastObservedSheathState ~= 1 and isAddonSheathe then
        addonSheathePendingUntil = 0
    end

    if addonSheathePendingUntil > 0 and now > addonSheathePendingUntil then
        addonSheathePendingUntil = 0
    end

    if chatSheathePendingUntil > 0 and now > chatSheathePendingUntil then
        chatSheathePendingUntil = 0
    end

    lastObservedSheathState = state
    return state
end

-- Wake the state machine when a post-shoot combat block expires.
local function schedulePostShootBlockWake(delay)
    if type(C_Timer) ~= "table"
        or type(C_Timer.NewTimer) ~= "function"
        or postShootBlockTimer then
        return
    end

    local generation = postShootBlockGeneration + 1
    postShootBlockGeneration = generation

    postShootBlockTimer = C_Timer.NewTimer(math.max(delay, 0), function()
        if generation ~= postShootBlockGeneration then
            return
        end

        postShootBlockTimer = nil

        if enabled then
            updateState()
        end
    end)
end

-- Apply the optional combat block after ranged fire. While in combat, activity
-- within the handoff window keeps main-hand automation blocked. Once combat
-- ends, wait out any remaining window before allowing the next state update.
local function updatePostShootCombatBlock(now, combatNow)
    if not DISABLE_POST_SHOOT_MAINHAND_IN_COMBAT or not INCLUDE_COMBAT then
        postShootCombatBlocked = false
        postShootBlockUntil = 0
        cancelPostShootBlockTimer()
        return false
    end

    if combatNow then
        if autoRepeatActive
            or now - lastShootActivityAt <= SHOOT_HANDOFF_WINDOW then
            postShootCombatBlocked = true
            postShootBlockUntil = math.max(
                postShootBlockUntil,
                lastShootActivityAt + SHOOT_HANDOFF_WINDOW
            )
        end

        return postShootCombatBlocked
    end

    if postShootCombatBlocked then
        local remaining = postShootBlockUntil - now
        if remaining > 0 then
            schedulePostShootBlockWake(remaining)
            return true
        end

        postShootCombatBlocked = false
        postShootBlockUntil = 0
        cancelPostShootBlockTimer()
    end

    return false
end

-- Request the selected weapon state after checking all pause conditions,
-- equipment availability, casting, and the selected delay.
local function requestUnsheathe(shootActive)
    if not enabled
        or isEatingOrDrinkingWhileSitting()
        or combatAutomationPaused()
        or not wantsUnsheathedState() then
        return
    end

    ensureActionTimer()

    if postShootMainhand then
        cancelDrawTimer()

        if mainHandPresent and not isCastingOrChanneling() then
            driveTowardState(2, shootActive)
        end

        return
    end

    if not hasSelectedWeapon() or isCastingOrChanneling() then
        return
    end

    local goalState = selectedSheathState()
    local state = getSheathState()

    if state == goalState then
        cancelDrawTimer()
        drawReadyKey = nil
        cancelToggleTimer()
        pendingToggleGoal = nil
        idleSheathing = false
        return
    end

    local delay, kind = getDrawDelay()
    local key = tostring(goalState) .. ":" .. kind

    if delay > 0 and drawReadyKey ~= key then
        scheduleDraw(delay, key)
        return
    end

    cancelDrawTimer()
    drawReadyKey = nil
    driveTowardState(goalState, shootActive)
end

-- Central decision routine. It refreshes cached conditions, honors pause
-- policies, prioritizes combat movement and shoot handoffs, then chooses whether
-- to draw, wait, or start the sheathe delay.
local function updateStateCore()
    if not enabled then
        return
    end

    moving = isMovingNow()
    attackableTarget =
        INCLUDE_ATTACKABLE_TARGETS and hasAttackableTarget()

    local now = GetTime()
    local combatNow = isInCombatNow()
    local shootActive = isShootActive()

    local state = updateObservedSheathState(now)

    if isEatingOrDrinkingWhileSitting() then
        cancelSheatheTimer()
        cancelDrawTimer()
        cancelToggleTimer()
        cancelActionTimer()
        drawReadyKey = nil
        idleSheathing = false
        return
    end

    if WAIT_FOR_MOVEMENT_IN_COMBAT
        and INCLUDE_COMBAT
        and combatNow
        and not USE_RANGED_WEAPON
        and not moving then
        cancelSheatheTimer()
        cancelDrawTimer()
        cancelToggleTimer()
        cancelActionTimer()
        drawReadyKey = nil
        idleSheathing = false
        return
    end

    if updatePostShootCombatBlock(now, combatNow)
        or combatAutomationPaused() then
        cancelSheatheTimer()
        cancelDrawTimer()
        cancelToggleTimer()
        cancelActionTimer()
        drawReadyKey = nil
        idleSheathing = false
        postShootMainhand = false
        return
    end

    if WAIT_FOR_MOVEMENT_IN_COMBAT
        and INCLUDE_COMBAT
        and combatNow
        and moving
        and not USE_RANGED_WEAPON then
        cancelSheatheTimer()
        idleSheathing = false

        if mainHandPresent
            and not shootActive
            and not isCastingOrChanneling() then
            local currentState = getSheathState()

            if currentState == 3 then
                cancelDrawTimer()
                drawReadyKey = nil
                driveTowardState(2, false, true)
            elseif currentState == 1 then
                local movementDrawKey = "2:combat-movement"

                if drawReadyKey == movementDrawKey then
                    cancelDrawTimer()
                    drawReadyKey = nil
                    driveTowardState(2, false)
                else
                    scheduleDraw(COMBAT_DELAY, movementDrawKey)
                end
            elseif currentState == 2 then
                cancelDrawTimer()
                drawReadyKey = nil
                driveTowardState(2, false)
            end
        end

        if getSheathState() == 2 then
            postShootMainhand = false
        end

        return
    end

    if postShootMainhand then
        cancelSheatheTimer()
        cancelDrawTimer()

        if mainHandPresent
            and not shootActive
            and not isCastingOrChanneling() then
            driveTowardState(2, false)
        end

        if getSheathState() == 2 then
            postShootMainhand = false
        end

        return
    end

    if wantsUnsheathedState() then
        cancelSheatheTimer()
        idleSheathing = false

        -- A draw delayed by a cast/channel is reconsidered by its stop event.
        if not isCastingOrChanneling() then
            requestUnsheathe(shootActive)
        end

        return
    end

    if pendingToggleGoal == 2 or pendingToggleGoal == 3 then
        cancelToggleTimer()
    end

    cancelDrawTimer()
    drawReadyKey = nil

    if not SHEATHE then
        cancelSheatheTimer()
        idleSheathing = false
        return
    end

    if state == 1 then
        cancelSheatheTimer()
        idleSheathing = false
        return
    end

    if idleSheathing then
        driveTowardState(1, shootActive)
        return
    end

    if state == 2 or state == 3 then
        scheduleSheathe()
    else
        cancelSheatheTimer()
    end
end

-- Enable OnUpdate only when falling/jumping detection requires periodic
-- sampling. With the option off, the addon relies on events and timers.
local function refreshPolling()
    local shouldPoll = enabled and INCLUDE_JUMPING_AND_FALLING

    if shouldPoll == pollingEnabled then
        return
    end

    pollingEnabled = shouldPoll
    pollElapsed = 0

    if pollingEnabled then
        frame:SetScript("OnUpdate", onUpdateScript)
    else
        frame:SetScript("OnUpdate", nil)
    end
end

-- Public internal entry point for all state changes. Polling configuration is
-- refreshed afterward in case the enabled state changed.
updateState = function()
    if not enabled then
        return
    end

    updateStateCore()
    refreshPolling()
end

-- Protect event registration so unavailable client events do not prevent the
-- addon from registering the events it can use.
local function registerEventSafely(eventName)
    pcall(frame.RegisterEvent, frame, eventName)
end

-- Register all events used for movement, combat, targeting, equipment, chat,
-- auras, casting, and auto-repeat fire.
local function registerEvents()
    local events = {
        "PLAYER_STARTED_MOVING",
        "PLAYER_STOPPED_MOVING",
        "PLAYER_REGEN_DISABLED",
        "PLAYER_REGEN_ENABLED",
        "PLAYER_TARGET_CHANGED",
        "PLAYER_EQUIPMENT_CHANGED",
        "PLAYER_ENTERING_WORLD",
        "PLAYER_FLAGS_CHANGED",
        "CHAT_MSG_SAY",
        "CHAT_MSG_YELL",
        "UNIT_AURA",
        "UNIT_FLAGS",
        "UNIT_FACTION",
        "UNIT_SPELLCAST_START",
        "UNIT_SPELLCAST_STOP",
        "UNIT_SPELLCAST_CHANNEL_START",
        "UNIT_SPELLCAST_CHANNEL_STOP",
        "UNIT_SPELLCAST_SUCCEEDED",
        "START_AUTOREPEAT_SPELL",
        "STOP_AUTOREPEAT_SPELL",
    }

    for _, eventName in ipairs(events) do
        registerEventSafely(eventName)
    end
end

-- Add one line to the default chat frame when it is available.
local function printLine(message)
    if DEFAULT_CHAT_FRAME
        and type(DEFAULT_CHAT_FRAME.AddMessage) == "function" then
        DEFAULT_CHAT_FRAME:AddMessage(message)
    end
end

-- Prefix a single response with the addon name.
local function printMessage(message)
    printLine("|cff80c0ffUnsheathed:|r " .. message)
end

-- Print a multi-line response with the addon name on its own line, keeping the
-- following lines reserved for the setting or status details.
local function printSettingResponse(message)
    printLine("|cff80c0ffUnsheathed:|r")
    printLine(message)
end

-- Load a saved boolean or initialize it to its default for this character.
local function getSavedBoolean(key, defaultValue)
    if type(UnsheathedDB[key]) == "boolean" then
        return UnsheathedDB[key]
    end

    UnsheathedDB[key] = defaultValue
    return defaultValue
end

-- The slash command accepts only delays within the documented 1–60 second
-- range. Decimal values are valid.
local function isValidSheatheDelay(value)
    return type(value) == "number"
        and value >= 1
        and value <= 60
end

-- Load the saved sheathe delay, resetting invalid or absent values to the
-- configured default.
local function getSavedSheatheDelay()
    local savedDelay = UnsheathedDB.sheatheDelay

    if isValidSheatheDelay(savedDelay) then
        return savedDelay
    end

    UnsheathedDB.sheatheDelay = DEFAULT_SHEATHE_DELAY
    return DEFAULT_SHEATHE_DELAY
end

-- Display numeric delay values without unnecessary trailing zeroes.
local function formatSheatheDelay(value)
    return string.format("%g", value)
end

-- Validate, save, and apply a new sheathe delay, then re-evaluate the current
-- state so the updated timing takes effect.
local function setSheatheDelay(value)
    if not isValidSheatheDelay(value) then
        printMessage("Delay must be a number from 1 to 60 seconds.")
        return
    end

    SHEATHE_DELAY = value
    UnsheathedDB.sheatheDelay = value

    cancelSheatheTimer()
    idleSheathing = false
    updateState()

    printSettingResponse(
        "|cff80c0ffSheathe Delay:|r "
            .. formatSheatheDelay(value)
            .. " Seconds"
    )
end

-- Clear timers, cached activity markers, polling, and handoff state when the
-- addon is disabled, preventing callbacks from operating on stale state.
local function resetRuntimeState()
    cancelSheatheTimer()
    cancelDrawTimer()
    cancelToggleTimer()
    cancelActionTimer()
    cancelPostShootBlockTimer()

    frame:SetScript("OnUpdate", nil)
    pollingEnabled = false
    pollElapsed = 0

    autoRepeatActive = false
    postShootMainhand = false
    postShootCombatBlocked = false
    postShootBlockUntil = 0
    drawReadyKey = nil
    idleSheathing = false

    actionDelayUntil = 0
    actionReadyUntil = 0
    addonSheathePendingUntil = 0
    chatSheathePendingUntil = 0
    lastShootActivityAt = -1000000
end

-- Change the global enabled state, persist it for this character, and either
-- register events and initialize caches or clean up runtime work.
setEnabled = function(value, report)
    value = value == true
    UnsheathedDB.enabled = value

    if value == enabled then
        if report then
            printSettingResponse(
                "|cff80c0ffStatus:|r "
                    .. (value and "|cff80ff80Enabled|r"
                        or "|cffff8080Disabled|r")
            )
        end
        return
    end

    enabled = value

    if not enabled then
        frame:UnregisterAllEvents()
        resetRuntimeState()

        if report then
            printSettingResponse(
                "|cff80c0ffStatus:|r |cffff8080Disabled|r"
            )
        end
        return
    end

    registerEvents()

    inCombat = safeBool(UnitAffectingCombat, "player")
    eventMoving = safeBool(IsPlayerMoving)

    mainHandSlot = getInventorySlotID("MainHandSlot", 16)
    rangedSlot = getInventorySlotID("RangedSlot", 18)

    refreshEquipment()
    refreshMealAuraCache()
    playerSitting = isPlayerSitting()
    lastObservedSheathState = getSheathState()

    updateState()

    if report then
        printSettingResponse(
            "|cff80c0ffStatus:|r |cff80ff80Enabled|r"
        )
    end
end

-- Expose a global setter for other addons or macros that want to control the
-- enabled state.
_G.Unsheathed_SetEnabled = function(value)
    setEnabled(value, true)
end

-- Apply and save one of the slash-command options. Ranged mode is validated
-- before changing settings so an unsupported class or missing weapon gets a
-- clear error rather than leaving the option enabled but unusable.
local function setOption(option, value)
    value = value == true

    -- Validate only when the user attempts to turn ranged mode on.
    if option == "ranged" and value then
        local canEnable, reason = canEnableRangedMode()

        if not canEnable then
            if reason == "class" then
                printSettingResponse(
                    "|cffff8080You cannot use ranged weapons.|r"
                )
            else
                printSettingResponse(
                    "|cffff8080You do not have a ranged weapon equipped.|r"
                )
            end
            return
        end
    end

    if option == "ranged" then
        USE_RANGED_WEAPON = value
        UnsheathedDB.useRangedWeapon = value
    elseif option == "combat" then
        INCLUDE_COMBAT = value
        UnsheathedDB.includeCombat = value
    elseif option == "target" then
        INCLUDE_ATTACKABLE_TARGETS = value
        UnsheathedDB.includeAttackableTargets = value
    elseif option == "sheathe" then
        SHEATHE = value
        UnsheathedDB.sheathe = value
    else
        return
    end

    cancelSheatheTimer()
    cancelDrawTimer()
    cancelToggleTimer()
    drawReadyKey = nil
    idleSheathing = false
    postShootMainhand = false

    updateState()

    local optionNames = {
        ranged = "Ranged",
        combat = "Combat",
        target = "Target",
        sheathe = "Sheathe",
    }

    local status = value
        and "|cff80ff80On|r"
        or "|cffff8080Off|r"

    printSettingResponse(
        "|cff80c0ff" .. optionNames[option] .. ":|r " .. status
    )
end

-- Print each behavior setting with the same color convention used by status
-- and setting-change responses.
local function printOptionStatus()
    local sheatheStatus = SHEATHE
        and "|cff80ff80On|r" or "|cffff8080Off|r"
    local combatStatus = INCLUDE_COMBAT
        and "|cff80ff80On|r" or "|cffff8080Off|r"
    local targetStatus = INCLUDE_ATTACKABLE_TARGETS
        and "|cff80ff80On|r" or "|cffff8080Off|r"
    local rangedStatus = USE_RANGED_WEAPON
        and "|cff80ff80On|r" or "|cffff8080Off|r"

    printLine("|cff80c0ffSheathe:|r " .. sheatheStatus)
    printLine("|cff80c0ffCombat:|r " .. combatStatus)
    printLine("|cff80c0ffTarget:|r " .. targetStatus)
    printLine("|cff80c0ffRanged:|r " .. rangedStatus)
end

-- Report the addon state, behavior options, and configured sheathe delay.
local function printStatus()
    printLine("|cff80c0ffUnsheathed:|r")
    printLine("|cff80c0ffStatus:|r "
        .. (enabled and "|cff80ff80Enabled|r"
            or "|cffff8080Disabled|r"))
    printOptionStatus()
    printLine("|cff80c0ffDelay:|r "
        .. formatSheatheDelay(SHEATHE_DELAY)
        .. " Seconds")
    printLine("|cffffd200Commands:|r Type |cffffd200/us help|r for options and commands.")
end

-- List the supported slash commands and their accepted on/off or delay values.
local function printHelp()
    local command = "|cff80c0ff/us|r"
    local options = "|cff80ff80on|r | |cffff8080off|r"

    printLine("|cff80c0ffUnsheathed:|r |cffffd200Commands|r")
    printLine(command .. " " .. options
        .. " - Enable or disable Unsheathed for this character.")
    printLine(command .. " |cffffd200sheathe|r " .. options
        .. " - Turn on or off automatic sheathing.")
    printLine(command .. " |cffffd200combat|r " .. options
        .. " - Allow unsheathing during combat.")
    printLine(command .. " |cffffd200target|r " .. options
        .. " - React to attackable targets.")
    printLine(command .. " |cffffd200ranged|r " .. options
        .. " - Prefer the ranged weapon over the main hand.")
    printLine(command .. " |cffffd200delay|r |cff80ff801-60|r"
        .. " - Set the sheathing delay in seconds.")
end

-- Handle player spellcast events. Ranged shots update shoot activity; other
-- successful player spells outside combat start the action delay because they
-- may cause the client to sheath the weapon.
local function handleSpellcastEvent(event, ...)
    local unit, _, spellID = ...

    if unit ~= "player" then
        return
    end

    if event == "UNIT_SPELLCAST_SUCCEEDED"
        and not isSecret(spellID)
        and type(spellID) == "number" then

        if spellID == SHOOT_SPELL_ID
            or spellID == AUTO_SHOT_SPELL_ID then
            lastShootActivityAt = GetTime()
        elseif not isInCombatNow() then
            startActionDelay()
            cancelDrawTimer()
            drawReadyKey = nil
        end
    end

    updateState()
end

-- Dispatch registered game events and initialize saved settings when the addon
-- loads. Returning early after event-specific handling avoids duplicate work.
frame:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        local loadedAddonName = ...
        if loadedAddonName ~= ADDON_NAME then
            return
        end

        frame:UnregisterEvent("ADDON_LOADED")
        UnsheathedDB = UnsheathedDB or {}

        USE_RANGED_WEAPON = getSavedBoolean(
            "useRangedWeapon",
            DEFAULT_USE_RANGED_WEAPON
        )
        INCLUDE_COMBAT = getSavedBoolean(
            "includeCombat",
            DEFAULT_INCLUDE_COMBAT
        )
        INCLUDE_ATTACKABLE_TARGETS = getSavedBoolean(
            "includeAttackableTargets",
            DEFAULT_INCLUDE_ATTACKABLE_TARGETS
        )
        SHEATHE = getSavedBoolean("sheathe", DEFAULT_SHEATHE)
        SHEATHE_DELAY = getSavedSheatheDelay()

        initialized = true
        setEnabled(getSavedBoolean("enabled", DEFAULT_ENABLED), false)
        return
    end

    if not enabled then
        return
    end

    if event == "UNIT_AURA" then
        local unit = ...
        if unit == "player" then
            refreshMealAuraCache()
            updateState()
        end
        return
    end

    if event == "UNIT_FLAGS" or event == "UNIT_FACTION" then
        local unit = ...
        if unit == "target" then
            updateState()
        end
        return
    end

    if event == "UNIT_SPELLCAST_START"
        or event == "UNIT_SPELLCAST_STOP"
        or event == "UNIT_SPELLCAST_CHANNEL_START"
        or event == "UNIT_SPELLCAST_CHANNEL_STOP"
        or event == "UNIT_SPELLCAST_SUCCEEDED" then
        handleSpellcastEvent(event, ...)
        return
    end

    if event == "START_AUTOREPEAT_SPELL" then
        autoRepeatActive = true
        lastShootActivityAt = GetTime()
        updateState()
        return
    end

    if event == "STOP_AUTOREPEAT_SPELL" then
        if autoRepeatActive then
            lastShootActivityAt = GetTime()
        end

        autoRepeatActive = false
        updateState()
        return
    end

    if event == "PLAYER_STARTED_MOVING" then
        eventMoving = true
        cancelSheatheTimer()
        idleSheathing = false
        cancelToggleTimer()
    elseif event == "PLAYER_STOPPED_MOVING" then
        eventMoving = false
    elseif event == "PLAYER_REGEN_DISABLED" then
        inCombat = true
    elseif event == "PLAYER_REGEN_ENABLED" then
        inCombat = false
    elseif event == "PLAYER_TARGET_CHANGED" then
        -- Recompute target state; movement still prevents an early sheathe.
        cancelSheatheTimer()
    elseif event == "PLAYER_EQUIPMENT_CHANGED"
        or event == "PLAYER_ENTERING_WORLD" then
        refreshEquipment()
        refreshMealAuraCache()
        inCombat = safeBool(UnitAffectingCombat, "player")
        eventMoving = safeBool(IsPlayerMoving)
    elseif event == "PLAYER_FLAGS_CHANGED" then
        playerSitting = isPlayerSitting()
    elseif event == "CHAT_MSG_SAY" or event == "CHAT_MSG_YELL" then
        local args = {...}

        -- Sender GUID is argument 12; author name is a fallback.
        if isOwnChatMessage(args[2], args[12]) then
            startActionDelay(CHAT_DELAY)
            chatSheathePendingUntil =
                GetTime() + math.max(CHAT_DELAY, ADDON_SHEATHE_WINDOW)

            cancelDrawTimer()
            drawReadyKey = nil
            updateState()
            return
        end
    end

    updateState()
end)

-- Optional low-frequency sampling catches falling/jumping movement when that
-- file-level option is enabled. The interval avoids running the full state
-- machine on every frame.
onUpdateScript = function(_, elapsed)
    if not enabled or not INCLUDE_JUMPING_AND_FALLING then
        return
    end

    pollElapsed = pollElapsed + elapsed
    if pollElapsed < POLL_INTERVAL then
        return
    end

    pollElapsed = 0
    updateState()
end

-- Register the /us command and parse its optional subcommand and arguments.
SLASH_UNSHEATHED1 = "/us"
SlashCmdList["UNSHEATHED"] = function(message)
    if not initialized then
        printMessage("Still initializing; try again in a moment.")
        return
    end

    local first, second, extra =
        (message or ""):match("^%s*(%S*)%s*(%S*)%s*(%S*)%s*$")

    first = string.lower(first or "")
    second = string.lower(second or "")
    extra = string.lower(extra or "")

    -- Reject extra arguments rather than silently accepting a malformed command.
    if extra ~= "" then
        printHelp()
        return
    end

    if first == "" or first == "status" then
        printStatus()
        return
    end

    if first == "help" then
        printHelp()
        return
    end

    if first == "delay" then
        local delay = tonumber(second)
        if delay then
            setSheatheDelay(delay)
        else
            printHelp()
        end
        return
    end

    if first == "on" then
        if second == "" then
            setEnabled(true, true)
        else
            printHelp()
        end
        return
    end

    if first == "off" then
        if second == "" then
            setEnabled(false, true)
        else
            printHelp()
        end
        return
    end

    local optionNames = {
        ranged = true,
        combat = true,
        target = true,
        sheathe = true,
    }

    if optionNames[first]
        and (second == "on" or second == "off") then
        setOption(first, second == "on")
        return
    end

    printHelp()
end

-- Listen for addon loading so saved variables and the configured initial state
-- are applied once this addon has been loaded by the client.
frame:RegisterEvent("ADDON_LOADED")
