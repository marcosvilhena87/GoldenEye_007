-- GoldenEyeDiagnostic 0.0.5.1
-- Replay Alignment Validation
--
-- Objetivo:
-- - Reproduzir a rota frame-locked.
-- - Registrar checkpoints importantes.
-- - Comparar cada tentativa com uma referencia salva.
-- - Classificar KILL, MISS, ROUTE_DESYNC ou TIMEOUT.
--
-- A referencia e criada na primeira execucao "CAPTURAR REFERENCIA".
-- Depois, recarregue o mesmo savestate e use "VALIDAR TENTATIVA".
--
-- Somente leitura de memoria via mainmemory.

local VERSION = "0.0.5.1"
local CONTROLLER = 1
local EXPECTED_ROM_HASH = "ABE01E4AEB033B6C0836819F549C791B26CFDE83"

local DEFAULT_ROUTE_LIMIT = 1003
local DEFAULT_TIMEOUT_FRAMES = 1300

-- Checkpoints baseados na demonstracao conhecida.
local CHECKPOINTS = {
    { name = "START", index = 1 },
    { name = "SOLDIER_VISIBLE", index = 339 },
    { name = "BEFORE_SHOT_1", index = 714 },
    { name = "AFTER_SHOT_1", index = 726 },
    { name = "BEFORE_SHOT_2", index = 793 },
    { name = "AFTER_SHOT_2", index = 803 },
    { name = "END", index = 1003 }
}

-- Memoria ja validada / util para alinhamento.
local CANDIDATES = {
    { name = "state", address = 0x00030A37, kind = "u8" },
    { name = "death", address = 0x00030A6B, kind = "u8" },
    { name = "hitSignal", address = 0x0003CB7F, kind = "u8" },
    { name = "pointer", address = 0x001F421C, kind = "u32be" },
    { name = "aux", address = 0x001E015C, kind = "u8" }
}

local stopped = false
local running = false
local pendingMode = nil
local mode = "IDLE"
local phase = "IDLE"

local replayRows = {}
local selectedCsvPath = nil
local routeIndex = 1
local routeLimit = DEFAULT_ROUTE_LIMIT
local timeoutFrames = DEFAULT_TIMEOUT_FRAMES

local startEmuFrame = nil
local outcomeFrame = nil
local outcome = nil
local shotPressTransitions = 0
local previousZ = false

local reference = {}
local referenceLoaded = false
local referencePath = nil
local checkpointResults = {}
local desyncDetected = false
local firstDesyncCheckpoint = nil

local logFile = nil
local logPath = nil
local summaryPath = nil

local function scriptDirectory()
    local source = debug.getinfo(1, "S").source
    if source:sub(1, 1) == "@" then
        source = source:sub(2)
    end
    return source:match("^(.*[\\/])") or ".\\"
end

local BASE_DIR = scriptDirectory()
local DEMO_DIR = BASE_DIR .. "demonstrations\\"
local OUTPUT_DIR = BASE_DIR .. "output\\"
local DEFAULT_CSV = DEMO_DIR .. "session-20260727-234451-frames.csv"
local DEFAULT_REFERENCE = OUTPUT_DIR .. "replay-alignment-reference.csv"

os.execute('if not exist "' .. OUTPUT_DIR .. '" mkdir "' .. OUTPUT_DIR .. '"')

local function log(text)
    console.log("[GoldenEyeDiagnostic] " .. text)
end

local function fileExists(path)
    local f = io.open(path, "r")
    if f then f:close(); return true end
    return false
end

local function parseCsvLine(line)
    local fields = {}
    local field = ""
    local quoted = false
    local i = 1

    while i <= #line do
        local c = line:sub(i, i)

        if quoted then
            if c == '"' then
                if line:sub(i + 1, i + 1) == '"' then
                    field = field .. '"'
                    i = i + 1
                else
                    quoted = false
                end
            else
                field = field .. c
            end
        else
            if c == '"' then
                quoted = true
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
        local name, raw = pair:match("^(.-)=(.*)$")
        if name then
            if name == "X Axis" or name == "Y Axis" then
                analog[name] = tonumber(raw) or 0
            else
                digital[name] = raw == "1" or raw == "true"
            end
        end
    end

    return digital, analog
end

local function loadReplay(path)
    local file, err = io.open(path, "r")
    if not file then
        return nil, "Nao foi possivel abrir o CSV: " .. tostring(err)
    end

    local header = file:read("*l")
    if not header then
        file:close()
        return nil, "CSV vazio."
    end

    local rows = {}
    local startPosition = nil
    local endPosition = nil

    for line in file:lines() do
        if line ~= "" then
            local fields = parseCsvLine(line)
            if #fields >= 6 then
                local row = {
                    event = fields[5] or "",
                    inputState = fields[6] or ""
                }

                row.digital, row.analog = parseInputState(row.inputState)
                table.insert(rows, row)

                if row.event == "START" and not startPosition then
                    startPosition = #rows
                end

                if row.event == "SOLDIER_DEAD" and not endPosition then
                    endPosition = #rows
                end
            end
        end
    end

    file:close()

    if not startPosition then
        return nil, "Marcador START ausente."
    end

    endPosition = endPosition or #rows

    local useful = {}
    for i = startPosition, endPosition do
        table.insert(useful, rows[i])
    end

    return useful, nil
end

local function clampInteger(value, minimum, maximum, defaultValue)
    local number = tonumber(value)
    if not number then return defaultValue end
    number = math.floor(number)
    if number < minimum then number = minimum end
    if number > maximum then number = maximum end
    return number
end

local function clearController()
    joypad.set({
        ["A Up"] = false, ["A Down"] = false,
        ["A Left"] = false, ["A Right"] = false,
        ["Z"] = false, ["A"] = false, ["B"] = false,
        ["R"] = false, ["L"] = false, ["Start"] = false
    }, CONTROLLER)

    joypad.setanalog({
        ["X Axis"] = 0,
        ["Y Axis"] = 0
    }, CONTROLLER)
end

local function applyInput(digital, analog)
    joypad.set(digital or {}, CONTROLLER)
    joypad.setanalog(analog or {
        ["X Axis"] = 0,
        ["Y Axis"] = 0
    }, CONTROLLER)
end

local function readU32BE(address)
    if mainmemory.read_u32_be then
        return mainmemory.read_u32_be(address)
    end

    local b0 = mainmemory.read_u8(address)
    local b1 = mainmemory.read_u8(address + 1)
    local b2 = mainmemory.read_u8(address + 2)
    local b3 = mainmemory.read_u8(address + 3)

    return b0 * 0x1000000 + b1 * 0x10000 + b2 * 0x100 + b3
end

local function readCandidate(candidate)
    if candidate.kind == "u32be" then
        return readU32BE(candidate.address)
    end
    return mainmemory.read_u8(candidate.address)
end

local function readState()
    local values = {}
    for _, c in ipairs(CANDIDATES) do
        values[c.name] = readCandidate(c)
    end
    return values
end

local function stateText(values)
    return "state=" .. tostring(values.state)
        .. " | death=" .. tostring(values.death)
        .. " | hitSignal=" .. tostring(values.hitSignal)
        .. " | ptr=0x" .. string.format("%08X", values.pointer)
        .. " | aux=" .. tostring(values.aux)
end

local function killDetected(values)
    return values.death == 1
        or values.state == 2
        or (
            values.pointer == 0
            and values.hitSignal == 1
        )
end

local function findCheckpoint(index)
    for _, cp in ipairs(CHECKPOINTS) do
        if cp.index == index then return cp end
    end
    return nil
end

local function compareValues(referenceValues, currentValues)
    local differences = {}

    for _, c in ipairs(CANDIDATES) do
        local name = c.name
        if referenceValues[name] ~= currentValues[name] then
            table.insert(differences,
                name .. ":ref=" .. tostring(referenceValues[name])
                .. "/cur=" .. tostring(currentValues[name]))
        end
    end

    return differences
end

local statusLabel
local phaseLabel
local progressLabel
local memoryLabel
local resultLabel
local referenceLabel
local routeLimitBox
local timeoutBox
local form

local function setStatus(text)
    forms.settext(statusLabel, "Status: " .. text)
end

local function setPhase(text)
    forms.settext(phaseLabel, "Fase: " .. text)
end

local function setProgress(text)
    forms.settext(progressLabel, "Progresso: " .. text)
end

local function setResult(text)
    forms.settext(resultLabel, text)
end

local function updateReferenceLabel()
    forms.settext(referenceLabel,
        "Referencia: "
        .. (referenceLoaded and "CARREGADA" or "NAO CARREGADA")
        .. " | " .. tostring(referencePath or DEFAULT_REFERENCE))
end

local function saveReference()
    local file = assert(io.open(DEFAULT_REFERENCE, "w"))
    file:write("checkpoint,index,state,death,hitSignal,pointer,aux\n")

    for _, cp in ipairs(CHECKPOINTS) do
        local values = reference[cp.name]
        if values then
            file:write(
                cp.name .. ","
                .. tostring(cp.index) .. ","
                .. tostring(values.state) .. ","
                .. tostring(values.death) .. ","
                .. tostring(values.hitSignal) .. ","
                .. string.format("0x%08X", values.pointer) .. ","
                .. tostring(values.aux) .. "\n"
            )
        end
    end

    file:close()
    referencePath = DEFAULT_REFERENCE
    referenceLoaded = true
    updateReferenceLabel()
    log("Referencia salva=" .. DEFAULT_REFERENCE)
end

local function loadReference()
    if not fileExists(DEFAULT_REFERENCE) then
        referenceLoaded = false
        referencePath = DEFAULT_REFERENCE
        updateReferenceLabel()
        return
    end

    local file = assert(io.open(DEFAULT_REFERENCE, "r"))
    file:read("*l")
    reference = {}

    for line in file:lines() do
        local f = parseCsvLine(line)
        if #f >= 7 then
            local pointer = tonumber(f[6])
            if not pointer then
                pointer = tonumber(f[6]:gsub("^0x", ""), 16) or 0
            end

            reference[f[1]] = {
                state = tonumber(f[3]) or 0,
                death = tonumber(f[4]) or 0,
                hitSignal = tonumber(f[5]) or 0,
                pointer = pointer,
                aux = tonumber(f[7]) or 0
            }
        end
    end

    file:close()
    referenceLoaded = true
    referencePath = DEFAULT_REFERENCE
    updateReferenceLabel()
    log("Referencia carregada=" .. DEFAULT_REFERENCE)
end

local function openLog()
    local timestamp = os.date("%Y%m%d-%H%M%S")
    local prefix = mode == "CAPTURE_REFERENCE"
        and "alignment-reference"
        or "alignment-validation"

    logPath = OUTPUT_DIR .. prefix .. "-" .. timestamp .. "-log.csv"
    summaryPath = OUTPUT_DIR .. prefix .. "-" .. timestamp .. "-summary.txt"

    logFile = assert(io.open(logPath, "w"))
    logFile:write(
        "relative_frame,emu_frame,route_index,event,checkpoint,"
        .. "state,death,hitSignal,pointer_hex,aux,differences\n"
    )
end

local function writeLog(eventName, checkpointName, values, differences)
    if not logFile then return end

    logFile:write(
        tostring(emu.framecount() - startEmuFrame) .. ","
        .. tostring(emu.framecount()) .. ","
        .. tostring(routeIndex) .. ","
        .. tostring(eventName or "") .. ","
        .. tostring(checkpointName or "") .. ","
        .. tostring(values.state) .. ","
        .. tostring(values.death) .. ","
        .. tostring(values.hitSignal) .. ","
        .. string.format("0x%08X", values.pointer) .. ","
        .. tostring(values.aux) .. ","
        .. '"' .. table.concat(differences or {}, "; ") .. '"' .. "\n"
    )
    logFile:flush()
end

local function closeLog()
    if logFile then
        logFile:flush()
        logFile:close()
        logFile = nil
    end
end

local function writeSummary(finalValues)
    local file = assert(io.open(summaryPath, "w"))

    file:write("GoldenEyeDiagnostic " .. VERSION .. "\n")
    file:write("ROM: " .. tostring(gameinfo.getromname()) .. "\n")
    file:write("Hash: " .. tostring(gameinfo.getromhash()) .. "\n")
    file:write("Mode: " .. tostring(mode) .. "\n")
    file:write("CSV: " .. tostring(selectedCsvPath) .. "\n")
    file:write("Route limit: " .. tostring(routeLimit) .. "\n")
    file:write("Timeout frames: " .. tostring(timeoutFrames) .. "\n")
    file:write("Outcome: " .. tostring(outcome) .. "\n")
    file:write("First desync checkpoint: "
        .. tostring(firstDesyncCheckpoint or "NONE") .. "\n\n")

    file:write("Final memory:\n")
    file:write(stateText(finalValues) .. "\n\n")

    file:write("Checkpoint results:\n")
    for _, cp in ipairs(CHECKPOINTS) do
        local r = checkpointResults[cp.name]
        if r then
            file:write(cp.name
                .. " | index=" .. tostring(cp.index)
                .. " | status=" .. tostring(r.status)
                .. " | " .. stateText(r.values)
                .. " | differences="
                .. table.concat(r.differences or {}, "; ")
                .. "\n")
        else
            file:write(cp.name .. " | NAO_ATINGIDO\n")
        end
    end

    file:write("\nLog: " .. tostring(logPath) .. "\n")
    file:close()
end

local function finish(finalOutcome, values)
    if not running then return end

    outcome = finalOutcome
    outcomeFrame = emu.framecount()
    running = false
    phase = "DONE"

    clearController()
    writeLog("OUTCOME_" .. finalOutcome, "", values, {})
    closeLog()

    if mode == "CAPTURE_REFERENCE" and finalOutcome ~= "TIMEOUT" then
        saveReference()
    end

    writeSummary(values)

    setStatus("CONCLUIDO")
    setPhase("DONE")
    setProgress("100%")
    setResult(
        "Resultado: " .. finalOutcome
        .. "\nPrimeiro desync: "
        .. tostring(firstDesyncCheckpoint or "nenhum")
        .. "\nResumo: " .. summaryPath
    )

    log("Resultado=" .. finalOutcome)
    log("Resumo=" .. summaryPath)
end

local function validateInitialState(values)
    if values.death ~= 0 then
        return false, "death inicial diferente de 0"
    end
    if values.state == 2 then
        return false, "state inicial indica morto"
    end
    if values.pointer == 0 then
        return false, "ponteiro inicial zerado"
    end
    return true, nil
end

local function startRun(selectedMode)
    if running or #replayRows == 0 then return end

    if selectedMode == "VALIDATE" and not referenceLoaded then
        setStatus("REFERENCIA AUSENTE")
        setResult("Capture uma referencia primeiro.")
        return
    end

    routeLimit = clampInteger(
        forms.gettext(routeLimitBox),
        1,
        #replayRows,
        DEFAULT_ROUTE_LIMIT
    )

    timeoutFrames = clampInteger(
        forms.gettext(timeoutBox),
        routeLimit,
        3000,
        DEFAULT_TIMEOUT_FRAMES
    )

    local values = readState()
    local valid, reason = validateInitialState(values)

    if not valid then
        setStatus("ESTADO INICIAL INVALIDO")
        setResult("Recarregue o savestate.\nMotivo: "
            .. tostring(reason) .. "\n" .. stateText(values))
        return
    end

    mode = selectedMode == "VALIDATE"
        and "VALIDATE"
        or "CAPTURE_REFERENCE"

    routeIndex = 1
    shotPressTransitions = 0
    previousZ = false
    checkpointResults = {}
    desyncDetected = false
    firstDesyncCheckpoint = nil
    outcome = nil

    startEmuFrame = emu.framecount()
    openLog()
    writeLog("START", "", values, {})

    running = true
    phase = "ROUTE"

    setStatus("EXECUTANDO")
    setPhase("ROUTE")
    setResult(mode == "CAPTURE_REFERENCE"
        and "Capturando referencia..."
        or "Validando tentativa...")

    log("Execucao iniciada | modo=" .. mode)
end

local function processCheckpoint(cp, values)
    if not cp then return end

    if mode == "CAPTURE_REFERENCE" then
        reference[cp.name] = values
        checkpointResults[cp.name] = {
            status = "REFERENCE_CAPTURED",
            values = values,
            differences = {}
        }
        writeLog("CHECKPOINT_CAPTURE", cp.name, values, {})
    else
        local ref = reference[cp.name]
        local differences = ref and compareValues(ref, values)
            or {"reference_missing"}

        local status = #differences == 0 and "MATCH" or "DESYNC"

        checkpointResults[cp.name] = {
            status = status,
            values = values,
            differences = differences
        }

        if status == "DESYNC" and not desyncDetected then
            desyncDetected = true
            firstDesyncCheckpoint = cp.name
        end

        writeLog("CHECKPOINT_COMPARE", cp.name, values, differences)
    end
end

local function loadDefaultCsv()
    selectedCsvPath = DEFAULT_CSV

    if not fileExists(selectedCsvPath) then
        setStatus("CSV PADRAO AUSENTE")
        setResult("Arquivo ausente: " .. selectedCsvPath)
        return
    end

    local rows, err = loadReplay(selectedCsvPath)
    if not rows then
        setStatus("ERRO AO CARREGAR CSV")
        setResult(tostring(err))
        return
    end

    replayRows = rows
    setStatus("PRONTO")
    setResult("CSV carregado | frames=" .. tostring(#replayRows))
    log("CSV carregado | frames=" .. tostring(#replayRows))
end

form = forms.newform(
    900,
    610,
    "GoldenEyeDiagnostic " .. VERSION,
    function() stopped = true end
)

forms.label(form,
    "Replay Alignment Validation — referencia e deteccao de desync",
    12, 10, 860, 24)

statusLabel = forms.label(form,
    "Status: inicializando", 12, 40, 860, 24)

phaseLabel = forms.label(form,
    "Fase: IDLE", 12, 70, 860, 24)

progressLabel = forms.label(form,
    "Progresso: 0%", 12, 100, 860, 24)

memoryLabel = forms.label(form,
    "Memoria: aguardando", 12, 130, 860, 48, true)

referenceLabel = forms.label(form,
    "Referencia: verificando...", 12, 180, 860, 40, true)

resultLabel = forms.label(form,
    "Nenhuma execucao", 12, 225, 860, 60, true)

forms.label(form, "Limite da rota", 12, 305, 100, 22)
routeLimitBox = forms.textbox(form,
    tostring(DEFAULT_ROUTE_LIMIT),
    80, 24, nil, 115, 302)

forms.label(form, "Timeout", 220, 305, 60, 22)
timeoutBox = forms.textbox(form,
    tostring(DEFAULT_TIMEOUT_FRAMES),
    80, 24, nil, 285, 302)

forms.button(form, "CAPTURAR REFERENCIA",
    function() pendingMode = "CAPTURE" end,
    390, 298, 200, 38)

forms.button(form, "VALIDAR TENTATIVA",
    function() pendingMode = "VALIDATE" end,
    605, 298, 180, 38)

forms.button(form, "ABORTAR",
    function()
        if running then
            finish("TIMEOUT", readState())
        end
    end,
    12, 350, 120, 36)

forms.label(form,
    "Procedimento:\n"
    .. "1. Recarregue o savestate e clique em CAPTURAR REFERENCIA.\n"
    .. "2. Aguarde terminar; a referencia sera salva em output.\n"
    .. "3. Recarregue exatamente o mesmo savestate.\n"
    .. "4. Clique em VALIDAR TENTATIVA.\n"
    .. "5. O script compara START, SOLDIER_VISIBLE, antes/depois dos tiros e END.\n\n"
    .. "Resultados:\n"
    .. "• KILL: matou o soldado.\n"
    .. "• MISS: terminou alinhado, mas nao matou.\n"
    .. "• ROUTE_DESYNC: divergiu da referencia antes do fim.\n"
    .. "• TIMEOUT: interrompido ou excedeu limite.",
    12, 400, 860, 180)

console.clear()
log("Carregado | versao=" .. VERSION)
log("ROM=" .. tostring(gameinfo.getromname()))
log("Hash=" .. tostring(gameinfo.getromhash()))

loadDefaultCsv()
loadReference()

event.onexit(function()
    clearController()
    if running and logFile then
        closeLog()
    end
    stopped = true
end, "GoldenEyeDiagnostic-0.0.5.1-exit")

while not stopped do
    if pendingMode and not running then
        local selected = pendingMode
        pendingMode = nil

        local ok, err = pcall(function()
            startRun(selected)
        end)

        if not ok then
            setStatus("ERRO")
            setResult(tostring(err))
            log("ERRO ao iniciar: " .. tostring(err))
        end
    end

    local values = readState()
    forms.settext(memoryLabel, "Memoria: " .. stateText(values))

    if running then
        if killDetected(values) then
            finish("KILL", values)
        elseif emu.framecount() - startEmuFrame >= timeoutFrames then
            finish("TIMEOUT", values)
        elseif routeIndex <= routeLimit then
            local cp = findCheckpoint(routeIndex)
            if cp then
                processCheckpoint(cp, values)
            end

            local row = replayRows[routeIndex]
            local zPressed = row.digital and row.digital["Z"] == true

            if zPressed and not previousZ then
                shotPressTransitions = shotPressTransitions + 1
            end
            previousZ = zPressed

            applyInput(row.digital, row.analog)
            writeLog(row.event, "", values, {})

            setProgress(tostring(routeIndex) .. "/" .. tostring(routeLimit))

            routeIndex = routeIndex + 1
            emu.frameadvance()
        else
            clearController()

            local finalOutcome
            if mode == "VALIDATE" and desyncDetected then
                finalOutcome = "ROUTE_DESYNC"
            else
                finalOutcome = "MISS"
            end

            finish(finalOutcome, values)
        end
    else
        emu.yield()
    end

    gui.drawString(
        8, 8,
        "GoldenEyeDiagnostic " .. VERSION .. " | " .. phase,
        "white", "black", 12
    )

    gui.drawString(
        8, 26,
        "Modo=" .. tostring(mode)
        .. " indice=" .. tostring(routeIndex)
        .. " tiros=" .. tostring(shotPressTransitions),
        "white", "black", 12
    )
end
