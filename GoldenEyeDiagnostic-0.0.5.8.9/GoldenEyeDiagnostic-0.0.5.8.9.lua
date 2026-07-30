-- GoldenEyeDiagnostic 0.0.5.8.9
-- Two-Axis Shot Reference Collector
--
-- Detecta automaticamente a borda de subida de P1 Z e registra:
-- screen_x, screen_y, normalized_horizontal, normalized_vertical,
-- raw_horizontal e raw_vertical.
--
-- Depois do tiro, o usuario classifica o disparo como:
-- HIT, MISS ou KILL.
--
-- Cada classificacao e ligada ao tiro pendente mais recente.
-- Somente leitura de memoria e leitura do controle.

local VERSION = "0.0.5.8.9"
local EXPECTED_ROM_HASH = "ABE01E4AEB033B6C0836819F549C791B26CFDE83"

local SCREEN_X_ADDRESS = 0x000D3F48
local SCREEN_Y_ADDRESS = 0x000D3F4C
local SCREEN_X_COPY_ADDRESS = 0x000D3F5C
local SCREEN_Y_COPY_ADDRESS = 0x000D3F60

local RAW_HORIZONTAL_ADDRESS = 0x000D3998
local RAW_VERTICAL_ADDRESS = 0x000D3F50
local RAW_VERTICAL_COPY_ADDRESS = 0x000D3F64

local NORMALIZED_VERTICAL_ADDRESS = 0x000D5968
local NORMALIZED_HORIZONTAL_ADDRESS = 0x000D596C

local DEFAULT_PRE_SHOT_FRAMES = 12
local DEFAULT_POST_SHOT_FRAMES = 20
local DEFAULT_LOG_INTERVAL = 1

local stopped = false
local recording = false
local pendingAction = nil
local session = nil

local previousZ = false
local pendingShot = nil
local nextShotId = 1
local preShotBuffer = {}
local postShotRemaining = 0

local form
local statusLabel
local liveLabel
local shotLabel
local statsLabel
local filesLabel
local preShotFramesBox
local postShotFramesBox
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

local function integerFromBox(box, defaultValue, minimum, maximum)
    local value = tonumber(forms.gettext(box)) or defaultValue
    value = math.floor(value + 0.5)
    if value < minimum then value = minimum end
    if value > maximum then value = maximum end
    return value
end

local function readState()
    return {
        frame = emu.framecount(),
        screenX = mainmemory.readfloat(SCREEN_X_ADDRESS, true),
        screenY = mainmemory.readfloat(SCREEN_Y_ADDRESS, true),
        screenXCopy = mainmemory.readfloat(SCREEN_X_COPY_ADDRESS, true),
        screenYCopy = mainmemory.readfloat(SCREEN_Y_COPY_ADDRESS, true),
        rawHorizontal = mainmemory.readfloat(RAW_HORIZONTAL_ADDRESS, true),
        rawVertical = mainmemory.readfloat(RAW_VERTICAL_ADDRESS, true),
        rawVerticalCopy = mainmemory.readfloat(RAW_VERTICAL_COPY_ADDRESS, true),
        normalizedVertical =
            mainmemory.readfloat(NORMALIZED_VERTICAL_ADDRESS, true),
        normalizedHorizontal =
            mainmemory.readfloat(NORMALIZED_HORIZONTAL_ADDRESS, true)
    }
end

local function readZ()
    local input = joypad.get()
    return input["P1 Z"] == true
end

local function copyState(state)
    local result = {}
    for key, value in pairs(state) do
        result[key] = value
    end
    return result
end

local function pushPreShot(state, maximum)
    table.insert(preShotBuffer, copyState(state))
    while #preShotBuffer > maximum do
        table.remove(preShotBuffer, 1)
    end
end

local function writeHeader(file)
    file:write(
        "shot_id,frame,event,outcome,relative_frame,"
        .. "screen_x,screen_y,screen_x_copy,screen_y_copy,"
        .. "raw_horizontal,raw_vertical,raw_vertical_copy,"
        .. "normalized_horizontal,normalized_vertical\n"
    )
end

local function writeRow(shotId, eventName, outcome, relativeFrame, state)
    if not session or not session.csv then return end

    session.csv:write(
        tostring(shotId or "") .. ","
        .. tostring(state.frame) .. ","
        .. tostring(eventName or "") .. ","
        .. tostring(outcome or "") .. ","
        .. tostring(relativeFrame or "") .. ","
        .. tostring(state.screenX) .. ","
        .. tostring(state.screenY) .. ","
        .. tostring(state.screenXCopy) .. ","
        .. tostring(state.screenYCopy) .. ","
        .. tostring(state.rawHorizontal) .. ","
        .. tostring(state.rawVertical) .. ","
        .. tostring(state.rawVerticalCopy) .. ","
        .. tostring(state.normalizedHorizontal) .. ","
        .. tostring(state.normalizedVertical)
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
        .. "two-axis-shot-reference-" .. timestamp .. ".csv"
    local summaryPath = OUTPUT_DIR
        .. "two-axis-shot-reference-" .. timestamp .. "-summary.txt"

    local csv = assert(io.open(csvPath, "w"))
    writeHeader(csv)

    session = {
        csv = csv,
        csvPath = csvPath,
        summaryPath = summaryPath,
        startedFrame = emu.framecount(),
        shots = {},
        counts = {HIT = 0, MISS = 0, KILL = 0, UNCLASSIFIED = 0},
        continuousRows = 0
    }

    nextShotId = 1
    pendingShot = nil
    preShotBuffer = {}
    postShotRemaining = 0

    forms.settext(
        filesLabel,
        "CSV: " .. csvPath .. "\nResumo: " .. summaryPath
    )
    setStatus("sessao iniciada")
end

local function outcomeStats(outcome)
    local rows = {}
    for _, shot in ipairs(session.shots) do
        if shot.outcome == outcome then
            table.insert(rows, shot.shotState)
        end
    end

    if #rows == 0 then return nil end

    local fields = {
        "screenX",
        "screenY",
        "rawHorizontal",
        "rawVertical",
        "normalizedHorizontal",
        "normalizedVertical"
    }

    local stats = {count = #rows}

    for _, field in ipairs(fields) do
        local minimum = rows[1][field]
        local maximum = rows[1][field]
        local total = 0

        for _, row in ipairs(rows) do
            minimum = math.min(minimum, row[field])
            maximum = math.max(maximum, row[field])
            total = total + row[field]
        end

        stats[field] = {
            min = minimum,
            max = maximum,
            mean = total / #rows
        }
    end

    return stats
end

local function stopSession()
    recording = false

    if not session then
        setStatus("nenhuma sessao")
        return
    end

    if pendingShot and pendingShot.outcome == nil then
        pendingShot.outcome = "UNCLASSIFIED"
        session.counts.UNCLASSIFIED = session.counts.UNCLASSIFIED + 1
        writeRow(
            pendingShot.id,
            "OUTCOME",
            "UNCLASSIFIED",
            0,
            pendingShot.shotState
        )
    end

    session.csv:close()
    session.csv = nil

    local summary = assert(io.open(session.summaryPath, "w"))
    summary:write("GoldenEyeDiagnostic " .. VERSION .. "\n")
    summary:write("ROM: " .. tostring(gameinfo.getromname()) .. "\n")
    summary:write("Hash: " .. tostring(gameinfo.getromhash()) .. "\n")
    summary:write("Started frame: " .. tostring(session.startedFrame) .. "\n")
    summary:write("Stopped frame: " .. tostring(emu.framecount()) .. "\n")
    summary:write("Shots captured: " .. tostring(#session.shots) .. "\n")
    summary:write("HIT: " .. tostring(session.counts.HIT) .. "\n")
    summary:write("MISS: " .. tostring(session.counts.MISS) .. "\n")
    summary:write("KILL: " .. tostring(session.counts.KILL) .. "\n")
    summary:write(
        "UNCLASSIFIED: " .. tostring(session.counts.UNCLASSIFIED) .. "\n"
    )
    summary:write(
        "Pre-shot frames: " .. forms.gettext(preShotFramesBox) .. "\n"
    )
    summary:write(
        "Post-shot frames: " .. forms.gettext(postShotFramesBox) .. "\n"
    )
    summary:write(
        "Continuous log interval: " .. forms.gettext(logIntervalBox) .. "\n"
    )
    summary:write("CSV: " .. tostring(session.csvPath) .. "\n\n")

    for _, outcome in ipairs({"HIT", "MISS", "KILL"}) do
        local stats = outcomeStats(outcome)
        summary:write(outcome .. " statistics:\n")

        if not stats then
            summary:write("Count: 0\n\n")
        else
            summary:write("Count: " .. tostring(stats.count) .. "\n")
            for _, field in ipairs({
                "screenX",
                "screenY",
                "rawHorizontal",
                "rawVertical",
                "normalizedHorizontal",
                "normalizedVertical"
            }) do
                local item = stats[field]
                summary:write(
                    field .. " min/max/mean: "
                    .. tostring(item.min) .. " / "
                    .. tostring(item.max) .. " / "
                    .. tostring(item.mean) .. "\n"
                )
            end
            summary:write("\n")
        end
    end

    summary:write("Individual shots:\n")
    for _, shot in ipairs(session.shots) do
        local s = shot.shotState
        summary:write(
            "Shot " .. tostring(shot.id)
            .. " | outcome=" .. tostring(shot.outcome or "UNCLASSIFIED")
            .. " | frame=" .. tostring(s.frame)
            .. " | screen_x=" .. tostring(s.screenX)
            .. " | screen_y=" .. tostring(s.screenY)
            .. " | raw_x=" .. tostring(s.rawHorizontal)
            .. " | raw_y=" .. tostring(s.rawVertical)
            .. " | norm_x=" .. tostring(s.normalizedHorizontal)
            .. " | norm_y=" .. tostring(s.normalizedVertical)
            .. "\n"
        )
    end

    summary:close()
    setStatus("sessao encerrada")
    session = nil
end

local function captureShot(state)
    if not session then startSession() end

    if pendingShot and pendingShot.outcome == nil then
        pendingShot.outcome = "UNCLASSIFIED"
        session.counts.UNCLASSIFIED = session.counts.UNCLASSIFIED + 1
        writeRow(
            pendingShot.id,
            "OUTCOME",
            "UNCLASSIFIED",
            0,
            pendingShot.shotState
        )
    end

    local shot = {
        id = nextShotId,
        shotState = copyState(state),
        outcome = nil
    }

    nextShotId = nextShotId + 1
    pendingShot = shot
    table.insert(session.shots, shot)

    for index, buffered in ipairs(preShotBuffer) do
        local relative = index - #preShotBuffer - 1
        writeRow(shot.id, "PRE_SHOT", "", relative, buffered)
    end

    writeRow(shot.id, "SHOT", "", 0, state)

    postShotRemaining = integerFromBox(
        postShotFramesBox,
        DEFAULT_POST_SHOT_FRAMES,
        0,
        300
    )

    forms.settext(
        shotLabel,
        string.format(
            "Tiro pendente #%d | frame=%d\n"
            .. "screen=(% .6f,% .6f) | norm=(% .6f,% .6f)\n"
            .. "raw=(% .6f,% .6f)",
            shot.id,
            state.frame,
            state.screenX,
            state.screenY,
            state.normalizedHorizontal,
            state.normalizedVertical,
            state.rawHorizontal,
            state.rawVertical
        )
    )

    setStatus("tiro #" .. tostring(shot.id) .. " capturado")
    log(
        "SHOT #" .. tostring(shot.id)
        .. " | frame=" .. tostring(state.frame)
        .. " | norm_x=" .. tostring(state.normalizedHorizontal)
        .. " | norm_y=" .. tostring(state.normalizedVertical)
    )
end

local function classifyPending(outcome)
    if not session or not pendingShot then
        setStatus("nenhum tiro pendente")
        return
    end

    if pendingShot.outcome ~= nil then
        setStatus("tiro ja classificado")
        return
    end

    pendingShot.outcome = outcome
    session.counts[outcome] = session.counts[outcome] + 1

    writeRow(
        pendingShot.id,
        "OUTCOME",
        outcome,
        0,
        pendingShot.shotState
    )

    forms.settext(
        shotLabel,
        "Tiro #" .. tostring(pendingShot.id)
        .. " classificado como " .. outcome
    )

    setStatus("resultado=" .. outcome)
    log(
        "OUTCOME #" .. tostring(pendingShot.id)
        .. " | " .. outcome
    )
end

local function processAction()
    if not pendingAction then return end

    local action = pendingAction
    pendingAction = nil

    local ok, err = pcall(function()
        if action == "START_SESSION" then
            startSession()
        elseif action == "START_RECORDING" then
            if not session then startSession() end
            recording = true
            setStatus("gravacao ativada")
        elseif action == "STOP_RECORDING" then
            recording = false
            setStatus("gravacao pausada")
        elseif action == "STOP_SESSION" then
            stopSession()
        elseif action == "MANUAL_SHOT" then
            captureShot(readState())
        elseif action == "HIT"
            or action == "MISS"
            or action == "KILL" then
            classifyPending(action)
        end
    end)

    if not ok then
        recording = false
        setStatus("erro")
        forms.settext(shotLabel, tostring(err))
        log("ERRO: " .. tostring(err))
    end
end

form = forms.newform(
    1100,
    850,
    "GoldenEyeDiagnostic " .. VERSION,
    function() stopped = true end
)

forms.label(
    form,
    "Two-Axis Shot Reference Collector",
    12, 10, 1060, 24
)

statusLabel = forms.label(
    form,
    "Status: pronto",
    12, 40, 1060, 24
)

liveLabel = forms.label(
    form,
    "Leitura ao vivo: aguardando",
    12, 75, 1060, 185, true
)

shotLabel = forms.label(
    form,
    "Tiro pendente: nenhum",
    12, 265, 1060, 105, true
)

statsLabel = forms.label(
    form,
    "Contadores: aguardando",
    12, 375, 1060, 65, true
)

filesLabel = forms.label(
    form,
    "Nenhuma sessao aberta",
    12, 445, 1060, 55, true
)

forms.label(form, "Pre-shot frames", 12, 515, 100, 22)
preShotFramesBox = forms.textbox(
    form,
    tostring(DEFAULT_PRE_SHOT_FRAMES),
    60, 24, nil, 117, 512
)

forms.label(form, "Post-shot frames", 205, 515, 105, 22)
postShotFramesBox = forms.textbox(
    form,
    tostring(DEFAULT_POST_SHOT_FRAMES),
    60, 24, nil, 315, 512
)

forms.label(form, "Intervalo log", 405, 515, 85, 22)
logIntervalBox = forms.textbox(
    form,
    tostring(DEFAULT_LOG_INTERVAL),
    60, 24, nil, 495, 512
)

forms.button(
    form,
    "INICIAR SESSAO",
    function() pendingAction = "START_SESSION" end,
    12, 565, 155, 40
)

forms.button(
    form,
    "GRAVAR",
    function() pendingAction = "START_RECORDING" end,
    180, 565, 125, 40
)

forms.button(
    form,
    "PAUSAR",
    function() pendingAction = "STOP_RECORDING" end,
    318, 565, 125, 40
)

forms.button(
    form,
    "MARCAR SHOT",
    function() pendingAction = "MANUAL_SHOT" end,
    456, 565, 145, 40
)

forms.button(
    form,
    "ENCERRAR",
    function() pendingAction = "STOP_SESSION" end,
    614, 565, 140, 40
)

forms.button(
    form,
    "HIT",
    function() pendingAction = "HIT" end,
    12, 625, 145, 45
)

forms.button(
    form,
    "MISS",
    function() pendingAction = "MISS" end,
    170, 625, 145, 45
)

forms.button(
    form,
    "KILL",
    function() pendingAction = "KILL" end,
    328, 625, 145, 45
)

forms.label(
    form,
    "Uso recomendado:\n"
    .. "1. Inicie a sessao e clique em GRAVAR.\n"
    .. "2. Pressione Z normalmente. A borda de subida de P1 Z cria automaticamente "
    .. "um registro SHOT no frame exato.\n"
    .. "3. Depois do resultado visual, clique em HIT, MISS ou KILL.\n"
    .. "4. O botao MARCAR SHOT serve como alternativa caso a leitura de P1 Z nao seja "
    .. "detectada pelo BizHawk.\n"
    .. "5. Repita pelo menos cinco acertos e cinco erros; depois clique em ENCERRAR.\n\n"
    .. "O CSV inclui os frames anteriores e posteriores a cada disparo. "
    .. "O resumo calcula min/max/media para cada resultado.",
    12, 695, 1060, 130
)

console.clear()
log("Carregado | versao=" .. VERSION)
log("ROM=" .. tostring(gameinfo.getromname()))
log("Hash=" .. tostring(gameinfo.getromhash()))

if tostring(gameinfo.getromhash()) ~= EXPECTED_ROM_HASH then
    log("AVISO | hash inesperado")
end

event.onexit(function()
    recording = false
    if session then pcall(stopSession) end
    stopped = true
end, "GoldenEyeDiagnostic-0.0.5.8.9-exit")

while not stopped do
    processAction()

    local state = readState()
    local currentZ = readZ()

    local preShotFrames = integerFromBox(
        preShotFramesBox,
        DEFAULT_PRE_SHOT_FRAMES,
        1,
        300
    )
    pushPreShot(state, preShotFrames)

    if recording and currentZ and not previousZ then
        captureShot(state)
    end

    if recording and session then
        local logInterval = integerFromBox(
            logIntervalBox,
            DEFAULT_LOG_INTERVAL,
            1,
            600
        )

        if state.frame % logInterval == 0 then
            writeRow(
                pendingShot and pendingShot.id or "",
                "SAMPLE",
                pendingShot and pendingShot.outcome or "",
                "",
                state
            )
            session.continuousRows = session.continuousRows + 1
        end
    end

    if pendingShot and postShotRemaining > 0 then
        local totalPost = integerFromBox(
            postShotFramesBox,
            DEFAULT_POST_SHOT_FRAMES,
            0,
            300
        )
        local relative = totalPost - postShotRemaining + 1
        writeRow(pendingShot.id, "POST_SHOT", "", relative, state)
        postShotRemaining = postShotRemaining - 1
    end

    forms.settext(
        liveLabel,
        string.format(
            "frame=%d | P1 Z=%s\n"
            .. "screen_x=% .6f | screen_y=% .6f\n"
            .. "screen_x_copy=% .6f | screen_y_copy=% .6f\n"
            .. "raw_horizontal=% .6f | raw_vertical=% .6f\n"
            .. "normalized_horizontal=% .6f | normalized_vertical=% .6f",
            state.frame,
            tostring(currentZ),
            state.screenX,
            state.screenY,
            state.screenXCopy,
            state.screenYCopy,
            state.rawHorizontal,
            state.rawVertical,
            state.normalizedHorizontal,
            state.normalizedVertical
        )
    )

    if session then
        forms.settext(
            statsLabel,
            string.format(
                "Shots=%d | HIT=%d | MISS=%d | KILL=%d | UNCLASSIFIED=%d\n"
                .. "Recording=%s | pending=%s",
                #session.shots,
                session.counts.HIT,
                session.counts.MISS,
                session.counts.KILL,
                session.counts.UNCLASSIFIED,
                tostring(recording),
                pendingShot
                    and ("#" .. tostring(pendingShot.id)
                        .. " " .. tostring(pendingShot.outcome or "PENDING"))
                    or "none"
            )
        )
    end

    gui.drawString(
        8, 8,
        "GoldenEyeDiagnostic " .. VERSION,
        "white", "black", 12
    )

    gui.drawString(
        8, 26,
        string.format(
            "NormX=% .4f | NormY=% .4f",
            state.normalizedHorizontal,
            state.normalizedVertical
        ),
        "white", "black", 12
    )

    previousZ = currentZ
    emu.frameadvance()
end
