-- GoldenEyeDiagnostic 0.0.5.8.1
-- Automatic Shot Gate Diagnostic
--
-- Modos:
-- ARM_ONLY
-- CAMERA_ONLY
-- ARM_AND_CAMERA
--
-- Recursos:
-- captura local da referencia da camera;
-- log periodico mesmo quando bloqueado;
-- diagnostico explicito de ARM_READY e CAMERA_READY;
-- minimos e maximos de screen_x e camera_max_delta;
-- um tiro por aquisicao.

local VERSION = "0.0.5.8.1"
local EXPECTED_ROM_HASH = "ABE01E4AEB033B6C0836819F549C791B26CFDE83"

local SCREEN_X_ADDRESS = 0x000D3F48
local SCREEN_X_COPY_ADDRESS = 0x000D3F5C
local RAW_HORIZONTAL_ADDRESS = 0x000D3998
local NORMALIZED_ADDRESS = 0x000D596C

local CAMERA_ADDRESSES = {
    0x00079950, 0x00079954, 0x00079958,
    0x00079960, 0x00079964, 0x00079968,
    0x00079970, 0x00079974, 0x00079978
}

local DEFAULT_SCREEN_MIN = 157.0
local DEFAULT_SCREEN_MAX = 163.0
local DEFAULT_CAMERA_TOLERANCE = 0.020
local DEFAULT_STABLE_FRAMES = 3
local DEFAULT_SHOT_FRAMES = 1
local DEFAULT_REARM_FRAMES = 12
local DEFAULT_LOG_INTERVAL = 10

local Z_BUTTON_NAME = "P1 Z"

local stopped = false
local gateEnabled = false
local armed = true
local stableCount = 0
local invalidCount = 0
local fireFramesRemaining = 0
local releaseFramesRemaining = 0
local pendingAction = nil
local cameraReference = nil
local session = nil
local shotCount = 0
local currentMode = "ARM_ONLY"

local form
local statusLabel
local liveLabel
local gateLabel
local filesLabel
local screenMinBox
local screenMaxBox
local cameraToleranceBox
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
local CAMERA_REFERENCE_PATH = OUTPUT_DIR .. "camera-reference.csv"
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

local function readCamera()
    local matrix = {}
    for i, address in ipairs(CAMERA_ADDRESSES) do
        matrix[i] = mainmemory.readfloat(address, true)
    end
    return matrix
end

local function saveCameraReference(matrix)
    local file = assert(io.open(CAMERA_REFERENCE_PATH, "w"))
    file:write("index,address_hex,value\n")
    for i, address in ipairs(CAMERA_ADDRESSES) do
        file:write(
            tostring(i) .. ","
            .. string.format("0x%08X", address) .. ","
            .. tostring(matrix[i]) .. "\n"
        )
    end
    file:close()
    cameraReference = matrix
end

local function loadCameraReference()
    local file = io.open(CAMERA_REFERENCE_PATH, "r")
    if not file then return false end
    file:read("*l")
    local matrix = {}
    for line in file:lines() do
        local indexText, _, valueText =
            line:match("^([^,]+),([^,]+),([^,]+)$")
        if indexText and valueText then
            matrix[tonumber(indexText)] = tonumber(valueText)
        end
    end
    file:close()
    if #matrix ~= 9 then return false end
    cameraReference = matrix
    return true
end

local function cameraMaxDelta(matrix)
    if not cameraReference then return math.huge end
    local maximum = 0
    for i = 1, 9 do
        maximum = math.max(
            maximum,
            math.abs(matrix[i] - cameraReference[i])
        )
    end
    return maximum
end

local function readState()
    local camera = readCamera()
    return {
        frame = emu.framecount(),
        screenX = mainmemory.readfloat(SCREEN_X_ADDRESS, true),
        screenXCopy = mainmemory.readfloat(SCREEN_X_COPY_ADDRESS, true),
        raw = mainmemory.readfloat(RAW_HORIZONTAL_ADDRESS, true),
        normalized = mainmemory.readfloat(NORMALIZED_ADDRESS, true),
        camera = camera,
        cameraDelta = cameraMaxDelta(camera)
    }
end

local function evaluate(state)
    local screenMin = numberFromBox(
        screenMinBox, DEFAULT_SCREEN_MIN, 0, 320
    )
    local screenMax = numberFromBox(
        screenMaxBox, DEFAULT_SCREEN_MAX, 0, 320
    )
    local cameraTolerance = numberFromBox(
        cameraToleranceBox,
        DEFAULT_CAMERA_TOLERANCE,
        0.0001,
        10.0
    )

    local armReady =
        state.screenX >= screenMin
        and state.screenX <= screenMax

    local cameraReady =
        cameraReference ~= nil
        and state.cameraDelta <= cameraTolerance

    local gateReady = false
    local blocker = "NONE"

    if currentMode == "ARM_ONLY" then
        gateReady = armReady
        blocker = armReady and "NONE" or "ARM"
    elseif currentMode == "CAMERA_ONLY" then
        gateReady = cameraReady
        blocker = cameraReady and "NONE" or "CAMERA"
    else
        gateReady = armReady and cameraReady
        if not armReady and not cameraReady then
            blocker = "ARM+CAMERA"
        elseif not armReady then
            blocker = "ARM"
        elseif not cameraReady then
            blocker = "CAMERA"
        end
    end

    return armReady, cameraReady, gateReady, blocker
end

local function setZ(pressed)
    joypad.set({[Z_BUTTON_NAME] = pressed})
end

local function writeHeader(file)
    file:write(
        "frame,event,mode,gate_enabled,armed,stable_count,invalid_count,"
        .. "screen_x,screen_x_copy,raw_horizontal,normalized,"
        .. "camera_reference_loaded,camera_max_delta,"
        .. "arm_ready,camera_ready,gate_ready,blocker\n"
    )
end

local function writeRow(eventName, state, armReady, cameraReady, gateReady, blocker)
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
        .. tostring(cameraReference ~= nil) .. ","
        .. tostring(state.cameraDelta) .. ","
        .. tostring(armReady) .. ","
        .. tostring(cameraReady) .. ","
        .. tostring(gateReady) .. ","
        .. blocker .. "\n"
    )
    session.csv:flush()
end

local function updateStats(state, armReady, cameraReady, gateReady, blocker)
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

    if state.cameraDelta ~= math.huge then
        session.cameraMinObserved =
            session.cameraMinObserved
            and math.min(session.cameraMinObserved, state.cameraDelta)
            or state.cameraDelta
        session.cameraMaxObserved =
            session.cameraMaxObserved
            and math.max(session.cameraMaxObserved, state.cameraDelta)
            or state.cameraDelta
    end

    if armReady then session.armReadyFrames = session.armReadyFrames + 1 end
    if cameraReady then session.cameraReadyFrames = session.cameraReadyFrames + 1 end
    if gateReady then session.gateReadyFrames = session.gateReadyFrames + 1 end

    session.blockers[blocker] = (session.blockers[blocker] or 0) + 1
end

local function startSession()
    if session then
        setStatus("sessao ja iniciada")
        return
    end

    local timestamp = os.date("%Y%m%d-%H%M%S")
    local csvPath = OUTPUT_DIR
        .. "automatic-shot-gate-diagnostic-" .. timestamp .. ".csv"
    local summaryPath = OUTPUT_DIR
        .. "automatic-shot-gate-diagnostic-" .. timestamp .. "-summary.txt"

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
        cameraReadyFrames = 0,
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
    summary:write("Started frame: " .. tostring(session.startedFrame) .. "\n")
    summary:write("Stopped frame: " .. tostring(emu.framecount()) .. "\n")
    summary:write("Rows: " .. tostring(session.rows) .. "\n")
    summary:write("Automatic shots: " .. tostring(session.shots) .. "\n")
    summary:write("Arm ready frames: " .. tostring(session.armReadyFrames) .. "\n")
    summary:write("Camera ready frames: " .. tostring(session.cameraReadyFrames) .. "\n")
    summary:write("Gate ready frames: " .. tostring(session.gateReadyFrames) .. "\n")
    summary:write("Screen observed min: " .. tostring(session.screenMinObserved) .. "\n")
    summary:write("Screen observed max: " .. tostring(session.screenMaxObserved) .. "\n")
    summary:write("Camera delta observed min: " .. tostring(session.cameraMinObserved) .. "\n")
    summary:write("Camera delta observed max: " .. tostring(session.cameraMaxObserved) .. "\n")
    summary:write("Camera reference loaded: " .. tostring(cameraReference ~= nil) .. "\n")
    summary:write("Screen window: "
        .. forms.gettext(screenMinBox) .. " to "
        .. forms.gettext(screenMaxBox) .. "\n")
    summary:write("Camera tolerance: "
        .. forms.gettext(cameraToleranceBox) .. "\n")
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
    for _, key in ipairs({"NONE", "ARM", "CAMERA", "ARM+CAMERA"}) do
        summary:write(
            key .. ": " .. tostring(session.blockers[key] or 0) .. "\n"
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

local function captureCameraReference()
    local matrix = readCamera()
    saveCameraReference(matrix)
    setStatus("referencia da camera capturada")
    log("Referencia da camera capturada | frame=" .. tostring(emu.framecount()))
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
        elseif action == "CAPTURE_CAMERA" then
            captureCameraReference()
        elseif action == "ARM_ONLY" then
            currentMode = "ARM_ONLY"
            resetGate()
            setStatus("modo ARM_ONLY")
        elseif action == "CAMERA_ONLY" then
            currentMode = "CAMERA_ONLY"
            resetGate()
            setStatus("modo CAMERA_ONLY")
        elseif action == "ARM_AND_CAMERA" then
            currentMode = "ARM_AND_CAMERA"
            resetGate()
            setStatus("modo ARM_AND_CAMERA")
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
    980,
    760,
    "GoldenEyeDiagnostic " .. VERSION,
    function() stopped = true end
)

forms.label(form, "Automatic Shot Gate Diagnostic", 12, 10, 940, 24)
statusLabel = forms.label(form, "Status: pronto", 12, 40, 940, 24)
liveLabel = forms.label(form, "Estado atual: aguardando", 12, 75, 940, 145, true)
gateLabel = forms.label(form, "Gate: aguardando", 12, 225, 940, 95, true)
filesLabel = forms.label(form, "Nenhuma sessao aberta", 12, 325, 940, 55, true)

forms.label(form, "screen_x minimo", 12, 395, 105, 22)
screenMinBox = forms.textbox(form, "157", 75, 24, nil, 120, 392)
forms.label(form, "screen_x maximo", 215, 395, 105, 22)
screenMaxBox = forms.textbox(form, "163", 75, 24, nil, 323, 392)
forms.label(form, "Tolerancia camera", 418, 395, 115, 22)
cameraToleranceBox = forms.textbox(form, "0.020", 75, 24, nil, 538, 392)
forms.label(form, "Frames estaveis", 633, 395, 100, 22)
stableFramesBox = forms.textbox(form, "3", 60, 24, nil, 738, 392)

forms.label(form, "Frames de Z", 12, 435, 85, 22)
shotFramesBox = forms.textbox(form, "1", 60, 24, nil, 102, 432)
forms.label(form, "Frames para rearmar", 185, 435, 125, 22)
rearmFramesBox = forms.textbox(form, "12", 60, 24, nil, 315, 432)
forms.label(form, "Intervalo do log", 405, 435, 105, 22)
logIntervalBox = forms.textbox(form, "10", 60, 24, nil, 515, 432)

forms.button(form, "ARM_ONLY", function() pendingAction = "ARM_ONLY" end, 12, 480, 140, 40)
forms.button(form, "CAMERA_ONLY", function() pendingAction = "CAMERA_ONLY" end, 165, 480, 140, 40)
forms.button(form, "ARM_AND_CAMERA", function() pendingAction = "ARM_AND_CAMERA" end, 318, 480, 170, 40)
forms.button(form, "CAPTURAR CAMERA", function() pendingAction = "CAPTURE_CAMERA" end, 501, 480, 170, 40)

forms.button(form, "INICIAR SESSAO", function() pendingAction = "START_SESSION" end, 12, 535, 150, 40)
forms.button(form, "ATIVAR GATE", function() pendingAction = "ENABLE" end, 175, 535, 140, 40)
forms.button(form, "DESATIVAR", function() pendingAction = "DISABLE" end, 328, 535, 130, 40)
forms.button(form, "REINICIAR", function() pendingAction = "RESET" end, 471, 535, 130, 40)
forms.button(form, "ENCERRAR", function() pendingAction = "STOP_SESSION" end, 614, 535, 140, 40)

forms.label(
    form,
    "Teste recomendado:\n"
    .. "1. Selecione ARM_ONLY.\n"
    .. "2. Inicie a sessao e ative o gate.\n"
    .. "3. Conduza Bond ate o primeiro soldado. A camera sera ignorada.\n"
    .. "4. Se funcionar, capture a camera no ponto correto e teste CAMERA_ONLY.\n"
    .. "5. Por fim, teste ARM_AND_CAMERA.\n\n"
    .. "O CSV registra o estado periodicamente mesmo quando bloqueado e mostra "
    .. "blocker=ARM, CAMERA ou ARM+CAMERA.",
    12, 595, 940, 120
)

console.clear()
log("Carregado | versao=" .. VERSION)
log("ROM=" .. tostring(gameinfo.getromname()))
log("Hash=" .. tostring(gameinfo.getromhash()))
if tostring(gameinfo.getromhash()) ~= EXPECTED_ROM_HASH then
    log("AVISO | hash inesperado")
end

if loadCameraReference() then
    setStatus("referencia da camera carregada")
else
    setStatus("pronto; sem referencia da camera")
end

event.onexit(function()
    gateEnabled = false
    pcall(function() setZ(false) end)
    if session then pcall(stopSession) end
    stopped = true
end, "GoldenEyeDiagnostic-0.0.5.8.1-exit")

while not stopped do
    processAction()

    local state = readState()
    local armReady, cameraReady, gateReady, blocker = evaluate(state)

    local stableRequired = integerFromBox(stableFramesBox, 3, 1, 120)
    local shotFrames = integerFromBox(shotFramesBox, 1, 1, 20)
    local rearmFrames = integerFromBox(rearmFramesBox, 12, 1, 300)
    local logInterval = integerFromBox(logIntervalBox, 10, 1, 600)

    if gateReady then
        stableCount = stableCount + 1
        invalidCount = 0
    else
        stableCount = 0
        invalidCount = invalidCount + 1
    end

    if not armed and invalidCount >= rearmFrames then
        armed = true
        if session then
            writeRow("REARMED", state, armReady, cameraReady, gateReady, blocker)
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
            writeRow("AUTO_SHOT", state, armReady, cameraReady, gateReady, blocker)
        end

        setStatus("AUTO_SHOT #" .. tostring(shotCount))
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
        writeRow("SAMPLE", state, armReady, cameraReady, gateReady, blocker)
        updateStats(state, armReady, cameraReady, gateReady, blocker)
    end

    forms.settext(
        liveLabel,
        string.format(
            "frame=%d | mode=%s\n"
            .. "screen_x=% .6f | copy=% .6f | raw=% .6f | normalized=% .6f\n"
            .. "camera ref=%s | camera max delta=%s",
            state.frame,
            currentMode,
            state.screenX,
            state.screenXCopy,
            state.raw,
            state.normalized,
            tostring(cameraReference ~= nil),
            state.cameraDelta == math.huge
                and "NO_REFERENCE"
                or string.format("%.6f", state.cameraDelta)
        )
    )

    forms.settext(
        gateLabel,
        string.format(
            "ARM_READY=%s | CAMERA_READY=%s | GATE_READY=%s | BLOCKER=%s\n"
            .. "enabled=%s | armed=%s | stable=%d/%d | invalid=%d/%d | shots=%d",
            tostring(armReady),
            tostring(cameraReady),
            tostring(gateReady),
            blocker,
            tostring(gateEnabled),
            tostring(armed),
            stableCount,
            stableRequired,
            invalidCount,
            rearmFrames,
            shotCount
        )
    )

    gui.drawString(8, 8, "GoldenEyeDiagnostic " .. VERSION, "white", "black", 12)
    gui.drawString(8, 26, gateReady and "SHOT READY" or "SHOT BLOCKED", "white", "black", 12)

    emu.frameadvance()
end
