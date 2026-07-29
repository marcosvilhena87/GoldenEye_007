-- GoldenEyeDiagnostic 0.0.5.8
-- Automatic Shot Gate
--
-- Dispara automaticamente somente quando:
-- 1. screen_x do braco esta entre 157 e 163;
-- 2. matriz da camera esta a no maximo 0.020 da referencia;
-- 3. as duas condicoes permanecem validas por alguns frames consecutivos.
--
-- A referencia da camera e a media de dois tiros confirmados como KILL
-- registrados na versao 0.0.5.7.
--
-- Esta versao nao move Bond nem corrige camera/braco.
-- Ela apenas decide quando liberar um unico pressionamento de Z.

local VERSION = "0.0.5.8"
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

-- Media das matrizes capturadas nos dois KILLs:
-- screen_x = 157.14744567871
-- screen_x = 160.87979125977
local CAMERA_REFERENCE = {
    0.28969436883926,
   -0.828962534666065,
   -0.478421211242675,
    0.98643657565117,
    0.047479035332799,
   -0.15705117583275,
   -0.327542752027515,
    0.0423796344548465,
   -0.94388175010681
}

local DEFAULT_SCREEN_MIN = 157.0
local DEFAULT_SCREEN_MAX = 163.0
local DEFAULT_CAMERA_TOLERANCE = 0.020
local DEFAULT_STABLE_FRAMES = 3
local DEFAULT_SHOT_FRAMES = 1
local DEFAULT_RELEASE_FRAMES = 8
local DEFAULT_REARM_FRAMES = 12

local Z_BUTTON_NAME = "P1 Z"

local stopped = false
local gateEnabled = false
local stableCount = 0
local invalidCount = 0
local fireFramesRemaining = 0
local releaseFramesRemaining = 0
local armed = true
local shotCount = 0
local pendingAction = nil
local session = nil

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

local function scriptDirectory()
    local source = debug.getinfo(1, "S").source
    if source:sub(1, 1) == "@" then
        source = source:sub(2)
    end
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

local function readCamera()
    local matrix = {}
    for i, address in ipairs(CAMERA_ADDRESSES) do
        matrix[i] = mainmemory.readfloat(address, true)
    end
    return matrix
end

local function cameraMaxDelta(matrix)
    local maximum = 0
    for i = 1, 9 do
        local difference = math.abs(matrix[i] - CAMERA_REFERENCE[i])
        if difference > maximum then
            maximum = difference
        end
    end
    return maximum
end

local function readState()
    local camera = readCamera()
    local screenX = mainmemory.readfloat(SCREEN_X_ADDRESS, true)

    return {
        frame = emu.framecount(),
        screenX = screenX,
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
        1.0
    )

    local armReady =
        state.screenX >= screenMin
        and state.screenX <= screenMax

    local cameraReady =
        state.cameraDelta <= cameraTolerance

    return armReady, cameraReady, armReady and cameraReady
end

local function setZ(pressed)
    joypad.set({[Z_BUTTON_NAME] = pressed})
end

local function writeHeader(file)
    file:write(
        "frame,event,gate_enabled,armed,stable_count,"
        .. "screen_x,screen_x_copy,raw_horizontal,normalized,"
        .. "camera_max_delta,arm_ready,camera_ready,gate_ready\n"
    )
end

local function writeRow(eventName, state, armReady, cameraReady, gateReady)
    if not session or not session.csv then
        return
    end

    session.csv:write(
        tostring(state.frame) .. ","
        .. tostring(eventName or "") .. ","
        .. tostring(gateEnabled) .. ","
        .. tostring(armed) .. ","
        .. tostring(stableCount) .. ","
        .. tostring(state.screenX) .. ","
        .. tostring(state.screenXCopy) .. ","
        .. tostring(state.raw) .. ","
        .. tostring(state.normalized) .. ","
        .. tostring(state.cameraDelta) .. ","
        .. tostring(armReady) .. ","
        .. tostring(cameraReady) .. ","
        .. tostring(gateReady) .. "\n"
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
        .. "automatic-shot-gate-" .. timestamp .. ".csv"
    local summaryPath = OUTPUT_DIR
        .. "automatic-shot-gate-" .. timestamp .. "-summary.txt"

    local csv = assert(io.open(csvPath, "w"))
    writeHeader(csv)

    session = {
        csv = csv,
        csvPath = csvPath,
        summaryPath = summaryPath,
        startedFrame = emu.framecount(),
        shots = 0,
        readyFrames = 0,
        blockedFrames = 0
    }

    forms.settext(
        filesLabel,
        "CSV: " .. csvPath .. "\nResumo: " .. summaryPath
    )

    setStatus("sessao iniciada; gate desativado")
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
    summary:write("Automatic shots: "
        .. tostring(session.shots) .. "\n")
    summary:write("Ready frames: "
        .. tostring(session.readyFrames) .. "\n")
    summary:write("Blocked frames: "
        .. tostring(session.blockedFrames) .. "\n")
    summary:write("Screen window: "
        .. forms.gettext(screenMinBox)
        .. " to " .. forms.gettext(screenMaxBox) .. "\n")
    summary:write("Camera tolerance: "
        .. forms.gettext(cameraToleranceBox) .. "\n")
    summary:write("Stable frames: "
        .. forms.gettext(stableFramesBox) .. "\n")
    summary:write("Shot frames: "
        .. forms.gettext(shotFramesBox) .. "\n")
    summary:write("Rearm frames: "
        .. forms.gettext(rearmFramesBox) .. "\n")
    summary:write("CSV: " .. tostring(session.csvPath) .. "\n")
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
    if not pendingAction then
        return
    end

    local action = pendingAction
    pendingAction = nil

    local ok, err = pcall(function()
        if action == "START_SESSION" then
            startSession()
        elseif action == "ENABLE" then
            if not session then
                startSession()
            end
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
    960,
    720,
    "GoldenEyeDiagnostic " .. VERSION,
    function()
        stopped = true
    end
)

forms.label(
    form,
    "Automatic Shot Gate — primeiro soldado",
    12, 10, 920, 24
)

statusLabel = forms.label(
    form,
    "Status: pronto",
    12, 40, 920, 24
)

liveLabel = forms.label(
    form,
    "Estado atual: aguardando",
    12, 75, 920, 135, true
)

gateLabel = forms.label(
    form,
    "Gate: aguardando",
    12, 215, 920, 80, true
)

filesLabel = forms.label(
    form,
    "Nenhuma sessao aberta",
    12, 300, 920, 55, true
)

forms.label(form, "screen_x minimo", 12, 375, 105, 22)
screenMinBox = forms.textbox(
    form, tostring(DEFAULT_SCREEN_MIN), 75, 24, nil, 120, 372
)

forms.label(form, "screen_x maximo", 215, 375, 105, 22)
screenMaxBox = forms.textbox(
    form, tostring(DEFAULT_SCREEN_MAX), 75, 24, nil, 323, 372
)

forms.label(form, "Tolerancia camera", 418, 375, 115, 22)
cameraToleranceBox = forms.textbox(
    form, tostring(DEFAULT_CAMERA_TOLERANCE),
    75, 24, nil, 538, 372
)

forms.label(form, "Frames estaveis", 633, 375, 100, 22)
stableFramesBox = forms.textbox(
    form, tostring(DEFAULT_STABLE_FRAMES),
    60, 24, nil, 738, 372
)

forms.label(form, "Frames de Z", 12, 415, 85, 22)
shotFramesBox = forms.textbox(
    form, tostring(DEFAULT_SHOT_FRAMES),
    60, 24, nil, 102, 412
)

forms.label(form, "Frames para rearmar", 185, 415, 125, 22)
rearmFramesBox = forms.textbox(
    form, tostring(DEFAULT_REARM_FRAMES),
    60, 24, nil, 315, 412
)

forms.button(
    form, "INICIAR SESSAO",
    function() pendingAction = "START_SESSION" end,
    12, 465, 150, 40
)

forms.button(
    form, "ATIVAR GATE",
    function() pendingAction = "ENABLE" end,
    175, 465, 140, 40
)

forms.button(
    form, "DESATIVAR",
    function() pendingAction = "DISABLE" end,
    328, 465, 130, 40
)

forms.button(
    form, "REINICIAR GATE",
    function() pendingAction = "RESET" end,
    471, 465, 150, 40
)

forms.button(
    form, "ENCERRAR SESSAO",
    function() pendingAction = "STOP_SESSION" end,
    634, 465, 165, 40
)

forms.label(
    form,
    "Funcionamento:\n"
    .. "• O gate nao move Bond nem a camera.\n"
    .. "• Ele observa continuamente screen_x e a matriz da camera.\n"
    .. "• Quando os dois criterios permanecem validos pelo numero configurado "
    .. "de frames, o script pressiona Z automaticamente.\n"
    .. "• Depois do tiro, o gate fica desarmado ate as condicoes ficarem "
    .. "invalidas pelo numero configurado de frames. Isso evita tiros repetidos.\n\n"
    .. "Configuracao inicial validada:\n"
    .. "screen_x entre 157 e 163; camera delta <= 0.020; 3 frames estaveis.\n\n"
    .. "Use primeiro em uma copia do savestate. O bot ainda nao detecta KILL "
    .. "automaticamente e nao tenta um segundo tiro na mesma aquisicao.",
    12, 530, 920, 165
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
end, "GoldenEyeDiagnostic-0.0.5.8-exit")

while not stopped do
    processAction()

    local state = readState()
    local armReady, cameraReady, gateReady = evaluate(state)
    local stableRequired = integerFromBox(
        stableFramesBox, DEFAULT_STABLE_FRAMES, 1, 120
    )
    local shotFrames = integerFromBox(
        shotFramesBox, DEFAULT_SHOT_FRAMES, 1, 20
    )
    local rearmFrames = integerFromBox(
        rearmFramesBox, DEFAULT_REARM_FRAMES, 1, 300
    )

    if gateReady then
        stableCount = stableCount + 1
        invalidCount = 0
        if session then session.readyFrames = session.readyFrames + 1 end
    else
        stableCount = 0
        invalidCount = invalidCount + 1
        if session then session.blockedFrames = session.blockedFrames + 1 end
    end

    if not armed and invalidCount >= rearmFrames then
        armed = true
        setStatus("gate rearmado")
        if session then
            writeRow("REARMED", state, armReady, cameraReady, gateReady)
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
            writeRow("AUTO_SHOT", state, armReady, cameraReady, gateReady)
        end

        setStatus("AUTO_SHOT #" .. tostring(shotCount))
        log(
            "AUTO_SHOT | frame=" .. tostring(state.frame)
            .. " | screen_x=" .. tostring(state.screenX)
            .. " | cameraDelta=" .. tostring(state.cameraDelta)
        )
    end

    if gateEnabled and fireFramesRemaining > 0 then
        setZ(true)
        fireFramesRemaining = fireFramesRemaining - 1

        if fireFramesRemaining == 0 then
            releaseFramesRemaining = DEFAULT_RELEASE_FRAMES
        end
    else
        setZ(false)

        if releaseFramesRemaining > 0 then
            releaseFramesRemaining = releaseFramesRemaining - 1
        end
    end

    forms.settext(
        liveLabel,
        string.format(
            "frame=%d\n"
            .. "screen_x=% .6f | copy=% .6f | raw=% .6f | normalized=% .6f\n"
            .. "camera max delta=% .6f",
            state.frame,
            state.screenX,
            state.screenXCopy,
            state.raw,
            state.normalized,
            state.cameraDelta
        )
    )

    forms.settext(
        gateLabel,
        string.format(
            "ARM_READY=%s | CAMERA_READY=%s | GATE_READY=%s\n"
            .. "enabled=%s | armed=%s | stable=%d/%d | invalid=%d/%d | shots=%d",
            tostring(armReady),
            tostring(cameraReady),
            tostring(gateReady),
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
        gateReady and "SHOT READY" or "SHOT BLOCKED",
        "white", "black", 12
    )

    emu.frameadvance()
end
