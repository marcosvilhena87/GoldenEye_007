-- GoldenEyeDiagnostic 0.0.5.3
-- Candidate Live Monitor
--
-- Monitora em tempo real apenas os candidatos prioritarios de posicao e rotacao.
-- Permite marcar movimentos controlados e registrar mudancas quadro a quadro.
--
-- Somente leitura via mainmemory.

local VERSION = "0.0.5.3"
local EXPECTED_ROM_HASH = "ABE01E4AEB033B6C0836819F549C791B26CFDE83"

local stopped = false
local recording = false
local pendingMarker = nil
local logFile = nil
local logPath = nil
local summaryPath = nil
local startFrame = nil
local rowsWritten = 0
local lastValues = {}
local markerHistory = {}

local form
local statusLabel
local frameLabel
local markerLabel
local valuesLabel
local resultLabel

local CANDIDATES = {
    { name = "cand_0006D188", address = 0x0006D188 },

    { name = "cam_0007994C", address = 0x0007994C },
    { name = "cam_00079950", address = 0x00079950 },
    { name = "cam_00079954", address = 0x00079954 },
    { name = "cam_00079958", address = 0x00079958 },
    { name = "cam_0007995C", address = 0x0007995C },
    { name = "cam_00079960", address = 0x00079960 },
    { name = "cam_00079964", address = 0x00079964 },
    { name = "cam_00079968", address = 0x00079968 },
    { name = "cam_0007996C", address = 0x0007996C },
    { name = "cam_00079970", address = 0x00079970 },
    { name = "cam_00079974", address = 0x00079974 },
    { name = "cam_00079978", address = 0x00079978 },
    { name = "cam_0007997C", address = 0x0007997C },
    { name = "cam_00079980", address = 0x00079980 },

    { name = "cam_000F8AD0", address = 0x000F8AD0 },
    { name = "cam_000F8AD4", address = 0x000F8AD4 },
    { name = "cam_000F8AD8", address = 0x000F8AD8 },

    { name = "cam_001052D0", address = 0x001052D0 },
    { name = "cam_001052D4", address = 0x001052D4 },
    { name = "cam_001052D8", address = 0x001052D8 },

    { name = "struct_001F25C8", address = 0x001F25C8 },
    { name = "struct_001F25CC", address = 0x001F25CC },
    { name = "struct_001F25D0", address = 0x001F25D0 },
    { name = "struct_001F25D4", address = 0x001F25D4 },
    { name = "struct_001F25D8", address = 0x001F25D8 },
    { name = "struct_001F25DC", address = 0x001F25DC },
    { name = "struct_001F25E0", address = 0x001F25E0 },
    { name = "struct_001F25E4", address = 0x001F25E4 },
    { name = "struct_001F25E8", address = 0x001F25E8 },
    { name = "struct_001F25EC", address = 0x001F25EC },
    { name = "struct_001F25F0", address = 0x001F25F0 },
    { name = "struct_001F25F4", address = 0x001F25F4 },
    { name = "struct_001F25F8", address = 0x001F25F8 },
    { name = "struct_001F25FC", address = 0x001F25FC },
    { name = "struct_001F2600", address = 0x001F2600 },
    { name = "struct_001F2604", address = 0x001F2604 },
    { name = "struct_001F2608", address = 0x001F2608 },
    { name = "struct_001F260C", address = 0x001F260C },
    { name = "struct_001F2610", address = 0x001F2610 },
    { name = "struct_001F2614", address = 0x001F2614 },
    { name = "struct_001F2618", address = 0x001F2618 }
}

local MARKERS = {
    "STOPPED",
    "ROTATE_LEFT",
    "ROTATE_RIGHT",
    "FORWARD",
    "BACKWARD",
    "STRAFE_LEFT",
    "STRAFE_RIGHT",
    "RETURN_BASE"
}

local function scriptDirectory()
    local source = debug.getinfo(1, "S").source
    if source:sub(1,1) == "@" then source = source:sub(2) end
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
    for _, c in ipairs(CANDIDATES) do
        local ok, value = pcall(function()
            return mainmemory.readfloat(c.address, true)
        end)

        values[c.name] = ok and value or 0/0
    end
    return values
end

local function changed(values)
    if not next(lastValues) then return true end

    for _, c in ipairs(CANDIDATES) do
        local a = lastValues[c.name]
        local b = values[c.name]

        if a ~= b then
            return true
        end
    end

    return false
end

local function formatValue(v)
    if v ~= v then return "NaN" end
    if v == math.huge then return "Inf" end
    if v == -math.huge then return "-Inf" end
    return string.format("%.6f", v)
end

local function shortValuesText(values)
    local lines = {}

    table.insert(lines,
        "0x0006D188=" .. formatValue(values.cand_0006D188))

    table.insert(lines,
        "0x0007994C=" .. formatValue(values.cam_0007994C)
        .. " | 0x0007995C=" .. formatValue(values.cam_0007995C)
        .. " | 0x0007996C=" .. formatValue(values.cam_0007996C)
        .. " | 0x0007997C=" .. formatValue(values.cam_0007997C))

    table.insert(lines,
        "0x000F8AD0=" .. formatValue(values.cam_000F8AD0)
        .. " | 0x000F8AD4=" .. formatValue(values.cam_000F8AD4)
        .. " | 0x000F8AD8=" .. formatValue(values.cam_000F8AD8))

    table.insert(lines,
        "0x001052D0=" .. formatValue(values.cam_001052D0)
        .. " | 0x001052D4=" .. formatValue(values.cam_001052D4)
        .. " | 0x001052D8=" .. formatValue(values.cam_001052D8))

    table.insert(lines,
        "0x001F25C8=" .. formatValue(values.struct_001F25C8)
        .. " | 0x001F25F8=" .. formatValue(values.struct_001F25F8)
        .. " | 0x001F2618=" .. formatValue(values.struct_001F2618))

    return table.concat(lines, "\n")
end

local function writeHeader()
    logFile:write("relative_frame,emu_frame,event")

    for _, c in ipairs(CANDIDATES) do
        logFile:write("," .. c.name)
    end

    logFile:write("\n")
end

local function writeRow(eventName, values)
    if not recording or not logFile then return end

    local frame = emu.framecount()
    logFile:write(
        tostring(frame - startFrame) .. ","
        .. tostring(frame) .. ","
        .. tostring(eventName or "")
    )

    for _, c in ipairs(CANDIDATES) do
        logFile:write("," .. tostring(values[c.name]))
    end

    logFile:write("\n")
    logFile:flush()
    rowsWritten = rowsWritten + 1
end

local function startRecording()
    if recording then return end

    local timestamp = os.date("%Y%m%d-%H%M%S")
    logPath = OUTPUT_DIR
        .. "candidate-live-monitor-" .. timestamp .. "-log.csv"
    summaryPath = OUTPUT_DIR
        .. "candidate-live-monitor-" .. timestamp .. "-summary.txt"

    logFile = assert(io.open(logPath, "w"))
    writeHeader()

    startFrame = emu.framecount()
    rowsWritten = 0
    markerHistory = {}
    lastValues = {}

    recording = true

    local values = readValues()
    writeRow("START", values)
    lastValues = values

    setStatus("gravando")
    forms.settext(resultLabel, "Log: " .. logPath)
    log("Gravacao iniciada | arquivo=" .. logPath)
end

local function processMarker(name)
    if not recording then
        setStatus("inicie a gravacao primeiro")
        return
    end

    local values = readValues()

    table.insert(markerHistory, {
        name = name,
        frame = emu.framecount()
    })

    writeRow(name, values)
    forms.settext(markerLabel,
        "Ultimo marcador: " .. name
        .. " | frame=" .. tostring(emu.framecount()))

    log("Marcador=" .. name
        .. " | frame=" .. tostring(emu.framecount()))
end

local function writeSummary()
    if not summaryPath then return end

    local file = assert(io.open(summaryPath, "w"))

    file:write("GoldenEyeDiagnostic " .. VERSION .. "\n")
    file:write("ROM: " .. tostring(gameinfo.getromname()) .. "\n")
    file:write("Hash: " .. tostring(gameinfo.getromhash()) .. "\n")
    file:write("Start frame: " .. tostring(startFrame) .. "\n")
    file:write("Rows written: " .. tostring(rowsWritten) .. "\n")
    file:write("Log: " .. tostring(logPath) .. "\n\n")

    file:write("Candidates:\n")
    for _, c in ipairs(CANDIDATES) do
        file:write(
            c.name
            .. " | address=0x"
            .. string.format("%08X", c.address)
            .. " | type=float32_be\n"
        )
    end

    file:write("\nMarkers:\n")
    for _, m in ipairs(markerHistory) do
        file:write(
            m.name
            .. " | frame="
            .. tostring(m.frame)
            .. "\n"
        )
    end

    file:close()
end

local function stopRecording()
    if not recording then return end

    local values = readValues()
    writeRow("STOP", values)

    recording = false

    if logFile then
        logFile:flush()
        logFile:close()
        logFile = nil
    end

    writeSummary()

    setStatus("gravacao encerrada")
    forms.settext(resultLabel,
        "Resumo: " .. tostring(summaryPath))

    log("Gravacao encerrada")
end

form = forms.newform(
    940,
    650,
    "GoldenEyeDiagnostic " .. VERSION,
    function()
        stopped = true
    end
)

forms.label(form,
    "Candidate Live Monitor — candidatos prioritarios",
    12, 10, 900, 24)

statusLabel = forms.label(form,
    "Status: pronto", 12, 40, 900, 24)

frameLabel = forms.label(form,
    "Frame: 0", 12, 70, 900, 24)

markerLabel = forms.label(form,
    "Ultimo marcador: nenhum", 12, 100, 900, 24)

valuesLabel = forms.label(form,
    "Valores: aguardando",
    12, 130, 900, 150, true)

resultLabel = forms.label(form,
    "Nenhuma gravacao iniciada",
    12, 285, 900, 48, true)

forms.button(form, "INICIAR",
    startRecording,
    12, 350, 120, 36)

forms.button(form, "ENCERRAR",
    stopRecording,
    145, 350, 120, 36)

local x1 = 12
local y1 = 405
local width = 140
local gap = 10

for i, marker in ipairs(MARKERS) do
    local col = (i - 1) % 4
    local row = math.floor((i - 1) / 4)

    forms.button(form, marker,
        function()
            pendingMarker = marker
        end,
        x1 + col * (width + gap),
        y1 + row * 48,
        width,
        36)
end

forms.label(form,
    "Procedimento:\n"
    .. "1. Clique em INICIAR e mantenha Bond parado; marque STOPPED.\n"
    .. "2. Gire para a esquerda e marque ROTATE_LEFT.\n"
    .. "3. Gire para a direita e marque ROTATE_RIGHT.\n"
    .. "4. Ande para frente e para tras, marcando FORWARD/BACKWARD.\n"
    .. "5. Faça strafe para esquerda e direita.\n"
    .. "6. Volte aproximadamente ao ponto inicial e marque RETURN_BASE.\n"
    .. "7. Clique em ENCERRAR e envie o log CSV e o resumo.\n\n"
    .. "O CSV registra todas as mudancas dos candidatos, permitindo verificar "
    .. "continuidade, reversao e retorno ao valor inicial.",
    12, 510, 900, 120)

console.clear()
log("Carregado | versao=" .. VERSION)
log("ROM=" .. tostring(gameinfo.getromname()))
log("Hash=" .. tostring(gameinfo.getromhash()))

if tostring(gameinfo.getromhash()) ~= EXPECTED_ROM_HASH then
    log("AVISO | hash inesperado")
end

event.onexit(function()
    if recording then
        stopRecording()
    end
    stopped = true
end, "GoldenEyeDiagnostic-0.0.5.3-exit")

while not stopped do
    if pendingMarker then
        local marker = pendingMarker
        pendingMarker = nil
        processMarker(marker)
    end

    local values = readValues()

    forms.settext(frameLabel,
        "Frame: " .. tostring(emu.framecount())
        .. " | gravando=" .. tostring(recording)
        .. " | linhas=" .. tostring(rowsWritten))

    forms.settext(valuesLabel,
        shortValuesText(values))

    if recording and changed(values) then
        writeRow("CHANGE", values)
        lastValues = values
    end

    gui.drawString(
        8, 8,
        "GoldenEyeDiagnostic " .. VERSION,
        "white", "black", 12
    )

    gui.drawString(
        8, 26,
        "0x0006D188="
        .. formatValue(values.cand_0006D188),
        "white", "black", 12
    )

    emu.yield()
end
