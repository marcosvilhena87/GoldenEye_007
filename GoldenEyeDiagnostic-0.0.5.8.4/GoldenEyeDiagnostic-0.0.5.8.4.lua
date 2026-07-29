-- GoldenEyeDiagnostic 0.0.5.8.4
-- Single Target Shot Lock
--
-- Estados:
-- IDLE
-- TRACKING
-- CONVERGING
-- SHOT_READY
-- FIRED
-- TARGET_LOCKED
-- TARGET_LOST
--
-- Objetivo:
-- permitir apenas um disparo por aquisicao de alvo.
-- Depois do tiro, o gate permanece bloqueado ate detectar perda real
-- do alvo por varios frames consecutivos.
--
-- Perda do alvo:
-- screen_x proximo do centro
-- E abs(raw_horizontal) pequeno
-- E abs(normalized) pequeno
-- por N frames consecutivos.
--
-- Somente leitura de memoria; escrita apenas no controle P1 Z.

local VERSION = "0.0.5.8.4"
local EXPECTED_ROM_HASH = "ABE01E4AEB033B6C0836819F549C791B26CFDE83"

local SCREEN_X_ADDRESS = 0x000D3F48
local SCREEN_X_COPY_ADDRESS = 0x000D3F5C
local RAW_HORIZONTAL_ADDRESS = 0x000D3998
local NORMALIZED_ADDRESS = 0x000D596C

local DEFAULT_SCREEN_MIN = 157.0
local DEFAULT_SCREEN_MAX = 163.0

local DEFAULT_DETECT_RAW = 20.0
local DEFAULT_DETECT_NORMALIZED = 0.020
local DEFAULT_MEMORY_FRAMES = 45
local DEFAULT_READY_FRAMES = 2
local DEFAULT_SHOT_FRAMES = 1

local DEFAULT_LOST_CENTER_MIN = 158.0
local DEFAULT_LOST_CENTER_MAX = 162.0
local DEFAULT_LOST_RAW_MAX = 2.0
local DEFAULT_LOST_NORMALIZED_MAX = 0.002
local DEFAULT_LOST_FRAMES = 50

local DEFAULT_LOG_INTERVAL = 5
local Z_BUTTON_NAME = "P1 Z"

local stopped = false
local gateEnabled = false
local pendingAction = nil
local session = nil

local trackingState = "IDLE"
local memoryRemaining = 0
local readyCount = 0
local lostCount = 0
local fireFramesRemaining = 0
local releaseFramesRemaining = 0
local shotCount = 0
local acquisitionCount = 0

local form
local statusLabel
local liveLabel
local gateLabel
local filesLabel

local screenMinBox
local screenMaxBox
local detectRawBox
local detectNormalizedBox
local memoryFramesBox
local readyFramesBox
local shotFramesBox

local lostCenterMinBox
local lostCenterMaxBox
local lostRawMaxBox
local lostNormalizedMaxBox
local lostFramesBox
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

local function readState()
    return {
        frame = emu.framecount(),
        screenX = mainmemory.readfloat(SCREEN_X_ADDRESS, true),
        screenXCopy = mainmemory.readfloat(SCREEN_X_COPY_ADDRESS, true),
        raw = mainmemory.readfloat(RAW_HORIZONTAL_ADDRESS, true),
        normalized = mainmemory.readfloat(NORMALIZED_ADDRESS, true)
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

        lostCenterMin = numberFromBox(
            lostCenterMinBox,
            DEFAULT_LOST_CENTER_MIN,
            0,
            320
        ),
        lostCenterMax = numberFromBox(
            lostCenterMaxBox,
            DEFAULT_LOST_CENTER_MAX,
            0,
            320
        ),
        lostRawMax = numberFromBox(
            lostRawMaxBox,
            DEFAULT_LOST_RAW_MAX,
            0,
            1000000
        ),
        lostNormalizedMax = numberFromBox(
            lostNormalizedMaxBox,
            DEFAULT_LOST_NORMALIZED_MAX,
            0,
            1000
        ),
        lostFrames = integerFromBox(
            lostFramesBox,
            DEFAULT_LOST_FRAMES,
            1,
            600
        ),
        logInterval = integerFromBox(
            logIntervalBox,
            DEFAULT_LOG_INTERVAL,
            1,
            600
        )
    }
end

local function evaluate(state, thresholds)
    local armReady =
        state.screenX >= thresholds.screenMin
        and state.screenX <= thresholds.screenMax

    local rawDetected = math.abs(state.raw) >= thresholds.detectRaw
    local normalizedDetected =
        math.abs(state.normalized) >= thresholds.detectNormalized

    local autoAimDetected = rawDetected or normalizedDetected

    local centeredForLost =
        state.screenX >= thresholds.lostCenterMin
        and state.screenX <= thresholds.lostCenterMax

    local rawQuiet = math.abs(state.raw) <= thresholds.lostRawMax
    local normalizedQuiet =
        math.abs(state.normalized) <= thresholds.lostNormalizedMax

    local targetLostCandidate =
        centeredForLost and rawQuiet and normalizedQuiet

    return {
        armReady = armReady,
        rawDetected = rawDetected,
        normalizedDetected = normalizedDetected,
        autoAimDetected = autoAimDetected,
        centeredForLost = centeredForLost,
        rawQuiet = rawQuiet,
        normalizedQuiet = normalizedQuiet,
        targetLostCandidate = targetLostCandidate
    }
end

local function setZ(pressed)
    joypad.set({[Z_BUTTON_NAME] = pressed})
end

local function resetTracking()
    trackingState = "IDLE"
    memoryRemaining = 0
    readyCount = 0
    lostCount = 0
    fireFramesRemaining = 0
    releaseFramesRemaining = 0
    setZ(false)
end

local function writeHeader(file)
    file:write(
        "frame,event,state,gate_enabled,"
        .. "memory_remaining,ready_count,lost_count,"
        .. "screen_x,screen_x_copy,raw_horizontal,normalized,"
        .. "arm_ready,raw_detected,normalized_detected,auto_aim_detected,"
        .. "centered_for_lost,raw_quiet,normalized_quiet,target_lost_candidate\n"
    )
end

local function writeRow(eventName, state, result)
    if not session or not session.csv then return end

    session.csv:write(
        tostring(state.frame) .. ","
        .. tostring(eventName or "") .. ","
        .. trackingState .. ","
        .. tostring(gateEnabled) .. ","
        .. tostring(memoryRemaining) .. ","
        .. tostring(readyCount) .. ","
        .. tostring(lostCount) .. ","
        .. tostring(state.screenX) .. ","
        .. tostring(state.screenXCopy) .. ","
        .. tostring(state.raw) .. ","
        .. tostring(state.normalized) .. ","
        .. tostring(result.armReady) .. ","
        .. tostring(result.rawDetected) .. ","
        .. tostring(result.normalizedDetected) .. ","
        .. tostring(result.autoAimDetected) .. ","
        .. tostring(result.centeredForLost) .. ","
        .. tostring(result.rawQuiet) .. ","
        .. tostring(result.normalizedQuiet) .. ","
        .. tostring(result.targetLostCandidate)
        .. "\n"
    )
    session.csv:flush()
end

local function updateStats(state, result)
    if not session then return end

    session.rows = session.rows + 1
    session.screenMinObserved =
        session.screenMinObserved
        and math.min(session.screenMinObserved, state.screenX)
        or state.screenX
    session.screenMaxObserved =
        session.screenMaxObserved
        and math.max(session.screenMaxObserved, state.screenX)
        or state.screenX

    if result.autoAimDetected then
        session.autoAimDetectedFrames =
            session.autoAimDetectedFrames + 1
    end

    if result.armReady then
        session.armReadyFrames = session.armReadyFrames + 1
    end

    if result.targetLostCandidate then
        session.targetLostCandidateFrames =
            session.targetLostCandidateFrames + 1
    end

    session.stateCounts[trackingState] =
        (session.stateCounts[trackingState] or 0) + 1
end

local function startSession()
    if session then
        setStatus("sessao ja iniciada")
        return
    end

    local timestamp = os.date("%Y%m%d-%H%M%S")
    local csvPath = OUTPUT_DIR
        .. "single-target-shot-lock-" .. timestamp .. ".csv"
    local summaryPath = OUTPUT_DIR
        .. "single-target-shot-lock-" .. timestamp .. "-summary.txt"

    local csv = assert(io.open(csvPath, "w"))
    writeHeader(csv)

    session = {
        csv = csv,
        csvPath = csvPath,
        summaryPath = summaryPath,
        startedFrame = emu.framecount(),
        rows = 0,
        shots = 0,
        acquisitions = 0,
        targetLosses = 0,
        autoAimDetectedFrames = 0,
        armReadyFrames = 0,
        targetLostCandidateFrames = 0,
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
    summary:write("Started frame: "
        .. tostring(session.startedFrame) .. "\n")
    summary:write("Stopped frame: "
        .. tostring(emu.framecount()) .. "\n")
    summary:write("Rows: " .. tostring(session.rows) .. "\n")
    summary:write("Automatic shots: "
        .. tostring(session.shots) .. "\n")
    summary:write("Acquisitions: "
        .. tostring(session.acquisitions) .. "\n")
    summary:write("Target losses: "
        .. tostring(session.targetLosses) .. "\n")
    summary:write("Auto-aim detected frames: "
        .. tostring(session.autoAimDetectedFrames) .. "\n")
    summary:write("Arm ready frames: "
        .. tostring(session.armReadyFrames) .. "\n")
    summary:write("Target-lost candidate frames: "
        .. tostring(session.targetLostCandidateFrames) .. "\n")
    summary:write("Screen observed min: "
        .. tostring(session.screenMinObserved) .. "\n")
    summary:write("Screen observed max: "
        .. tostring(session.screenMaxObserved) .. "\n")

    summary:write("Screen window: "
        .. forms.gettext(screenMinBox) .. " to "
        .. forms.gettext(screenMaxBox) .. "\n")
    summary:write("Detect raw: "
        .. forms.gettext(detectRawBox) .. "\n")
    summary:write("Detect normalized: "
        .. forms.gettext(detectNormalizedBox) .. "\n")
    summary:write("Memory frames: "
        .. forms.gettext(memoryFramesBox) .. "\n")
    summary:write("Ready frames: "
        .. forms.gettext(readyFramesBox) .. "\n")
    summary:write("Shot frames: "
        .. forms.gettext(shotFramesBox) .. "\n")

    summary:write("Lost center window: "
        .. forms.gettext(lostCenterMinBox) .. " to "
        .. forms.gettext(lostCenterMaxBox) .. "\n")
    summary:write("Lost raw max: "
        .. forms.gettext(lostRawMaxBox) .. "\n")
    summary:write("Lost normalized max: "
        .. forms.gettext(lostNormalizedMaxBox) .. "\n")
    summary:write("Lost frames: "
        .. forms.gettext(lostFramesBox) .. "\n")
    summary:write("Log interval: "
        .. forms.gettext(logIntervalBox) .. "\n")
    summary:write("CSV: " .. tostring(session.csvPath) .. "\n\n")

    summary:write("State counts:\n")
    for _, name in ipairs({
        "IDLE",
        "TRACKING",
        "CONVERGING",
        "SHOT_READY",
        "FIRED",
        "TARGET_LOCKED",
        "TARGET_LOST"
    }) do
        summary:write(
            name .. ": "
            .. tostring(session.stateCounts[name] or 0)
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
            resetTracking()
            shotCount = 0
            acquisitionCount = 0
            setStatus("tracking reiniciado")

        elseif action == "STOP_SESSION" then
            stopSession()
        end
    end)

    if not ok then
        gateEnabled = false
        setZ(false)
        setStatus("erro")
        forms.settext(gateLabel, tostring(err))
        log("ERRO: " .. tostring(err))
    end
end

form = forms.newform(
    1020,
    850,
    "GoldenEyeDiagnostic " .. VERSION,
    function() stopped = true end
)

forms.label(
    form,
    "Single Target Shot Lock — um tiro por aquisicao",
    12, 10, 980, 24
)

statusLabel = forms.label(
    form,
    "Status: pronto",
    12, 40, 980, 24
)

liveLabel = forms.label(
    form,
    "Estado atual: aguardando",
    12, 75, 980, 130, true
)

gateLabel = forms.label(
    form,
    "Tracking: aguardando",
    12, 210, 980, 130, true
)

filesLabel = forms.label(
    form,
    "Nenhuma sessao aberta",
    12, 345, 980, 55, true
)

forms.label(form, "screen_x minimo", 12, 415, 105, 22)
screenMinBox = forms.textbox(form, "157", 75, 24, nil, 120, 412)

forms.label(form, "screen_x maximo", 215, 415, 105, 22)
screenMaxBox = forms.textbox(form, "163", 75, 24, nil, 323, 412)

forms.label(form, "|raw| deteccao", 418, 415, 95, 22)
detectRawBox = forms.textbox(form, "20", 75, 24, nil, 518, 412)

forms.label(form, "|normalized| deteccao", 613, 415, 145, 22)
detectNormalizedBox = forms.textbox(
    form, "0.020", 85, 24, nil, 763, 412
)

forms.label(form, "Memoria", 12, 455, 60, 22)
memoryFramesBox = forms.textbox(form, "45", 60, 24, nil, 77, 452)

forms.label(form, "Frames alinhados", 160, 455, 110, 22)
readyFramesBox = forms.textbox(form, "2", 60, 24, nil, 275, 452)

forms.label(form, "Frames de Z", 350, 455, 85, 22)
shotFramesBox = forms.textbox(form, "1", 60, 24, nil, 440, 452)

forms.label(form, "Lost center min", 12, 505, 100, 22)
lostCenterMinBox = forms.textbox(form, "158", 70, 24, nil, 117, 502)

forms.label(form, "Lost center max", 205, 505, 100, 22)
lostCenterMaxBox = forms.textbox(form, "162", 70, 24, nil, 310, 502)

forms.label(form, "Lost |raw| max", 398, 505, 95, 22)
lostRawMaxBox = forms.textbox(form, "2", 70, 24, nil, 498, 502)

forms.label(form, "Lost |norm| max", 586, 505, 105, 22)
lostNormalizedMaxBox = forms.textbox(
    form, "0.002", 80, 24, nil, 696, 502
)

forms.label(form, "Lost frames", 796, 505, 80, 22)
lostFramesBox = forms.textbox(form, "50", 60, 24, nil, 881, 502)

forms.label(form, "Intervalo do log", 12, 545, 105, 22)
logIntervalBox = forms.textbox(form, "5", 60, 24, nil, 122, 542)

forms.button(
    form,
    "INICIAR SESSAO",
    function() pendingAction = "START_SESSION" end,
    12, 595, 155, 40
)

forms.button(
    form,
    "ATIVAR GATE",
    function() pendingAction = "ENABLE" end,
    180, 595, 145, 40
)

forms.button(
    form,
    "DESATIVAR",
    function() pendingAction = "DISABLE" end,
    338, 595, 130, 40
)

forms.button(
    form,
    "REINICIAR",
    function() pendingAction = "RESET" end,
    481, 595, 130, 40
)

forms.button(
    form,
    "ENCERRAR",
    function() pendingAction = "STOP_SESSION" end,
    624, 595, 140, 40
)

forms.label(
    form,
    "Fluxo:\n"
    .. "IDLE -> TRACKING -> CONVERGING -> SHOT_READY -> FIRED -> TARGET_LOCKED\n"
    .. "TARGET_LOCKED permanece bloqueado ate detectar TARGET_LOST.\n\n"
    .. "TARGET_LOST exige simultaneamente:\n"
    .. "screen_x entre 158 e 162; |raw| <= 2; |normalized| <= 0.002;\n"
    .. "condicao mantida por 50 frames consecutivos.\n\n"
    .. "Assim, pequenas oscilacoes apos o tiro nao rearmam o gate. "
    .. "Um novo tiro so pode ocorrer depois de uma perda prolongada e clara do alvo.",
    12, 655, 980, 160
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
end, "GoldenEyeDiagnostic-0.0.5.8.4-exit")

while not stopped do
    processAction()

    local thresholds = getThresholds()
    local state = readState()
    local result = evaluate(state, thresholds)

    if trackingState == "IDLE" then
        memoryRemaining = 0
        readyCount = 0
        lostCount = 0

        if result.autoAimDetected then
            trackingState = "TRACKING"
            memoryRemaining = thresholds.memoryFrames
            acquisitionCount = acquisitionCount + 1

            if session then
                session.acquisitions = session.acquisitions + 1
                writeRow("ACQUIRED", state, result)
            end
        end

    elseif trackingState == "TRACKING"
        or trackingState == "CONVERGING"
        or trackingState == "SHOT_READY" then

        if result.autoAimDetected then
            memoryRemaining = thresholds.memoryFrames
            trackingState = "TRACKING"
        elseif memoryRemaining > 0 then
            memoryRemaining = memoryRemaining - 1
            trackingState = "CONVERGING"
        else
            trackingState = "IDLE"
            readyCount = 0
        end

        if memoryRemaining > 0 and result.armReady then
            readyCount = readyCount + 1
            trackingState = "SHOT_READY"
        else
            readyCount = 0
        end

        if gateEnabled
            and trackingState == "SHOT_READY"
            and readyCount >= thresholds.readyFrames
            and fireFramesRemaining == 0
            and releaseFramesRemaining == 0 then

            fireFramesRemaining = thresholds.shotFrames
            trackingState = "FIRED"
            shotCount = shotCount + 1

            if session then
                session.shots = session.shots + 1
                writeRow("AUTO_SHOT", state, result)
            end

            setStatus("AUTO_SHOT #" .. tostring(shotCount))
            log(
                "AUTO_SHOT | frame=" .. tostring(state.frame)
                .. " | screen_x=" .. tostring(state.screenX)
            )
        end

    elseif trackingState == "FIRED" then
        trackingState = "TARGET_LOCKED"
        lostCount = 0

    elseif trackingState == "TARGET_LOCKED" then
        memoryRemaining = 0
        readyCount = 0

        if result.targetLostCandidate then
            lostCount = lostCount + 1
        else
            lostCount = 0
        end

        if lostCount >= thresholds.lostFrames then
            trackingState = "TARGET_LOST"

            if session then
                session.targetLosses = session.targetLosses + 1
                writeRow("TARGET_LOST", state, result)
            end

            setStatus("alvo perdido; gate pode rearmar")
        end

    elseif trackingState == "TARGET_LOST" then
        trackingState = "IDLE"
        memoryRemaining = 0
        readyCount = 0
        lostCount = 0
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

    if session and state.frame % thresholds.logInterval == 0 then
        writeRow("SAMPLE", state, result)
        updateStats(state, result)
    end

    forms.settext(
        liveLabel,
        string.format(
            "frame=%d\n"
            .. "screen_x=% .6f | copy=% .6f\n"
            .. "raw=% .6f | |raw|=% .6f\n"
            .. "normalized=% .6f | |normalized|=% .6f",
            state.frame,
            state.screenX,
            state.screenXCopy,
            state.raw,
            math.abs(state.raw),
            state.normalized,
            math.abs(state.normalized)
        )
    )

    forms.settext(
        gateLabel,
        string.format(
            "STATE=%s | AUTO_AIM=%s | ARM_READY=%s\n"
            .. "memory=%d/%d | ready=%d/%d | lost=%d/%d\n"
            .. "LOST_CANDIDATE=%s | enabled=%s | shots=%d | acquisitions=%d",
            trackingState,
            tostring(result.autoAimDetected),
            tostring(result.armReady),
            memoryRemaining,
            thresholds.memoryFrames,
            readyCount,
            thresholds.readyFrames,
            lostCount,
            thresholds.lostFrames,
            tostring(result.targetLostCandidate),
            tostring(gateEnabled),
            shotCount,
            acquisitionCount
        )
    )

    gui.drawString(
        8, 8,
        "GoldenEyeDiagnostic " .. VERSION,
        "white", "black", 12
    )

    gui.drawString(
        8, 26,
        trackingState,
        "white", "black", 12
    )

    emu.frameadvance()
end
