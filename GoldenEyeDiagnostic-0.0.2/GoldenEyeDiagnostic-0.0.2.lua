-- GoldenEyeDiagnostic 0.0.2
-- Input Replay para GoldenEye 007 (N64) no BizHawk.
-- Reproduz uma demonstracao CSV criada pela versao 0.0.1.
-- Nao le nem escreve na memoria do jogo.

local VERSION = "0.0.2"
local CONTROLLER = 1
local EXPECTED_ROM_HASH = "ABE01E4AEB033B6C0836819F549C791B26CFDE83"

local stopped = false
local replaying = false
local replayFinished = false
local selectedCsvPath = nil
local replayRows = {}
local replayIndex = 1
local replayStartEmuFrame = nil
local stopReason = nil
local logFile = nil
local logPath = nil

local function scriptDirectory()
    local source = debug.getinfo(1, "S").source
    if string.sub(source, 1, 1) == "@" then
        source = string.sub(source, 2)
    end
    return source:match("^(.*[\\/])") or ".\\"
end

local BASE_DIR = scriptDirectory()
local DEMO_DIR = BASE_DIR .. "demonstrations\\"
local OUTPUT_DIR = BASE_DIR .. "output\\"
local DEFAULT_CSV = DEMO_DIR .. "session-20260727-234451-frames.csv"

os.execute('if not exist "' .. OUTPUT_DIR .. '" mkdir "' .. OUTPUT_DIR .. '"')

local function fileExists(path)
    local f = io.open(path, "r")
    if f then
        f:close()
        return true
    end
    return false
end

local function parseCsvLine(line)
    local fields = {}
    local field = ""
    local inQuotes = false
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
    local digital = {}
    local analog = {}

    for pair in string.gmatch(text or "", "([^;]+)") do
        local name, rawValue = pair:match("^(.-)=(.*)$")
        if name then
            local numeric = tonumber(rawValue)
            if name == "X Axis" or name == "Y Axis" then
                analog[name] = numeric or 0
            else
                digital[name] = (rawValue == "1" or rawValue == "true")
            end
        end
    end

    return digital, analog
end

local function loadReplay(path)
    local f, err = io.open(path, "r")
    if not f then
        return nil, "Nao foi possivel abrir o CSV: " .. tostring(err)
    end

    local header = f:read("*l")
    if not header then
        f:close()
        return nil, "CSV vazio."
    end

    local allRows = {}
    local startPosition = nil
    local endPosition = nil
    local sourceLine = 1

    for line in f:lines() do
        sourceLine = sourceLine + 1
        if line ~= "" then
            local fields = parseCsvLine(line)
            if #fields >= 6 then
                local row = {
                    frame = tonumber(fields[1]) or 0,
                    relativeFrame = tonumber(fields[2]) or 0,
                    isLagged = tonumber(fields[3]) or 0,
                    lagCount = tonumber(fields[4]) or 0,
                    event = fields[5] or "",
                    inputState = fields[6] or "",
                    sourceLine = sourceLine
                }

                row.digital, row.analog = parseInputState(row.inputState)
                table.insert(allRows, row)

                if row.event == "START" and not startPosition then
                    startPosition = #allRows
                end
                if row.event == "SOLDIER_DEAD" and not endPosition then
                    endPosition = #allRows
                end
            end
        end
    end
    f:close()

    if not startPosition then
        return nil, "O CSV nao possui o marcador START."
    end

    endPosition = endPosition or #allRows

    local usefulRows = {}
    for i = startPosition, endPosition do
        table.insert(usefulRows, allRows[i])
    end

    if #usefulRows == 0 then
        return nil, "Nenhum frame util encontrado."
    end

    return usefulRows, nil
end

local function clearController()
    local released = {}
    if replayRows and #replayRows > 0 then
        for name, _ in pairs(replayRows[math.min(replayIndex, #replayRows)].digital or {}) do
            released[name] = false
        end
    end
    joypad.set(released, CONTROLLER)
    joypad.setanalog({ ["X Axis"] = 0, ["Y Axis"] = 0 }, CONTROLLER)
end

local function openLog()
    local timestamp = os.date("%Y%m%d-%H%M%S")
    logPath = OUTPUT_DIR .. "replay-" .. timestamp .. "-log.txt"
    logFile = io.open(logPath, "w")
    if logFile then
        logFile:write("GoldenEyeDiagnostic " .. VERSION .. "\n")
        logFile:write("ROM: " .. tostring(gameinfo.getromname()) .. "\n")
        logFile:write("Hash: " .. tostring(gameinfo.getromhash()) .. "\n")
        logFile:write("CSV: " .. tostring(selectedCsvPath) .. "\n")
        logFile:write("Frames uteis: " .. tostring(#replayRows) .. "\n")
        logFile:write("Frame inicial do emulador: " .. tostring(replayStartEmuFrame) .. "\n\n")
        logFile:write("replay_index,emu_frame,source_relative_frame,event\n")
        logFile:flush()
    end
end

local function closeLog(reason)
    if logFile then
        logFile:write("\nMotivo do encerramento: " .. tostring(reason) .. "\n")
        logFile:write("Frames aplicados: " .. tostring(math.max(0, replayIndex - 1)) .. "\n")
        logFile:write("Frame final do emulador: " .. tostring(emu.framecount()) .. "\n")
        logFile:close()
        logFile = nil
    end
end

local statusLabel
local csvLabel
local progressLabel
local form

local function updateStatus(text)
    if statusLabel then forms.settext(statusLabel, "Status: " .. text) end
end

local function updateProgress()
    if progressLabel then
        forms.settext(progressLabel,
            "Progresso: " .. tostring(math.min(replayIndex, #replayRows)) ..
            " / " .. tostring(#replayRows))
    end
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
        updateStatus("CSV selecionado; clique em CARREGAR")
    end
end

local function loadSelectedCsv()
    if not selectedCsvPath or selectedCsvPath == "" then
        updateStatus("selecione um CSV")
        return
    end

    local rows, err = loadReplay(selectedCsvPath)
    if not rows then
        updateStatus("ERRO: " .. err)
        console.log("[GoldenEyeDiagnostic] " .. err)
        return
    end

    replayRows = rows
    replayIndex = 1
    replayFinished = false
    updateProgress()
    updateStatus("PRONTO - carregue o savestate e clique INICIAR")
    console.log("[GoldenEyeDiagnostic] CSV carregado | framesUteis=" .. #replayRows)
end

local function startReplay()
    if replaying then return end
    if #replayRows == 0 then
        updateStatus("carregue o CSV primeiro")
        return
    end

    local currentHash = tostring(gameinfo.getromhash())
    if currentHash ~= EXPECTED_ROM_HASH then
        updateStatus("ATENCAO: hash da ROM diferente")
        console.log("[GoldenEyeDiagnostic] AVISO | hash esperado=" ..
            EXPECTED_ROM_HASH .. " | atual=" .. currentHash)
    end

    replayIndex = 1
    replayStartEmuFrame = emu.framecount()
    replayFinished = false
    stopReason = nil
    openLog()
    replaying = true
    updateStatus("REPRODUZINDO")
    console.log("[GoldenEyeDiagnostic] Replay iniciado | emuFrame=" ..
        tostring(replayStartEmuFrame))
end

local function abortReplay(reason)
    if not replaying then return end
    replaying = false
    stopReason = reason or "ABORTADO"
    clearController()
    closeLog(stopReason)
    updateStatus(stopReason)
    console.log("[GoldenEyeDiagnostic] Replay encerrado | motivo=" .. stopReason)
end

local function finishReplay()
    replaying = false
    replayFinished = true
    clearController()
    closeLog("SOLDIER_DEAD_REACHED")
    updateStatus("CONCLUIDO - avalie o resultado")
    console.log("[GoldenEyeDiagnostic] Replay concluido.")
    if logPath then console.log("[GoldenEyeDiagnostic] Log: " .. logPath) end
end

local function stopScript(reason)
    if stopped then return end
    if replaying then abortReplay(reason or "SCRIPT_STOP") end
    stopped = true
end

form = forms.newform(610, 300, "GoldenEyeDiagnostic " .. VERSION, function()
    stopScript("FORM_CLOSED")
end)

forms.label(form, "Input Replay — Dam / primeiro soldado", 12, 10, 560, 24)
statusLabel = forms.label(form, "Status: inicializando", 12, 38, 575, 24)
csvLabel = forms.label(form, "", 12, 68, 575, 42, true)
progressLabel = forms.label(form, "Progresso: 0 / 0", 12, 112, 300, 24)

forms.button(form, "SELECIONAR CSV", selectCsv, 12, 145, 135, 32)
forms.button(form, "CARREGAR", loadSelectedCsv, 157, 145, 95, 32)
forms.button(form, "INICIAR REPLAY", startReplay, 262, 145, 135, 32)
forms.button(form, "ABORTAR", function() abortReplay("ABORTADO_PELO_USUARIO") end,
    407, 145, 90, 32)

forms.label(form,
    "Procedimento:\n" ..
    "1. Carregue no BizHawk o MESMO savestate usado na demonstracao.\n" ..
    "2. Nao toque nos controles durante o replay.\n" ..
    "3. Clique em INICIAR REPLAY.\n" ..
    "4. Ao final, observe se Bond chegou ao soldado e se ele morreu.",
    12, 190, 575, 90)

console.clear()
console.log("[GoldenEyeDiagnostic] Carregado | versao=" .. VERSION)
console.log("[GoldenEyeDiagnostic] ROM=" .. tostring(gameinfo.getromname()))
console.log("[GoldenEyeDiagnostic] Hash=" .. tostring(gameinfo.getromhash()))

selectedCsvPath = DEFAULT_CSV
forms.settext(csvLabel, selectedCsvPath)

if fileExists(DEFAULT_CSV) then
    loadSelectedCsv()
else
    updateStatus("CSV padrao nao encontrado; selecione manualmente")
end

event.onexit(function()
    stopScript("SCRIPT_EXIT")
end, "GoldenEyeDiagnostic-0.0.2-exit")

while not stopped do
    if replaying then
        local row = replayRows[replayIndex]

        if not row then
            finishReplay()
        else
            -- Digital e analogico sao aplicados separadamente.
            joypad.set(row.digital, CONTROLLER)
            joypad.setanalog(row.analog, CONTROLLER)

            if logFile then
                logFile:write(
                    tostring(replayIndex) .. "," ..
                    tostring(emu.framecount()) .. "," ..
                    tostring(row.relativeFrame) .. "," ..
                    tostring(row.event) .. "\n"
                )
                if replayIndex % 60 == 0 then logFile:flush() end
            end

            if row.event ~= "" then
                console.log("[GoldenEyeDiagnostic] Evento=" .. row.event ..
                    " | replayIndex=" .. replayIndex ..
                    " | emuFrame=" .. emu.framecount())
            end

            gui.drawString(8, 8,
                "GoldenEyeDiagnostic " .. VERSION ..
                " | REPLAY " .. replayIndex .. "/" .. #replayRows,
                "white", "black", 12)

            replayIndex = replayIndex + 1
            updateProgress()
            emu.frameadvance()
        end
    else
        gui.drawString(8, 8,
            "GoldenEyeDiagnostic " .. VERSION ..
            (replayFinished and " | CONCLUIDO" or " | AGUARDANDO"),
            "white", "black", 12)
        emu.yield()
    end
end
