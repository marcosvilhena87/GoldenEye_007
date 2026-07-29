-- GoldenEyeDiagnostic 0.0.5.8.3
-- Auto-Aim Tracking Memory Gate
--
-- Estados:
-- IDLE
-- AUTO_AIM_DETECTED
-- CONVERGING
-- SHOT_READY
-- FIRED
--
-- Ideia:
-- detectar que o auto-aim puxou o braco recentemente e manter essa
-- aquisicao em memoria por alguns frames. O tiro e liberado quando o
-- braco converge para a janela central, mesmo que raw/normalized ja
-- tenham voltado para perto de zero.
--
-- Somente leitura de memoria; escrita apenas no controle P1 Z.

local VERSION = "0.0.5.8.3"
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
local DEFAULT_REARM_INVALID_FRAMES = 12
local DEFAULT_LOG_INTERVAL = 5

local Z_BUTTON_NAME = "P1 Z"

local stopped = false
local gateEnabled = false
local pendingAction = nil
local session = nil

local trackingState = "IDLE"
local memoryRemaining = 0
local readyCount = 0
local invalidCount = 0
local armed = true
local fireFramesRemaining = 0
local releaseFramesRemaining = 0
local shotCount = 0

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
local rearmFramesBox
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
        rearmFrames = integerFromBox(
            rearmFramesBox,
            DEFAULT_REARM_INVALID_FRAMES,
            1,
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

local function evaluate(state, thresholds)
    local armReady =
        state.screenX >= thresholds.screenMin
        and state.screenX <= thresholds.screenMax

    local rawDetected = math.abs(state.raw) >= thresholds.detectRaw
    local normalizedDetected =
        math.abs(state.normalized) >= thresholds.detectNormalized

    local autoAimDetected = rawDetected or normalizedDetected

    return {
        armReady = armReady,
        rawDetected = rawDetected,
        normalizedDetected = normalizedDetected,
        autoAimDetected = autoAimDetected
    }
end

local function setZ(pressed)
    joypad.set({[Z_BUTTON_NAME] = pressed})
end

local function resetTracking()
    trackingState = "IDLE"
    memoryRemaining = 0
    readyCount = 0
    invalidCount = 0
    armed = true
    fireFramesRemaining = 0
    releaseFramesRemaining = 0
    setZ(false)
end

local function writeHeader(file)
    file:write(
        "frame,event,state,gate_enabled,armed,"
        .. "memory_remaining,ready_count,invalid_count,"
        .. "screen_x,screen_x_copy,raw_horizontal,normalized,"
        .. "arm_ready,raw_detected,normalized_detected,auto_aim_detected\n"
    )
end

local function writeRow(eventName, state, result)
    if not session or not session.csv then return end

    session.csv:write(
        tostring(state.frame) .. ","
        .. tostring(eventName or "") .. ","
        .. trackingState .. ","
        .. tostring(gateEnabled) .. ","
        .. tostring(armed) .. ","
        .. tostring(memoryRemaining) .. ","
        .. tostring(readyCount) .. ","
        .. tostring(invalidCount) .. ","
        .. tostring(state.screenX) .. ","
        .. tostring(state.screenXCopy) .. ","
        .. tostring(state.raw) .. ","
        .. tostring(state.normalized) .. ","
        .. tostring(result.armReady) .. ","
        .. tostring(result.rawDetected) .. ","
        .. tostring(result.normalizedDetected) .. ","
        .. tostring(result.autoAimDetected) .. "\n"
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
        session.detectedFrames = session.detectedFrames + 1
    end
    if result.armReady then
        session.armReadyFrames = session.armReadyFrames + 1
    end
    if memoryRemaining > 0 then
        session.memoryActiveFrames = session.memoryActiveFrames + 1
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
        .. "auto-aim-tracking-memory-gate-" .. timestamp .. ".csv"
    local summaryPath = OUTPUT_DIR
        .. "auto-aim-tracking-memory-gate-" .. timestamp .. "-summary.txt"

    local csv = assert(io.open(csvPath, "w"))
    writeHeader(csv)

    session = {
        csv = csv,
        csvPath = csvPath,
        summaryPath = summaryPath,
        startedFrame = emu.framecount(),
        rows = 0,
        shots = 0,
        detectedFrames = 0,
        armReadyFrames = 0,
        memoryActiveFrames = 0,
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
    summary:write("Rows: " .. tostring(session.rows) .. "\n")
    summary:write("Automatic shots: " .. tostring(session.shots) .. "\n")
    summary:write("Auto-aim detected frames: "
        .. tostring(session.detectedFrames) .. "\n")
    summary:write("Arm ready frames: "
        .. tostring(session.armReadyFrames) .. "\n")
    summary:write("Memory active frames: "
        .. tostring(session.memoryActiveFrames) .. "\n")
    summary:write("Screen observed min: "
        .. tostring(session.screenMinObserved) .. "\n")
    summary:write("Screen observed max: "
        .. tostring(session.screenMaxObserved) .. "\n")
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
    summary:write("Rearm invalid frames: "
        .. forms.gettext(rearmFramesBox) .. "\n")
    summary:write("Log interval: "
        .. forms.gettext(logIntervalBox) .. "\n")
    summary:write("CSV: " .. tostring(session.csvPath) .. "\n\n")

    summary:write("State counts:\n")
    for _, name in ipairs({
        "IDLE",
        "AUTO_AIM_DETECTED",
        "CONVERGING",
        "SHOT_READY",
        "FIRED"
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
    1000,
    780,
    "GoldenEyeDiagnostic " .. VERSION,
    function() stopped = true end
)

forms.label(
    form,
    "Auto-Aim Tracking Memory Gate — primeiro soldado",
    12, 10, 960, 24
)

statusLabel = forms.label(
    form,
    "Status: pronto",
    12, 40, 960, 24
)

liveLabel = forms.label(
    form,
    "Estado atual: aguardando",
    12, 75, 960, 130, true
)

gateLabel = forms.label(
    form,
    "Tracking: aguardando",
    12, 210, 960, 115, true
)

filesLabel = forms.label(
    form,
    "Nenhuma sessao aberta",
    12, 330, 960, 55, true
)

forms.label(form, "screen_x minimo", 12, 400, 105, 22)
screenMinBox = forms.textbox(
    form, tostring(DEFAULT_SCREEN_MIN),
    75, 24, nil, 120, 397
)

forms.label(form, "screen_x maximo", 215, 400, 105, 22)
screenMaxBox = forms.textbox(
    form, tostring(DEFAULT_SCREEN_MAX),
    75, 24, nil, 323, 397
)

forms.label(form, "|raw| deteccao", 418, 400, 95, 22)
detectRawBox = forms.textbox(
    form, tostring(DEFAULT_DETECT_RAW),
    75, 24, nil, 518, 397
)

forms.label(form, "|normalized| deteccao", 613, 400, 145, 22)
detectNormalizedBox = forms.textbox(
    form, tostring(DEFAULT_DETECT_NORMALIZED),
    85, 24, nil, 763, 397
)

forms.label(form, "Memoria (frames)", 12, 440, 105, 22)
memoryFramesBox = forms.textbox(
    form, tostring(DEFAULT_MEMORY_FRAMES),
    60, 24, nil, 122, 437
)

forms.label(form, "Frames alinhados", 200, 440, 110, 22)
readyFramesBox = forms.textbox(
    form, tostring(DEFAULT_READY_FRAMES),
    60, 24, nil, 315, 437
)

forms.label(form, "Frames de Z", 390, 440, 85, 22)
shotFramesBox = forms.textbox(
    form, tostring(DEFAULT_SHOT_FRAMES),
    60, 24, nil, 480, 437
)

forms.label(form, "Rearmar apos invalidos", 560, 440, 145, 22)
rearmFramesBox = forms.textbox(
    form, tostring(DEFAULT_REARM_INVALID_FRAMES),
    60, 24, nil, 710, 437
)

forms.label(form, "Intervalo do log", 795, 440, 105, 22)
logIntervalBox = forms.textbox(
    form, tostring(DEFAULT_LOG_INTERVAL),
    60, 24, nil, 905, 437
)

forms.button(
    form, "INICIAR SESSAO",
    function() pendingAction = "START_SESSION" end,
    12, 495, 155, 40
)

forms.button(
    form, "ATIVAR GATE",
    function() pendingAction = "ENABLE" end,
    180, 495, 145, 40
)

forms.button(
    form, "DESATIVAR",
    function() pendingAction = "DISABLE" end,
    338, 495, 130, 40
)

forms.button(
    form, "REINICIAR",
    function() pendingAction = "RESET" end,
    481, 495, 130, 40
)

forms.button(
    form, "ENCERRAR",
    function() pendingAction = "STOP_SESSION" end,
    624, 495, 140, 40
)

forms.label(
    form,
    "Fluxo:\n"
    .. "IDLE -> detecta deslocamento forte do braco -> AUTO_AIM_DETECTED\n"
    .. "AUTO_AIM_DETECTED -> mantem memoria por alguns frames -> CONVERGING\n"
    .. "CONVERGING -> screen_x entra em 157–163 -> SHOT_READY\n"
    .. "SHOT_READY por 2 frames -> FIRED\n\n"
    .. "A aquisicao continua valida mesmo quando raw/normalized voltam para perto "
    .. "de zero. Isso preserva as oportunidades em que o auto-aim ja terminou de "
    .. "alinhar o braco.\n\n"
    .. "Valores iniciais: detectar com |raw| >= 20 ou |normalized| >= 0.020; "
    .. "memoria de 45 frames; 2 frames alinhados.",
    12, 555, 960, 175
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
end, "GoldenEyeDiagnostic-0.0.5.8.3-exit")

while not stopped do
    processAction()

    local thresholds = getThresholds()
    local state = readState()
    local result = evaluate(state, thresholds)

    if result.autoAimDetected and armed then
        memoryRemaining = thresholds.memoryFrames

        if trackingState == "IDLE" or trackingState == "FIRED" then
            trackingState = "AUTO_AIM_DETECTED"
        else
            trackingState = "CONVERGING"
        end
    elseif memoryRemaining > 0 then
        memoryRemaining = memoryRemaining - 1
        if armed and trackingState ~= "SHOT_READY" then
            trackingState = "CONVERGING"
        end
    elseif armed then
        trackingState = "IDLE"
        readyCount = 0
    end

    if armed and memoryRemaining > 0 and result.armReady then
        readyCount = readyCount + 1
        trackingState = "SHOT_READY"
        invalidCount = 0
    else
        if armed then readyCount = 0 end
        invalidCount = invalidCount + 1
    end

    if gateEnabled
        and armed
        and trackingState == "SHOT_READY"
        and readyCount >= thresholds.readyFrames
        and fireFramesRemaining == 0
        and releaseFramesRemaining == 0 then

        fireFramesRemaining = thresholds.shotFrames
        armed = false
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
            .. " | memory=" .. tostring(memoryRemaining)
        )
    end

    if not armed and invalidCount >= thresholds.rearmFrames then
        armed = true
        trackingState = "IDLE"
        memoryRemaining = 0
        readyCount = 0
        invalidCount = 0

        if session then
            writeRow("REARMED", state, result)
        end
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
            "STATE=%s | AUTO_AIM_DETECTED=%s | ARM_READY=%s\n"
            .. "memory=%d/%d | ready=%d/%d | invalid=%d/%d\n"
            .. "enabled=%s | armed=%s | shots=%d",
            trackingState,
            tostring(result.autoAimDetected),
            tostring(result.armReady),
            memoryRemaining,
            thresholds.memoryFrames,
            readyCount,
            thresholds.readyFrames,
            invalidCount,
            thresholds.rearmFrames,
            tostring(gateEnabled),
            tostring(armed),
            shotCount
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
