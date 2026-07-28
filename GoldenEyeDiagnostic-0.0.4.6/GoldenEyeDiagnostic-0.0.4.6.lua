-- GoldenEyeDiagnostic 0.0.4.6
-- Soldier Candidate Validation
-- Somente leitura via mainmemory.
--
-- Observa candidatos em tempo real e registra marcacoes manuais:
-- LIVE, HIT e DEAD.
--
-- Candidatos iniciais:
--   0x00030A37  possivel estado 0/1/2
--   0x00030A6B  possivel flag de morte 0/0/1
--   0x0003CB7F  possivel flag de acerto 0/1/1
--   0x001F421C  possivel ponteiro zerado na morte
--   0x001E015C  candidato auxiliar

local VERSION = "0.0.4.6"
local EXPECTED_ROM_HASH = "ABE01E4AEB033B6C0836819F549C791B26CFDE83"

local SAMPLE_INTERVAL = 1
local MAX_LOG_ROWS = 200000

local stopped = false
local recording = false
local logFile = nil
local summaryPath = nil
local logPath = nil
local startFrame = nil
local rowsWritten = 0
local lastValues = {}
local markers = {}

local form
local statusLabel
local frameLabel
local valuesLabel
local resultLabel

local CANDIDATES = {
    { name = "state_30A37", address = 0x00030A37, kind = "u8" },
    { name = "death_30A6B", address = 0x00030A6B, kind = "u8" },
    { name = "hit_3CB7F", address = 0x0003CB7F, kind = "u8" },
    { name = "ptr_1F421C", address = 0x001F421C, kind = "u32be" },
    { name = "aux_1E015C", address = 0x001E015C, kind = "u8" }
}

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

local function readCandidate(candidate)
    if candidate.kind == "u32be" then
        if mainmemory.read_u32_be then
            return mainmemory.read_u32_be(candidate.address)
        end

        local b0 = mainmemory.read_u8(candidate.address)
        local b1 = mainmemory.read_u8(candidate.address + 1)
        local b2 = mainmemory.read_u8(candidate.address + 2)
        local b3 = mainmemory.read_u8(candidate.address + 3)

        return b0 * 0x1000000
            + b1 * 0x10000
            + b2 * 0x100
            + b3
    end

    return mainmemory.read_u8(candidate.address)
end

local function readAll()
    local values = {}

    for _, candidate in ipairs(CANDIDATES) do
        values[candidate.name] = readCandidate(candidate)
    end

    return values
end

local function formatValue(candidate, value)
    if candidate.kind == "u32be" then
        return string.format("0x%08X", value)
    end

    return tostring(value)
end

local function valuesToText(values)
    local parts = {}

    for _, candidate in ipairs(CANDIDATES) do
        table.insert(parts,
            candidate.name .. "="
            .. formatValue(candidate, values[candidate.name]))
    end

    return table.concat(parts, " | ")
end

local function valuesChanged(values)
    if not next(lastValues) then
        return true
    end

    for _, candidate in ipairs(CANDIDATES) do
        if values[candidate.name] ~= lastValues[candidate.name] then
            return true
        end
    end

    return false
end

local function writeHeader()
    logFile:write(
        "relative_frame,emu_frame,event,"
        .. "state_30A37,death_30A6B,hit_3CB7F,"
        .. "ptr_1F421C,aux_1E015C\n"
    )
end

local function writeRow(eventName, values)
    if not recording or not logFile then
        return
    end

    if rowsWritten >= MAX_LOG_ROWS then
        setStatus("limite de linhas atingido")
        recording = false
        return
    end

    local emuFrame = emu.framecount()
    local relativeFrame = emuFrame - startFrame

    logFile:write(
        tostring(relativeFrame) .. ","
        .. tostring(emuFrame) .. ","
        .. tostring(eventName or "") .. ","
        .. tostring(values.state_30A37) .. ","
        .. tostring(values.death_30A6B) .. ","
        .. tostring(values.hit_3CB7F) .. ","
        .. string.format("0x%08X", values.ptr_1F421C) .. ","
        .. tostring(values.aux_1E015C) .. "\n"
    )

    logFile:flush()
    rowsWritten = rowsWritten + 1
end

local function startRecording()
    if recording then
        return
    end

    local timestamp = os.date("%Y%m%d-%H%M%S")
    logPath = OUTPUT_DIR
        .. "candidate-validation-" .. timestamp .. "-log.csv"
    summaryPath = OUTPUT_DIR
        .. "candidate-validation-" .. timestamp .. "-summary.txt"

    logFile = assert(io.open(logPath, "w"))
    writeHeader()

    startFrame = emu.framecount()
    rowsWritten = 0
    markers = {}
    lastValues = {}

    local values = readAll()
    writeRow("START", values)
    lastValues = values

    recording = true
    setStatus("gravando")
    forms.settext(resultLabel, "Log: " .. logPath)
    log("Gravacao iniciada | arquivo=" .. logPath)
end

local function markState(name)
    local values = readAll()
    markers[name] = {
        frame = emu.framecount(),
        values = values
    }

    writeRow(name, values)
    forms.settext(resultLabel,
        name .. " marcado | " .. valuesToText(values))
    log("Marcador=" .. name
        .. " | frame=" .. tostring(emu.framecount())
        .. " | " .. valuesToText(values))
end

local function writeSummary()
    if not summaryPath then
        return
    end

    local file = assert(io.open(summaryPath, "w"))

    file:write("GoldenEyeDiagnostic " .. VERSION .. "\n")
    file:write("ROM: " .. tostring(gameinfo.getromname()) .. "\n")
    file:write("Hash: " .. tostring(gameinfo.getromhash()) .. "\n")
    file:write("API: mainmemory\n")
    file:write("Start frame: " .. tostring(startFrame) .. "\n")
    file:write("Rows written: " .. tostring(rowsWritten) .. "\n")
    file:write("Log: " .. tostring(logPath) .. "\n\n")

    file:write("Candidates:\n")
    for _, candidate in ipairs(CANDIDATES) do
        file:write(candidate.name
            .. " | address=0x"
            .. string.format("%08X", candidate.address)
            .. " | kind=" .. candidate.kind .. "\n")
    end

    file:write("\nMarkers:\n")
    for _, markerName in ipairs({"LIVE", "HIT", "DEAD"}) do
        local marker = markers[markerName]

        if marker then
            file:write(markerName
                .. " | frame=" .. tostring(marker.frame)
                .. " | " .. valuesToText(marker.values) .. "\n")
        else
            file:write(markerName .. " | NAO_MARCADO\n")
        end
    end

    local verdict = "INCONCLUSIVO"

    if markers.LIVE and markers.HIT and markers.DEAD then
        local live = markers.LIVE.values
        local hit = markers.HIT.values
        local dead = markers.DEAD.values

        local score = 0
        local evidence = {}

        if live.state_30A37 == 0
            and hit.state_30A37 == 1
            and dead.state_30A37 == 2 then
            score = score + 3
            table.insert(evidence, "state_30A37=0/1/2")
        end

        if live.death_30A6B == 0
            and hit.death_30A6B == 0
            and dead.death_30A6B == 1 then
            score = score + 3
            table.insert(evidence, "death_30A6B=0/0/1")
        end

        if live.hit_3CB7F == 0
            and hit.hit_3CB7F == 1
            and dead.hit_3CB7F == 1 then
            score = score + 2
            table.insert(evidence, "hit_3CB7F=0/1/1")
        end

        if live.ptr_1F421C ~= 0
            and hit.ptr_1F421C ~= 0
            and dead.ptr_1F421C == 0 then
            score = score + 2
            table.insert(evidence, "ptr_1F421C=nonzero/nonzero/zero")
        end

        if score >= 7 then
            verdict = "VALIDADO_FORTE"
        elseif score >= 4 then
            verdict = "VALIDADO_PARCIAL"
        else
            verdict = "REPROVADO_OU_INSTAVEL"
        end

        file:write("\nAutomatic evaluation:\n")
        file:write("Score: " .. tostring(score) .. "/10\n")
        file:write("Evidence: " .. table.concat(evidence, "; ") .. "\n")
    end

    file:write("\nVerdict: " .. verdict .. "\n")
    file:close()

    log("Resumo=" .. summaryPath)
end

local function stopRecording()
    if not recording and not logFile then
        return
    end

    local values = readAll()

    if recording then
        writeRow("STOP", values)
    end

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
    860,
    460,
    "GoldenEyeDiagnostic " .. VERSION,
    function()
        stopped = true
    end
)

forms.label(form,
    "Soldier Candidate Validation — monitoramento em tempo real",
    12, 10, 820, 24)

statusLabel = forms.label(form,
    "Status: pronto", 12, 40, 820, 24)

frameLabel = forms.label(form,
    "Frame: 0", 12, 70, 820, 24)

valuesLabel = forms.label(form,
    "Valores: aguardando", 12, 100, 820, 70, true)

resultLabel = forms.label(form,
    "Nenhuma gravacao iniciada",
    12, 175, 820, 46, true)

forms.button(form, "1. INICIAR",
    startRecording,
    12, 240, 120, 36)

forms.button(form, "2. MARCAR LIVE",
    function()
        markState("LIVE")
    end,
    142, 240, 140, 36)

forms.button(form, "3. MARCAR HIT",
    function()
        markState("HIT")
    end,
    292, 240, 140, 36)

forms.button(form, "4. MARCAR DEAD",
    function()
        markState("DEAD")
    end,
    442, 240, 150, 36)

forms.button(form, "5. ENCERRAR",
    stopRecording,
    602, 240, 130, 36)

forms.label(form,
    "Procedimento:\n"
    .. "• Inicie a gravacao antes do combate.\n"
    .. "• Com o soldado vivo e a cena estabilizada, marque LIVE.\n"
    .. "• Acerte sem matar e marque HIT.\n"
    .. "• Mate o mesmo soldado e marque DEAD.\n"
    .. "• Encerre para gerar log e resumo.\n\n"
    .. "Repita depois de recarregar o mesmo savestate para validar estabilidade.",
    12, 300, 820, 135)

console.clear()
log("Carregado | versao=" .. VERSION)
log("ROM=" .. tostring(gameinfo.getromname()))
log("Hash=" .. tostring(gameinfo.getromhash()))

local currentHash = tostring(gameinfo.getromhash())
if currentHash ~= EXPECTED_ROM_HASH then
    log("AVISO | hash esperado=" .. EXPECTED_ROM_HASH
        .. " | atual=" .. currentHash)
end

event.onexit(function()
    if logFile then
        stopRecording()
    end
    stopped = true
end, "GoldenEyeDiagnostic-0.0.4.6-exit")

while not stopped do
    local values = readAll()
    local frame = emu.framecount()

    forms.settext(frameLabel,
        "Frame: " .. tostring(frame)
        .. " | gravando=" .. tostring(recording)
        .. " | linhas=" .. tostring(rowsWritten))

    forms.settext(valuesLabel,
        "Valores: " .. valuesToText(values))

    if recording
        and frame % SAMPLE_INTERVAL == 0
        and valuesChanged(values) then
        writeRow("CHANGE", values)
        lastValues = values
    end

    gui.drawString(8, 8,
        "GoldenEyeDiagnostic " .. VERSION,
        "white", "black", 12)

    gui.drawString(8, 26,
        "state=" .. tostring(values.state_30A37)
        .. " death=" .. tostring(values.death_30A6B)
        .. " hit=" .. tostring(values.hit_3CB7F),
        "white", "black", 12)

    emu.yield()
end
