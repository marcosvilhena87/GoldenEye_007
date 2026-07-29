-- GoldenEyeDiagnostic 0.0.5.6.2
-- Arm Aim Live Validation
--
-- Monitora ao vivo os candidatos horizontais encontrados:
-- 0x000D3998
-- 0x000D3D40
-- 0x000D3DD0
-- 0x000D3F48
-- 0x000D3F5C
-- 0x000D596C
--
-- Marcadores:
-- CENTER
-- AUTO_AIM_LEFT
-- AUTO_AIM_RIGHT
-- TARGET_LOST
-- SHOT
--
-- Somente leitura via mainmemory.

local VERSION = "0.0.5.6.2"
local EXPECTED_ROM_HASH = "ABE01E4AEB033B6C0836819F549C791B26CFDE83"

local CANDIDATES = {
    {name = "raw_horizontal", address = 0x000D3998},
    {name = "raw_offset", address = 0x000D3D40},
    {name = "related", address = 0x000D3DD0},
    {name = "screen_x", address = 0x000D3F48},
    {name = "screen_x_copy", address = 0x000D3F5C},
    {name = "normalized", address = 0x000D596C}
}

local SCREEN_CENTER_X = 160.0
local CENTER_TOLERANCE = 3.0
local CHANGE_EPSILON = 0.0001

local stopped = false
local recording = false
local pendingMarker = nil
local session = nil
local lastValues = nil

local form
local statusLabel
local valuesLabel
local interpretationLabel
local filesLabel

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

local function readValues()
    local values = {}

    for i, candidate in ipairs(CANDIDATES) do
        values[i] = mainmemory.readfloat(candidate.address, true)
    end

    return values
end

local function valuesText(values)
    local lines = {}

    for i, candidate in ipairs(CANDIDATES) do
        table.insert(
            lines,
            string.format(
                "%-14s 0x%08X = % .6f",
                candidate.name,
                candidate.address,
                values[i]
            )
        )
    end

    return table.concat(lines, "\n")
end

local function classify(values)
    local screenX = values[4]
    local normalized = values[6]

    if math.abs(screenX - SCREEN_CENTER_X) <= CENTER_TOLERANCE then
        return "ARM_CENTERED"
    end

    if screenX < SCREEN_CENTER_X then
        return "ARM_LEFT"
    end

    if screenX > SCREEN_CENTER_X then
        return "ARM_RIGHT"
    end

    if normalized > 0 then
        return "ARM_LEFT_NORMALIZED"
    elseif normalized < 0 then
        return "ARM_RIGHT_NORMALIZED"
    end

    return "ARM_UNKNOWN"
end

local function hasChanged(values)
    if not lastValues then
        return true
    end

    for i = 1, #values do
        if math.abs(values[i] - lastValues[i]) > CHANGE_EPSILON then
            return true
        end
    end

    return false
end

local function writeHeader(file)
    file:write("frame,event,classification")

    for _, candidate in ipairs(CANDIDATES) do
        file:write("," .. candidate.name)
    end

    file:write("\n")
end

local function writeRow(eventName, values)
    if not recording or not session or not session.csv then
        return
    end

    session.csv:write(
        tostring(emu.framecount())
        .. ","
        .. tostring(eventName or "")
        .. ","
        .. classify(values)
    )

    for i = 1, #values do
        session.csv:write("," .. tostring(values[i]))
    end

    session.csv:write("\n")
    session.csv:flush()
end

local function startRecording()
    if recording then
        setStatus("gravacao ja ativa")
        return
    end

    local timestamp = os.date("%Y%m%d-%H%M%S")
    local csvPath = OUTPUT_DIR
        .. "arm-aim-live-" .. timestamp .. ".csv"
    local summaryPath = OUTPUT_DIR
        .. "arm-aim-live-" .. timestamp .. "-summary.txt"

    local csv = assert(io.open(csvPath, "w"))
    writeHeader(csv)

    session = {
        csv = csv,
        csvPath = csvPath,
        summaryPath = summaryPath,
        startedFrame = emu.framecount(),
        markerCounts = {},
        minValues = {},
        maxValues = {},
        firstValues = nil,
        lastValues = nil,
        rows = 0
    }

    recording = true
    lastValues = nil

    local values = readValues()
    session.firstValues = values
    writeRow("START", values)

    setStatus("gravando")
    forms.settext(
        filesLabel,
        "CSV: " .. csvPath
        .. "\nResumo: " .. summaryPath
    )

    log("Gravacao iniciada | frame=" .. tostring(emu.framecount()))
end

local function updateStats(values)
    if not session then
        return
    end

    for i = 1, #values do
        if session.minValues[i] == nil
            or values[i] < session.minValues[i] then
            session.minValues[i] = values[i]
        end

        if session.maxValues[i] == nil
            or values[i] > session.maxValues[i] then
            session.maxValues[i] = values[i]
        end
    end

    session.lastValues = values
    session.rows = session.rows + 1
end

local function stopRecording()
    if not recording or not session then
        setStatus("nenhuma gravacao ativa")
        return
    end

    local values = readValues()
    writeRow("STOP", values)
    updateStats(values)

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
    summary:write("CSV: " .. tostring(session.csvPath) .. "\n\n")

    summary:write("Marker counts:\n")
    for _, marker in ipairs({
        "CENTER",
        "AUTO_AIM_LEFT",
        "AUTO_AIM_RIGHT",
        "TARGET_LOST",
        "SHOT"
    }) do
        summary:write(
            marker .. ": "
            .. tostring(session.markerCounts[marker] or 0)
            .. "\n"
        )
    end

    summary:write("\nCandidate ranges:\n")
    for i, candidate in ipairs(CANDIDATES) do
        summary:write(
            candidate.name
            .. " | address="
            .. string.format("0x%08X", candidate.address)
            .. " | min=" .. tostring(session.minValues[i])
            .. " | max=" .. tostring(session.maxValues[i])
            .. " | first="
            .. tostring(session.firstValues and session.firstValues[i])
            .. " | last="
            .. tostring(session.lastValues and session.lastValues[i])
            .. "\n"
        )
    end

    summary:close()

    recording = false
    setStatus("gravacao encerrada")

    log(
        "Gravacao encerrada | csv=" .. session.csvPath
        .. " | resumo=" .. session.summaryPath
    )
end

local function processMarker()
    if not pendingMarker then
        return
    end

    local marker = pendingMarker
    pendingMarker = nil

    if not recording or not session then
        setStatus("inicie a gravacao antes de marcar")
        return
    end

    local values = readValues()
    writeRow(marker, values)
    updateStats(values)

    session.markerCounts[marker] =
        (session.markerCounts[marker] or 0) + 1

    setStatus("marcador " .. marker)
    log("Marcador=" .. marker
        .. " | frame=" .. tostring(emu.framecount()))
end

form = forms.newform(
    930,
    650,
    "GoldenEyeDiagnostic " .. VERSION,
    function()
        stopped = true
    end
)

forms.label(
    form,
    "Arm Aim Live Validation — primeiro soldado",
    12,
    10,
    890,
    24
)

statusLabel = forms.label(
    form,
    "Status: pronto",
    12,
    40,
    890,
    24
)

valuesLabel = forms.label(
    form,
    "Valores: aguardando",
    12,
    75,
    890,
    170,
    true
)

interpretationLabel = forms.label(
    form,
    "Interpretacao: aguardando",
    12,
    250,
    890,
    45,
    true
)

filesLabel = forms.label(
    form,
    "Nenhum arquivo aberto",
    12,
    300,
    890,
    55,
    true
)

forms.button(
    form,
    "INICIAR",
    function()
        if not recording then
            startRecording()
        end
    end,
    12,
    380,
    120,
    38
)

forms.button(
    form,
    "ENCERRAR",
    function()
        if recording then
            stopRecording()
        end
    end,
    145,
    380,
    120,
    38
)

local markerButtons = {
    {"CENTER", 12, 440},
    {"AUTO_AIM_LEFT", 155, 440},
    {"AUTO_AIM_RIGHT", 318, 440},
    {"TARGET_LOST", 501, 440},
    {"SHOT", 654, 440}
}

for _, item in ipairs(markerButtons) do
    forms.button(
        form,
        item[1],
        function()
            pendingMarker = item[1]
        end,
        item[2],
        item[3],
        140,
        38
    )
end

forms.label(
    form,
    "Procedimento:\n"
    .. "1. Carregue o savestate antes do primeiro soldado.\n"
    .. "2. Clique em INICIAR.\n"
    .. "3. Marque CENTER quando o braco estiver centralizado.\n"
    .. "4. Quando o auto-aim puxar o braco para a esquerda, marque AUTO_AIM_LEFT.\n"
    .. "5. Quando puxar para a direita, marque AUTO_AIM_RIGHT.\n"
    .. "6. Quando o soldado sair do auto-aim e o braco retornar, marque TARGET_LOST.\n"
    .. "7. Ao disparar, marque SHOT.\n"
    .. "8. Clique em ENCERRAR e envie o CSV e o resumo.\n\n"
    .. "O endereco 0x000D3F48 e interpretado provisoriamente como coordenada "
    .. "horizontal da arma: aproximadamente 160=center, menor=esquerda, maior=direita.",
    12,
    500,
    890,
    125
)

console.clear()
log("Carregado | versao=" .. VERSION)
log("ROM=" .. tostring(gameinfo.getromname()))
log("Hash=" .. tostring(gameinfo.getromhash()))

if tostring(gameinfo.getromhash()) ~= EXPECTED_ROM_HASH then
    log("AVISO | hash inesperado")
end

event.onexit(function()
    if recording then
        pcall(stopRecording)
    end
    stopped = true
end, "GoldenEyeDiagnostic-0.0.5.6.2-exit")

while not stopped do
    processMarker()

    local values = readValues()
    local classification = classify(values)

    forms.settext(
        valuesLabel,
        "Valores atuais:\n" .. valuesText(values)
    )

    forms.settext(
        interpretationLabel,
        string.format(
            "Interpretacao: %s | screen_x=% .3f | desvio=% .3f",
            classification,
            values[4],
            values[4] - SCREEN_CENTER_X
        )
    )

    if recording and hasChanged(values) then
        writeRow("", values)
        updateStats(values)

        lastValues = {}
        for i = 1, #values do
            lastValues[i] = values[i]
        end
    end

    gui.drawString(
        8,
        8,
        "GoldenEyeDiagnostic " .. VERSION,
        "white",
        "black",
        12
    )

    gui.drawString(
        8,
        26,
        classification,
        "white",
        "black",
        12
    )

    emu.yield()
end
