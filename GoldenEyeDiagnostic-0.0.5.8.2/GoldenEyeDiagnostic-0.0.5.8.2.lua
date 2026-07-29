-- GoldenEyeDiagnostic 0.0.5.8.2
-- Auto-Aim Acquisition Gate
--
-- Dispara automaticamente somente quando:
-- 1. o braco esta na janela horizontal configurada;
-- 2. o auto-aim parece estar ativo;
-- 3. as condicoes permanecem validas por alguns frames.
--
-- O sinal de aquisicao usa:
-- abs(raw_horizontal) >= limite minimo
-- OU
-- abs(normalized) >= limite minimo
--
-- Isso evita disparar apenas porque screen_x voltou para 160 em repouso.
--
-- Modos:
-- ARM_ONLY
-- ARM_AND_ACQUISITION
-- ACQUISITION_ONLY
--
-- Somente leitura de memoria; escrita apenas no controle P1 Z.

local VERSION = "0.0.5.8.2"
local EXPECTED_ROM_HASH = "ABE01E4AEB033B6C0836819F549C791B26CFDE83"

local SCREEN_X_ADDRESS = 0x000D3F48
local SCREEN_X_COPY_ADDRESS = 0x000D3F5C
local RAW_HORIZONTAL_ADDRESS = 0x000D3998
local NORMALIZED_ADDRESS = 0x000D596C

local DEFAULT_SCREEN_MIN = 157.0
local DEFAULT_SCREEN_MAX = 163.0
local DEFAULT_RAW_MIN = 4.0
local DEFAULT_NORMALIZED_MIN = 0.004
local DEFAULT_STABLE_FRAMES = 3
local DEFAULT_SHOT_FRAMES = 1
local DEFAULT_REARM_FRAMES = 12
local DEFAULT_LOG_INTERVAL = 5

local Z_BUTTON_NAME = "P1 Z"

local stopped = false
local gateEnabled = false
local armed = true
local stableCount = 0
local invalidCount = 0
local fireFramesRemaining = 0
local releaseFramesRemaining = 0
local pendingAction = nil
local currentMode = "ARM_AND_ACQUISITION"
local session = nil
local shotCount = 0

local form
local statusLabel
local liveLabel
local gateLabel
local filesLabel
local screenMinBox
local screenMaxBox
local rawMinBox
local normalizedMinBox
local stableFramesBox
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

local function evaluate(state)
    local screenMin = numberFromBox(
        screenMinBox, DEFAULT_SCREEN_MIN, 0, 320
    )
    local screenMax = numberFromBox(
        screenMaxBox, DEFAULT_SCREEN_MAX, 0, 320
    )
    local rawMin = numberFromBox(
        rawMinBox, DEFAULT_RAW_MIN, 0, 1000000
    )
    local normalizedMin = numberFromBox(
        normalizedMinBox, DEFAULT_NORMALIZED_MIN, 0, 1000
    )

    local armReady =
        state.screenX >= screenMin
        and state.screenX <= screenMax

    local rawActive = math.abs(state.raw) >= rawMin
    local normalizedActive =
        math.abs(state.normalized) >= normalizedMin

    local acquisitionReady = rawActive or normalizedActive

    local gateReady = false
    local blocker = "NONE"

    if currentMode == "ARM_ONLY" then
        gateReady = armReady
        blocker = armReady and "NONE" or "ARM"

    elseif currentMode == "ACQUISITION_ONLY" then
        gateReady = acquisitionReady
        blocker = acquisitionReady and "NONE" or "ACQUISITION"

    else
        gateReady = armReady and acquisitionReady

        if not armReady and not acquisitionReady then
            blocker = "ARM+ACQUISITION"
        elseif not armReady then
            blocker = "ARM"
        elseif not acquisitionReady then
            blocker = "ACQUISITION"
        end
    end

    return {
        armReady = armReady,
        rawActive = rawActive,
        normalizedActive = normalizedActive,
        acquisitionReady = acquisitionReady,
        gateReady = gateReady,
        blocker = blocker
    }
end

local function setZ(pressed)
    joypad.set({[Z_BUTTON_NAME] = pressed})
end

local function writeHeader(file)
    file:write(
        "frame,event,mode,gate_enabled,armed,stable_count,invalid_count,"
        .. "screen_x,screen_x_copy,raw_horizontal,normalized,"
        .. "arm_ready,raw_active,normalized_active,"
        .. "acquisition_ready,gate_ready,blocker\n"
    )
end

local function writeRow(eventName, state, result)
    if not session or not session.csv then return end

    session.csv:write(
        tostring(state.frame) .. ","
        .. tostring(eventName or "") .. ","
        .. currentMode .. ","
        .. tostring(gateEnabled) .. ","
        .. tostring(armed) .. ","
        .. tostring(stableCount) .. ","
        .. tostring(invalidCount) .. ","
        .. tostring(state.screenX) .. ","
        .. tostring(state.screenXCopy) .. ","
        .. tostring(state.raw) .. ","
        .. tostring(state.normalized) .. ","
        .. tostring(result.armReady) .. ","
        .. tostring(result.rawActive) .. ","
        .. tostring(result.normalizedActive) .. ","
        .. tostring(result.acquisitionReady) .. ","
        .. tostring(result.gateReady) .. ","
        .. result.blocker .. "\n"
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

    session.rawAbsMinObserved =
        session.rawAbsMinObserved
        and math.min(session.rawAbsMinObserved, math.abs(state.raw))
        or math.abs(state.raw)

    session.rawAbsMaxObserved =
        session.rawAbsMaxObserved
        and math.max(session.rawAbsMaxObserved, math.abs(state.raw))
        or math.abs(state.raw)

    session.normalizedAbsMinObserved =
        session.normalizedAbsMinObserved
        and math.min(
            session.normalizedAbsMinObserved,
            math.abs(state.normalized)
        )
        or math.abs(state.normalized)

    session.normalizedAbsMaxObserved =
        session.normalizedAbsMaxObserved
        and math.max(
            session.normalizedAbsMaxObserved,
            math.abs(state.normalized)
        )
        or math.abs(state.normalized)

    if result.armReady then
        session.armReadyFrames = session.armReadyFrames + 1
    end

    if result.acquisitionReady then
        session.acquisitionReadyFrames =
            session.acquisitionReadyFrames + 1
    end

    if result.gateReady then
        session.gateReadyFrames = session.gateReadyFrames + 1
    end

    session.blockers[result.blocker] =
        (session.blockers[result.blocker] or 0) + 1
end

local function startSession()
    if session then
        setStatus("sessao ja iniciada")
        return
    end

    local timestamp = os.date("%Y%m%d-%H%M%S")
    local csvPath = OUTPUT_DIR
        .. "auto-aim-acquisition-gate-" .. timestamp .. ".csv"
    local summaryPath = OUTPUT_DIR
        .. "auto-aim-acquisition-gate-" .. timestamp .. "-summary.txt"

    local csv = assert(io.open(csvPath, "w"))
    writeHeader(csv)

    session = {
        csv = csv,
        csvPath = csvPath,
        summaryPath = summaryPath,
        startedFrame = emu.framecount(),
        shots = 0,
        rows = 0,
        armReadyFrames = 0,
        acquisitionReadyFrames = 0,
        gateReadyFrames = 0,
        blockers = {}
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
    summary:write("Mode: " .. currentMode .. "\n")
    summary:write("Started frame: "
        .. tostring(session.startedFrame) .. "\n")
    summary:write("Stopped frame: "
        .. tostring(emu.framecount()) .. "\n")
    summary:write("Rows: " .. tostring(session.rows) .. "\n")
    summary:write("Automatic shots: "
        .. tostring(session.shots) .. "\n")
    summary:write("Arm ready frames: "
        .. tostring(session.armReadyFrames) .. "\n")
    summary:write("Acquisition ready frames: "
        .. tostring(session.acquisitionReadyFrames) .. "\n")
    summary:write("Gate ready frames: "
        .. tostring(session.gateReadyFrames) .. "\n")
    summary:write("Screen observed min: "
        .. tostring(session.screenMinObserved) .. "\n")
    summary:write("Screen observed max: "
        .. tostring(session.screenMaxObserved) .. "\n")
    summary:write("Raw abs observed min: "
        .. tostring(session.rawAbsMinObserved) .. "\n")
    summary:write("Raw abs observed max: "
        .. tostring(session.rawAbsMaxObserved) .. "\n")
    summary:write("Normalized abs observed min: "
        .. tostring(session.normalizedAbsMinObserved) .. "\n")
    summary:write("Normalized abs observed max: "
        .. tostring(session.normalizedAbsMaxObserved) .. "\n")
    summary:write("Screen window: "
        .. forms.gettext(screenMinBox)
        .. " to " .. forms.gettext(screenMaxBox) .. "\n")
    summary:write("Raw minimum: "
        .. forms.gettext(rawMinBox) .. "\n")
    summary:write("Normalized minimum: "
        .. forms.gettext(normalizedMinBox) .. "\n")
    summary:write("Stable frames: "
        .. forms.gettext(stableFramesBox) .. "\n")
    summary:write("Shot frames: "
        .. forms.gettext(shotFramesBox) .. "\n")
    summary:write("Rearm frames: "
        .. forms.gettext(rearmFramesBox) .. "\n")
    summary:write("Log interval: "
        .. forms.gettext(logIntervalBox) .. "\n")
    summary:write("CSV: " .. tostring(session.csvPath) .. "\n\n")

    summary:write("Blockers:\n")
    for _, key in ipairs({
        "NONE",
        "ARM",
        "ACQUISITION",
        "ARM+ACQUISITION"
    }) do
        summary:write(
            key .. ": "
            .. tostring(session.blockers[key] or 0)
            .. "\n"
        )
    end

    summary:close()

    setStatus("sessao encerrada")
    session = nil
end

local function resetGate()
    stableCount = 0
    invalidCount = 0
    fireFramesRemaining = 0
    releaseFramesRemaining = 0
    armed = true
    shotCount = 0
    setZ(false)
    setStatus("gate reiniciado")
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
            resetGate()

        elseif action == "STOP_SESSION" then
            stopSession()

        elseif action == "ARM_ONLY" then
            currentMode = "ARM_ONLY"
            resetGate()
            setStatus("modo ARM_ONLY")

        elseif action == "ACQUISITION_ONLY" then
            currentMode = "ACQUISITION_ONLY"
            resetGate()
            setStatus("modo ACQUISITION_ONLY")

        elseif action == "ARM_AND_ACQUISITION" then
            currentMode = "ARM_AND_ACQUISITION"
            resetGate()
            setStatus("modo ARM_AND_ACQUISITION")
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
    990,
    760,
    "GoldenEyeDiagnostic " .. VERSION,
    function() stopped = true end
)

forms.label(
    form,
    "Auto-Aim Acquisition Gate — primeiro soldado",
    12, 10, 950, 24
)

statusLabel = forms.label(
    form,
    "Status: pronto",
    12, 40, 950, 24
)

liveLabel = forms.label(
    form,
    "Estado atual: aguardando",
    12, 75, 950, 130, true
)

gateLabel = forms.label(
    form,
    "Gate: aguardando",
    12, 210, 950, 105, true
)

filesLabel = forms.label(
    form,
    "Nenhuma sessao aberta",
    12, 320, 950, 55, true
)

forms.label(form, "screen_x minimo", 12, 390, 105, 22)
screenMinBox = forms.textbox(
    form, tostring(DEFAULT_SCREEN_MIN),
    75, 24, nil, 120, 387
)

forms.label(form, "screen_x maximo", 215, 390, 105, 22)
screenMaxBox = forms.textbox(
    form, tostring(DEFAULT_SCREEN_MAX),
    75, 24, nil, 323, 387
)

forms.label(form, "|raw| minimo", 418, 390, 80, 22)
rawMinBox = forms.textbox(
    form, tostring(DEFAULT_RAW_MIN),
    75, 24, nil, 503, 387
)

forms.label(form, "|normalized| minimo", 598, 390, 125, 22)
normalizedMinBox = forms.textbox(
    form, tostring(DEFAULT_NORMALIZED_MIN),
    85, 24, nil, 728, 387
)

forms.label(form, "Frames estaveis", 12, 430, 100, 22)
stableFramesBox = forms.textbox(
    form, tostring(DEFAULT_STABLE_FRAMES),
    60, 24, nil, 117, 427
)

forms.label(form, "Frames de Z", 195, 430, 85, 22)
shotFramesBox = forms.textbox(
    form, tostring(DEFAULT_SHOT_FRAMES),
    60, 24, nil, 285, 427
)

forms.label(form, "Frames para rearmar", 365, 430, 125, 22)
rearmFramesBox = forms.textbox(
    form, tostring(DEFAULT_REARM_FRAMES),
    60, 24, nil, 495, 427
)

forms.label(form, "Intervalo do log", 575, 430, 105, 22)
logIntervalBox = forms.textbox(
    form, tostring(DEFAULT_LOG_INTERVAL),
    60, 24, nil, 685, 427
)

forms.button(
    form, "ARM_ONLY",
    function() pendingAction = "ARM_ONLY" end,
    12, 480, 145, 40
)

forms.button(
    form, "ACQUISITION_ONLY",
    function() pendingAction = "ACQUISITION_ONLY" end,
    170, 480, 180, 40
)

forms.button(
    form, "ARM_AND_ACQUISITION",
    function() pendingAction = "ARM_AND_ACQUISITION" end,
    363, 480, 215, 40
)

forms.button(
    form, "INICIAR SESSAO",
    function() pendingAction = "START_SESSION" end,
    12, 535, 150, 40
)

forms.button(
    form, "ATIVAR GATE",
    function() pendingAction = "ENABLE" end,
    175, 535, 140, 40
)

forms.button(
    form, "DESATIVAR",
    function() pendingAction = "DISABLE" end,
    328, 535, 130, 40
)

forms.button(
    form, "REINICIAR",
    function() pendingAction = "RESET" end,
    471, 535, 130, 40
)

forms.button(
    form, "ENCERRAR",
    function() pendingAction = "STOP_SESSION" end,
    614, 535, 140, 40
)

forms.label(
    form,
    "Teste recomendado:\n"
    .. "1. Use ARM_AND_ACQUISITION.\n"
    .. "2. Inicie a sessao e ative o gate.\n"
    .. "3. Conduza Bond ate o primeiro soldado.\n"
    .. "4. O tiro so sera liberado quando screen_x estiver na janela e houver "
    .. "sinal de auto-aim em raw ou normalized.\n\n"
    .. "Valores iniciais:\n"
    .. "screen_x 157–163; |raw| >= 4; |normalized| >= 0.004.\n\n"
    .. "Se nao disparar, o CSV mostrara se o bloqueador dominante foi ARM ou "
    .. "ACQUISITION.",
    12, 595, 950, 135
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

    if session then
        pcall(stopSession)
    end

    stopped = true
end, "GoldenEyeDiagnostic-0.0.5.8.2-exit")

while not stopped do
    processAction()

    local state = readState()
    local result = evaluate(state)

    local stableRequired = integerFromBox(
        stableFramesBox, DEFAULT_STABLE_FRAMES, 1, 120
    )
    local shotFrames = integerFromBox(
        shotFramesBox, DEFAULT_SHOT_FRAMES, 1, 20
    )
    local rearmFrames = integerFromBox(
        rearmFramesBox, DEFAULT_REARM_FRAMES, 1, 300
    )
    local logInterval = integerFromBox(
        logIntervalBox, DEFAULT_LOG_INTERVAL, 1, 600
    )

    if result.gateReady then
        stableCount = stableCount + 1
        invalidCount = 0
    else
        stableCount = 0
        invalidCount = invalidCount + 1
    end

    if not armed and invalidCount >= rearmFrames then
        armed = true

        if session then
            writeRow("REARMED", state, result)
        end
    end

    if gateEnabled
        and armed
        and fireFramesRemaining == 0
        and releaseFramesRemaining == 0
        and stableCount >= stableRequired then

        fireFramesRemaining = shotFrames
        armed = false
        stableCount = 0
        shotCount = shotCount + 1

        if session then
            session.shots = session.shots + 1
            writeRow("AUTO_SHOT", state, result)
        end

        setStatus("AUTO_SHOT #" .. tostring(shotCount))

        log(
            "AUTO_SHOT | frame=" .. tostring(state.frame)
            .. " | screen_x=" .. tostring(state.screenX)
            .. " | raw=" .. tostring(state.raw)
            .. " | normalized=" .. tostring(state.normalized)
        )
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

    if session and state.frame % logInterval == 0 then
        writeRow("SAMPLE", state, result)
        updateStats(state, result)
    end

    forms.settext(
        liveLabel,
        string.format(
            "frame=%d | mode=%s\n"
            .. "screen_x=% .6f | copy=% .6f\n"
            .. "raw=% .6f | |raw|=% .6f\n"
            .. "normalized=% .6f | |normalized|=% .6f",
            state.frame,
            currentMode,
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
            "ARM_READY=%s | RAW_ACTIVE=%s | NORMALIZED_ACTIVE=%s\n"
            .. "ACQUISITION_READY=%s | GATE_READY=%s | BLOCKER=%s\n"
            .. "enabled=%s | armed=%s | stable=%d/%d | invalid=%d/%d | shots=%d",
            tostring(result.armReady),
            tostring(result.rawActive),
            tostring(result.normalizedActive),
            tostring(result.acquisitionReady),
            tostring(result.gateReady),
            result.blocker,
            tostring(gateEnabled),
            tostring(armed),
            stableCount,
            stableRequired,
            invalidCount,
            rearmFrames,
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
        result.gateReady and "SHOT READY" or "SHOT BLOCKED",
        "white", "black", 12
    )

    emu.frameadvance()
end
