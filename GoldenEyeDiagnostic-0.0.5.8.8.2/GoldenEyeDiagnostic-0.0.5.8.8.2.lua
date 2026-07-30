-- GoldenEyeDiagnostic 0.0.5.8.8.2
-- Vertical Candidate Live Validator
--
-- Leitura continua:
-- screen_y        0x000D3F4C
-- screen_y_copy   0x000D3F60
-- vertical_norm   0x000D5968
-- horizontal_norm 0x000D596C
--
-- Marcacoes manuais:
-- HEAD
-- UPPER_BODY
-- LOWER_BODY
-- SHOT
-- HIT
-- MISS
-- TARGET_LOST
--
-- Objetivo:
-- validar ao vivo quais faixas verticais acompanham o alvo e quais valores
-- aparecem em tiros que acertam ou erram.
--
-- Somente leitura de memoria.

local VERSION = "0.0.5.8.8.2"
local EXPECTED_ROM_HASH = "ABE01E4AEB033B6C0836819F549C791B26CFDE83"

local SCREEN_X_ADDRESS = 0x000D3F48
local SCREEN_Y_ADDRESS = 0x000D3F4C
local SCREEN_X_COPY_ADDRESS = 0x000D3F5C
local SCREEN_Y_COPY_ADDRESS = 0x000D3F60
local RAW_VERTICAL_ADDRESS = 0x000D3F50
local RAW_VERTICAL_COPY_ADDRESS = 0x000D3F64
local NORMALIZED_VERTICAL_ADDRESS = 0x000D5968
local NORMALIZED_HORIZONTAL_ADDRESS = 0x000D596C

local DEFAULT_LOG_INTERVAL = 1
local DEFAULT_ROLLING_FRAMES = 15

local stopped = false
local recording = false
local pendingAction = nil
local session = nil

local rolling = {}
local markerCounts = {}
local lastMarker = "NONE"

local form
local statusLabel
local liveLabel
local rollingLabel
local markerLabel
local filesLabel
local logIntervalBox
local rollingFramesBox

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
        rawVertical = mainmemory.readfloat(RAW_VERTICAL_ADDRESS, true),
        rawVerticalCopy = mainmemory.readfloat(RAW_VERTICAL_COPY_ADDRESS, true),
        normalizedVertical =
            mainmemory.readfloat(NORMALIZED_VERTICAL_ADDRESS, true),
        normalizedHorizontal =
            mainmemory.readfloat(NORMALIZED_HORIZONTAL_ADDRESS, true)
    }
end

local function pushRolling(state, maxFrames)
    table.insert(rolling, {
        frame = state.frame,
        screenY = state.screenY,
        rawVertical = state.rawVertical,
        normalizedVertical = state.normalizedVertical
    })

    while #rolling > maxFrames do
        table.remove(rolling, 1)
    end
end

local function rollingStats()
    if #rolling == 0 then
        return {
            count = 0,
            screenYMin = 0,
            screenYMax = 0,
            screenYMean = 0,
            normMin = 0,
            normMax = 0,
            normMean = 0,
            rawMin = 0,
            rawMax = 0,
            rawMean = 0
        }
    end

    local syMin, syMax = rolling[1].screenY, rolling[1].screenY
    local nMin, nMax = rolling[1].normalizedVertical,
        rolling[1].normalizedVertical
    local rMin, rMax = rolling[1].rawVertical, rolling[1].rawVertical
    local sySum, nSum, rSum = 0, 0, 0

    for _, item in ipairs(rolling) do
        syMin = math.min(syMin, item.screenY)
        syMax = math.max(syMax, item.screenY)
        nMin = math.min(nMin, item.normalizedVertical)
        nMax = math.max(nMax, item.normalizedVertical)
        rMin = math.min(rMin, item.rawVertical)
        rMax = math.max(rMax, item.rawVertical)

        sySum = sySum + item.screenY
        nSum = nSum + item.normalizedVertical
        rSum = rSum + item.rawVertical
    end

    return {
        count = #rolling,
        screenYMin = syMin,
        screenYMax = syMax,
        screenYMean = sySum / #rolling,
        normMin = nMin,
        normMax = nMax,
        normMean = nSum / #rolling,
        rawMin = rMin,
        rawMax = rMax,
        rawMean = rSum / #rolling
    }
end

local function writeHeader(file)
    file:write(
        "frame,event,last_marker,"
        .. "screen_x,screen_y,screen_x_copy,screen_y_copy,"
        .. "raw_vertical,raw_vertical_copy,"
        .. "normalized_vertical,normalized_horizontal,"
        .. "rolling_count,"
        .. "rolling_screen_y_min,rolling_screen_y_max,rolling_screen_y_mean,"
        .. "rolling_norm_y_min,rolling_norm_y_max,rolling_norm_y_mean,"
        .. "rolling_raw_y_min,rolling_raw_y_max,rolling_raw_y_mean\n"
    )
end

local function writeRow(eventName, state, stats)
    if not session or not session.csv then return end

    session.csv:write(
        tostring(state.frame) .. ","
        .. tostring(eventName or "") .. ","
        .. tostring(lastMarker) .. ","
        .. tostring(state.screenX) .. ","
        .. tostring(state.screenY) .. ","
        .. tostring(state.screenXCopy) .. ","
        .. tostring(state.screenYCopy) .. ","
        .. tostring(state.rawVertical) .. ","
        .. tostring(state.rawVerticalCopy) .. ","
        .. tostring(state.normalizedVertical) .. ","
        .. tostring(state.normalizedHorizontal) .. ","
        .. tostring(stats.count) .. ","
        .. tostring(stats.screenYMin) .. ","
        .. tostring(stats.screenYMax) .. ","
        .. tostring(stats.screenYMean) .. ","
        .. tostring(stats.normMin) .. ","
        .. tostring(stats.normMax) .. ","
        .. tostring(stats.normMean) .. ","
        .. tostring(stats.rawMin) .. ","
        .. tostring(stats.rawMax) .. ","
        .. tostring(stats.rawMean)
        .. "\n"
    )
    session.csv:flush()
end

local function updateMarkerStats(marker, state, stats)
    markerCounts[marker] = (markerCounts[marker] or 0) + 1

    session.markers[marker] = session.markers[marker] or {
        count = 0,
        normMin = nil,
        normMax = nil,
        normSum = 0,
        screenYMin = nil,
        screenYMax = nil,
        screenYSum = 0,
        rawMin = nil,
        rawMax = nil,
        rawSum = 0
    }

    local item = session.markers[marker]
    item.count = item.count + 1

    item.normMin = item.normMin
        and math.min(item.normMin, state.normalizedVertical)
        or state.normalizedVertical
    item.normMax = item.normMax
        and math.max(item.normMax, state.normalizedVertical)
        or state.normalizedVertical
    item.normSum = item.normSum + state.normalizedVertical

    item.screenYMin = item.screenYMin
        and math.min(item.screenYMin, state.screenY)
        or state.screenY
    item.screenYMax = item.screenYMax
        and math.max(item.screenYMax, state.screenY)
        or state.screenY
    item.screenYSum = item.screenYSum + state.screenY

    item.rawMin = item.rawMin
        and math.min(item.rawMin, state.rawVertical)
        or state.rawVertical
    item.rawMax = item.rawMax
        and math.max(item.rawMax, state.rawVertical)
        or state.rawVertical
    item.rawSum = item.rawSum + state.rawVertical

    item.lastRolling = stats
end

local function startSession()
    if session then
        setStatus("sessao ja iniciada")
        return
    end

    local timestamp = os.date("%Y%m%d-%H%M%S")
    local csvPath = OUTPUT_DIR
        .. "vertical-candidate-live-validator-" .. timestamp .. ".csv"
    local summaryPath = OUTPUT_DIR
        .. "vertical-candidate-live-validator-" .. timestamp .. "-summary.txt"

    local csv = assert(io.open(csvPath, "w"))
    writeHeader(csv)

    session = {
        csv = csv,
        csvPath = csvPath,
        summaryPath = summaryPath,
        startedFrame = emu.framecount(),
        rows = 0,
        markers = {}
    }

    rolling = {}
    markerCounts = {}
    lastMarker = "NONE"

    forms.settext(
        filesLabel,
        "CSV: " .. csvPath .. "\nResumo: " .. summaryPath
    )

    setStatus("sessao iniciada")
end

local function stopSession()
    recording = false

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
    summary:write("Log interval: " .. forms.gettext(logIntervalBox) .. "\n")
    summary:write("Rolling frames: " .. forms.gettext(rollingFramesBox) .. "\n")
    summary:write("CSV: " .. tostring(session.csvPath) .. "\n\n")

    summary:write("Marker statistics:\n")

    local markerOrder = {
        "HEAD",
        "UPPER_BODY",
        "LOWER_BODY",
        "SHOT",
        "HIT",
        "MISS",
        "TARGET_LOST"
    }

    for _, marker in ipairs(markerOrder) do
        local item = session.markers[marker]
        if item then
            summary:write("\n" .. marker .. "\n")
            summary:write("Count: " .. tostring(item.count) .. "\n")
            summary:write(
                "normalized_vertical min/max/mean: "
                .. tostring(item.normMin) .. " / "
                .. tostring(item.normMax) .. " / "
                .. tostring(item.normSum / item.count)
                .. "\n"
            )
            summary:write(
                "screen_y min/max/mean: "
                .. tostring(item.screenYMin) .. " / "
                .. tostring(item.screenYMax) .. " / "
                .. tostring(item.screenYSum / item.count)
                .. "\n"
            )
            summary:write(
                "raw_vertical min/max/mean: "
                .. tostring(item.rawMin) .. " / "
                .. tostring(item.rawMax) .. " / "
                .. tostring(item.rawSum / item.count)
                .. "\n"
            )
        else
            summary:write("\n" .. marker .. "\nCount: 0\n")
        end
    end

    summary:close()

    setStatus("sessao encerrada")
    session = nil
end

local function markEvent(marker)
    if not session then
        startSession()
    end

    local state = readState()
    local maxFrames = integerFromBox(
        rollingFramesBox,
        DEFAULT_ROLLING_FRAMES,
        1,
        300
    )
    pushRolling(state, maxFrames)
    local stats = rollingStats()

    lastMarker = marker
    updateMarkerStats(marker, state, stats)
    writeRow(marker, state, stats)

    forms.settext(
        markerLabel,
        string.format(
            "Ultima marcacao: %s | frame=%d\n"
            .. "norm_y=% .6f | screen_y=% .6f | raw_y=% .6f",
            marker,
            state.frame,
            state.normalizedVertical,
            state.screenY,
            state.rawVertical
        )
    )

    setStatus(marker .. " marcado")
    log(
        marker
        .. " | frame=" .. tostring(state.frame)
        .. " | norm_y=" .. tostring(state.normalizedVertical)
        .. " | screen_y=" .. tostring(state.screenY)
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
            setStatus("gravacao continua ativada")
        elseif action == "STOP_RECORDING" then
            recording = false
            setStatus("gravacao continua pausada")
        elseif action == "STOP_SESSION" then
            stopSession()
        elseif action == "CLEAR_ROLLING" then
            rolling = {}
            setStatus("janela rolante limpa")
        else
            markEvent(action)
        end
    end)

    if not ok then
        recording = false
        setStatus("erro")
        forms.settext(markerLabel, tostring(err))
        log("ERRO: " .. tostring(err))
    end
end

form = forms.newform(
    1080,
    850,
    "GoldenEyeDiagnostic " .. VERSION,
    function() stopped = true end
)

forms.label(
    form,
    "Vertical Candidate Live Validator",
    12, 10, 1040, 24
)

statusLabel = forms.label(
    form,
    "Status: pronto",
    12, 40, 1040, 24
)

liveLabel = forms.label(
    form,
    "Leitura ao vivo: aguardando",
    12, 75, 1040, 185, true
)

rollingLabel = forms.label(
    form,
    "Janela rolante: aguardando",
    12, 265, 1040, 115, true
)

markerLabel = forms.label(
    form,
    "Ultima marcacao: nenhuma",
    12, 385, 1040, 75, true
)

filesLabel = forms.label(
    form,
    "Nenhuma sessao aberta",
    12, 465, 1040, 55, true
)

forms.label(form, "Intervalo do log", 12, 535, 105, 22)
logIntervalBox = forms.textbox(
    form,
    tostring(DEFAULT_LOG_INTERVAL),
    60, 24, nil, 122, 532
)

forms.label(form, "Janela rolante", 210, 535, 95, 22)
rollingFramesBox = forms.textbox(
    form,
    tostring(DEFAULT_ROLLING_FRAMES),
    60, 24, nil, 310, 532
)

forms.button(
    form,
    "INICIAR SESSAO",
    function() pendingAction = "START_SESSION" end,
    12, 580, 155, 40
)

forms.button(
    form,
    "GRAVAR CONTINUO",
    function() pendingAction = "START_RECORDING" end,
    180, 580, 170, 40
)

forms.button(
    form,
    "PAUSAR",
    function() pendingAction = "STOP_RECORDING" end,
    363, 580, 130, 40
)

forms.button(
    form,
    "LIMPAR JANELA",
    function() pendingAction = "CLEAR_ROLLING" end,
    506, 580, 155, 40
)

forms.button(
    form,
    "ENCERRAR",
    function() pendingAction = "STOP_SESSION" end,
    674, 580, 140, 40
)

forms.button(
    form,
    "HEAD",
    function() pendingAction = "HEAD" end,
    12, 640, 120, 40
)

forms.button(
    form,
    "UPPER_BODY",
    function() pendingAction = "UPPER_BODY" end,
    145, 640, 145, 40
)

forms.button(
    form,
    "LOWER_BODY",
    function() pendingAction = "LOWER_BODY" end,
    303, 640, 145, 40
)

forms.button(
    form,
    "SHOT",
    function() pendingAction = "SHOT" end,
    461, 640, 110, 40
)

forms.button(
    form,
    "HIT",
    function() pendingAction = "HIT" end,
    584, 640, 110, 40
)

forms.button(
    form,
    "MISS",
    function() pendingAction = "MISS" end,
    707, 640, 110, 40
)

forms.button(
    form,
    "TARGET_LOST",
    function() pendingAction = "TARGET_LOST" end,
    830, 640, 150, 40
)

forms.label(
    form,
    "Uso recomendado:\n"
    .. "1. Inicie a sessao e ative GRAVAR CONTINUO.\n"
    .. "2. Marque HEAD, UPPER_BODY e LOWER_BODY enquanto o braco acompanha cada regiao.\n"
    .. "3. Marque SHOT exatamente no disparo; depois HIT ou MISS conforme o resultado visual.\n"
    .. "4. Repita varias vezes. O resumo mostrara min/max/media de normalized_vertical, "
    .. "screen_y e raw_vertical para cada marcador.\n"
    .. "5. TARGET_LOST serve para registrar o retorno ao repouso.",
    12, 705, 1040, 115
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
end, "GoldenEyeDiagnostic-0.0.5.8.8.2-exit")

while not stopped do
    processAction()

    local state = readState()
    local rollingFrames = integerFromBox(
        rollingFramesBox,
        DEFAULT_ROLLING_FRAMES,
        1,
        300
    )

    pushRolling(state, rollingFrames)
    local stats = rollingStats()

    local logInterval = integerFromBox(
        logIntervalBox,
        DEFAULT_LOG_INTERVAL,
        1,
        600
    )

    if recording and session and state.frame % logInterval == 0 then
        writeRow("SAMPLE", state, stats)
        session.rows = session.rows + 1
    end

    forms.settext(
        liveLabel,
        string.format(
            "frame=%d\n"
            .. "screen_x=% .6f | screen_y=% .6f\n"
            .. "screen_x_copy=% .6f | screen_y_copy=% .6f\n"
            .. "raw_vertical=% .6f | raw_vertical_copy=% .6f\n"
            .. "normalized_vertical=% .6f | normalized_horizontal=% .6f",
            state.frame,
            state.screenX,
            state.screenY,
            state.screenXCopy,
            state.screenYCopy,
            state.rawVertical,
            state.rawVerticalCopy,
            state.normalizedVertical,
            state.normalizedHorizontal
        )
    )

    forms.settext(
        rollingLabel,
        string.format(
            "rolling=%d frames\n"
            .. "screen_y min/max/mean=% .6f / % .6f / % .6f\n"
            .. "norm_y min/max/mean=% .6f / % .6f / % .6f\n"
            .. "raw_y min/max/mean=% .6f / % .6f / % .6f",
            stats.count,
            stats.screenYMin,
            stats.screenYMax,
            stats.screenYMean,
            stats.normMin,
            stats.normMax,
            stats.normMean,
            stats.rawMin,
            stats.rawMax,
            stats.rawMean
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
            "Y=% .3f | NormY=% .4f",
            state.screenY,
            state.normalizedVertical
        ),
        "white", "black", 12
    )

    emu.frameadvance()
end
