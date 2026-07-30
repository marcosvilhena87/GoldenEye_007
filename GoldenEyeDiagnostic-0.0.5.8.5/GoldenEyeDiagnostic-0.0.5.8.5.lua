-- GoldenEyeDiagnostic 0.0.5.8.5
-- First Soldier Outcome Gate
--
-- Estados:
-- IDLE
-- TRACKING
-- SHOT_READY
-- FIRED
-- WAITING_RESULT
-- KILL_CONFIRMED
-- SHOT_FAILED
-- COMPLETE
--
-- Fluxo:
-- detecta auto-aim recente;
-- aguarda braco convergir;
-- dispara uma vez;
-- monitora sinais do primeiro soldado;
-- confirma KILL ou declara SHOT_FAILED;
-- opcionalmente permite uma segunda tentativa;
-- encerra em COMPLETE.
--
-- Somente leitura de memoria; escrita apenas no controle P1 Z.

local VERSION = "0.0.5.8.5"
local EXPECTED_ROM_HASH = "ABE01E4AEB033B6C0836819F549C791B26CFDE83"

local SCREEN_X_ADDRESS = 0x000D3F48
local SCREEN_X_COPY_ADDRESS = 0x000D3F5C
local RAW_HORIZONTAL_ADDRESS = 0x000D3998
local NORMALIZED_ADDRESS = 0x000D596C

local SOLDIER_STATE_A_ADDRESS = 0x00030A37
local SOLDIER_STATE_B_ADDRESS = 0x00030A6B
local SOLDIER_POINTER_ADDRESS = 0x001F421C

local DEFAULT_SCREEN_MIN = 157.0
local DEFAULT_SCREEN_MAX = 163.0
local DEFAULT_DETECT_RAW = 20.0
local DEFAULT_DETECT_NORMALIZED = 0.020
local DEFAULT_MEMORY_FRAMES = 45
local DEFAULT_READY_FRAMES = 2
local DEFAULT_SHOT_FRAMES = 1

local DEFAULT_RESULT_DELAY_FRAMES = 4
local DEFAULT_RESULT_TIMEOUT_FRAMES = 90
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
local baselineStateA = nil
local baselineStateB = nil
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

local function readPointer32(address)
    return mainmemory.read_u32_be(address)
end

local function readState()
    return {
        frame = emu.framecount(),
        screenX = mainmemory.readfloat(SCREEN_X_ADDRESS, true),
        screenXCopy = mainmemory.readfloat(SCREEN_X_COPY_ADDRESS, true),
        raw = mainmemory.readfloat(RAW_HORIZONTAL_ADDRESS, true),
        normalized = mainmemory.readfloat(NORMALIZED_ADDRESS, true),
        soldierStateA = mainmemory.read_u8(SOLDIER_STATE_A_ADDRESS),
        soldierStateB = mainmemory.read_u8(SOLDIER_STATE_B_ADDRESS),
        soldierPointer = readPointer32(SOLDIER_POINTER_ADDRESS)
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

local function evaluateKill(current)
    local pointerWasLive =
        baselinePointer ~= nil and baselinePointer ~= 0

    local pointerDead =
        pointerWasLive and current.soldierPointer == 0

    local stateADead =
        current.soldierStateA == 2
        or (
            baselineStateA ~= nil
            and baselineStateA ~= 2
            and current.soldierStateA == 2
        )

    local stateBDead =
        current.soldierStateB == 1
        and (
            baselineStateB == nil
            or baselineStateB ~= 1
        )

    local strongKill =
        pointerDead
        and (stateADead or stateBDead)

    local mediumKill =
        stateADead and stateBDead

    local killCandidate = strongKill or mediumKill

    return {
        pointerDead = pointerDead,
        stateADead = stateADead,
        stateBDead = stateBDead,
        strongKill = strongKill,
        mediumKill = mediumKill,
        killCandidate = killCandidate
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
    baselineStateA = nil
    baselineStateB = nil
    shotSnapshot = nil
    setZ(false)
end

local function writeHeader(file)
    file:write(
        "frame,event,state,gate_enabled,attempt,"
        .. "memory_remaining,ready_count,result_elapsed,kill_confirm_count,"
        .. "screen_x,screen_x_copy,raw_horizontal,normalized,"
        .. "soldier_state_a,soldier_state_b,soldier_pointer_hex,"
        .. "arm_ready,raw_detected,normalized_detected,auto_aim_detected,"
        .. "pointer_dead,state_a_dead,state_b_dead,strong_kill,medium_kill,kill_candidate\n"
    )
end

local function writeRow(eventName, current, aim, kill)
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
        .. tostring(current.screenX) .. ","
        .. tostring(current.screenXCopy) .. ","
        .. tostring(current.raw) .. ","
        .. tostring(current.normalized) .. ","
        .. tostring(current.soldierStateA) .. ","
        .. tostring(current.soldierStateB) .. ","
        .. string.format("0x%08X", current.soldierPointer) .. ","
        .. tostring(aim.armReady) .. ","
        .. tostring(aim.rawDetected) .. ","
        .. tostring(aim.normalizedDetected) .. ","
        .. tostring(aim.autoAimDetected) .. ","
        .. tostring(kill.pointerDead) .. ","
        .. tostring(kill.stateADead) .. ","
        .. tostring(kill.stateBDead) .. ","
        .. tostring(kill.strongKill) .. ","
        .. tostring(kill.mediumKill) .. ","
        .. tostring(kill.killCandidate)
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
        .. "first-soldier-outcome-gate-" .. timestamp .. ".csv"
    local summaryPath = OUTPUT_DIR
        .. "first-soldier-outcome-gate-" .. timestamp .. "-summary.txt"

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
    summary:write("Final state: " .. stateName .. "\n")
    summary:write("Attempts used: " .. tostring(attemptCount) .. "\n")
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
            .. string.format("0x%08X", shotSnapshot.soldierPointer)
            .. "\n"
        )
        summary:write(
            "stateA/stateB: "
            .. tostring(shotSnapshot.soldierStateA)
            .. "/"
            .. tostring(shotSnapshot.soldierStateB)
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
    "First Soldier Outcome Gate — tiro, resultado e encerramento",
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
resultTimeoutBox = forms.textbox(form, "90", 60, 24, nil, 780, 487)

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
    "Fluxo:\n"
    .. "IDLE -> TRACKING -> SHOT_READY -> FIRED -> WAITING_RESULT\n"
    .. "WAITING_RESULT -> KILL_CONFIRMED -> COMPLETE\n"
    .. "ou WAITING_RESULT -> SHOT_FAILED -> nova tentativa, ate o limite.\n\n"
    .. "Kill forte: ponteiro do soldado zerou e stateA=2 ou stateB=1.\n"
    .. "Kill medio: stateA=2 e stateB=1.\n"
    .. "A confirmacao precisa persistir por alguns frames consecutivos.\n\n"
    .. "Depois de COMPLETE, nenhum novo tiro e permitido.",
    12, 645, 1000, 160
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
end, "GoldenEyeDiagnostic-0.0.5.8.5-exit")

while not stopped do
    processAction()

    local thresholds = getThresholds()
    local current = readState()
    local aim = evaluateAim(current, thresholds)
    local kill = evaluateKill(current)

    if stateName == "IDLE" then
        memoryRemaining = 0
        readyCount = 0
        resultElapsed = 0
        killConfirmCount = 0
        retryDelayRemaining = 0

        if aim.autoAimDetected and attemptCount < thresholds.maxAttempts then
            stateName = "TRACKING"
            memoryRemaining = thresholds.memoryFrames
            baselinePointer = current.soldierPointer
            baselineStateA = current.soldierStateA
            baselineStateB = current.soldierStateB

            if session then
                writeRow("ACQUIRED", current, aim, kill)
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
            resultElapsed = 0
            killConfirmCount = 0

            if session then
                session.shots = session.shots + 1
                writeRow("AUTO_SHOT", current, aim, kill)
            end

            setStatus("AUTO_SHOT tentativa " .. tostring(attemptCount))
        end

    elseif stateName == "FIRED" then
        stateName = "WAITING_RESULT"
        resultElapsed = 0

    elseif stateName == "WAITING_RESULT" then
        resultElapsed = resultElapsed + 1

        if resultElapsed >= thresholds.resultDelay then
            if kill.killCandidate then
                killConfirmCount = killConfirmCount + 1
            else
                killConfirmCount = 0
            end

            if killConfirmCount >= thresholds.killConfirmFrames then
                stateName = "KILL_CONFIRMED"

                if session then
                    session.kills = session.kills + 1
                    writeRow("KILL_CONFIRMED", current, aim, kill)
                end

                setStatus("KILL_CONFIRMED")
            elseif resultElapsed >= thresholds.resultTimeout then
                stateName = "SHOT_FAILED"

                if session then
                    session.failures = session.failures + 1
                    writeRow("SHOT_FAILED", current, aim, kill)
                end

                setStatus("SHOT_FAILED")
            end
        end

    elseif stateName == "KILL_CONFIRMED" then
        stateName = "COMPLETE"

        if session then
            session.completes = session.completes + 1
            writeRow("COMPLETE", current, aim, kill)
        end

        gateEnabled = false
        setZ(false)

    elseif stateName == "SHOT_FAILED" then
        if attemptCount >= thresholds.maxAttempts then
            stateName = "COMPLETE"

            if session then
                session.completes = session.completes + 1
                writeRow("COMPLETE_FAILED", current, aim, kill)
            end

            gateEnabled = false
            setZ(false)
        else
            retryDelayRemaining = thresholds.retryDelay
            stateName = "IDLE"
            memoryRemaining = 0
            readyCount = 0
        end

    elseif stateName == "COMPLETE" then
        gateEnabled = false
        setZ(false)
    end

    if retryDelayRemaining > 0 then
        retryDelayRemaining = retryDelayRemaining - 1
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
        writeRow("SAMPLE", current, aim, kill)
        session.stateCounts[stateName] =
            (session.stateCounts[stateName] or 0) + 1
    end

    forms.settext(
        liveLabel,
        string.format(
            "frame=%d | state=%s | attempt=%d/%d\n"
            .. "screen_x=% .6f | raw=% .6f | normalized=% .6f\n"
            .. "stateA=%d | stateB=%d | pointer=0x%08X\n"
            .. "baseline A/B=%s/%s | baseline pointer=%s",
            current.frame,
            stateName,
            attemptCount,
            thresholds.maxAttempts,
            current.screenX,
            current.raw,
            current.normalized,
            current.soldierStateA,
            current.soldierStateB,
            current.soldierPointer,
            tostring(baselineStateA),
            tostring(baselineStateB),
            baselinePointer
                and string.format("0x%08X", baselinePointer)
                or "nil"
        )
    )

    forms.settext(
        outcomeLabel,
        string.format(
            "ARM_READY=%s | AUTO_AIM=%s | memory=%d | ready=%d/%d\n"
            .. "pointerDead=%s | stateADead=%s | stateBDead=%s\n"
            .. "killCandidate=%s | confirm=%d/%d | result=%d/%d\n"
            .. "gateEnabled=%s | shots=%d",
            tostring(aim.armReady),
            tostring(aim.autoAimDetected),
            memoryRemaining,
            readyCount,
            thresholds.readyFrames,
            tostring(kill.pointerDead),
            tostring(kill.stateADead),
            tostring(kill.stateBDead),
            tostring(kill.killCandidate),
            killConfirmCount,
            thresholds.killConfirmFrames,
            resultElapsed,
            thresholds.resultTimeout,
            tostring(gateEnabled),
            session and session.shots or 0
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

    emu.frameadvance()
end
