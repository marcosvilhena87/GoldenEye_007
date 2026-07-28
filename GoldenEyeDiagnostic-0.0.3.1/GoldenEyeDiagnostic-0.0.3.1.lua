-- GoldenEyeDiagnostic 0.0.3.1
-- Combat Isolation para GoldenEye 007 (N64) no BizHawk.
--
-- Reproduz a rota da demonstracao ate um ponto de corte e substitui o combate
-- original por uma sequencia parametrizada de espera, ajuste lateral e tiros.
-- Nao le nem escreve na memoria do jogo.

local VERSION = "0.0.3.1"
local CONTROLLER = 1
local EXPECTED_ROM_HASH = "ABE01E4AEB033B6C0836819F549C791B26CFDE83"

local stopped = false
local running = false
local phase = "IDLE"
local replayRows = {}
local routeRows = {}
local replayIndex = 1
local routeIndex = 1
local combatIndex = 1
local combatSequence = {}
local selectedCsvPath = nil
local logFile = nil
local logPath = nil
local resultPath = nil
local startEmuFrame = nil
local routeCutIndex = 820

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
                    relativeFrame = tonumber(fields[2]) or 0,
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
    for i = startPos, endPos do table.insert(useful, allRows[i]) end
    return useful, nil
end

local function clearController()
    local released = {
        ["A Up"] = false,
        ["A Down"] = false,
        ["A Left"] = false,
        ["A Right"] = false,
        ["Z"] = false,
        ["A"] = false,
        ["B"] = false,
        ["R"] = false,
        ["L"] = false,
        ["Start"] = false
    }
    joypad.set(released, CONTROLLER)
    joypad.setanalog({ ["X Axis"] = 0, ["Y Axis"] = 0 }, CONTROLLER)
end

local function clampInt(value, minValue, maxValue, defaultValue)
    local n = tonumber(value)
    if not n then return defaultValue end
    n = math.floor(n)
    if n < minValue then n = minValue end
    if n > maxValue then n = maxValue end
    return n
end

local function appendFrames(sequence, count, digital, label)
    for _ = 1, count do
        table.insert(sequence, {
            digital = digital or {},
            analog = { ["X Axis"] = 0, ["Y Axis"] = 0 },
            label = label or ""
        })
    end
end

local function buildCombatSequence(waitFrames, direction, adjustFrames,
                                  shotCount, pressFrames, releaseFrames)
    local seq = {}

    appendFrames(seq, waitFrames, {}, "WAIT")

    if adjustFrames > 0 and direction ~= "NONE" then
        local input = {}
        if direction == "LEFT" then input["A Left"] = true end
        if direction == "RIGHT" then input["A Right"] = true end
        appendFrames(seq, adjustFrames, input, "ADJUST_" .. direction)
        appendFrames(seq, 3, {}, "SETTLE")
    end

    for shot = 1, shotCount do
        appendFrames(seq, pressFrames, { ["Z"] = true }, "SHOT_" .. tostring(shot))
        if shot < shotCount then
            appendFrames(seq, releaseFrames, {}, "RELEASE_" .. tostring(shot))
        end
    end

    appendFrames(seq, 120, {}, "OBSERVE")
    return seq
end

local statusLabel, phaseLabel, progressLabel, resultLabel
local cutBox, waitBox, adjustBox, shotsBox, pressBox, releaseBox, directionBox, notesBox
local form

local function setStatus(text)
    if statusLabel then forms.settext(statusLabel, "Status: " .. text) end
end

local function setPhase(text)
    if phaseLabel then forms.settext(phaseLabel, "Fase: " .. text) end
end

local function setProgress(text)
    if progressLabel then forms.settext(progressLabel, "Progresso: " .. text) end
end

local function openLog()
    local timestamp = os.date("%Y%m%d-%H%M%S")
    logPath = OUTPUT_DIR .. "combat-" .. timestamp .. "-log.txt"
    logFile = io.open(logPath, "w")
    if logFile then
        logFile:write("GoldenEyeDiagnostic " .. VERSION .. "\n")
        logFile:write("CSV: " .. tostring(selectedCsvPath) .. "\n")
        logFile:write("Route cut index: " .. tostring(routeCutIndex) .. "\n")
        logFile:write("Start emu frame: " .. tostring(startEmuFrame) .. "\n")
        logFile:write("phase,index,emu_frame,label\n")
    end
end

local function closeLog(reason)
    if logFile then
        logFile:write("\nMotivo do encerramento: " .. tostring(reason) .. "\n")
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
    setStatus("CSV carregado | frames=" .. tostring(#rows))
end

local function startTest()
    if running or #replayRows == 0 then return end

    routeCutIndex = clampInt(forms.gettext(cutBox), 1, #replayRows, 820)
    local waitFrames = clampInt(forms.gettext(waitBox), 0, 180, 0)
    local adjustFrames = clampInt(forms.gettext(adjustBox), 0, 30, 0)
    local shotCount = clampInt(forms.gettext(shotsBox), 1, 6, 2)
    local pressFrames = clampInt(forms.gettext(pressBox), 1, 30, 5)
    local releaseFrames = clampInt(forms.gettext(releaseBox), 1, 30, 5)
    local direction = forms.gettext(directionBox)
    if direction ~= "LEFT" and direction ~= "RIGHT" then direction = "NONE" end

    routeRows = {}
    for i = 1, routeCutIndex do routeRows[i] = replayRows[i] end

    combatSequence = buildCombatSequence(
        waitFrames, direction, adjustFrames,
        shotCount, pressFrames, releaseFrames
    )

    routeIndex = 1
    combatIndex = 1
    phase = "ROUTE"
    running = true
    startEmuFrame = emu.framecount()
    openLog()

    setStatus("EXECUTANDO")
    setPhase("ROTA")
    setProgress("0 / " .. tostring(#routeRows))
    forms.settext(resultLabel, "Resultado: aguardando observacao")

    console.log("[GoldenEyeDiagnostic] Teste iniciado")
    console.log("[GoldenEyeDiagnostic] routeCutIndex=" .. routeCutIndex)
    console.log("[GoldenEyeDiagnostic] combatFrames=" .. #combatSequence)
end

local function stopTest(reason)
    if not running then return end
    running = false
    phase = "IDLE"
    clearController()
    closeLog(reason)
    setStatus(reason)
    setPhase("PARADO")
end

local function saveResult(verdict)
    local timestamp = os.date("%Y%m%d-%H%M%S")
    resultPath = OUTPUT_DIR .. "combat-" .. timestamp .. "-summary.txt"
    local f = io.open(resultPath, "w")
    if not f then return end

    f:write("GoldenEyeDiagnostic " .. VERSION .. "\n")
    f:write("Veredito: " .. tostring(verdict) .. "\n")
    f:write("ROM: " .. tostring(gameinfo.getromname()) .. "\n")
    f:write("Hash: " .. tostring(gameinfo.getromhash()) .. "\n")
    f:write("CSV: " .. tostring(selectedCsvPath) .. "\n")
    f:write("Route cut index: " .. tostring(routeCutIndex) .. "\n")
    f:write("Frame atual: " .. tostring(emu.framecount()) .. "\n")
    f:write("Notas: " .. tostring(forms.gettext(notesBox) or "") .. "\n")
    f:close()

    forms.settext(resultLabel, "Resultado: " .. verdict)
    console.log("[GoldenEyeDiagnostic] Resultado salvo: " .. resultPath)
end

form = forms.newform(680, 540, "GoldenEyeDiagnostic " .. VERSION, function()
    stopped = true
    if running then stopTest("FORM_CLOSED") end
end)

forms.label(form, "Combat Isolation — Dam / primeiro soldado", 12, 10, 620, 24)
statusLabel = forms.label(form, "Status: inicializando", 12, 38, 620, 24)
phaseLabel = forms.label(form, "Fase: IDLE", 12, 66, 250, 24)
progressLabel = forms.label(form, "Progresso: 0", 275, 66, 330, 24)
resultLabel = forms.label(form, "Resultado: aguardando", 12, 94, 620, 24)

forms.label(form, "Corte da rota (indice):", 12, 132, 180, 24)
cutBox = forms.textbox(form, "820", 70, 24, nil, 195, 130)

forms.label(form, "Espera antes do combate:", 12, 168, 180, 24)
waitBox = forms.textbox(form, "0", 70, 24, nil, 195, 166)

forms.label(form, "Direcao do ajuste:", 12, 204, 180, 24)
directionBox = forms.dropdown(form, {"NONE", "LEFT", "RIGHT"}, 195, 202, 110, 24)

forms.label(form, "Frames de ajuste:", 330, 204, 140, 24)
adjustBox = forms.textbox(form, "0", 70, 24, nil, 475, 202)

forms.label(form, "Quantidade de tiros:", 12, 240, 180, 24)
shotsBox = forms.textbox(form, "2", 70, 24, nil, 195, 238)

forms.label(form, "Frames com Z:", 330, 240, 140, 24)
pressBox = forms.textbox(form, "5", 70, 24, nil, 475, 238)

forms.label(form, "Intervalo entre tiros:", 12, 276, 180, 24)
releaseBox = forms.textbox(form, "5", 70, 24, nil, 195, 274)

forms.button(form, "CARREGAR CSV", loadSelected, 12, 318, 120, 32)
forms.button(form, "INICIAR TESTE", startTest, 142, 318, 120, 32)
forms.button(form, "ABORTAR", function() stopTest("ABORTADO") end, 272, 318, 90, 32)

forms.label(form, "Classificacao visual:", 12, 366, 180, 24)
forms.button(form, "MATOU", function()
    saveResult("APROVADO_COMBAT_KILL")
end, 12, 394, 90, 30)
forms.button(form, "ACERTOU, NAO MATOU", function()
    saveResult("PARCIAL_HIT_NO_KILL")
end, 110, 394, 150, 30)
forms.button(form, "ERROU O TIRO", function()
    saveResult("REPROVADO_SHOT_MISS")
end, 268, 394, 120, 30)
forms.button(form, "NAO CHEGOU", function()
    saveResult("REPROVADO_ROUTE")
end, 396, 394, 110, 30)

forms.label(form, "Notas:", 12, 438, 100, 24)
notesBox = forms.textbox(form, "", 630, 50, nil, 12, 464, false, true)

console.clear()
console.log("[GoldenEyeDiagnostic] Carregado | versao=" .. VERSION)
console.log("[GoldenEyeDiagnostic] ROM=" .. tostring(gameinfo.getromname()))
console.log("[GoldenEyeDiagnostic] Hash=" .. tostring(gameinfo.getromhash()))

selectedCsvPath = DEFAULT_CSV
if fileExists(DEFAULT_CSV) then loadSelected()
else setStatus("CSV padrao ausente") end

event.onexit(function()
    if running then stopTest("SCRIPT_EXIT") end
end, "GoldenEyeDiagnostic-0.0.3.1-exit")

while not stopped do
    if running then
        if phase == "ROUTE" then
            local row = routeRows[routeIndex]
            if row then
                joypad.set(row.digital, CONTROLLER)
                joypad.setanalog(row.analog, CONTROLLER)

                if logFile then
                    logFile:write("ROUTE," .. routeIndex .. "," ..
                        emu.framecount() .. "," .. tostring(row.event) .. "\n")
                end

                setProgress(tostring(routeIndex) .. " / " .. tostring(#routeRows))
                routeIndex = routeIndex + 1
                emu.frameadvance()
            else
                clearController()
                phase = "COMBAT"
                setPhase("COMBATE")
                setProgress("0 / " .. tostring(#combatSequence))
            end
        elseif phase == "COMBAT" then
            local step = combatSequence[combatIndex]
            if step then
                joypad.set(step.digital, CONTROLLER)
                joypad.setanalog(step.analog, CONTROLLER)

                if logFile then
                    logFile:write("COMBAT," .. combatIndex .. "," ..
                        emu.framecount() .. "," .. tostring(step.label) .. "\n")
                end

                setProgress(tostring(combatIndex) .. " / " ..
                    tostring(#combatSequence))
                combatIndex = combatIndex + 1
                emu.frameadvance()
            else
                stopTest("TESTE_CONCLUIDO")
                setStatus("CONCLUIDO - classifique o resultado")
            end
        end
    else
        gui.drawString(8, 8,
            "GoldenEyeDiagnostic " .. VERSION .. " | AGUARDANDO",
            "white", "black", 12)
        emu.yield()
    end
end
