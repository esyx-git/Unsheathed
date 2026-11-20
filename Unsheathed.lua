local ADDON_NAME = ...

local DEFAULT_USE_RANGED_WEAPON = false
local DEFAULT_INCLUDE_COMBAT = true
local DEFAULT_INCLUDE_ATTACKABLE_TARGETS = true
local DEFAULT_ENABLED = true
local DEFAULT_SHEATHE = true
local DEFAULT_SHEATHE_DELAY = 3.0

local INCLUDE_JUMPING_AND_FALLING = false
local DISABLE_POST_SHOOT_MAINHAND_IN_COMBAT = false

local SheatheDelay = DEFAULT_SHEATHE_DELAY
local UnsheatheDelay = 0.5
local ActionDelay = 0.5

local POLL_INTERVAL = 0.5
local TOGGLE_TIMEOUT = 2.0
local AUTO_REPEAT_SCAN_INTERVAL = 1.0
local SHOOT_HANDOFF_WINDOW = 1.5

local SHOOT_SPELL_ID = 5019
local AUTO_SHOT_SPELL_ID = 75
local MAX_ACTION_SLOTS = 180
local ADDON_SHEATHE_WINDOW = 1.0

local ACTION_RECHECK_FIRST_DELAY = 0.10
local ACTION_RECHECK_REPEAT_DELAY = 0.25
local ACTION_RECHECK_COUNT = 3

local EATING_DRINKING_AURA_IDS = {
    [430] = true,
    [431] = true,
    [432] = true,
    [2639] = true,
    [24005] = true,
}

UnsheathedDB = UnsheathedDB or {}

local _issecretvalue = issecretvalue or function()
    return false
end

local frame = CreateFrame("Frame")

local initialized = false
local enabled = false
local pollingEnabled = false

local USE_RANGED_WEAPON = DEFAULT_USE_RANGED_WEAPON
local INCLUDE_COMBAT = DEFAULT_INCLUDE_COMBAT
local INCLUDE_ATTACKABLE_TARGETS =
    DEFAULT_INCLUDE_ATTACKABLE_TARGETS
local SHEATHE = DEFAULT_SHEATHE

local eventMoving = false
local moving = false
local inCombat = false
local attackableTarget = false
local pollElapsed = 0

local sheatheTimer
local sheatheGeneration = 0

local unsheatheTimer
local unsheatheGeneration = 0
local unsheatheTimerKind

local actionRecheckTimer
local actionRecheckGeneration = 0

local pendingToggle

local idleSheathing = false
local unsheatheReady = false

local postShootActionPause = false
local resumeActionAwaitingShootStop = false

local postShootMainhand = false
local lastShootActivityAt = -1000000

local actionDelayUntil = 0
local chatSheatheUntil = 0
local addonSheathePendingUntil = 0
local chatSheathePendingUntil = 0
local lastObservedSheathState

local mainHandSlot
local rangedSlot
local mainHandPresent = false
local rangedPresent = false

local cachedAutoRepeat = false
local lastAutoRepeatScan = 0

local updateState
local onUpdateScript
local setEnabled

local function isSecret(value)
    local ok, result = pcall(_issecretvalue, value)
    return not ok or result == true
end

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

local function isCastingOrChanneling()
    return isFunctionCasting(UnitCastingInfo)
        or isFunctionCasting(UnitChannelInfo)
end

local function isMovingNow()
    if eventMoving then
        return true
    end

    return INCLUDE_JUMPING_AND_FALLING and safeBool(IsFalling)
end

local function isInCombatNow()
    return inCombat or safeBool(UnitAffectingCombat, "player")
end

local function combatAutomationPaused()
    if not isInCombatNow() then
        return false
    end

    if not INCLUDE_COMBAT then
        return true
    end

    -- In ranged mode, leave combat weapon changes to the client.
    return USE_RANGED_WEAPON
end

local function hasAttackableTarget()
    if not safeBool(UnitExists, "target") then
        return false
    end

    if safeBool(UnitIsDeadOrGhost, "target") then
        return false
    end

    return safeBool(UnitCanAttack, "player", "target")
end

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

    return nil
end

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

local function pack(...)
    return { n = select("#", ...), ... }
end

local function hasEatingOrDrinkingAura()
    -- Prefer the aura-data API when available. It exposes the aura name and
    -- spell ID directly, avoiding differences in UnitAura return positions.
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

            if not isSecret(auraData) and type(auraData) == "table" then
                if isEatingOrDrinkingAura(
                    auraData.name,
                    auraData.spellId or auraData.spellID
                ) then
                    return true
                end
            end
        end

        if auraAPIUsable then
            return false
        end
    end

    if type(UnitAura) ~= "function" then
        return false
    end

    for index = 1, 40 do
        local values = pack(
            pcall(UnitAura, "player", index, "HELPFUL")
        )

        if values[1] ~= true then
            break
        end

        local auraName = values[2]
        if auraName == nil then
            break
        end

        -- UnitAura's spell ID is at return position 10 on some clients and
        -- position 11 on others. The pcall success value is values[1], so
        -- those positions are values[11] and values[12] here.
        local spellID = values[11]
        if type(spellID) ~= "number" then
            spellID = values[12]
        end

        if isEatingOrDrinkingAura(auraName, spellID) then
            return true
        end
    end

    return false
end

local function isEatingOrDrinkingWhileSitting()
    local sitting = isPlayerSitting()

    if sitting ~= true then
        -- If the sitting query is unavailable, the active aura can still
        -- identify a meal. A known false sitting state is not treated as one.
        return sitting == nil and hasEatingOrDrinkingAura()
    end

    if hasEatingOrDrinkingAura() then
        return true
    end

    -- Some food and drink effects do not expose a recognizable aura name
    -- or spell ID. In persistent-draw mode, a seated player whose weapon
    -- has been sheathed is treated as eating/drinking until the next state
    -- change, rather than repeatedly trying to draw the weapon.
    return not SHEATHE and getSheathState() == 1
end

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

local function hasSelectedWeapon()
    if USE_RANGED_WEAPON then
        return rangedPresent
    end

    return mainHandPresent
end

local function selectedSheathState()
    if postShootMainhand then
        return 2
    end

    return USE_RANGED_WEAPON and 3 or 2
end

local function isShootActive()
    local now = GetTime()

    if type(IsCurrentSpell) == "function" then
        local ok, current = pcall(IsCurrentSpell, SHOOT_SPELL_ID)

        if ok and not isSecret(current)
            and (current == true or current == 1) then
            lastShootActivityAt = now
            postShootMainhand = false
            return true
        end
    end

    local state = getSheathState()

    -- Avoid scanning the action bar merely because ranged gear is equipped.
    local shouldScanAutoRepeat =
        state == 3
        or cachedAutoRepeat
        or isInCombatNow()
        or (now - lastShootActivityAt <= SHOOT_HANDOFF_WINDOW)

    if not shouldScanAutoRepeat then
        return false
    end

    if now - lastAutoRepeatScan >= AUTO_REPEAT_SCAN_INTERVAL then
        lastAutoRepeatScan = now
        cachedAutoRepeat = false

        if type(IsAutoRepeatAction) == "function" then
            for slot = 1, MAX_ACTION_SLOTS do
                local ok, repeating = pcall(IsAutoRepeatAction, slot)

                if ok and not isSecret(repeating)
                    and (repeating == true or repeating == 1) then
                    cachedAutoRepeat = true
                    break
                end
            end
        end
    end

    if cachedAutoRepeat then
        lastShootActivityAt = now
        postShootMainhand = false
        return true
    end

    return false
end

local function shouldUnsheatheNow()
    if isInCombatNow() then
        return INCLUDE_COMBAT and not USE_RANGED_WEAPON
    end

    -- With automatic sheathing disabled, keep the selected weapon drawn
    -- even when the player is idle or has no attackable target.
    if not SHEATHE then
        return true
    end

    return moving
        or (INCLUDE_ATTACKABLE_TARGETS and attackableTarget)
end

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

local function cancelSheatheTimer()
    sheatheGeneration = sheatheGeneration + 1

    if sheatheTimer then
        sheatheTimer:Cancel()
        sheatheTimer = nil
    end
end

local function cancelUnsheatheTimer()
    unsheatheGeneration = unsheatheGeneration + 1

    if unsheatheTimer then
        unsheatheTimer:Cancel()
        unsheatheTimer = nil
    end

    unsheatheTimerKind = nil
end

local function cancelActionRecheckTimer()
    actionRecheckGeneration = actionRecheckGeneration + 1

    if actionRecheckTimer then
        actionRecheckTimer:Cancel()
        actionRecheckTimer = nil
    end
end

local function scheduleActionRecheckPass(generation, pass, delay)
    if type(C_Timer) ~= "table"
        or type(C_Timer.NewTimer) ~= "function" then
        return
    end

    actionRecheckTimer = C_Timer.NewTimer(delay, function()
        if generation ~= actionRecheckGeneration then
            return
        end

        actionRecheckTimer = nil

        if enabled and updateState then
            updateState()
        end

        if enabled and pass < ACTION_RECHECK_COUNT then
            scheduleActionRecheckPass(
                generation,
                pass + 1,
                ACTION_RECHECK_REPEAT_DELAY
            )
        end
    end)
end

local function scheduleActionRechecks()
    if not enabled or isEatingOrDrinkingWhileSitting() then
        return
    end

    cancelActionRecheckTimer()

    local generation = actionRecheckGeneration
    scheduleActionRecheckPass(
        generation,
        1,
        ACTION_RECHECK_FIRST_DELAY
    )
end

local function finishAtGoal(goalState)
    pendingToggle = nil

    if goalState == 1 then
        idleSheathing = false
        postShootMainhand = false
    else
        actionDelayUntil = 0
        chatSheatheUntil = 0
        idleSheathing = false
    end
end

local function markAddonSheathe()
    addonSheathePendingUntil = GetTime() + ADDON_SHEATHE_WINDOW
end

local function callToggle(goalState)
    if type(ToggleSheath) ~= "function" then
        return false
    end

    local fromState = getSheathState()
    if fromState == nil then
        return false
    end

    local expectedState = nextSheathState(fromState)
    if not expectedState then
        return false
    end

    if goalState == 1 then
        markAddonSheathe()
    end

    local ok = pcall(ToggleSheath)
    if not ok then
        return false
    end

    pendingToggle = {
        from = fromState,
        expected = expectedState,
        expires = GetTime() + TOGGLE_TIMEOUT,
    }

    return true
end

local function driveTowardState(goalState, shootActive)
    local state = getSheathState()
    if state == nil then
        return
    end

    if state == goalState then
        finishAtGoal(goalState)
        return
    end

    if pendingToggle then
        local now = GetTime()

        if state == pendingToggle.from
            and now < pendingToggle.expires then
            return
        end

        pendingToggle = nil
        state = getSheathState()

        if state == nil then
            return
        end

        if state == goalState then
            finishAtGoal(goalState)
            return
        end
    end

    if shootActive == nil then
        shootActive = isShootActive()
    end

    if shootActive then
        return
    end

    -- When a ranged weapon is equipped, melee -> sheathed normally passes
    -- through ranged, so preserve the existing paired-toggle behavior.
    if goalState == 1 and state == 2 and rangedPresent then
        if type(ToggleSheath) ~= "function" then
            return
        end

        markAddonSheathe()
        if not pcall(ToggleSheath) then
            return
        end

        markAddonSheathe()
        if not pcall(ToggleSheath) then
            pendingToggle = {
                from = state,
                expected = 3,
                expires = GetTime() + TOGGLE_TIMEOUT,
            }
            return
        end

        local afterPair = getSheathState()

        if afterPair == 1 then
            finishAtGoal(1)
            return
        end

        if afterPair == 3 then
            markAddonSheathe()
            pcall(ToggleSheath)

            if getSheathState() == 1 then
                finishAtGoal(1)
                return
            end
        end

        local current = getSheathState()
        if current ~= nil then
            pendingToggle = {
                from = current,
                expected = nextSheathState(current),
                expires = GetTime() + TOGGLE_TIMEOUT,
            }
        end

        return
    end

    -- Without a ranged weapon, do not run the paired-toggle path. One toggle
    -- from melee should sheath the weapon; check the observed state afterward.
    if goalState == 1 and state == 2 and not rangedPresent then
        if callToggle(goalState) then
            local afterSingle = getSheathState()

            if afterSingle == goalState then
                finishAtGoal(goalState)
            elseif afterSingle ~= nil and afterSingle ~= state then
                pendingToggle = {
                    from = state,
                    expected = afterSingle,
                    expires = GetTime() + TOGGLE_TIMEOUT,
                }
            end
        end

        return
    end

    local nextState = nextSheathState(state)
    if not nextState then
        return
    end

    if not callToggle(goalState) then
        return
    end

    local afterFirst = getSheathState()

    if afterFirst == goalState then
        finishAtGoal(goalState)
        return
    end

    if afterFirst == nextState and nextState ~= goalState then
        pendingToggle = nil

        if shootActive then
            return
        end

        if callToggle(goalState) and getSheathState() == goalState then
            finishAtGoal(goalState)
        end
    end
end

local function getUnsheatheDelay()
    if postShootMainhand then
        return 0, "post-shoot"
    end

    local now = GetTime()
    local combatNow = isInCombatNow()

    local delay = UnsheatheDelay
    local kind = combatNow and "combat" or "unsheathe"

    if not combatNow then
        local actionRemaining = actionDelayUntil - now
        local chatRemaining = chatSheatheUntil - now

        if actionRemaining > delay then
            delay = actionRemaining
            kind = "action"
        end

        if chatRemaining > delay then
            delay = chatRemaining
            kind = "chat"
        end
    end

    return math.max(delay, 0), kind
end

local function scheduleUnsheatheTimer(delay, kind)
    if unsheatheTimer and unsheatheTimerKind == kind then
        return
    end

    cancelUnsheatheTimer()

    if type(C_Timer) ~= "table"
        or type(C_Timer.NewTimer) ~= "function" then
        unsheatheReady = true
        return
    end

    local generation = unsheatheGeneration + 1
    unsheatheGeneration = generation
    unsheatheTimerKind = kind

    unsheatheTimer = C_Timer.NewTimer(delay, function()
        if generation ~= unsheatheGeneration then
            return
        end

        unsheatheTimer = nil
        unsheatheTimerKind = nil

        if enabled
            and not isEatingOrDrinkingWhileSitting()
            and not postShootActionPause
            and not combatAutomationPaused()
            and shouldUnsheatheNow()
            and hasSelectedWeapon() then
            unsheatheReady = true
            updateState()
        end
    end)
end

local function requestUnsheathe(shootActive)
    if not enabled
        or isEatingOrDrinkingWhileSitting()
        or postShootActionPause
        or combatAutomationPaused()
        or not shouldUnsheatheNow() then
        return
    end

    if postShootMainhand then
        cancelUnsheatheTimer()
        unsheatheReady = true

        if not isCastingOrChanneling() then
            driveTowardState(2, shootActive)
        end

        return
    end

    if not hasSelectedWeapon() or isCastingOrChanneling() then
        return
    end

    local goalState = selectedSheathState()
    if getSheathState() == goalState then
        unsheatheReady = true
        cancelUnsheatheTimer()
        return
    end

    local delay, kind = getUnsheatheDelay()

    if delay > 0 and not unsheatheReady then
        scheduleUnsheatheTimer(delay, kind or "normal")
        return
    end

    unsheatheReady = true
    cancelUnsheatheTimer()
    driveTowardState(goalState, shootActive)
end

local function scheduleSheathe()
    cancelSheatheTimer()

    if type(C_Timer) ~= "table"
        or type(C_Timer.NewTimer) ~= "function" then
        return
    end

    local generation = sheatheGeneration + 1
    sheatheGeneration = generation

    sheatheTimer = C_Timer.NewTimer(SheatheDelay, function()
        if generation ~= sheatheGeneration then
            return
        end

        sheatheTimer = nil

        if enabled
            and SHEATHE
            and not isEatingOrDrinkingWhileSitting()
            and not postShootActionPause
            and not combatAutomationPaused()
            and not shouldUnsheatheNow() then
            idleSheathing = true
            updateState()
        end
    end)
end

local function isOwnChatMessage(author, senderGUID)
    if type(senderGUID) == "string"
        and type(UnitGUID) == "function" then
        local ok, playerGUID = pcall(UnitGUID, "player")

        if ok and type(playerGUID) == "string"
            and senderGUID == playerGUID then
            return true
        end
    end

    -- Fall back to the player name if the sender GUID is missing,
    -- unavailable, or does not match.
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

local function shouldKeepPolling()
    if not enabled
        or isEatingOrDrinkingWhileSitting()
        or combatAutomationPaused() then
        return false
    end

    -- Falling-state changes do not have a reliable event.
    if INCLUDE_JUMPING_AND_FALLING then
        return true
    end

    if pendingToggle or postShootMainhand then
        return true
    end

    local now = GetTime()

    -- Poll only while repeat fire is cached or the Shoot handoff window
    -- is active. Ranged weapon presence alone does not require polling.
    if cachedAutoRepeat
        or now - lastShootActivityAt <= SHOOT_HANDOFF_WINDOW then
        return true
    end

    -- Detect ranged fire that begins during combat when using the main hand.
    if INCLUDE_COMBAT
        and DISABLE_POST_SHOOT_MAINHAND_IN_COMBAT
        and not USE_RANGED_WEAPON
        and rangedPresent
        and isInCombatNow() then
        return true
    end

    return false
end

local function refreshPolling()
    local shouldPoll = shouldKeepPolling()

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

local function updateStateCore()
    if not enabled then
        return
    end

    if isEatingOrDrinkingWhileSitting() then
        cancelSheatheTimer()
        cancelUnsheatheTimer()
        cancelActionRecheckTimer()

        pendingToggle = nil
        idleSheathing = false
        unsheatheReady = false

        return
    end

    moving = isMovingNow()
    attackableTarget =
        INCLUDE_ATTACKABLE_TARGETS and hasAttackableTarget()

    local now = GetTime()
    local combatNow = isInCombatNow()
    local shootActive = isShootActive()

    if not DISABLE_POST_SHOOT_MAINHAND_IN_COMBAT or not INCLUDE_COMBAT then
        postShootActionPause = false
        resumeActionAwaitingShootStop = false
    elseif not combatNow then
        postShootActionPause = false
        resumeActionAwaitingShootStop = false
    else
        if resumeActionAwaitingShootStop and not shootActive then
            resumeActionAwaitingShootStop = false
        end

        if shootActive and not resumeActionAwaitingShootStop then
            postShootActionPause = true
        end
    end

    if postShootActionPause or combatAutomationPaused() then
        cancelSheatheTimer()
        cancelUnsheatheTimer()
        unsheatheReady = false
        idleSheathing = false
        pendingToggle = nil
        postShootMainhand = false
        return
    end

    local state = getSheathState()

    -- Resolve pending toggles even when the current goal has changed.
    if pendingToggle then
        if state == nil
            or state ~= pendingToggle.from
            or now >= pendingToggle.expires then
            pendingToggle = nil
        end
    end

    local enteredSheathedState =
        state == 1 and lastObservedSheathState ~= 1

    local addonSheathe = now <= addonSheathePendingUntil
    local chatSheathe = now <= chatSheathePendingUntil

    local postShootHandoff =
        USE_RANGED_WEAPON
        and lastObservedSheathState == 3
        and state == 1
        and now - lastShootActivityAt <= SHOOT_HANDOFF_WINDOW
        and not addonSheathe
        and not chatSheathe

    if postShootHandoff then
        postShootMainhand = true
        actionDelayUntil = 0
        chatSheatheUntil = 0
        unsheatheReady = true
        cancelUnsheatheTimer()
    elseif enteredSheathedState then
        unsheatheReady = false
        cancelUnsheatheTimer()

        if lastObservedSheathState == 2
            or lastObservedSheathState == 3 then
            if addonSheathe then
                addonSheathePendingUntil = 0
            elseif chatSheathe then
                chatSheathePendingUntil = 0
            elseif not (USE_RANGED_WEAPON and combatNow) then
                actionDelayUntil = now + ActionDelay
            end
        end
    end

    if addonSheathePendingUntil > 0
        and now > addonSheathePendingUntil then
        addonSheathePendingUntil = 0
    end

    if chatSheathePendingUntil > 0
        and now > chatSheathePendingUntil then
        chatSheathePendingUntil = 0
    end

    if state ~= nil then
        lastObservedSheathState = state
    end

    if postShootMainhand then
        cancelSheatheTimer()
        cancelUnsheatheTimer()
        unsheatheReady = true

        if not shootActive and not isCastingOrChanneling() then
            driveTowardState(2, shootActive)
        end

        if getSheathState() == 2 and not shouldUnsheatheNow() then
            postShootMainhand = false
        end

        return
    end

    if shouldUnsheatheNow() then
        cancelSheatheTimer()
        idleSheathing = false

        if not isCastingOrChanneling() then
            requestUnsheathe(shootActive)
        end

        return
    end

    cancelUnsheatheTimer()
    unsheatheReady = false
    postShootMainhand = false

    -- SHEATHE=false must never enter the automatic sheathing path.
    if not SHEATHE then
        cancelSheatheTimer()
        idleSheathing = false
        return
    end

    if idleSheathing then
        if state == 1 then
            finishAtGoal(1)
        else
            driveTowardState(1, shootActive)
        end

        return
    end

    if state == 2 or state == 3 then
        if not sheatheTimer then
            scheduleSheathe()
        end
    else
        cancelSheatheTimer()
    end
end

updateState = function()
    if not enabled then
        return
    end

    updateStateCore()
    refreshPolling()
end

local function registerEvents()
    frame:RegisterEvent("PLAYER_STARTED_MOVING")
    frame:RegisterEvent("PLAYER_STOPPED_MOVING")
    frame:RegisterEvent("PLAYER_REGEN_DISABLED")
    frame:RegisterEvent("PLAYER_REGEN_ENABLED")
    frame:RegisterEvent("PLAYER_TARGET_CHANGED")
    frame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
    frame:RegisterEvent("PLAYER_ENTERING_WORLD")
    frame:RegisterEvent("CHAT_MSG_SAY")
    frame:RegisterEvent("CHAT_MSG_YELL")
    frame:RegisterEvent("UNIT_AURA")

    frame:RegisterEvent("UNIT_FLAGS")
    frame:RegisterEvent("UNIT_FACTION")
    frame:RegisterEvent("UNIT_SPELLCAST_START")
    frame:RegisterEvent("UNIT_SPELLCAST_STOP")
    frame:RegisterEvent("UNIT_SPELLCAST_CHANNEL_START")
    frame:RegisterEvent("UNIT_SPELLCAST_CHANNEL_STOP")
    frame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
end

local function printLine(message)
    if DEFAULT_CHAT_FRAME
        and type(DEFAULT_CHAT_FRAME.AddMessage) == "function" then
        DEFAULT_CHAT_FRAME:AddMessage(message)
    end
end

local function printMessage(message)
    printLine("|cff80c0ffUnsheathed:|r " .. message)
end

local function printSettingResponse(message)
    printLine("|cff80c0ffUnsheathed:|r")
    printLine(message)
end

local function getSavedBoolean(key, defaultValue)
    if type(UnsheathedDB[key]) == "boolean" then
        return UnsheathedDB[key]
    end

    UnsheathedDB[key] = defaultValue
    return defaultValue
end

local function isValidSheatheDelay(value)
    return type(value) == "number"
        and value >= 1
        and value <= 60
end

local function getSavedSheatheDelay()
    local savedDelay = UnsheathedDB.sheatheDelay

    if isValidSheatheDelay(savedDelay) then
        return savedDelay
    end

    UnsheathedDB.sheatheDelay = DEFAULT_SHEATHE_DELAY
    return DEFAULT_SHEATHE_DELAY
end

local function formatSheatheDelay(value)
    return string.format("%g", value)
end

local function setSheatheDelay(value)
    if not isValidSheatheDelay(value) then
        printMessage("Delay must be a number from 1 to 60 seconds.")
        return
    end

    SheatheDelay = value
    UnsheathedDB.sheatheDelay = value

    -- Restart any pending sheathe timer using the newly selected delay.
    cancelSheatheTimer()
    updateState()

    printSettingResponse(
        "Delay: " .. formatSheatheDelay(value) .. " Seconds"
    )
end

local function resetRuntimeState()
    cancelSheatheTimer()
    cancelUnsheatheTimer()
    cancelActionRecheckTimer()

    frame:SetScript("OnUpdate", nil)
    pollingEnabled = false
    pollElapsed = 0

    pendingToggle = nil
    idleSheathing = false
    unsheatheReady = false

    postShootActionPause = false
    resumeActionAwaitingShootStop = false
    postShootMainhand = false

    cachedAutoRepeat = false
    lastShootActivityAt = -1000000

    actionDelayUntil = 0
    chatSheatheUntil = 0
    addonSheathePendingUntil = 0
    chatSheathePendingUntil = 0
end

setEnabled = function(value, report)
    value = value == true

    UnsheathedDB.enabled = value

    if value == enabled then
        if report then
            printSettingResponse(
                "Status: "
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
                "Status: |cffff8080Disabled|r"
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

    lastObservedSheathState = getSheathState()
    updateState()

    if report then
        printSettingResponse(
            "Status: |cff80ff80Enabled|r"
        )
    end
end

local function setOption(option, value)
    value = value == true

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

    -- Re-evaluate promptly under the newly selected behavior.
    cancelSheatheTimer()
    cancelUnsheatheTimer()
    pendingToggle = nil
    unsheatheReady = false
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

    printSettingResponse(optionNames[option] .. ": " .. status)
end

local function printOptionStatus()
    local sheatheStatus = SHEATHE
        and "|cff80ff80On|r" or "|cffff8080Off|r"
    local combatStatus = INCLUDE_COMBAT
        and "|cff80ff80On|r" or "|cffff8080Off|r"
    local targetStatus = INCLUDE_ATTACKABLE_TARGETS
        and "|cff80ff80On|r" or "|cffff8080Off|r"
    local rangedStatus = USE_RANGED_WEAPON
        and "|cff80ff80On|r" or "|cffff8080Off|r"

    printLine("Sheathe: " .. sheatheStatus)
    printLine("Combat: " .. combatStatus)
    printLine("Target: " .. targetStatus)
    printLine("Ranged: " .. rangedStatus)
end

local function printStatus()
    printLine("|cff80c0ffUnsheathed:|r")
    printLine("Status: "
        .. (enabled and "|cff80ff80Enabled|r"
            or "|cffff8080Disabled|r"))
    printOptionStatus()
    printLine("Delay: " .. formatSheatheDelay(SheatheDelay) .. " Seconds")
    printLine("Commands: Type |cffffd200/us help|r for options and commands.")
end

local function printHelp()
    local options = "[|cff80ff80enable|r|||cffff8080disable|r]"

    printLine("|cff80c0ffUnsheathed:|r |cffffd200Commands|r")
    printLine("/us " .. options .. " - Enable or disable Unsheathed for this character.")
    printLine("/us sheathe " .. options .. " - Enable or disable automatic sheathing.")
    printLine("/us combat " .. options .. " - Allow unsheathing during combat.")
    printLine("/us target " .. options .. " - React to attackable targets.")
    printLine("/us ranged " .. options .. " - Prefer the ranged weapon over the main hand.")
    printLine("/us delay [|cff80ff801-60|r] - Set the sheathing delay in seconds.")
end

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
        SHEATHE = getSavedBoolean(
            "sheathe",
            DEFAULT_SHEATHE
        )
        SheatheDelay = getSavedSheatheDelay()

        initialized = true

        local savedEnabled = getSavedBoolean("enabled", DEFAULT_ENABLED)
        setEnabled(savedEnabled, false)
        return
    end

    if not enabled then
        return
    end

    if event == "UNIT_AURA" then
        local unit = ...
        if unit == "player" then
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

        local unit, _, spellID = ...

        if unit ~= "player" then
            return
        end

        if event == "UNIT_SPELLCAST_SUCCEEDED"
            and not isSecret(spellID)
            and type(spellID) == "number"
            and spellID ~= SHOOT_SPELL_ID
            and spellID ~= AUTO_SHOT_SPELL_ID
            and postShootActionPause then

            postShootActionPause = false
            resumeActionAwaitingShootStop = isShootActive()
            unsheatheReady = false
            cancelUnsheatheTimer()
        end

        updateState()

        if not isEatingOrDrinkingWhileSitting() then
            scheduleActionRechecks()
        end

        return
    end

    if event == "PLAYER_STARTED_MOVING" then
        eventMoving = true

    elseif event == "PLAYER_STOPPED_MOVING" then
        eventMoving = false

    elseif event == "PLAYER_REGEN_DISABLED" then
        inCombat = true

    elseif event == "PLAYER_REGEN_ENABLED" then
        inCombat = false

        -- Discard stale ranged-fire tracking when combat ends without the
        -- ranged weapon drawn; keep it only if a ranged handoff may remain.
        if getSheathState() ~= 3 then
            cachedAutoRepeat = false
            lastShootActivityAt = -1000000
            postShootActionPause = false
            resumeActionAwaitingShootStop = false
        end

    elseif event == "PLAYER_EQUIPMENT_CHANGED"
        or event == "PLAYER_ENTERING_WORLD" then
        refreshEquipment()

    elseif event == "CHAT_MSG_SAY" or event == "CHAT_MSG_YELL" then
        local args = {...}

        if isOwnChatMessage(args[2], args[12]) then
            local now = GetTime()

            actionDelayUntil = 0
            chatSheatheUntil = now + SheatheDelay
            chatSheathePendingUntil =
                now + math.max(SheatheDelay, ADDON_SHEATHE_WINDOW)

            unsheatheReady = false
            cancelUnsheatheTimer()

            updateState()
            scheduleActionRechecks()
            return
        end
    end

    updateState()
end)

onUpdateScript = function(_, elapsed)
    if not enabled then
        return
    end

    pollElapsed = pollElapsed + elapsed

    if pollElapsed < POLL_INTERVAL then
        return
    end

    pollElapsed = 0
    updateState()
end

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

    if first == "enable" or first == "on" then
        if second == "" then
            setEnabled(true, true)
        else
            printHelp()
        end
        return
    end

    if first == "disable" or first == "off" then
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
        and (second == "enable" or second == "disable") then
        setOption(first, second == "enable")
        return
    end

    printHelp()
end

frame:RegisterEvent("ADDON_LOADED")
