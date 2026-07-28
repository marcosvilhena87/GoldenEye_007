-- GoldenEyeDiagnostic 0.0.3
-- Replay Validation para GoldenEye 007 (N64) no BizHawk.
--
-- Reproduz a demonstracao gravada, apresenta checkpoints esperados e permite
-- confirmar visualmente chegada, alinhamento do tiro, morte e divergencia.
-- Nao le nem escreve na memoria do jogo.

local VERSION = "0.0.3"
local CONTROLLER = 1
local EXPECTED_ROM_HASH = "ABE01E4AEB033B6C0836819F549C791B26CFDE83"

local stopped = false
local replaying = false
local replayFinished = false
local selectedCsvPath = nil
local replayRows = {}
local replayIndex = 1
local replayStartEmuFrame = nil
local logFile = nil
local logPath = nil
local validationPath = nil
local expected = {}
local confirmations = {}
local observations = {}
local verdictWritten = false

local function scriptDirectory()
    local source = debug.getinfo(1, "S").source
    if string.sub(source, 1, 1) == "@" then source = string.sub(source, 2) end
    return source:match("^(.*[\\/])") or ".\\"
end

local BASE_DIR = scriptDirectory()
local DEMO_DIR = BASE_DIR .. "demonstrations\\"
local OUTPUT_DIR = BASE_DIR .. "output\\"
local DEFAULT_CSV = DEMO_DIR .. "session-20260727-234451-frames.csv"

os.execute('if not exist "' .. OUTPUT_DIR .. '" mkdir "' .. OUTPUT_DIR .. '"')

local function fileExists(path)
    local f = io.open(path, "r")
    if f then f:close(); return true end
    return false
end

local function parseCsvLine(line)
    local fields, field, inQuotes = {}, "", false
    local i = 1
    while i <= #line do
        local c = line:sub(i, i)
        if inQuotes then
            if c == '"' then
                if line:sub(i + 1, i + 1) == '"' then
                    field = field .. '"'
                    i = i + 1
                else
                    inQuotes = false
                end
            else
                field = field .. c
            end
        else
            if c == '"' then
                inQuotes = true
            elseif c == "," then
                table.insert(fields, field)
                field = ""
            else
                field = field .. c
            end
        end
        i = i + 1
    end
    table.insert(fields, field)
    return fields
end

local function parseInputState(text)
    local digital, analog = {}, {}
    for pair in string.gmatch(text or "", "([^;]+)") do
        local name, raw = pair:match("^(.-)=(.*)$")
        if name then
            if name == "X Axis" or name == "Y Axis" then
                analog[name] = tonumber(raw) or 0
            else
                digital[name] = (raw == "1" or raw == "true")
            end
        end
    end
    return digital, analog
end

local function loadReplay(path)
    local f, err = io.open(path, "r")
    if not f then return nil, "Nao foi possivel abrir o CSV: " .. tostring(err) end
    if not f:read("*l") then f:close(); return nil, "CSV vazio." end

    local allRows, startPos, endPos = {}, nil, nil
    for line in f:lines() do
        if line ~= "" then
            local fields = parseCsvLine(line)
            if #fields >= 6 then
                local row = {
                    frame = tonumber(fields[1]) or 0,
                    relativeFrame = tonumber(fields[2]) or 0,
                    isLagged = tonumber(fields[3]) or 0,
                    lagCount = tonumber(fields[4]) or 0,
                    event = fields[5] or "",
                    inputState = fields[6] or ""
                }
                row.digital, row.analog = parseInputState(row.inputState)
                table.insert(allRows, row)
                if row.event == "START" and not startPos then startPos = #allRows end
                if row.event == "SOLDIER_DEAD" and not endPos then endPos = #allRows end
            end
        end
    end
    f:close()

    if not startPos then return nil, "Marcador START ausente." end
    endPos = endPos or #allRows

    local useful = {}
    expected = {}
    for i = startPos, endPos do
        local row = allRows[i]
        table.insert(useful, row)
        if row.event ~= "" then
            expected[row.event] = {
                replayIndex = #useful,
                sourceRelativeFrame = row.relativeFrame
            }
        end
    end
    return useful, nil
end

local function clearController()
    local released = {}
    for _, row in ipairs(replayRows) do
        for name, _ in pairs(row.digital or {}) do released[name] = false end
    end
    joypad.set(released, CONTROLLER)
    joypad.setanalog({ ["X Axis"] = 0, ["Y Axis"] = 0 }, CONTROLLER)
end

local statusLabel, csvLabel, progressLabel, checkpointLabel, resultLabel, notesBox
local form

local function setStatus(text)
    if statusLabel then forms.settext(statusLabel, "Status: " .. text) end
end

local function setResult(text)
    if resultLabel then forms.settext(resultLabel, "Validacao: " .. text) end
end

local function updateProgress()
    if progressLabel then
        forms.settext(progressLabel,
            "Progresso: " .. tostring(math.min(replayIndex, #replayRows)) ..
            " / " .. tostring(#replayRows))
    end
end

local function currentReplayIndex()
    if replaying then return math.max(1, replayIndex - 1) end
    return math.min(replayIndex, #replayRows)
end

local function recordObservation(kind, value)
    local idx = currentReplayIndex()
    local emuFrame = emu.framecount()
    observations[kind] = observations[kind] or {}
    table.insert(observations[kind], {
        value = value,
        replayIndex = idx,
        emuFrame = emuFrame
    })
    console.log("[GoldenEyeDiagnostic] Observacao=" .. kind ..
        " | valor=" .. tostring(value) ..
        " | replayIndex=" .. tostring(idx) ..
        " | emuFrame=" .. tostring(emuFrame))
end

local function confirmEvent(name)
    local idx = currentReplayIndex()
    local expectedInfo = expected[name]
    confirmations[name] = {
        replayIndex = idx,
        emuFrame = emu.framecount(),
        offset = expectedInfo and (idx - expectedInfo.replayIndex) or nil
    }
    local offsetText = confirmations[name].offset and
        tostring(confirmations[name].offset) or "n/a"
    setResult(name .. " confirmado | desvio=" .. offsetText .. " frames")
    recordObservation("CONFIRM_" .. name, true)
end

local function classifyVerdict()
    if observations.ROUTE_DIVERGENCE then
        return "REPROVADO_ROUTE_DIVERGENCE"
    end

    local arrived = observations.ARRIVED and
        observations.ARRIVED[#observations.ARRIVED].value
    local shotAligned = observations.SHOT_ALIGNED and
        observations.SHOT_ALIGNED[#observations.SHOT_ALIGNED].value
    local dead = observations.SOLDIER_DEAD_VISUAL and
        observations.SOLDIER_DEAD_VISUAL[#observations.SOLDIER_DEAD_VISUAL].value

    if dead == true and arrived ~= false and shotAligned ~= false then
        return "APROVADO_SOLDIER_DEAD"
    elseif arrived == true and dead == false then
        return "PARCIAL_ROUTE_OK_COMBAT_FAILED"
    elseif arrived == false then
        return "REPROVADO_DID_NOT_ARRIVE"
    elseif shotAligned == false then
        return "PARCIAL_AIM_DIVERGENCE"
    end
    return "INCONCLUSIVO"
end

local function writeValidation()
    if verdictWritten then return end
    verdictWritten = true

    local timestamp = os.date("%Y%m%d-%H%M%S")
    validationPath = OUTPUT_DIR .. "validation-" .. timestamp .. "-summary.txt"
    local f = io.open(validationPath, "w")
    if not f then return end

    local notes = notesBox and forms.gettext(notesBox) or ""
    local verdict = classifyVerdict()

    f:write("GoldenEyeDiagnostic " .. VERSION .. "\n")
    f:write("Veredito: " .. verdict .. "\n")
    f:write("ROM: " .. tostring(gameinfo.getromname()) .. "\n")
    f:write("Hash: " .. tostring(gameinfo.getromhash()) .. "\n")
    f:write("CSV: " .. tostring(selectedCsvPath) .. "\n")
    f:write("Frames uteis: " .. tostring(#replayRows) .. "\n")
    f:write("Frame inicial do replay: " .. tostring(replayStartEmuFrame) .. "\n")
    f:write("Frame final: " .. tostring(emu.framecount()) .. "\n\n")

    f:write("[CHECKPOINTS ESPERADOS]\n")
    for _, name in ipairs({"START", "SOLDIER_VISIBLE", "SHOT", "SOLDIER_DEAD"}) do
        local e = expected[name]
        if e then
            f:write(name .. ": replay_index=" .. tostring(e.replayIndex) ..
                ", source_relative_frame=" .. tostring(e.sourceRelativeFrame) .. "\n")
        end
    end

    f:write("\n[CONFIRMACOES MANUAIS]\n")
    for _, name in ipairs({"SOLDIER_VISIBLE", "SHOT", "SOLDIER_DEAD"}) do
        local c = confirmations[name]
        if c then
            f:write(name .. ": replay_index=" .. tostring(c.replayIndex) ..
                ", emu_frame=" .. tostring(c.emuFrame) ..
                ", offset=" .. tostring(c.offset) .. "\n")
        else
            f:write(name .. ": NAO_CONFIRMADO\n")
        end
    end

    f:write("\n[OBSERVACOES]\n")
    for kind, items in pairs(observations) do
        for _, item in ipairs(items) do
            f:write(kind .. ": value=" .. tostring(item.value) ..
                ", replay_index=" .. tostring(item.replayIndex) ..
                ", emu_frame=" .. tostring(item.emuFrame) .. "\n")
        end
    end

    f:write("\n[NOTAS]\n" .. notes .. "\n")
    f:close()

    setResult(verdict)
    console.log("[GoldenEyeDiagnostic] Validacao salva: " .. validationPath)
end

local function openReplayLog()
    local timestamp = os.date("%Y%m%d-%H%M%S")
    logPath = OUTPUT_DIR .. "replay-" .. timestamp .. "-log.txt"
    logFile = io.open(logPath, "w")
    if logFile then
        logFile:write("GoldenEyeDiagnostic " .. VERSION .. "\n")
        logFile:write("CSV: " .. tostring(selectedCsvPath) .. "\n")
        logFile:write("Frames uteis: " .. tostring(#replayRows) .. "\n")
        logFile:write("replay_index,emu_frame,source_relative_frame,event\n")
    end
end

local function closeReplayLog(reason)
    if logFile then
        logFile:write("\nMotivo do encerramento: " .. tostring(reason) .. "\n")
        logFile:write("Frames aplicados: " .. tostring(math.max(0, replayIndex - 1)) .. "\n")
        logFile:close()
        logFile = nil
    end
end

local function loadSelected()
    local rows, err = loadReplay(selectedCsvPath)
    if not rows then
        setStatus("ERRO: " .. tostring(err))
        return
    end
    replayRows = rows
    replayIndex = 1
    replayFinished = false
    confirmations, observations = {}, {}
    verdictWritten = false
    updateProgress()
    setStatus("PRONTO - carregue o savestate")
    setResult("aguardando replay")
end

local function selectCsv()
    local picked = forms.openfile(
        "session-frames.csv",
        DEMO_DIR,
        "CSV de demonstracao (*.csv)|*.csv|Todos os arquivos (*.*)|*.*"
    )
    if picked and picked ~= "" then
        selectedCsvPath = picked
        forms.settext(csvLabel, selectedCsvPath)
        setStatus("CSV selecionado; clique CARREGAR")
    end
end

local function startReplay()
    if replaying or #replayRows == 0 then return end

    replayIndex = 1
    replayStartEmuFrame = emu.framecount()
    replayFinished = false
    confirmations, observations = {}, {}
    verdictWritten = false
    openReplayLog()
    replaying = true
    setStatus("REPRODUZINDO")
    setResult("observe os checkpoints")

    local currentHash = tostring(gameinfo.getromhash())
    if currentHash ~= EXPECTED_ROM_HASH then
        console.log("[GoldenEyeDiagnostic] AVISO: hash da ROM diferente.")
    end
end

local function abortReplay(reason)
    if replaying then
        replaying = false
        clearController()
        closeReplayLog(reason)
    end
    recordObservation("ROUTE_DIVERGENCE", true)
    setStatus(reason)
end

local function finishReplay()
    replaying = false
    replayFinished = true
    clearController()
    closeReplayLog("EXPECTED_END_REACHED")
    setStatus("FIM ESPERADO ATINGIDO")
    setResult("marque o resultado visual e SALVAR")
end

form = forms.newform(700, 520, "GoldenEyeDiagnostic " .. VERSION, function()
    stopped = true
    if replaying then abortReplay("FORM_CLOSED") end
end)

forms.label(form, "Replay Validation — Dam / primeiro soldado", 12, 10, 650, 24)
statusLabel = forms.label(form, "Status: inicializando", 12, 38, 650, 24)
csvLabel = forms.label(form, "", 12, 66, 660, 40, true)
progressLabel = forms.label(form, "Progresso: 0 / 0", 12, 108, 280, 24)
checkpointLabel = forms.label(form, "Checkpoint esperado: nenhum", 305, 108, 360, 24)
resultLabel = forms.label(form, "Validacao: aguardando", 12, 136, 650, 24)

forms.button(form, "SELECIONAR CSV", selectCsv, 12, 170, 130, 30)
forms.button(form, "CARREGAR", loadSelected, 150, 170, 90, 30)
forms.button(form, "INICIAR REPLAY", startReplay, 248, 170, 125, 30)
forms.button(form, "DIVERGIU / ABORTAR", function()
    abortReplay("DIVERGENCIA_VISUAL")
end, 381, 170, 145, 30)

forms.label(form, "Confirmacoes durante o replay:", 12, 214, 300, 24)
forms.button(form, "SOLDADO VISIVEL AGORA", function()
    confirmEvent("SOLDIER_VISIBLE")
end, 12, 242, 165, 30)
forms.button(form, "TIRO AGORA", function()
    confirmEvent("SHOT")
end, 185, 242, 100, 30)
forms.button(form, "SOLDADO MORREU AGORA", function()
    confirmEvent("SOLDIER_DEAD")
    recordObservation("SOLDIER_DEAD_VISUAL", true)
end, 293, 242, 175, 30)

forms.label(form, "Resultado visual final:", 12, 286, 300, 24)
forms.button(form, "CHEGOU: SIM", function()
    recordObservation("ARRIVED", true); setResult("chegada confirmada")
end, 12, 314, 105, 30)
forms.button(form, "CHEGOU: NAO", function()
    recordObservation("ARRIVED", false); setResult("nao chegou")
end, 125, 314, 105, 30)
forms.button(form, "MIRA: CORRETA", function()
    recordObservation("SHOT_ALIGNED", true); setResult("mira correta")
end, 238, 314, 115, 30)
forms.button(form, "MIRA: ERRADA", function()
    recordObservation("SHOT_ALIGNED", false); setResult("mira divergente")
end, 361, 314, 115, 30)
forms.button(form, "SOLDADO VIVO", function()
    recordObservation("SOLDIER_DEAD_VISUAL", false); setResult("soldado permaneceu vivo")
end, 484, 314, 115, 30)

forms.label(form, "Notas da observacao:", 12, 360, 300, 24)
notesBox = forms.textbox(form, "", 650, 55, nil, 12, 386, false, true)

forms.button(form, "SALVAR VALIDACAO", writeValidation, 12, 452, 155, 34)
forms.button(form, "ENCERRAR", function()
    if not verdictWritten then writeValidation() end
    stopped = true
end, 175, 452, 100, 34)

console.clear()
console.log("[GoldenEyeDiagnostic] Carregado | versao=" .. VERSION)
console.log("[GoldenEyeDiagnostic] ROM=" .. tostring(gameinfo.getromname()))
console.log("[GoldenEyeDiagnostic] Hash=" .. tostring(gameinfo.getromhash()))

selectedCsvPath = DEFAULT_CSV
forms.settext(csvLabel, selectedCsvPath)
if fileExists(DEFAULT_CSV) then loadSelected()
else setStatus("CSV padrao ausente; selecione manualmente") end

event.onexit(function()
    if replaying then
        clearController()
        closeReplayLog("SCRIPT_EXIT")
    end
    if not verdictWritten and (#replayRows > 0) then writeValidation() end
end, "GoldenEyeDiagnostic-0.0.3-exit")

while not stopped do
    if replaying then
        local row = replayRows[replayIndex]
        if not row then
            finishReplay()
        else
            joypad.set(row.digital, CONTROLLER)
            joypad.setanalog(row.analog, CONTROLLER)

            if row.event ~= "" then
                forms.settext(checkpointLabel,
                    "Checkpoint esperado: " .. row.event ..
                    " | indice=" .. tostring(replayIndex))
                console.log("[GoldenEyeDiagnostic] Checkpoint esperado=" ..
                    row.event .. " | replayIndex=" .. tostring(replayIndex))
            end

            if logFile then
                logFile:write(
                    tostring(replayIndex) .. "," ..
                    tostring(emu.framecount()) .. "," ..
                    tostring(row.relativeFrame) .. "," ..
                    tostring(row.event) .. "\n"
                )
                if replayIndex % 60 == 0 then logFile:flush() end
            end

            gui.drawString(8, 8,
                "GoldenEyeDiagnostic " .. VERSION ..
                " | VALIDATION " .. replayIndex .. "/" .. #replayRows,
                "white", "black", 12)

            replayIndex = replayIndex + 1
            updateProgress()
            emu.frameadvance()
        end
    else
        gui.drawString(8, 8,
            "GoldenEyeDiagnostic " .. VERSION ..
            (replayFinished and " | AVALIE O RESULTADO" or " | AGUARDANDO"),
            "white", "black", 12)
        emu.yield()
    end
end
