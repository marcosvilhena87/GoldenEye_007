-- GoldenEyeDiagnostic 0.0.5.8.7
-- First Soldier Pointer Death Gate
--
-- Sinal principal:
-- 0x001F421C (U32 big-endian)
--
-- Padrão validado:
-- BEFORE_SHOT  = valor diferente de zero
-- HIT          = mesmo valor diferente de zero
-- VISUAL_DEATH = zero
-- MISS         = mesmo valor diferente de zero
--
-- Fluxo:
-- IDLE
-- TRACKING
-- SHOT_READY
-- FIRED
-- WAITING_RESULT
-- KILL_CONFIRMED
-- SHOT_FAILED
-- COMPLETE
--
-- Somente leitura de memória; escrita apenas no controle P1 Z.

local VERSION = "0.0.5.8.7"
local EXPECTED_ROM_HASH = "ABE01E4AEB033B6C0836819F549C791B26CFDE83"

local SCREEN_X_ADDRESS = 0x000D3F48
local SCREEN_X_COPY_ADDRESS = 0x000D3F5C
local RAW_HORIZONTAL_ADDRESS = 0x000D3998
local NORMALIZED_ADDRESS = 0x000D596C

local FIRST_SOLDIER_POINTER_ADDRESS = 0x001F421C

local DEFAULT_SCREEN_MIN = 157.0
local DEFAULT_SCREEN_MAX = 163.0
local DEFAULT_DETECT_RAW = 20.0
local DEFAULT_DETECT_NORMALIZED = 0.020
local DEFAULT_MEMORY_FRAMES = 45
local DEFAULT_READY_FRAMES = 2
local DEFAULT_SHOT_FRAMES = 1

local DEFAULT_RESULT_DELAY_FRAMES = 4
local DEFAULT_RESULT_TIMEOUT_FRAMES = 120
local DEFAULT_KILL_CONFIRM_FRAMES = 3
local DEFAULT_MAX_ATTEMPTS = 2
local DEFAULT_RETRY_DELAY_FRAMES = 20
local DEFAULT_LOG_INTERVAL = 2

local Z_BUTTON_NAME = "P1 Z"

local stopped = false
local gateEnabled = false
local pendingAction = nil
local session = nil

local stateName = "IDLE"
local memoryRemaining = 0
local readyCount = 0
local fireFramesRemaining = 0
local releaseFramesRemaining = 0

local attemptCount = 0
local resultElapsed = 0
local killConfirmCount = 0
local retryDelayRemaining = 0

local baselinePointer = nil
local shotPointer = nil
local lastPointer = nil
local shotSnapshot = nil

local form
local statusLabel
local liveLabel
local outcomeLabel
local filesLabel

local screenMinBox
local screenMaxBox
local detectRawBox
local detectNormalizedBox
local memoryFramesBox
local readyFramesBox
local shotFramesBox
local resultDelayBox
local resultTimeoutBox
local killConfirmBox
local maxAttemptsBox
local retryDelayBox
local logIntervalBox

local function scriptDirectory()
    local source = debug.getinfo(1, "S").source
    if source:sub(1, 1) == "@" then source = source:sub(2) end
    return source:match("^(.*[\\/])") or ".\\"
end

local BASE_DIR = scriptDirectory()
local OUTPUT_DIR = BASE_DIR .. "output\\"
os.execute('if not exist "' .. OUTPUT_DIR .. '" mkdir "' .. OUTPUT_DIR .. '"')

local function log(text)
    console.log("[GoldenEyeDiagnostic] " .. text)
end

local function setStatus(text)
    forms.settext(statusLabel, "Status: " .. text)
end

local function numberFromBox(box, defaultValue, minimum, maximum)
    local value = tonumber(forms.gettext(box)) or defaultValue
    if value < minimum then value = minimum end
    if value > maximum then value = maximum end
    return value
end

local function integerFromBox(box, defaultValue, minimum, maximum)
    return math.floor(numberFromBox(box, defaultValue, minimum, maximum) + 0.5)
end

local function readPointer()
    return mainmemory.read_u32_be(FIRST_SOLDIER_POINTER_ADDRESS)
end

local function readState()
    return {
        frame = emu.framecount(),
        screenX = mainmemory.readfloat(SCREEN_X_ADDRESS, true),
        screenXCopy = mainmemory.readfloat(SCREEN_X_COPY_ADDRESS, true),
        raw = mainmemory.readfloat(RAW_HORIZONTAL_ADDRESS, true),
        normalized = mainmemory.readfloat(NORMALIZED_ADDRESS, true),
        soldierPointer = readPointer()
    }
end

local function getThresholds()
    return {
        screenMin = numberFromBox(screenMinBox, DEFAULT_SCREEN_MIN, 0, 320),
        screenMax = numberFromBox(screenMaxBox, DEFAULT_SCREEN_MAX, 0, 320),
        detectRaw = numberFromBox(detectRawBox, DEFAULT_DETECT_RAW, 0, 1000000),
        detectNormalized = numberFromBox(
            detectNormalizedBox,
            DEFAULT_DETECT_NORMALIZED,
            0,
            1000
        ),
        memoryFrames = integerFromBox(
            memoryFramesBox,
            DEFAULT_MEMORY_FRAMES,
            1,
            600
        ),
        readyFrames = integerFromBox(
            readyFramesBox,
            DEFAULT_READY_FRAMES,
            1,
            120
        ),
        shotFrames = integerFromBox(
            shotFramesBox,
            DEFAULT_SHOT_FRAMES,
            1,
            20
        ),
        resultDelay = integerFromBox(
            resultDelayBox,
            DEFAULT_RESULT_DELAY_FRAMES,
            0,
            120
        ),
        resultTimeout = integerFromBox(
            resultTimeoutBox,
            DEFAULT_RESULT_TIMEOUT_FRAMES,
            5,
            600
        ),
        killConfirmFrames = integerFromBox(
            killConfirmBox,
            DEFAULT_KILL_CONFIRM_FRAMES,
            1,
            120
        ),
        maxAttempts = integerFromBox(
            maxAttemptsBox,
            DEFAULT_MAX_ATTEMPTS,
            1,
            10
        ),
        retryDelay = integerFromBox(
            retryDelayBox,
            DEFAULT_RETRY_DELAY_FRAMES,
            0,
            300
        ),
        logInterval = integerFromBox(
            logIntervalBox,
            DEFAULT_LOG_INTERVAL,
            1,
            600
        )
    }
end

local function evaluateAim(current, thresholds)
    local armReady =
        current.screenX >= thresholds.screenMin
        and current.screenX <= thresholds.screenMax

    local rawDetected = math.abs(current.raw) >= thresholds.detectRaw
    local normalizedDetected =
        math.abs(current.normalized) >= thresholds.detectNormalized

    return {
        armReady = armReady,
        rawDetected = rawDetected,
        normalizedDetected = normalizedDetected,
        autoAimDetected = rawDetected or normalizedDetected
    }
end

local function evaluatePointer(current)
    local pointerWasLive =
        baselinePointer ~= nil
        and baselinePointer ~= 0

    local pointerZeroNow =
        current.soldierPointer == 0

    local pointerTransitionedToZero =
        pointerWasLive
        and pointerZeroNow

    local changedFromShot =
        shotPointer ~= nil
        and current.soldierPointer ~= shotPointer

    return {
        pointerWasLive = pointerWasLive,
        pointerZeroNow = pointerZeroNow,
        pointerTransitionedToZero = pointerTransitionedToZero,
        changedFromShot = changedFromShot
    }
end

local function setZ(pressed)
    joypad.set({[Z_BUTTON_NAME] = pressed})
end

local function resetFlow()
    stateName = "IDLE"
    memoryRemaining = 0
    readyCount = 0
    fireFramesRemaining = 0
    releaseFramesRemaining = 0
    attemptCount = 0
    resultElapsed = 0
    killConfirmCount = 0
    retryDelayRemaining = 0
    baselinePointer = nil
    shotPointer = nil
    lastPointer = nil
    shotSnapshot = nil
    setZ(false)
end

local function writeHeader(file)
    file:write(
        "frame,event,state,gate_enabled,attempt,"
        .. "memory_remaining,ready_count,result_elapsed,kill_confirm_count,retry_delay_remaining,"
        .. "screen_x,screen_x_copy,raw_horizontal,normalized,"
        .. "baseline_pointer_hex,shot_pointer_hex,current_pointer_hex,last_pointer_hex,"
        .. "arm_ready,raw_detected,normalized_detected,auto_aim_detected,"
        .. "pointer_was_live,pointer_zero_now,pointer_transitioned_to_zero,changed_from_shot\n"
    )
end

local function pointerHex(value)
    if value == nil then return "nil" end
    return string.format("0x%08X", value)
end

local function writeRow(eventName, current, aim, pointerState)
    if not session or not session.csv then return end

    session.csv:write(
        tostring(current.frame) .. ","
        .. tostring(eventName or "") .. ","
        .. stateName .. ","
        .. tostring(gateEnabled) .. ","
        .. tostring(attemptCount) .. ","
        .. tostring(memoryRemaining) .. ","
        .. tostring(readyCount) .. ","
        .. tostring(resultElapsed) .. ","
        .. tostring(killConfirmCount) .. ","
        .. tostring(retryDelayRemaining) .. ","
        .. tostring(current.screenX) .. ","
        .. tostring(current.screenXCopy) .. ","
        .. tostring(current.raw) .. ","
        .. tostring(current.normalized) .. ","
        .. pointerHex(baselinePointer) .. ","
        .. pointerHex(shotPointer) .. ","
        .. pointerHex(current.soldierPointer) .. ","
        .. pointerHex(lastPointer) .. ","
        .. tostring(aim.armReady) .. ","
        .. tostring(aim.rawDetected) .. ","
        .. tostring(aim.normalizedDetected) .. ","
        .. tostring(aim.autoAimDetected) .. ","
        .. tostring(pointerState.pointerWasLive) .. ","
        .. tostring(pointerState.pointerZeroNow) .. ","
        .. tostring(pointerState.pointerTransitionedToZero) .. ","
        .. tostring(pointerState.changedFromShot)
        .. "\n"
    )
    session.csv:flush()
end

local function startSession()
    if session then
        setStatus("sessao ja iniciada")
        return
    end

    local timestamp = os.date("%Y%m%d-%H%M%S")
    local csvPath = OUTPUT_DIR
        .. "first-soldier-pointer-death-gate-" .. timestamp .. ".csv"
    local summaryPath = OUTPUT_DIR
        .. "first-soldier-pointer-death-gate-" .. timestamp .. "-summary.txt"

    local csv = assert(io.open(csvPath, "w"))
    writeHeader(csv)

    session = {
        csv = csv,
        csvPath = csvPath,
        summaryPath = summaryPath,
        startedFrame = emu.framecount(),
        shots = 0,
        kills = 0,
        failures = 0,
        completes = 0,
        pointerZeroFrames = 0,
        pointerChanges = 0,
        stateCounts = {}
    }

    forms.settext(
        filesLabel,
        "CSV: " .. csvPath .. "\nResumo: " .. summaryPath
    )

    setStatus("sessao iniciada")
end

local function stopSession()
    gateEnabled = false
    setZ(false)

    if not session then
        setStatus("nenhuma sessao")
        return
    end

    session.csv:close()
    session.csv = nil

    local summary = assert(io.open(session.summaryPath, "w"))
    summary:write("GoldenEyeDiagnostic " .. VERSION .. "\n")
    summary:write("ROM: " .. tostring(gameinfo.getromname()) .. "\n")
    summary:write("Hash: " .. tostring(gameinfo.getromhash()) .. "\n")
    summary:write("Started frame: " .. tostring(session.startedFrame) .. "\n")
    summary:write("Stopped frame: " .. tostring(emu.framecount()) .. "\n")
    summary:write("Shots: " .. tostring(session.shots) .. "\n")
    summary:write("Kills confirmed: " .. tostring(session.kills) .. "\n")
    summary:write("Shot failures: " .. tostring(session.failures) .. "\n")
    summary:write("Complete states: " .. tostring(session.completes) .. "\n")
    summary:write("Pointer zero frames: "
        .. tostring(session.pointerZeroFrames) .. "\n")
    summary:write("Pointer changes: "
        .. tostring(session.pointerChanges) .. "\n")
    summary:write("Final state: " .. stateName .. "\n")
    summary:write("Attempts used: " .. tostring(attemptCount) .. "\n")
    summary:write("Baseline pointer: " .. pointerHex(baselinePointer) .. "\n")
    summary:write("Shot pointer: " .. pointerHex(shotPointer) .. "\n")
    summary:write("Last pointer: " .. pointerHex(lastPointer) .. "\n")
    summary:write("Screen window: "
        .. forms.gettext(screenMinBox) .. " to "
        .. forms.gettext(screenMaxBox) .. "\n")
    summary:write("Detect raw: " .. forms.gettext(detectRawBox) .. "\n")
    summary:write("Detect normalized: "
        .. forms.gettext(detectNormalizedBox) .. "\n")
    summary:write("Memory frames: "
        .. forms.gettext(memoryFramesBox) .. "\n")
    summary:write("Ready frames: "
        .. forms.gettext(readyFramesBox) .. "\n")
    summary:write("Shot frames: "
        .. forms.gettext(shotFramesBox) .. "\n")
    summary:write("Result delay: "
        .. forms.gettext(resultDelayBox) .. "\n")
    summary:write("Result timeout: "
        .. forms.gettext(resultTimeoutBox) .. "\n")
    summary:write("Kill confirm frames: "
        .. forms.gettext(killConfirmBox) .. "\n")
    summary:write("Max attempts: "
        .. forms.gettext(maxAttemptsBox) .. "\n")
    summary:write("Retry delay: "
        .. forms.gettext(retryDelayBox) .. "\n")
    summary:write("CSV: " .. tostring(session.csvPath) .. "\n\n")

    summary:write("State counts:\n")
    for _, name in ipairs({
        "IDLE",
        "TRACKING",
        "SHOT_READY",
        "FIRED",
        "WAITING_RESULT",
        "KILL_CONFIRMED",
        "SHOT_FAILED",
        "RETRY_DELAY",
        "COMPLETE"
    }) do
        summary:write(
            name .. ": "
            .. tostring(session.stateCounts[name] or 0)
            .. "\n"
        )
    end

    if shotSnapshot then
        summary:write("\nLast shot snapshot:\n")
        summary:write("Frame: " .. tostring(shotSnapshot.frame) .. "\n")
        summary:write("screen_x: " .. tostring(shotSnapshot.screenX) .. "\n")
        summary:write("raw: " .. tostring(shotSnapshot.raw) .. "\n")
        summary:write("normalized: " .. tostring(shotSnapshot.normalized) .. "\n")
        summary:write(
            "pointer: "
            .. pointerHex(shotSnapshot.soldierPointer)
            .. "\n"
        )
    end

    summary:close()

    setStatus("sessao encerrada")
    session = nil
end

local function processAction()
    if not pendingAction then return end

    local action = pendingAction
    pendingAction = nil

    local ok, err = pcall(function()
        if action == "START_SESSION" then
            startSession()

        elseif action == "ENABLE" then
            if not session then startSession() end
            gateEnabled = true
            setStatus("gate ativado")

        elseif action == "DISABLE" then
            gateEnabled = false
            setZ(false)
            setStatus("gate desativado")

        elseif action == "RESET" then
            resetFlow()
            setStatus("fluxo reiniciado")

        elseif action == "STOP_SESSION" then
            stopSession()
        end
    end)

    if not ok then
        gateEnabled = false
        setZ(false)
        setStatus("erro")
        forms.settext(outcomeLabel, tostring(err))
        log("ERRO: " .. tostring(err))
    end
end

form = forms.newform(
    1040,
    860,
    "GoldenEyeDiagnostic " .. VERSION,
    function() stopped = true end
)

forms.label(
    form,
    "First Soldier Pointer Death Gate — 0x001F421C",
    12, 10, 1000, 24
)

statusLabel = forms.label(
    form,
    "Status: pronto",
    12, 40, 1000, 24
)

liveLabel = forms.label(
    form,
    "Estado atual: aguardando",
    12, 75, 1000, 170, true
)

outcomeLabel = forms.label(
    form,
    "Outcome: aguardando",
    12, 250, 1000, 125, true
)

filesLabel = forms.label(
    form,
    "Nenhuma sessao aberta",
    12, 380, 1000, 55, true
)

forms.label(form, "screen_x min", 12, 450, 85, 22)
screenMinBox = forms.textbox(form, "157", 70, 24, nil, 102, 447)

forms.label(form, "screen_x max", 195, 450, 85, 22)
screenMaxBox = forms.textbox(form, "163", 70, 24, nil, 285, 447)

forms.label(form, "|raw| detect", 378, 450, 85, 22)
detectRawBox = forms.textbox(form, "20", 70, 24, nil, 468, 447)

forms.label(form, "|norm| detect", 561, 450, 90, 22)
detectNormalizedBox = forms.textbox(
    form, "0.020", 80, 24, nil, 656, 447
)

forms.label(form, "Memoria", 12, 490, 60, 22)
memoryFramesBox = forms.textbox(form, "45", 60, 24, nil, 77, 487)

forms.label(form, "Frames alinhados", 155, 490, 110, 22)
readyFramesBox = forms.textbox(form, "2", 60, 24, nil, 270, 487)

forms.label(form, "Frames Z", 345, 490, 65, 22)
shotFramesBox = forms.textbox(form, "1", 60, 24, nil, 415, 487)

forms.label(form, "Delay resultado", 490, 490, 95, 22)
resultDelayBox = forms.textbox(form, "4", 60, 24, nil, 590, 487)

forms.label(form, "Timeout resultado", 665, 490, 110, 22)
resultTimeoutBox = forms.textbox(form, "120", 60, 24, nil, 780, 487)

forms.label(form, "Confirmar kill", 12, 530, 85, 22)
killConfirmBox = forms.textbox(form, "3", 60, 24, nil, 102, 527)

forms.label(form, "Max tentativas", 180, 530, 95, 22)
maxAttemptsBox = forms.textbox(form, "2", 60, 24, nil, 280, 527)

forms.label(form, "Delay retry", 355, 530, 75, 22)
retryDelayBox = forms.textbox(form, "20", 60, 24, nil, 435, 527)

forms.label(form, "Intervalo log", 510, 530, 85, 22)
logIntervalBox = forms.textbox(form, "2", 60, 24, nil, 600, 527)

forms.button(
    form,
    "INICIAR SESSAO",
    function() pendingAction = "START_SESSION" end,
    12, 585, 155, 40
)

forms.button(
    form,
    "ATIVAR GATE",
    function() pendingAction = "ENABLE" end,
    180, 585, 145, 40
)

forms.button(
    form,
    "DESATIVAR",
    function() pendingAction = "DISABLE" end,
    338, 585, 130, 40
)

forms.button(
    form,
    "REINICIAR",
    function() pendingAction = "RESET" end,
    481, 585, 130, 40
)

forms.button(
    form,
    "ENCERRAR",
    function() pendingAction = "STOP_SESSION" end,
    624, 585, 140, 40
)

forms.label(
    form,
    "Kill confirmado quando:\n"
    .. "baselinePointer != 0\n"
    .. "e currentPointer == 0\n"
    .. "por 3 frames consecutivos.\n\n"
    .. "O ponteiro validado foi 0x001F421C. Depois de KILL_CONFIRMED, "
    .. "o estado entra em COMPLETE e nenhum novo tiro e permitido.\n\n"
    .. "Se o ponteiro continuar diferente de zero ate o timeout, "
    .. "o tiro e classificado como SHOT_FAILED. O RETRY_DELAY agora bloqueia "
    .. "efetivamente uma nova aquisicao pelo numero configurado de frames.",
    12, 645, 1000, 170
)

console.clear()
log("Carregado | versao=" .. VERSION)
log("ROM=" .. tostring(gameinfo.getromname()))
log("Hash=" .. tostring(gameinfo.getromhash()))

if tostring(gameinfo.getromhash()) ~= EXPECTED_ROM_HASH then
    log("AVISO | hash inesperado")
end

event.onexit(function()
    gateEnabled = false
    pcall(function() setZ(false) end)
    if session then pcall(stopSession) end
    stopped = true
end, "GoldenEyeDiagnostic-0.0.5.8.7-exit")

while not stopped do
    processAction()

    local thresholds = getThresholds()
    local current = readState()
    local aim = evaluateAim(current, thresholds)
    local pointerState = evaluatePointer(current)

    if lastPointer ~= nil
        and current.soldierPointer ~= lastPointer
        and session then
        session.pointerChanges = session.pointerChanges + 1
        writeRow("POINTER_CHANGED", current, aim, pointerState)
    end

    if current.soldierPointer == 0 and session then
        session.pointerZeroFrames = session.pointerZeroFrames + 1
    end

    if stateName == "IDLE" then
        memoryRemaining = 0
        readyCount = 0
        resultElapsed = 0
        killConfirmCount = 0

        if retryDelayRemaining > 0 then
            stateName = "RETRY_DELAY"
        elseif aim.autoAimDetected
            and attemptCount < thresholds.maxAttempts
            and current.soldierPointer ~= 0 then

            stateName = "TRACKING"
            memoryRemaining = thresholds.memoryFrames
            baselinePointer = current.soldierPointer

            if session then
                writeRow("ACQUIRED", current, aim, pointerState)
            end
        end

    elseif stateName == "TRACKING" then
        if aim.autoAimDetected then
            memoryRemaining = thresholds.memoryFrames
        elseif memoryRemaining > 0 then
            memoryRemaining = memoryRemaining - 1
        else
            stateName = "IDLE"
            readyCount = 0
        end

        if memoryRemaining > 0 and aim.armReady then
            readyCount = readyCount + 1
            stateName = "SHOT_READY"
        else
            readyCount = 0
        end

    elseif stateName == "SHOT_READY" then
        if aim.armReady and memoryRemaining > 0 then
            readyCount = readyCount + 1
        else
            stateName = "TRACKING"
            readyCount = 0
        end

        if gateEnabled
            and readyCount >= thresholds.readyFrames
            and fireFramesRemaining == 0
            and releaseFramesRemaining == 0 then

            attemptCount = attemptCount + 1
            fireFramesRemaining = thresholds.shotFrames
            stateName = "FIRED"
            shotSnapshot = current
            shotPointer = current.soldierPointer
            resultElapsed = 0
            killConfirmCount = 0

            if session then
                session.shots = session.shots + 1
                writeRow("AUTO_SHOT", current, aim, pointerState)
            end

            setStatus("AUTO_SHOT tentativa " .. tostring(attemptCount))
        end

    elseif stateName == "FIRED" then
        stateName = "WAITING_RESULT"
        resultElapsed = 0

    elseif stateName == "WAITING_RESULT" then
        resultElapsed = resultElapsed + 1

        if resultElapsed >= thresholds.resultDelay then
            if pointerState.pointerTransitionedToZero then
                killConfirmCount = killConfirmCount + 1
            else
                killConfirmCount = 0
            end

            if killConfirmCount >= thresholds.killConfirmFrames then
                stateName = "KILL_CONFIRMED"

                if session then
                    session.kills = session.kills + 1
                    writeRow("KILL_CONFIRMED", current, aim, pointerState)
                end

                setStatus("KILL_CONFIRMED")
            elseif resultElapsed >= thresholds.resultTimeout then
                stateName = "SHOT_FAILED"

                if session then
                    session.failures = session.failures + 1
                    writeRow("SHOT_FAILED", current, aim, pointerState)
                end

                setStatus("SHOT_FAILED")
            end
        end

    elseif stateName == "KILL_CONFIRMED" then
        stateName = "COMPLETE"

        if session then
            session.completes = session.completes + 1
            writeRow("COMPLETE", current, aim, pointerState)
        end

        gateEnabled = false
        setZ(false)

    elseif stateName == "SHOT_FAILED" then
        if attemptCount >= thresholds.maxAttempts then
            stateName = "COMPLETE"

            if session then
                session.completes = session.completes + 1
                writeRow("COMPLETE_FAILED", current, aim, pointerState)
            end

            gateEnabled = false
            setZ(false)
        else
            retryDelayRemaining = thresholds.retryDelay
            stateName = "RETRY_DELAY"
            memoryRemaining = 0
            readyCount = 0
        end

    elseif stateName == "RETRY_DELAY" then
        if retryDelayRemaining > 0 then
            retryDelayRemaining = retryDelayRemaining - 1
        else
            stateName = "IDLE"
        end

    elseif stateName == "COMPLETE" then
        gateEnabled = false
        setZ(false)
    end

    if gateEnabled and fireFramesRemaining > 0 then
        setZ(true)
        fireFramesRemaining = fireFramesRemaining - 1

        if fireFramesRemaining == 0 then
            releaseFramesRemaining = 8
        end
    else
        setZ(false)

        if releaseFramesRemaining > 0 then
            releaseFramesRemaining = releaseFramesRemaining - 1
        end
    end

    if session and current.frame % thresholds.logInterval == 0 then
        writeRow("SAMPLE", current, aim, pointerState)
        session.stateCounts[stateName] =
            (session.stateCounts[stateName] or 0) + 1
    end

    forms.settext(
        liveLabel,
        string.format(
            "frame=%d | state=%s | attempt=%d/%d\n"
            .. "screen_x=% .6f | raw=% .6f | normalized=% .6f\n"
            .. "baseline=%s\n"
            .. "shot=%s | current=%s | last=%s",
            current.frame,
            stateName,
            attemptCount,
            thresholds.maxAttempts,
            current.screenX,
            current.raw,
            current.normalized,
            pointerHex(baselinePointer),
            pointerHex(shotPointer),
            pointerHex(current.soldierPointer),
            pointerHex(lastPointer)
        )
    )

    forms.settext(
        outcomeLabel,
        string.format(
            "ARM_READY=%s | AUTO_AIM=%s | memory=%d | ready=%d/%d\n"
            .. "pointerWasLive=%s | pointerZeroNow=%s\n"
            .. "transitionedToZero=%s | confirm=%d/%d\n"
            .. "result=%d/%d | retryDelay=%d | gateEnabled=%s",
            tostring(aim.armReady),
            tostring(aim.autoAimDetected),
            memoryRemaining,
            readyCount,
            thresholds.readyFrames,
            tostring(pointerState.pointerWasLive),
            tostring(pointerState.pointerZeroNow),
            tostring(pointerState.pointerTransitionedToZero),
            killConfirmCount,
            thresholds.killConfirmFrames,
            resultElapsed,
            thresholds.resultTimeout,
            retryDelayRemaining,
            tostring(gateEnabled)
        )
    )

    gui.drawString(
        8, 8,
        "GoldenEyeDiagnostic " .. VERSION,
        "white", "black", 12
    )

    gui.drawString(
        8, 26,
        stateName,
        "white", "black", 12
    )

    lastPointer = current.soldierPointer
    emu.frameadvance()
end
