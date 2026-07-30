-- GoldenEyeDiagnostic 0.0.5.8.9.2
-- Damped Camera Alignment with Target Memory
--
-- Objetivo:
-- alinhar a camera usando o auto-aim como referencia, reduzindo oscilacao
-- e mantendo uma memoria temporaria da ultima direcao conhecida quando
-- o soldado deixa de ficar visivel.
--
-- Sem disparo automatico.
--
-- Estados:
-- IDLE
-- ACQUIRED
-- ALIGNING
-- STABLE
-- TARGET_TEMPORARILY_LOST
-- SEARCHING_LAST_DIRECTION
-- REACQUIRED
-- LOST
--
-- Controle:
-- command = Kp * error + Kd * errorVelocity
--
-- Memoria:
-- quando o sinal atual deixa de ser confiavel, o controlador usa o ultimo
-- erro util com decaimento progressivo por alguns frames.
--
-- Somente leitura de memoria; escrita apenas nos eixos analogicos do P1.

local VERSION = "0.0.5.8.9.2"
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
local DEFAULT_SIGNAL_QUIET_X = 0.006
local DEFAULT_SIGNAL_QUIET_Y = 0.012
local DEFAULT_TEMP_LOST_FRAMES = 3

local DEFAULT_ENTER_X_TOLERANCE = 0.020
local DEFAULT_ENTER_Y_TOLERANCE = 0.030
local DEFAULT_EXIT_X_TOLERANCE = 0.035
local DEFAULT_EXIT_Y_TOLERANCE = 0.045
local DEFAULT_STABLE_FRAMES = 5

local DEFAULT_X_KP = 280.0
local DEFAULT_Y_KP = 220.0
local DEFAULT_X_KD = 90.0
local DEFAULT_Y_KD = 70.0

local DEFAULT_FINE_ERROR_X = 0.050
local DEFAULT_FINE_ERROR_Y = 0.060
local DEFAULT_COARSE_MIN_COMMAND = 4
local DEFAULT_FINE_MIN_COMMAND = 0
local DEFAULT_MAX_COMMAND = 45
local DEFAULT_SEARCH_MAX_COMMAND = 20
local DEFAULT_X_SIGN = -1
local DEFAULT_Y_SIGN = 1

local DEFAULT_MEMORY_FRAMES = 30
local DEFAULT_MEMORY_MIN_DECAY = 0.10
local DEFAULT_REACQUIRE_FRAMES = 2
local DEFAULT_LOG_INTERVAL = 1

local stopped = false
local controllerEnabled = false
local pendingAction = nil
local session = nil

local stateName = "IDLE"
local acquireCount = 0
local stableCount = 0
local quietCount = 0
local reacquireCount = 0
local searchFrame = 0

local alignmentStartFrame = nil
local acquisitionCount = 0

local previousErrorX = 0
local previousErrorY = 0
local filteredVelocityX = 0
local filteredVelocityY = 0

local rememberedErrorX = 0
local rememberedErrorY = 0
local rememberedCommandX = 0
local rememberedCommandY = 0
local rememberedFrame = nil

local form
local statusLabel
local liveLabel
local controllerLabel
local memoryLabel
local filesLabel

local targetXBox
local targetYBox
local acquireXBox
local acquireYBox
local acquireFramesBox
local quietXBox
local quietYBox
local tempLostFramesBox

local enterXToleranceBox
local enterYToleranceBox
local exitXToleranceBox
local exitYToleranceBox
local stableFramesBox

local xKpBox
local yKpBox
local xKdBox
local yKdBox
local fineErrorXBox
local fineErrorYBox
local coarseMinCommandBox
local fineMinCommandBox
local maxCommandBox
local searchMaxCommandBox
local xSignBox
local ySignBox

local memoryFramesBox
local memoryMinDecayBox
local reacquireFramesBox
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

local function roundSigned(value)
    if value >= 0 then
        return math.floor(value + 0.5)
    end
    return math.ceil(value - 0.5)
end

local function releaseAxes()
    joypad.set({
        [X_AXIS_NAME] = 0,
        [Y_AXIS_NAME] = 0
    })
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

        acquireX = numberFromBox(acquireXBox, DEFAULT_ACQUIRE_X, 0, 2),
        acquireY = numberFromBox(acquireYBox, DEFAULT_ACQUIRE_Y_DELTA, 0, 2),
        acquireFrames = integerFromBox(
            acquireFramesBox, DEFAULT_ACQUIRE_FRAMES, 1, 120
        ),
        quietX = numberFromBox(
            quietXBox, DEFAULT_SIGNAL_QUIET_X, 0, 2
        ),
        quietY = numberFromBox(
            quietYBox, DEFAULT_SIGNAL_QUIET_Y, 0, 2
        ),
        tempLostFrames = integerFromBox(
            tempLostFramesBox, DEFAULT_TEMP_LOST_FRAMES, 1, 120
        ),

        enterXTolerance = numberFromBox(
            enterXToleranceBox, DEFAULT_ENTER_X_TOLERANCE, 0, 2
        ),
        enterYTolerance = numberFromBox(
            enterYToleranceBox, DEFAULT_ENTER_Y_TOLERANCE, 0, 2
        ),
        exitXTolerance = numberFromBox(
            exitXToleranceBox, DEFAULT_EXIT_X_TOLERANCE, 0, 2
        ),
        exitYTolerance = numberFromBox(
            exitYToleranceBox, DEFAULT_EXIT_Y_TOLERANCE, 0, 2
        ),
        stableFrames = integerFromBox(
            stableFramesBox, DEFAULT_STABLE_FRAMES, 1, 120
        ),

        xKp = numberFromBox(xKpBox, DEFAULT_X_KP, 0, 5000),
        yKp = numberFromBox(yKpBox, DEFAULT_Y_KP, 0, 5000),
        xKd = numberFromBox(xKdBox, DEFAULT_X_KD, 0, 5000),
        yKd = numberFromBox(yKdBox, DEFAULT_Y_KD, 0, 5000),

        fineErrorX = numberFromBox(
            fineErrorXBox, DEFAULT_FINE_ERROR_X, 0, 2
        ),
        fineErrorY = numberFromBox(
            fineErrorYBox, DEFAULT_FINE_ERROR_Y, 0, 2
        ),
        coarseMinCommand = integerFromBox(
            coarseMinCommandBox, DEFAULT_COARSE_MIN_COMMAND, 0, 127
        ),
        fineMinCommand = integerFromBox(
            fineMinCommandBox, DEFAULT_FINE_MIN_COMMAND, 0, 127
        ),
        maxCommand = integerFromBox(
            maxCommandBox, DEFAULT_MAX_COMMAND, 1, 127
        ),
        searchMaxCommand = integerFromBox(
            searchMaxCommandBox, DEFAULT_SEARCH_MAX_COMMAND, 1, 127
        ),
        xSign = signFromBox(xSignBox, DEFAULT_X_SIGN),
        ySign = signFromBox(ySignBox, DEFAULT_Y_SIGN),

        memoryFrames = integerFromBox(
            memoryFramesBox, DEFAULT_MEMORY_FRAMES, 1, 600
        ),
        memoryMinDecay = numberFromBox(
            memoryMinDecayBox, DEFAULT_MEMORY_MIN_DECAY, 0, 1
        ),
        reacquireFrames = integerFromBox(
            reacquireFramesBox, DEFAULT_REACQUIRE_FRAMES, 1, 120
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

    local quietSignal =
        math.abs(current.normalizedX) <= settings.quietX
        and math.abs(errorY) <= settings.quietY

    local enterAligned =
        math.abs(errorX) <= settings.enterXTolerance
        and math.abs(errorY) <= settings.enterYTolerance

    local exitAligned =
        math.abs(errorX) <= settings.exitXTolerance
        and math.abs(errorY) <= settings.exitYTolerance

    return {
        errorX = errorX,
        errorY = errorY,
        acquiredSignal = acquiredSignal,
        quietSignal = quietSignal,
        enterAligned = enterAligned,
        exitAligned = exitAligned
    }
end

local function minimumCommandFor(error, fineThreshold, settings)
    if math.abs(error) <= fineThreshold then
        return settings.fineMinCommand
    end
    return settings.coarseMinCommand
end

local function controllerCommand(
    error,
    velocity,
    kp,
    kd,
    fineThreshold,
    sign,
    maximum,
    settings
)
    local raw = kp * error + kd * velocity
    local magnitude = math.abs(raw)
    local minimum = minimumCommandFor(error, fineThreshold, settings)

    if magnitude > 0 and magnitude < minimum then
        magnitude = minimum
    end

    magnitude = clamp(magnitude, 0, maximum)

    if raw < 0 then
        magnitude = -magnitude
    end

    local rounded = roundSigned(magnitude * sign)
    return clamp(rounded, -maximum, maximum)
end

local function searchDecay(settings)
    if settings.memoryFrames <= 1 then
        return settings.memoryMinDecay
    end

    local progress = searchFrame / settings.memoryFrames
    local decay = 1.0 - progress
    return clamp(decay, settings.memoryMinDecay, 1.0)
end

local function writeHeader(file)
    file:write(
        "frame,event,state,enabled,acquisition,"
        .. "stable_count,quiet_count,reacquire_count,search_frame,"
        .. "normalized_x,normalized_y,target_x,target_y,error_x,error_y,"
        .. "velocity_x,velocity_y,filtered_velocity_x,filtered_velocity_y,"
        .. "remembered_error_x,remembered_error_y,"
        .. "screen_x,screen_y,raw_x,raw_y,"
        .. "acquired_signal,quiet_signal,enter_aligned,exit_aligned,"
        .. "command_x,command_y,search_decay\n"
    )
end

local function writeRow(
    eventName,
    current,
    settings,
    evaluation,
    commandX,
    commandY,
    decay
)
    if not session or not session.csv then return end

    local velocityX = evaluation.errorX - previousErrorX
    local velocityY = evaluation.errorY - previousErrorY

    session.csv:write(
        tostring(current.frame) .. ","
        .. tostring(eventName or "") .. ","
        .. stateName .. ","
        .. tostring(controllerEnabled) .. ","
        .. tostring(acquisitionCount) .. ","
        .. tostring(stableCount) .. ","
        .. tostring(quietCount) .. ","
        .. tostring(reacquireCount) .. ","
        .. tostring(searchFrame) .. ","
        .. tostring(current.normalizedX) .. ","
        .. tostring(current.normalizedY) .. ","
        .. tostring(settings.targetX) .. ","
        .. tostring(settings.targetY) .. ","
        .. tostring(evaluation.errorX) .. ","
        .. tostring(evaluation.errorY) .. ","
        .. tostring(velocityX) .. ","
        .. tostring(velocityY) .. ","
        .. tostring(filteredVelocityX) .. ","
        .. tostring(filteredVelocityY) .. ","
        .. tostring(rememberedErrorX) .. ","
        .. tostring(rememberedErrorY) .. ","
        .. tostring(current.screenX) .. ","
        .. tostring(current.screenY) .. ","
        .. tostring(current.rawX) .. ","
        .. tostring(current.rawY) .. ","
        .. tostring(evaluation.acquiredSignal) .. ","
        .. tostring(evaluation.quietSignal) .. ","
        .. tostring(evaluation.enterAligned) .. ","
        .. tostring(evaluation.exitAligned) .. ","
        .. tostring(commandX) .. ","
        .. tostring(commandY) .. ","
        .. tostring(decay)
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
        .. "damped-camera-alignment-memory-" .. timestamp .. ".csv"
    local summaryPath = OUTPUT_DIR
        .. "damped-camera-alignment-memory-" .. timestamp .. "-summary.txt"

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
        temporaryLosses = 0,
        searches = 0,
        reacquisitions = 0,
        lostEvents = 0,
        completedAlignments = 0,
        totalAlignmentFrames = 0,
        maxSearchFrames = 0,
        maxAbsCommandX = 0,
        maxAbsCommandY = 0,
        maxAbsErrorX = 0,
        maxAbsErrorY = 0,
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
    summary:write(
        "Temporary losses: " .. tostring(session.temporaryLosses) .. "\n"
    )
    summary:write("Searches: " .. tostring(session.searches) .. "\n")
    summary:write(
        "Reacquisitions: " .. tostring(session.reacquisitions) .. "\n"
    )
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
        "Average ALIGNING-to-STABLE frames: "
        .. tostring(averageAlignment) .. "\n"
    )
    summary:write(
        "Max search frames: " .. tostring(session.maxSearchFrames) .. "\n"
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

    summary:write("Target X/Y: "
        .. forms.gettext(targetXBox) .. " / "
        .. forms.gettext(targetYBox) .. "\n")
    summary:write("Acquire X/Y: "
        .. forms.gettext(acquireXBox) .. " / "
        .. forms.gettext(acquireYBox) .. "\n")
    summary:write("Quiet X/Y: "
        .. forms.gettext(quietXBox) .. " / "
        .. forms.gettext(quietYBox) .. "\n")
    summary:write("Enter tolerance X/Y: "
        .. forms.gettext(enterXToleranceBox) .. " / "
        .. forms.gettext(enterYToleranceBox) .. "\n")
    summary:write("Exit tolerance X/Y: "
        .. forms.gettext(exitXToleranceBox) .. " / "
        .. forms.gettext(exitYToleranceBox) .. "\n")
    summary:write("Kp X/Y: "
        .. forms.gettext(xKpBox) .. " / "
        .. forms.gettext(yKpBox) .. "\n")
    summary:write("Kd X/Y: "
        .. forms.gettext(xKdBox) .. " / "
        .. forms.gettext(yKdBox) .. "\n")
    summary:write("Memory frames: "
        .. forms.gettext(memoryFramesBox) .. "\n")
    summary:write("Memory minimum decay: "
        .. forms.gettext(memoryMinDecayBox) .. "\n")
    summary:write("Search max command: "
        .. forms.gettext(searchMaxCommandBox) .. "\n")
    summary:write("Signs X/Y: "
        .. forms.gettext(xSignBox) .. " / "
        .. forms.gettext(ySignBox) .. "\n")
    summary:write("CSV: " .. tostring(session.csvPath) .. "\n\n")

    summary:write("State counts:\n")
    for _, name in ipairs({
        "IDLE",
        "ACQUIRED",
        "ALIGNING",
        "STABLE",
        "TARGET_TEMPORARILY_LOST",
        "SEARCHING_LAST_DIRECTION",
        "REACQUIRED",
        "LOST"
    }) do
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
    stableCount = 0
    quietCount = 0
    reacquireCount = 0
    searchFrame = 0
    alignmentStartFrame = nil

    previousErrorX = 0
    previousErrorY = 0
    filteredVelocityX = 0
    filteredVelocityY = 0

    rememberedErrorX = 0
    rememberedErrorY = 0
    rememberedCommandX = 0
    rememberedCommandY = 0
    rememberedFrame = nil

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
    1180,
    1010,
    "GoldenEyeDiagnostic " .. VERSION,
    function() stopped = true end
)

forms.label(
    form,
    "Damped Camera Alignment with Target Memory — sem tiro automatico",
    12, 10, 1140, 24
)

statusLabel = forms.label(
    form,
    "Status: pronto",
    12, 40, 1140, 24
)

liveLabel = forms.label(
    form,
    "Leitura ao vivo: aguardando",
    12, 75, 1140, 150, true
)

controllerLabel = forms.label(
    form,
    "Controlador: aguardando",
    12, 230, 1140, 125, true
)

memoryLabel = forms.label(
    form,
    "Memoria: aguardando",
    12, 360, 1140, 90, true
)

filesLabel = forms.label(
    form,
    "Nenhuma sessao aberta",
    12, 455, 1140, 55, true
)

forms.label(form, "Target X", 12, 525, 60, 22)
targetXBox = forms.textbox(form, "0.000", 70, 24, nil, 77, 522)

forms.label(form, "Target Y", 165, 525, 60, 22)
targetYBox = forms.textbox(form, "-0.070", 70, 24, nil, 230, 522)

forms.label(form, "Acquire X", 318, 525, 65, 22)
acquireXBox = forms.textbox(form, "0.020", 70, 24, nil, 388, 522)

forms.label(form, "Acquire Y", 476, 525, 65, 22)
acquireYBox = forms.textbox(form, "0.035", 70, 24, nil, 546, 522)

forms.label(form, "Acquire frames", 634, 525, 95, 22)
acquireFramesBox = forms.textbox(form, "2", 60, 24, nil, 734, 522)

forms.label(form, "Quiet X", 812, 525, 55, 22)
quietXBox = forms.textbox(form, "0.006", 70, 24, nil, 872, 522)

forms.label(form, "Quiet Y", 965, 525, 55, 22)
quietYBox = forms.textbox(form, "0.012", 70, 24, nil, 1025, 522)

forms.label(form, "Temp lost", 12, 565, 65, 22)
tempLostFramesBox = forms.textbox(form, "3", 60, 24, nil, 82, 562)

forms.label(form, "Enter tol X", 160, 565, 70, 22)
enterXToleranceBox = forms.textbox(form, "0.020", 70, 24, nil, 235, 562)

forms.label(form, "Enter tol Y", 318, 565, 70, 22)
enterYToleranceBox = forms.textbox(form, "0.030", 70, 24, nil, 393, 562)

forms.label(form, "Exit tol X", 476, 565, 65, 22)
exitXToleranceBox = forms.textbox(form, "0.035", 70, 24, nil, 546, 562)

forms.label(form, "Exit tol Y", 634, 565, 65, 22)
exitYToleranceBox = forms.textbox(form, "0.045", 70, 24, nil, 704, 562)

forms.label(form, "Stable frames", 792, 565, 85, 22)
stableFramesBox = forms.textbox(form, "5", 60, 24, nil, 882, 562)

forms.label(form, "X Kp", 12, 605, 35, 22)
xKpBox = forms.textbox(form, "280", 70, 24, nil, 52, 602)

forms.label(form, "Y Kp", 140, 605, 35, 22)
yKpBox = forms.textbox(form, "220", 70, 24, nil, 180, 602)

forms.label(form, "X Kd", 268, 605, 35, 22)
xKdBox = forms.textbox(form, "90", 70, 24, nil, 308, 602)

forms.label(form, "Y Kd", 396, 605, 35, 22)
yKdBox = forms.textbox(form, "70", 70, 24, nil, 436, 602)

forms.label(form, "Fine err X", 524, 605, 65, 22)
fineErrorXBox = forms.textbox(form, "0.050", 70, 24, nil, 594, 602)

forms.label(form, "Fine err Y", 682, 605, 65, 22)
fineErrorYBox = forms.textbox(form, "0.060", 70, 24, nil, 752, 602)

forms.label(form, "Coarse min", 840, 605, 70, 22)
coarseMinCommandBox = forms.textbox(form, "4", 60, 24, nil, 915, 602)

forms.label(form, "Fine min", 1000, 605, 55, 22)
fineMinCommandBox = forms.textbox(form, "0", 60, 24, nil, 1060, 602)

forms.label(form, "Max cmd", 12, 645, 55, 22)
maxCommandBox = forms.textbox(form, "45", 60, 24, nil, 72, 642)

forms.label(form, "Search max", 150, 645, 70, 22)
searchMaxCommandBox = forms.textbox(form, "20", 60, 24, nil, 225, 642)

forms.label(form, "X sign", 308, 645, 45, 22)
xSignBox = forms.textbox(form, "-1", 60, 24, nil, 358, 642)

forms.label(form, "Y sign", 446, 645, 45, 22)
ySignBox = forms.textbox(form, "1", 60, 24, nil, 496, 642)

forms.label(form, "Memory frames", 584, 645, 90, 22)
memoryFramesBox = forms.textbox(form, "30", 60, 24, nil, 679, 642)

forms.label(form, "Min decay", 762, 645, 65, 22)
memoryMinDecayBox = forms.textbox(form, "0.10", 70, 24, nil, 832, 642)

forms.label(form, "Reacquire", 920, 645, 65, 22)
reacquireFramesBox = forms.textbox(form, "2", 60, 24, nil, 990, 642)

forms.label(form, "Log", 1070, 645, 30, 22)
logIntervalBox = forms.textbox(form, "1", 50, 24, nil, 1105, 642)

forms.button(
    form,
    "INICIAR SESSAO",
    function() pendingAction = "START_SESSION" end,
    12, 700, 155, 40
)

forms.button(
    form,
    "ATIVAR CONTROLE",
    function() pendingAction = "ENABLE" end,
    180, 700, 170, 40
)

forms.button(
    form,
    "PAUSAR",
    function() pendingAction = "DISABLE" end,
    363, 700, 130, 40
)

forms.button(
    form,
    "REINICIAR",
    function() pendingAction = "RESET" end,
    506, 700, 140, 40
)

forms.button(
    form,
    "ENCERRAR",
    function() pendingAction = "STOP_SESSION" end,
    659, 700, 140, 40
)

forms.label(
    form,
    "Fluxo de memoria:\n"
    .. "ALIGNING/STABLE -> sinal fica quieto por alguns frames -> "
    .. "TARGET_TEMPORARILY_LOST -> SEARCHING_LAST_DIRECTION.\n"
    .. "Durante a busca, a camera continua na ultima direcao conhecida com "
    .. "forca decrescente. Se o auto-aim reaparecer, entra em REACQUIRED e "
    .. "volta para ALIGNING. Se a memoria expirar, entra em LOST.\n\n"
    .. "O controlador nao pressiona Z. Pause imediatamente se a camera girar "
    .. "na direcao errada.",
    12, 760, 1140, 145
)

forms.label(
    form,
    "Amortecimento e histerese:\n"
    .. "command = Kp*error + Kd*velocidade_do_erro.\n"
    .. "Entra em STABLE com tolerancias menores e so sai com tolerancias maiores. "
    .. "Proximo ao alvo, o comando minimo pode cair para zero, reduzindo a oscilacao. "
    .. "O limite final e aplicado apos o arredondamento.",
    12, 910, 1140, 75
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
end, "GoldenEyeDiagnostic-0.0.5.8.9.2-exit")

while not stopped do
    processAction()

    local settings = getSettings()
    local current = readState()
    local evaluation = evaluate(current, settings)

    local velocityX = evaluation.errorX - previousErrorX
    local velocityY = evaluation.errorY - previousErrorY

    filteredVelocityX = filteredVelocityX * 0.65 + velocityX * 0.35
    filteredVelocityY = filteredVelocityY * 0.65 + velocityY * 0.35

    local commandX = 0
    local commandY = 0
    local decay = 0
    local eventName = "SAMPLE"

    if stateName == "IDLE" then
        stableCount = 0
        quietCount = 0
        reacquireCount = 0
        searchFrame = 0

        if evaluation.acquiredSignal then
            acquireCount = acquireCount + 1
        else
            acquireCount = 0
        end

        if acquireCount >= settings.acquireFrames then
            stateName = "ACQUIRED"
            acquisitionCount = acquisitionCount + 1
            alignmentStartFrame = current.frame
            eventName = "ACQUIRED"

            rememberedErrorX = evaluation.errorX
            rememberedErrorY = evaluation.errorY
            rememberedFrame = current.frame

            if session then
                session.acquisitions = session.acquisitions + 1
            end
        end

    elseif stateName == "ACQUIRED" then
        stateName = "ALIGNING"
        alignmentStartFrame = current.frame
        eventName = "ALIGNING"

    elseif stateName == "ALIGNING" then
        if evaluation.acquiredSignal or not evaluation.quietSignal then
            quietCount = 0
            rememberedErrorX = evaluation.errorX
            rememberedErrorY = evaluation.errorY
            rememberedFrame = current.frame
        else
            quietCount = quietCount + 1
        end

        if evaluation.enterAligned then
            stableCount = stableCount + 1
        else
            stableCount = 0
        end

        if stableCount >= settings.stableFrames then
            stateName = "STABLE"
            eventName = "STABLE"

            if session then
                session.stableEvents = session.stableEvents + 1

                if alignmentStartFrame then
                    session.totalAlignmentFrames =
                        session.totalAlignmentFrames
                        + (current.frame - alignmentStartFrame)
                    session.completedAlignments =
                        session.completedAlignments + 1
                end
            end
        elseif quietCount >= settings.tempLostFrames then
            stateName = "TARGET_TEMPORARILY_LOST"
            eventName = "TARGET_TEMPORARILY_LOST"

            if session then
                session.temporaryLosses = session.temporaryLosses + 1
            end
        end

    elseif stateName == "STABLE" then
        if evaluation.acquiredSignal or not evaluation.quietSignal then
            quietCount = 0
            rememberedErrorX = evaluation.errorX
            rememberedErrorY = evaluation.errorY
            rememberedFrame = current.frame
        else
            quietCount = quietCount + 1
        end

        if not evaluation.exitAligned then
            stateName = "ALIGNING"
            stableCount = 0
            alignmentStartFrame = current.frame
            eventName = "ALIGNING"
        elseif quietCount >= settings.tempLostFrames then
            stateName = "TARGET_TEMPORARILY_LOST"
            eventName = "TARGET_TEMPORARILY_LOST"

            if session then
                session.temporaryLosses = session.temporaryLosses + 1
            end
        end

    elseif stateName == "TARGET_TEMPORARILY_LOST" then
        stateName = "SEARCHING_LAST_DIRECTION"
        searchFrame = 0
        reacquireCount = 0
        eventName = "SEARCHING_LAST_DIRECTION"

        if session then
            session.searches = session.searches + 1
        end

    elseif stateName == "SEARCHING_LAST_DIRECTION" then
        searchFrame = searchFrame + 1
        decay = searchDecay(settings)

        if evaluation.acquiredSignal then
            reacquireCount = reacquireCount + 1
        else
            reacquireCount = 0
        end

        if reacquireCount >= settings.reacquireFrames then
            stateName = "REACQUIRED"
            eventName = "REACQUIRED"

            if session then
                session.reacquisitions = session.reacquisitions + 1
            end
        elseif searchFrame >= settings.memoryFrames then
            stateName = "LOST"
            eventName = "LOST"

            if session then
                session.lostEvents = session.lostEvents + 1
            end
        end

        if session then
            session.maxSearchFrames =
                math.max(session.maxSearchFrames, searchFrame)
        end

    elseif stateName == "REACQUIRED" then
        rememberedErrorX = evaluation.errorX
        rememberedErrorY = evaluation.errorY
        rememberedFrame = current.frame
        quietCount = 0
        stableCount = 0
        alignmentStartFrame = current.frame
        stateName = "ALIGNING"
        eventName = "ALIGNING"

    elseif stateName == "LOST" then
        stateName = "IDLE"
        acquireCount = 0
        stableCount = 0
        quietCount = 0
        reacquireCount = 0
        searchFrame = 0
        rememberedErrorX = 0
        rememberedErrorY = 0
        rememberedCommandX = 0
        rememberedCommandY = 0
        rememberedFrame = nil
    end

    if controllerEnabled then
        if stateName == "ALIGNING" or stateName == "ACQUIRED" then
            commandX = controllerCommand(
                evaluation.errorX,
                filteredVelocityX,
                settings.xKp,
                settings.xKd,
                settings.fineErrorX,
                settings.xSign,
                settings.maxCommand,
                settings
            )

            commandY = controllerCommand(
                evaluation.errorY,
                filteredVelocityY,
                settings.yKp,
                settings.yKd,
                settings.fineErrorY,
                settings.ySign,
                settings.maxCommand,
                settings
            )

            rememberedCommandX = commandX
            rememberedCommandY = commandY

        elseif stateName == "STABLE" then
            -- Pequena manutencao; sem comando minimo forcado.
            commandX = controllerCommand(
                evaluation.errorX,
                filteredVelocityX,
                settings.xKp * 0.45,
                settings.xKd * 0.55,
                settings.fineErrorX,
                settings.xSign,
                math.min(settings.maxCommand, 16),
                settings
            )

            commandY = controllerCommand(
                evaluation.errorY,
                filteredVelocityY,
                settings.yKp * 0.45,
                settings.yKd * 0.55,
                settings.fineErrorY,
                settings.ySign,
                math.min(settings.maxCommand, 16),
                settings
            )

            rememberedCommandX = commandX
            rememberedCommandY = commandY

        elseif stateName == "SEARCHING_LAST_DIRECTION"
            or stateName == "TARGET_TEMPORARILY_LOST" then

            decay = searchDecay(settings)

            local searchRawX =
                settings.xKp * rememberedErrorX * decay
            local searchRawY =
                settings.yKp * rememberedErrorY * decay

            commandX = clamp(
                roundSigned(searchRawX * settings.xSign),
                -settings.searchMaxCommand,
                settings.searchMaxCommand
            )

            commandY = clamp(
                roundSigned(searchRawY * settings.ySign),
                -settings.searchMaxCommand,
                settings.searchMaxCommand
            )
        end

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

        if current.frame % settings.logInterval == 0
            or eventName ~= "SAMPLE" then

            writeRow(
                eventName,
                current,
                settings,
                evaluation,
                commandX,
                commandY,
                decay
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
            .. "velocity_x=% .6f | velocity_y=% .6f\n"
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
            filteredVelocityX,
            filteredVelocityY,
            current.screenX,
            current.screenY,
            current.rawX,
            current.rawY
        )
    )

    forms.settext(
        controllerLabel,
        string.format(
            "acquired=%s | quiet=%s | enterAligned=%s | exitAligned=%s\n"
            .. "stable=%d/%d | quiet=%d/%d | reacquire=%d/%d\n"
            .. "commandX=%d | commandY=%d | signs=%d/%d\n"
            .. "acquisitions=%d",
            tostring(evaluation.acquiredSignal),
            tostring(evaluation.quietSignal),
            tostring(evaluation.enterAligned),
            tostring(evaluation.exitAligned),
            stableCount,
            settings.stableFrames,
            quietCount,
            settings.tempLostFrames,
            reacquireCount,
            settings.reacquireFrames,
            commandX,
            commandY,
            settings.xSign,
            settings.ySign,
            acquisitionCount
        )
    )

    forms.settext(
        memoryLabel,
        string.format(
            "rememberedError=(% .6f,% .6f) | rememberedCommand=(%d,%d)\n"
            .. "rememberedFrame=%s | searchFrame=%d/%d | decay=% .3f",
            rememberedErrorX,
            rememberedErrorY,
            rememberedCommandX,
            rememberedCommandY,
            tostring(rememberedFrame),
            searchFrame,
            settings.memoryFrames,
            decay
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
            "%s | e=% .3f,% .3f | cmd=%d,%d",
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

    emu.frameadvance()
end
