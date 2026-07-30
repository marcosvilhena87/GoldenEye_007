-- GoldenEyeDiagnostic 0.0.5.8.9.1
-- Auto-Aim Camera Alignment Controller
--
-- Objetivo:
-- usar o deslocamento do auto-aim como erro de camera em malha fechada.
--
-- Sem disparo automatico.
--
-- Estados:
-- IDLE
-- ACQUIRED
-- ALIGNING
-- STABLE
-- LOST
--
-- Sinais:
-- normalized_horizontal = 0x000D596C
-- normalized_vertical   = 0x000D5968
--
-- Referencia inicial:
-- horizontal alvo = 0.000
-- vertical alvo   = -0.070
--
-- Saida:
-- P1 X Axis / P1 Y Axis
--
-- AVISO:
-- os sinais dos eixos podem precisar ser invertidos conforme o esquema de
-- controle usado no BizHawk. A interface permite configurar X sign e Y sign.
--
-- Somente leitura de memoria; escrita apenas nos eixos analogicos do P1.

local VERSION = "0.0.5.8.9.1"
local EXPECTED_ROM_HASH = "ABE01E4AEB033B6C0836819F549C791B26CFDE83"

local NORMALIZED_VERTICAL_ADDRESS = 0x000D5968
local NORMALIZED_HORIZONTAL_ADDRESS = 0x000D596C
local SCREEN_X_ADDRESS = 0x000D3F48
local SCREEN_Y_ADDRESS = 0x000D3F4C
local RAW_HORIZONTAL_ADDRESS = 0x000D3998
local RAW_VERTICAL_ADDRESS = 0x000D3F50

local X_AXIS_NAME = "P1 X Axis"
local Y_AXIS_NAME = "P1 Y Axis"

local DEFAULT_TARGET_X = 0.000
local DEFAULT_TARGET_Y = -0.070

local DEFAULT_ACQUIRE_X = 0.020
local DEFAULT_ACQUIRE_Y_DELTA = 0.035
local DEFAULT_ACQUIRE_FRAMES = 2
local DEFAULT_MEMORY_FRAMES = 45

local DEFAULT_X_TOLERANCE = 0.020
local DEFAULT_Y_TOLERANCE = 0.030
local DEFAULT_STABLE_FRAMES = 5

local DEFAULT_X_GAIN = 280.0
local DEFAULT_Y_GAIN = 220.0
local DEFAULT_MIN_COMMAND = 4
local DEFAULT_MAX_COMMAND = 45
local DEFAULT_X_SIGN = -1
local DEFAULT_Y_SIGN = 1

local DEFAULT_LOST_FRAMES = 40
local DEFAULT_LOG_INTERVAL = 1

local stopped = false
local controllerEnabled = false
local pendingAction = nil
local session = nil

local stateName = "IDLE"
local acquireCount = 0
local memoryRemaining = 0
local stableCount = 0
local lostCount = 0
local acquisitionFrame = nil
local stableFrame = nil
local acquisitionCount = 0

local previousErrorX = 0
local previousErrorY = 0
local previousCommandX = 0
local previousCommandY = 0

local form
local statusLabel
local liveLabel
local controllerLabel
local filesLabel

local targetXBox
local targetYBox
local acquireXBox
local acquireYBox
local acquireFramesBox
local memoryFramesBox
local xToleranceBox
local yToleranceBox
local stableFramesBox
local xGainBox
local yGainBox
local minCommandBox
local maxCommandBox
local xSignBox
local ySignBox
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

local function signFromBox(box, defaultValue)
    local value = tonumber(forms.gettext(box)) or defaultValue
    return value < 0 and -1 or 1
end

local function clamp(value, minimum, maximum)
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
end

local function signedCommand(error, gain, minimum, maximum, sign)
    local magnitude = math.abs(error) * gain

    if magnitude > 0 and magnitude < minimum then
        magnitude = minimum
    end

    magnitude = clamp(magnitude, 0, maximum)

    if error < 0 then
        magnitude = -magnitude
    end

    return math.floor(magnitude * sign + (magnitude * sign >= 0 and 0.5 or -0.5))
end

local function releaseAxes()
    joypad.set({
        [X_AXIS_NAME] = 0,
        [Y_AXIS_NAME] = 0
    })
    previousCommandX = 0
    previousCommandY = 0
end

local function readState()
    return {
        frame = emu.framecount(),
        normalizedX =
            mainmemory.readfloat(NORMALIZED_HORIZONTAL_ADDRESS, true),
        normalizedY =
            mainmemory.readfloat(NORMALIZED_VERTICAL_ADDRESS, true),
        screenX = mainmemory.readfloat(SCREEN_X_ADDRESS, true),
        screenY = mainmemory.readfloat(SCREEN_Y_ADDRESS, true),
        rawX = mainmemory.readfloat(RAW_HORIZONTAL_ADDRESS, true),
        rawY = mainmemory.readfloat(RAW_VERTICAL_ADDRESS, true)
    }
end

local function getSettings()
    return {
        targetX = numberFromBox(targetXBox, DEFAULT_TARGET_X, -2, 2),
        targetY = numberFromBox(targetYBox, DEFAULT_TARGET_Y, -2, 2),

        acquireX = numberFromBox(
            acquireXBox, DEFAULT_ACQUIRE_X, 0, 2
        ),
        acquireY = numberFromBox(
            acquireYBox, DEFAULT_ACQUIRE_Y_DELTA, 0, 2
        ),
        acquireFrames = integerFromBox(
            acquireFramesBox, DEFAULT_ACQUIRE_FRAMES, 1, 120
        ),
        memoryFrames = integerFromBox(
            memoryFramesBox, DEFAULT_MEMORY_FRAMES, 1, 600
        ),

        xTolerance = numberFromBox(
            xToleranceBox, DEFAULT_X_TOLERANCE, 0, 2
        ),
        yTolerance = numberFromBox(
            yToleranceBox, DEFAULT_Y_TOLERANCE, 0, 2
        ),
        stableFrames = integerFromBox(
            stableFramesBox, DEFAULT_STABLE_FRAMES, 1, 120
        ),

        xGain = numberFromBox(xGainBox, DEFAULT_X_GAIN, 0, 5000),
        yGain = numberFromBox(yGainBox, DEFAULT_Y_GAIN, 0, 5000),
        minCommand = integerFromBox(
            minCommandBox, DEFAULT_MIN_COMMAND, 0, 127
        ),
        maxCommand = integerFromBox(
            maxCommandBox, DEFAULT_MAX_COMMAND, 1, 127
        ),
        xSign = signFromBox(xSignBox, DEFAULT_X_SIGN),
        ySign = signFromBox(ySignBox, DEFAULT_Y_SIGN),

        lostFrames = integerFromBox(
            lostFramesBox, DEFAULT_LOST_FRAMES, 1, 600
        ),
        logInterval = integerFromBox(
            logIntervalBox, DEFAULT_LOG_INTERVAL, 1, 600
        )
    }
end

local function evaluate(current, settings)
    local errorX = current.normalizedX - settings.targetX
    local errorY = current.normalizedY - settings.targetY

    local acquiredSignal =
        math.abs(current.normalizedX) >= settings.acquireX
        or math.abs(errorY) >= settings.acquireY

    local alignedX = math.abs(errorX) <= settings.xTolerance
    local alignedY = math.abs(errorY) <= settings.yTolerance
    local aligned = alignedX and alignedY

    return {
        errorX = errorX,
        errorY = errorY,
        acquiredSignal = acquiredSignal,
        alignedX = alignedX,
        alignedY = alignedY,
        aligned = aligned
    }
end

local function writeHeader(file)
    file:write(
        "frame,event,state,enabled,acquisition,"
        .. "memory_remaining,stable_count,lost_count,"
        .. "normalized_x,normalized_y,target_x,target_y,error_x,error_y,"
        .. "screen_x,screen_y,raw_x,raw_y,"
        .. "acquired_signal,aligned_x,aligned_y,aligned,"
        .. "command_x,command_y,error_velocity_x,error_velocity_y\n"
    )
end

local function writeRow(eventName, current, settings, evaluation, commandX, commandY)
    if not session or not session.csv then return end

    session.csv:write(
        tostring(current.frame) .. ","
        .. tostring(eventName or "") .. ","
        .. stateName .. ","
        .. tostring(controllerEnabled) .. ","
        .. tostring(acquisitionCount) .. ","
        .. tostring(memoryRemaining) .. ","
        .. tostring(stableCount) .. ","
        .. tostring(lostCount) .. ","
        .. tostring(current.normalizedX) .. ","
        .. tostring(current.normalizedY) .. ","
        .. tostring(settings.targetX) .. ","
        .. tostring(settings.targetY) .. ","
        .. tostring(evaluation.errorX) .. ","
        .. tostring(evaluation.errorY) .. ","
        .. tostring(current.screenX) .. ","
        .. tostring(current.screenY) .. ","
        .. tostring(current.rawX) .. ","
        .. tostring(current.rawY) .. ","
        .. tostring(evaluation.acquiredSignal) .. ","
        .. tostring(evaluation.alignedX) .. ","
        .. tostring(evaluation.alignedY) .. ","
        .. tostring(evaluation.aligned) .. ","
        .. tostring(commandX) .. ","
        .. tostring(commandY) .. ","
        .. tostring(evaluation.errorX - previousErrorX) .. ","
        .. tostring(evaluation.errorY - previousErrorY)
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
        .. "auto-aim-camera-alignment-" .. timestamp .. ".csv"
    local summaryPath = OUTPUT_DIR
        .. "auto-aim-camera-alignment-" .. timestamp .. "-summary.txt"

    local csv = assert(io.open(csvPath, "w"))
    writeHeader(csv)

    session = {
        csv = csv,
        csvPath = csvPath,
        summaryPath = summaryPath,
        startedFrame = emu.framecount(),
        rows = 0,
        acquisitions = 0,
        stableEvents = 0,
        lostEvents = 0,
        totalAlignmentFrames = 0,
        completedAlignments = 0,
        maxAbsErrorX = 0,
        maxAbsErrorY = 0,
        maxAbsCommandX = 0,
        maxAbsCommandY = 0,
        stateCounts = {}
    }

    forms.settext(
        filesLabel,
        "CSV: " .. csvPath .. "\nResumo: " .. summaryPath
    )
    setStatus("sessao iniciada")
end

local function stopSession()
    controllerEnabled = false
    releaseAxes()

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
    summary:write("Acquisitions: " .. tostring(session.acquisitions) .. "\n")
    summary:write("Stable events: " .. tostring(session.stableEvents) .. "\n")
    summary:write("Lost events: " .. tostring(session.lostEvents) .. "\n")
    summary:write(
        "Completed alignments: "
        .. tostring(session.completedAlignments) .. "\n"
    )

    local averageAlignment = 0
    if session.completedAlignments > 0 then
        averageAlignment =
            session.totalAlignmentFrames / session.completedAlignments
    end

    summary:write(
        "Average frames to stable: "
        .. tostring(averageAlignment) .. "\n"
    )
    summary:write(
        "Max abs error X/Y: "
        .. tostring(session.maxAbsErrorX)
        .. " / "
        .. tostring(session.maxAbsErrorY)
        .. "\n"
    )
    summary:write(
        "Max abs command X/Y: "
        .. tostring(session.maxAbsCommandX)
        .. " / "
        .. tostring(session.maxAbsCommandY)
        .. "\n"
    )
    summary:write("Target X: " .. forms.gettext(targetXBox) .. "\n")
    summary:write("Target Y: " .. forms.gettext(targetYBox) .. "\n")
    summary:write("Acquire X: " .. forms.gettext(acquireXBox) .. "\n")
    summary:write("Acquire Y delta: " .. forms.gettext(acquireYBox) .. "\n")
    summary:write("Memory frames: " .. forms.gettext(memoryFramesBox) .. "\n")
    summary:write("X tolerance: " .. forms.gettext(xToleranceBox) .. "\n")
    summary:write("Y tolerance: " .. forms.gettext(yToleranceBox) .. "\n")
    summary:write("Stable frames: " .. forms.gettext(stableFramesBox) .. "\n")
    summary:write("X gain: " .. forms.gettext(xGainBox) .. "\n")
    summary:write("Y gain: " .. forms.gettext(yGainBox) .. "\n")
    summary:write("Min command: " .. forms.gettext(minCommandBox) .. "\n")
    summary:write("Max command: " .. forms.gettext(maxCommandBox) .. "\n")
    summary:write("X sign: " .. forms.gettext(xSignBox) .. "\n")
    summary:write("Y sign: " .. forms.gettext(ySignBox) .. "\n")
    summary:write("Lost frames: " .. forms.gettext(lostFramesBox) .. "\n")
    summary:write("CSV: " .. tostring(session.csvPath) .. "\n\n")

    summary:write("State counts:\n")
    for _, name in ipairs({"IDLE", "ACQUIRED", "ALIGNING", "STABLE", "LOST"}) do
        summary:write(
            name .. ": "
            .. tostring(session.stateCounts[name] or 0)
            .. "\n"
        )
    end

    summary:close()
    session = nil
    setStatus("sessao encerrada")
end

local function resetController()
    stateName = "IDLE"
    acquireCount = 0
    memoryRemaining = 0
    stableCount = 0
    lostCount = 0
    acquisitionFrame = nil
    stableFrame = nil
    previousErrorX = 0
    previousErrorY = 0
    releaseAxes()
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
            controllerEnabled = true
            setStatus("controlador ativado")
        elseif action == "DISABLE" then
            controllerEnabled = false
            releaseAxes()
            setStatus("controlador pausado")
        elseif action == "RESET" then
            resetController()
            setStatus("controlador reiniciado")
        elseif action == "STOP_SESSION" then
            stopSession()
        end
    end)

    if not ok then
        controllerEnabled = false
        pcall(releaseAxes)
        setStatus("erro")
        forms.settext(controllerLabel, tostring(err))
        log("ERRO: " .. tostring(err))
    end
end

form = forms.newform(
    1140,
    930,
    "GoldenEyeDiagnostic " .. VERSION,
    function() stopped = true end
)

forms.label(
    form,
    "Auto-Aim Camera Alignment Controller — sem tiro automatico",
    12, 10, 1100, 24
)

statusLabel = forms.label(
    form,
    "Status: pronto",
    12, 40, 1100, 24
)

liveLabel = forms.label(
    form,
    "Leitura ao vivo: aguardando",
    12, 75, 1100, 150, true
)

controllerLabel = forms.label(
    form,
    "Controlador: aguardando",
    12, 230, 1100, 125, true
)

filesLabel = forms.label(
    form,
    "Nenhuma sessao aberta",
    12, 360, 1100, 55, true
)

forms.label(form, "Target X", 12, 430, 60, 22)
targetXBox = forms.textbox(form, "0.000", 70, 24, nil, 77, 427)

forms.label(form, "Target Y", 165, 430, 60, 22)
targetYBox = forms.textbox(form, "-0.070", 70, 24, nil, 230, 427)

forms.label(form, "Acquire |X|", 318, 430, 80, 22)
acquireXBox = forms.textbox(form, "0.020", 70, 24, nil, 403, 427)

forms.label(form, "Acquire |Y error|", 491, 430, 105, 22)
acquireYBox = forms.textbox(form, "0.035", 70, 24, nil, 601, 427)

forms.label(form, "Acquire frames", 689, 430, 95, 22)
acquireFramesBox = forms.textbox(form, "2", 60, 24, nil, 789, 427)

forms.label(form, "Memory", 872, 430, 55, 22)
memoryFramesBox = forms.textbox(form, "45", 60, 24, nil, 932, 427)

forms.label(form, "X tolerance", 12, 470, 75, 22)
xToleranceBox = forms.textbox(form, "0.020", 70, 24, nil, 92, 467)

forms.label(form, "Y tolerance", 180, 470, 75, 22)
yToleranceBox = forms.textbox(form, "0.030", 70, 24, nil, 260, 467)

forms.label(form, "Stable frames", 348, 470, 85, 22)
stableFramesBox = forms.textbox(form, "5", 60, 24, nil, 438, 467)

forms.label(form, "X gain", 526, 470, 50, 22)
xGainBox = forms.textbox(form, "280", 70, 24, nil, 581, 467)

forms.label(form, "Y gain", 674, 470, 50, 22)
yGainBox = forms.textbox(form, "220", 70, 24, nil, 729, 467)

forms.label(form, "Min cmd", 822, 470, 55, 22)
minCommandBox = forms.textbox(form, "4", 60, 24, nil, 882, 467)

forms.label(form, "Max cmd", 970, 470, 60, 22)
maxCommandBox = forms.textbox(form, "45", 60, 24, nil, 1035, 467)

forms.label(form, "X sign", 12, 510, 45, 22)
xSignBox = forms.textbox(form, "-1", 60, 24, nil, 62, 507)

forms.label(form, "Y sign", 150, 510, 45, 22)
ySignBox = forms.textbox(form, "1", 60, 24, nil, 200, 507)

forms.label(form, "Lost frames", 288, 510, 75, 22)
lostFramesBox = forms.textbox(form, "40", 60, 24, nil, 368, 507)

forms.label(form, "Log interval", 456, 510, 75, 22)
logIntervalBox = forms.textbox(form, "1", 60, 24, nil, 536, 507)

forms.button(
    form,
    "INICIAR SESSAO",
    function() pendingAction = "START_SESSION" end,
    12, 565, 155, 40
)

forms.button(
    form,
    "ATIVAR CONTROLE",
    function() pendingAction = "ENABLE" end,
    180, 565, 170, 40
)

forms.button(
    form,
    "PAUSAR",
    function() pendingAction = "DISABLE" end,
    363, 565, 130, 40
)

forms.button(
    form,
    "REINICIAR",
    function() pendingAction = "RESET" end,
    506, 565, 140, 40
)

forms.button(
    form,
    "ENCERRAR",
    function() pendingAction = "STOP_SESSION" end,
    659, 565, 140, 40
)

forms.label(
    form,
    "Procedimento seguro:\n"
    .. "1. Inicie a sessao com o controlador PAUSADO.\n"
    .. "2. Aproxime Bond do primeiro soldado e deixe o auto-aim deslocar o braco.\n"
    .. "3. Ative o controle e observe se a camera gira na direcao do soldado.\n"
    .. "4. Se a camera se afastar do alvo, pause imediatamente e inverta X sign "
    .. "ou Y sign entre -1 e 1.\n"
    .. "5. O controlador nao pressiona Z.\n\n"
    .. "Sucesso inicial: |errorX| <= 0.020 e |errorY| <= 0.030 por 5 frames. "
    .. "O alvo vertical inicial e -0.070, aproximadamente a regiao corporal "
    .. "observada nos testes.",
    12, 625, 1100, 170
)

forms.label(
    form,
    "Controle proporcional:\n"
    .. "commandX = clamp(errorX * X gain * X sign)\n"
    .. "commandY = clamp(errorY * Y gain * Y sign)\n\n"
    .. "A magnitude diminui conforme o erro se aproxima da referencia. "
    .. "Comandos ficam limitados por Min cmd e Max cmd.",
    12, 805, 1100, 95
)

console.clear()
log("Carregado | versao=" .. VERSION)
log("ROM=" .. tostring(gameinfo.getromname()))
log("Hash=" .. tostring(gameinfo.getromhash()))

if tostring(gameinfo.getromhash()) ~= EXPECTED_ROM_HASH then
    log("AVISO | hash inesperado")
end

event.onexit(function()
    controllerEnabled = false
    pcall(releaseAxes)
    if session then pcall(stopSession) end
    stopped = true
end, "GoldenEyeDiagnostic-0.0.5.8.9.1-exit")

while not stopped do
    processAction()

    local settings = getSettings()
    local current = readState()
    local evaluation = evaluate(current, settings)

    local commandX = 0
    local commandY = 0
    local eventName = "SAMPLE"

    if stateName == "IDLE" then
        stableCount = 0
        lostCount = 0
        memoryRemaining = 0

        if evaluation.acquiredSignal then
            acquireCount = acquireCount + 1
        else
            acquireCount = 0
        end

        if acquireCount >= settings.acquireFrames then
            stateName = "ACQUIRED"
            memoryRemaining = settings.memoryFrames
            acquisitionFrame = current.frame
            stableFrame = nil
            acquisitionCount = acquisitionCount + 1
            eventName = "ACQUIRED"

            if session then
                session.acquisitions = session.acquisitions + 1
            end
        end

    elseif stateName == "ACQUIRED" then
        stateName = "ALIGNING"
        eventName = "ALIGNING"

    elseif stateName == "ALIGNING" then
        if evaluation.acquiredSignal then
            memoryRemaining = settings.memoryFrames
            lostCount = 0
        elseif memoryRemaining > 0 then
            memoryRemaining = memoryRemaining - 1
        else
            lostCount = lostCount + 1
        end

        if evaluation.aligned then
            stableCount = stableCount + 1
        else
            stableCount = 0
        end

        if stableCount >= settings.stableFrames then
            stateName = "STABLE"
            stableFrame = current.frame
            eventName = "STABLE"

            if session then
                session.stableEvents = session.stableEvents + 1
                if acquisitionFrame then
                    session.totalAlignmentFrames =
                        session.totalAlignmentFrames
                        + (stableFrame - acquisitionFrame)
                    session.completedAlignments =
                        session.completedAlignments + 1
                end
            end
        elseif lostCount >= settings.lostFrames then
            stateName = "LOST"
            eventName = "LOST"

            if session then
                session.lostEvents = session.lostEvents + 1
            end
        end

    elseif stateName == "STABLE" then
        if evaluation.aligned then
            stableCount = stableCount + 1
            memoryRemaining = settings.memoryFrames
            lostCount = 0
        else
            stateName = "ALIGNING"
            stableCount = 0
            eventName = "ALIGNING"
        end

    elseif stateName == "LOST" then
        stateName = "IDLE"
        acquireCount = 0
        memoryRemaining = 0
        stableCount = 0
        lostCount = 0
    end

    if controllerEnabled
        and (stateName == "ALIGNING" or stateName == "ACQUIRED") then

        commandX = signedCommand(
            evaluation.errorX,
            settings.xGain,
            settings.minCommand,
            settings.maxCommand,
            settings.xSign
        )

        commandY = signedCommand(
            evaluation.errorY,
            settings.yGain,
            settings.minCommand,
            settings.maxCommand,
            settings.ySign
        )

        joypad.set({
            [X_AXIS_NAME] = commandX,
            [Y_AXIS_NAME] = commandY
        })
    else
        releaseAxes()
        commandX = 0
        commandY = 0
    end

    if session then
        session.maxAbsErrorX =
            math.max(session.maxAbsErrorX, math.abs(evaluation.errorX))
        session.maxAbsErrorY =
            math.max(session.maxAbsErrorY, math.abs(evaluation.errorY))
        session.maxAbsCommandX =
            math.max(session.maxAbsCommandX, math.abs(commandX))
        session.maxAbsCommandY =
            math.max(session.maxAbsCommandY, math.abs(commandY))

        local interval = settings.logInterval
        if current.frame % interval == 0 or eventName ~= "SAMPLE" then
            writeRow(
                eventName,
                current,
                settings,
                evaluation,
                commandX,
                commandY
            )
            session.rows = session.rows + 1
            session.stateCounts[stateName] =
                (session.stateCounts[stateName] or 0) + 1
        end
    end

    forms.settext(
        liveLabel,
        string.format(
            "frame=%d | state=%s | enabled=%s\n"
            .. "norm_x=% .6f | norm_y=% .6f\n"
            .. "target_x=% .6f | target_y=% .6f\n"
            .. "error_x=% .6f | error_y=% .6f\n"
            .. "screen=(% .3f,% .3f) | raw=(% .3f,% .3f)",
            current.frame,
            stateName,
            tostring(controllerEnabled),
            current.normalizedX,
            current.normalizedY,
            settings.targetX,
            settings.targetY,
            evaluation.errorX,
            evaluation.errorY,
            current.screenX,
            current.screenY,
            current.rawX,
            current.rawY
        )
    )

    forms.settext(
        controllerLabel,
        string.format(
            "acquiredSignal=%s | memory=%d/%d\n"
            .. "alignedX=%s | alignedY=%s | stable=%d/%d\n"
            .. "commandX=%d | commandY=%d | signs=%d/%d\n"
            .. "acquisitions=%d",
            tostring(evaluation.acquiredSignal),
            memoryRemaining,
            settings.memoryFrames,
            tostring(evaluation.alignedX),
            tostring(evaluation.alignedY),
            stableCount,
            settings.stableFrames,
            commandX,
            commandY,
            settings.xSign,
            settings.ySign,
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
        string.format(
            "%s | ex=% .3f ey=% .3f | cmd=%d,%d",
            stateName,
            evaluation.errorX,
            evaluation.errorY,
            commandX,
            commandY
        ),
        "white", "black", 12
    )

    previousErrorX = evaluation.errorX
    previousErrorY = evaluation.errorY
    previousCommandX = commandX
    previousCommandY = commandY

    emu.frameadvance()
end
