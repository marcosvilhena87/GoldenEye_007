-- GoldenEyeDiagnostic 0.0.4.8
-- Frame-Locked Automatic Combat
--
-- Correcoes principais:
-- 1. Cada input ocupa exatamente um frame emulado via emu.frameadvance().
-- 2. hit_3CB7F nao e mais tratado como prova automatica de acerto.
-- 3. Resultados: KILL, MISS, UNKNOWN ou TIMEOUT.
-- 4. Detecta ROUTE_HIT_SIGNAL quando hit_3CB7F muda antes do combate.
--
-- Somente leitura de memoria via mainmemory.

local VERSION = "0.0.4.8"
local CONTROLLER = 1
local EXPECTED_ROM_HASH = "ABE01E4AEB033B6C0836819F549C791B26CFDE83"

local DEFAULT_ROUTE_CUT = 833
local DEFAULT_SHOTS = 2
local DEFAULT_PRESS_FRAMES = 5
local DEFAULT_RELEASE_FRAMES = 5
local DEFAULT_OBSERVE_FRAMES = 240

local ADDR_STATE = 0x00030A37
local ADDR_DEATH = 0x00030A6B
local ADDR_HIT_SIGNAL = 0x0003CB7F
local ADDR_POINTER = 0x001F421C

local stopped = false
local running = false
local pendingStart = false
local phase = "IDLE"

local replayRows = {}
local routeRows = {}
local combatSequence = {}

local routeIndex = 1
local combatIndex = 1
local observeIndex = 0

local selectedCsvPath = nil
local routeCutIndex = DEFAULT_ROUTE_CUT

local startEmuFrame = nil
local combatStartFrame = nil
local outcomeFrame = nil
local outcome = nil

local initialState = nil
local initialDeath = nil
local initialHitSignal = nil
local initialPointer = nil

local routeHitSignal = false
local combatHitSignal = false
local sawKill = false

local logFile = nil
local logPath = nil
local summaryPath = nil
local lastMemoryText = nil

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

os.execute('if not exist "' .. OUTPUT_DIR .. '" mkdir "' .. OUTPUT_DIR .. '"')

local function log(text)
    console.log("[GoldenEyeDiagnostic] " .. text)
end

local function fileExists(path)
    local file = io.open(path, "r")
    if file then
        file:close()
        return true
    end
    return false
end

local function parseCsvLine(line)
    local fields = {}
    local field = ""
    local quoted = false
    local i = 1

    while i <= #line do
        local char = line:sub(i, i)

        if quoted then
            if char == '"' then
                if line:sub(i + 1, i + 1) == '"' then
                    field = field .. '"'
                    i = i + 1
                else
                    quoted = false
                end
            else
                field = field .. char
            end
        else
            if char == '"' then
                quoted = true
            elseif char == "," then
                table.insert(fields, field)
                field = ""
            else
                field = field .. char
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

local function appendFrames(sequence, count, digital, label)
    for _ = 1, count do
        table.insert(sequence, {
            digital = digital or {},
            analog = {
                ["X Axis"] = 0,
                ["Y Axis"] = 0
            },
            label = label
        })
    end
end

local function buildCombatSequence(waitFrames, shotCount, pressFrames, releaseFrames)
    local sequence = {}

    appendFrames(sequence, waitFrames, {}, "WAIT")

    for shot = 1, shotCount do
        appendFrames(
            sequence,
            pressFrames,
            { ["Z"] = true },
            "SHOT_" .. tostring(shot)
        )

        if shot < shotCount then
            appendFrames(
                sequence,
                releaseFrames,
                {},
                "RELEASE_" .. tostring(shot)
            )
        end
    end

    return sequence
end

local function readU32BE(address)
    if mainmemory.read_u32_be then
        return mainmemory.read_u32_be(address)
    end

    local b0 = mainmemory.read_u8(address)
    local b1 = mainmemory.read_u8(address + 1)
    local b2 = mainmemory.read_u8(address + 2)
    local b3 = mainmemory.read_u8(address + 3)

    return b0 * 0x1000000
        + b1 * 0x10000
        + b2 * 0x100
        + b3
end

local function readCombatState()
    return {
        state = mainmemory.read_u8(ADDR_STATE),
        death = mainmemory.read_u8(ADDR_DEATH),
        hitSignal = mainmemory.read_u8(ADDR_HIT_SIGNAL),
        pointer = readU32BE(ADDR_POINTER)
    }
end

local function memoryText(values)
    return "state=" .. tostring(values.state)
        .. " | death=" .. tostring(values.death)
        .. " | hitSignal=" .. tostring(values.hitSignal)
        .. " | ptr=0x" .. string.format("%08X", values.pointer)
end

local statusLabel
local phaseLabel
local progressLabel
local memoryLabel
local resultLabel
local cutBox
local waitBox
local shotsBox
local pressBox
local releaseBox
local observeBox
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

local function openLog()
    local timestamp = os.date("%Y%m%d-%H%M%S")

    logPath = OUTPUT_DIR
        .. "frame-locked-combat-" .. timestamp .. "-log.csv"
    summaryPath = OUTPUT_DIR
        .. "frame-locked-combat-" .. timestamp .. "-summary.txt"

    logFile = assert(io.open(logPath, "w"))
    logFile:write(
        "relative_frame,emu_frame,phase,index,event,"
        .. "state,death,hit_signal,pointer_hex\n"
    )
end

local function writeLogRow(index, eventName, values)
    if not logFile then return end

    local frame = emu.framecount()
    local relative = frame - startEmuFrame

    logFile:write(
        tostring(relative) .. ","
        .. tostring(frame) .. ","
        .. tostring(phase) .. ","
        .. tostring(index or "") .. ","
        .. tostring(eventName or "") .. ","
        .. tostring(values.state) .. ","
        .. tostring(values.death) .. ","
        .. tostring(values.hitSignal) .. ","
        .. string.format("0x%08X", values.pointer) .. "\n"
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

local function killDetected(values)
    return values.death == 1
        or values.state == 2
        or (
            initialPointer ~= 0
            and values.pointer == 0
        )
end

local function classifyFinal(values, observeLimitReached)
    if killDetected(values) then
        return "KILL"
    end

    if observeLimitReached then
        if routeHitSignal or combatHitSignal then
            return "UNKNOWN"
        end
        return "MISS"
    end

    return "TIMEOUT"
end

local function writeSummary(finalValues)
    local file = assert(io.open(summaryPath, "w"))

    file:write("GoldenEyeDiagnostic " .. VERSION .. "\n")
    file:write("ROM: " .. tostring(gameinfo.getromname()) .. "\n")
    file:write("Hash: " .. tostring(gameinfo.getromhash()) .. "\n")
    file:write("CSV: " .. tostring(selectedCsvPath) .. "\n")
    file:write("Route cut index: " .. tostring(routeCutIndex) .. "\n")
    file:write("Start frame: " .. tostring(startEmuFrame) .. "\n")
    file:write("Combat start frame: " .. tostring(combatStartFrame) .. "\n")
    file:write("Outcome frame: " .. tostring(outcomeFrame) .. "\n")

    if combatStartFrame and outcomeFrame then
        file:write("Frames from combat to outcome: "
            .. tostring(outcomeFrame - combatStartFrame) .. "\n")
    end

    file:write("\nInitial memory:\n")
    file:write("state=" .. tostring(initialState) .. "\n")
    file:write("death=" .. tostring(initialDeath) .. "\n")
    file:write("hitSignal=" .. tostring(initialHitSignal) .. "\n")
    file:write("pointer=0x"
        .. string.format("%08X", initialPointer or 0) .. "\n")

    file:write("\nFinal memory:\n")
    file:write("state=" .. tostring(finalValues.state) .. "\n")
    file:write("death=" .. tostring(finalValues.death) .. "\n")
    file:write("hitSignal=" .. tostring(finalValues.hitSignal) .. "\n")
    file:write("pointer=0x"
        .. string.format("%08X", finalValues.pointer) .. "\n")

    file:write("\nRoute hit signal: " .. tostring(routeHitSignal) .. "\n")
    file:write("Combat hit signal: " .. tostring(combatHitSignal) .. "\n")
    file:write("Saw kill: " .. tostring(sawKill) .. "\n")
    file:write("Outcome: " .. tostring(outcome) .. "\n")
    file:write("Log: " .. tostring(logPath) .. "\n")
    file:write("\nImportant: hitSignal is diagnostic only and does not prove a hit.\n")
    file:close()
end

local function finishTest(finalOutcome, values)
    if not running then return end

    outcome = finalOutcome
    outcomeFrame = emu.framecount()
    running = false
    phase = "DONE"

    clearController()
    writeLogRow("", "OUTCOME_" .. outcome, values)
    closeLog()
    writeSummary(values)

    setStatus("CONCLUIDO")
    setPhase("DONE")
    setProgress("100%")
    setResult(
        "Resultado: " .. outcome
        .. " | " .. memoryText(values)
        .. "\nResumo: " .. summaryPath
    )

    log("Resultado=" .. outcome)
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

local function startTest()
    if running or #replayRows == 0 then return end

    routeCutIndex = clampInteger(
        forms.gettext(cutBox),
        1,
        #replayRows,
        DEFAULT_ROUTE_CUT
    )

    local waitFrames = clampInteger(forms.gettext(waitBox), 0, 180, 0)
    local shotCount = clampInteger(forms.gettext(shotsBox), 1, 6, DEFAULT_SHOTS)
    local pressFrames = clampInteger(
        forms.gettext(pressBox), 1, 30, DEFAULT_PRESS_FRAMES
    )
    local releaseFrames = clampInteger(
        forms.gettext(releaseBox), 1, 30, DEFAULT_RELEASE_FRAMES
    )

    routeRows = {}
    for i = 1, routeCutIndex do
        routeRows[i] = replayRows[i]
    end

    combatSequence = buildCombatSequence(
        waitFrames,
        shotCount,
        pressFrames,
        releaseFrames
    )

    routeIndex = 1
    combatIndex = 1
    observeIndex = 0

    routeHitSignal = false
    combatHitSignal = false
    sawKill = false
    outcome = nil
    outcomeFrame = nil
    lastMemoryText = nil

    local values = readCombatState()
    local valid, reason = validateInitialState(values)

    if not valid then
        setStatus("ESTADO INICIAL INVALIDO")
        setResult(
            "Recarregue o savestate.\nMotivo: " .. tostring(reason)
            .. "\n" .. memoryText(values)
        )
        log("Inicio rejeitado | " .. tostring(reason)
            .. " | " .. memoryText(values))
        return
    end

    initialState = values.state
    initialDeath = values.death
    initialHitSignal = values.hitSignal
    initialPointer = values.pointer

    startEmuFrame = emu.framecount()
    combatStartFrame = nil

    openLog()
    writeLogRow(0, "START", values)

    phase = "ROUTE"
    running = true
    setStatus("EXECUTANDO")
    setPhase("ROUTE")
    setResult("Teste em andamento...")
    log("Teste iniciado | corte=" .. tostring(routeCutIndex))
end

local function loadDefaultCsv()
    selectedCsvPath = DEFAULT_CSV

    if not fileExists(selectedCsvPath) then
        setStatus("CSV padrao ausente")
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
    setResult(
        "CSV carregado | frames=" .. tostring(#replayRows)
        .. "\nCorte validado recomendado: 833"
    )
    log("CSV carregado | frames=" .. tostring(#replayRows))
end

form = forms.newform(
    840,
    540,
    "GoldenEyeDiagnostic " .. VERSION,
    function()
        stopped = true
    end
)

forms.label(form,
    "Frame-Locked Automatic Combat — um input por frame real",
    12, 10, 800, 24)

statusLabel = forms.label(form,
    "Status: inicializando", 12, 40, 800, 24)

phaseLabel = forms.label(form,
    "Fase: IDLE", 12, 70, 800, 24)

progressLabel = forms.label(form,
    "Progresso: 0%", 12, 100, 800, 24)

memoryLabel = forms.label(form,
    "Memoria: aguardando", 12, 130, 800, 48, true)

resultLabel = forms.label(form,
    "Nenhum teste executado",
    12, 180, 800, 58, true)

forms.label(form, "Corte da rota", 12, 255, 105, 22)
cutBox = forms.textbox(form,
    tostring(DEFAULT_ROUTE_CUT),
    70, 24, nil, 120, 252)

forms.label(form, "Espera", 205, 255, 55, 22)
waitBox = forms.textbox(form,
    "0", 55, 24, nil, 260, 252)

forms.label(form, "Tiros", 330, 255, 45, 22)
shotsBox = forms.textbox(form,
    tostring(DEFAULT_SHOTS),
    50, 24, nil, 375, 252)

forms.label(form, "Z pressionado", 440, 255, 90, 22)
pressBox = forms.textbox(form,
    tostring(DEFAULT_PRESS_FRAMES),
    50, 24, nil, 535, 252)

forms.label(form, "Intervalo", 600, 255, 60, 22)
releaseBox = forms.textbox(form,
    tostring(DEFAULT_RELEASE_FRAMES),
    50, 24, nil, 665, 252)

forms.label(form, "Observacao", 12, 300, 80, 22)
observeBox = forms.textbox(form,
    tostring(DEFAULT_OBSERVE_FRAMES),
    70, 24, nil, 95, 297)

forms.button(form, "INICIAR TESTE",
    function()
        pendingStart = true
    end,
    190, 294, 160, 36)

forms.button(form, "ABORTAR",
    function()
        if running then
            local values = readCombatState()
            finishTest("TIMEOUT", values)
        end
    end,
    365, 294, 120, 36)

forms.label(form,
    "Resultados:\n"
    .. "• KILL: death=1, state=2 ou ponteiro zerado.\n"
    .. "• MISS: nenhuma morte e nenhum sinal auxiliar mudou.\n"
    .. "• UNKNOWN: hitSignal mudou, mas isso nao prova acerto visual.\n"
    .. "• TIMEOUT: interrupcao ou estado invalido.\n\n"
    .. "Cada etapa de rota, tiro, intervalo e observacao agora ocupa "
    .. "exatamente um frame emulado.",
    12, 350, 800, 165)

console.clear()
log("Carregado | versao=" .. VERSION)
log("ROM=" .. tostring(gameinfo.getromname()))
log("Hash=" .. tostring(gameinfo.getromhash()))

local currentHash = tostring(gameinfo.getromhash())
if currentHash ~= EXPECTED_ROM_HASH then
    log("AVISO | hash esperado=" .. EXPECTED_ROM_HASH
        .. " | atual=" .. currentHash)
end

loadDefaultCsv()

event.onexit(function()
    clearController()

    if running and logFile then
        local values = readCombatState()
        outcome = "TIMEOUT"
        outcomeFrame = emu.framecount()
        writeLogRow("", "SCRIPT_EXIT", values)
        closeLog()
        writeSummary(values)
    end

    stopped = true
end, "GoldenEyeDiagnostic-0.0.4.8-exit")

while not stopped do
    if pendingStart and not running then
        pendingStart = false

        local ok, err = pcall(startTest)
        if not ok then
            setStatus("ERRO")
            setResult(tostring(err))
            log("ERRO ao iniciar: " .. tostring(err))
        end
    end

    local values = readCombatState()
    local currentMemoryText = memoryText(values)

    forms.settext(memoryLabel,
        "Memoria: " .. currentMemoryText)

    if running then
        if values.hitSignal ~= initialHitSignal then
            if phase == "ROUTE" then
                routeHitSignal = true
            else
                combatHitSignal = true
            end
        end

        if killDetected(values) then
            sawKill = true
        end

        if currentMemoryText ~= lastMemoryText then
            local eventName = "MEMORY_CHANGE"

            if phase == "ROUTE"
                and values.hitSignal ~= initialHitSignal then
                eventName = "ROUTE_HIT_SIGNAL"
            elseif phase ~= "ROUTE"
                and values.hitSignal ~= initialHitSignal then
                eventName = "COMBAT_HIT_SIGNAL"
            end

            writeLogRow("", eventName, values)
            lastMemoryText = currentMemoryText
        end

        if sawKill then
            finishTest("KILL", values)
        elseif phase == "ROUTE" then
            if routeIndex <= #routeRows then
                local row = routeRows[routeIndex]
                applyInput(row.digital, row.analog)
                writeLogRow(routeIndex, row.event, values)

                setProgress(
                    tostring(routeIndex)
                    .. "/" .. tostring(#routeRows)
                )

                routeIndex = routeIndex + 1
                emu.frameadvance()
            else
                clearController()
                phase = "COMBAT"
                combatStartFrame = emu.framecount()
                setPhase("COMBAT")
                log("Combate iniciado | frame="
                    .. tostring(combatStartFrame))
            end
        elseif phase == "COMBAT" then
            if combatIndex <= #combatSequence then
                local row = combatSequence[combatIndex]
                applyInput(row.digital, row.analog)
                writeLogRow(combatIndex, row.label, values)

                setProgress(
                    tostring(combatIndex)
                    .. "/" .. tostring(#combatSequence)
                )

                combatIndex = combatIndex + 1
                emu.frameadvance()
            else
                clearController()
                phase = "OBSERVE"
                observeIndex = 0
                setPhase("OBSERVE")
            end
        elseif phase == "OBSERVE" then
            clearController()

            local observeLimit = clampInteger(
                forms.gettext(observeBox),
                30,
                900,
                DEFAULT_OBSERVE_FRAMES
            )

            observeIndex = observeIndex + 1
            setProgress(
                tostring(observeIndex)
                .. "/" .. tostring(observeLimit)
            )

            if observeIndex >= observeLimit then
                local finalOutcome = classifyFinal(values, true)
                finishTest(finalOutcome, values)
            else
                emu.frameadvance()
            end
        end
    else
        emu.yield()
    end

    gui.drawString(
        8,
        8,
        "GoldenEyeDiagnostic " .. VERSION
        .. " | " .. phase,
        "white",
        "black",
        12
    )

    gui.drawString(
        8,
        26,
        "state=" .. tostring(values.state)
        .. " death=" .. tostring(values.death)
        .. " hitSignal=" .. tostring(values.hitSignal),
        "white",
        "black",
        12
    )
end
