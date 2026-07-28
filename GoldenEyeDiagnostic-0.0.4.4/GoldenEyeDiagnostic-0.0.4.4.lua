-- GoldenEyeDiagnostic 0.0.4.4
-- MainMemory Snapshot Diagnostic para GoldenEye 007 (N64) no BizHawk.
-- Somente leitura.
--
-- Esta versao abandona memory.* / System Bus e usa mainmemory.*.
-- Antes dos snapshots, executa um teste de atividade para confirmar
-- que a memoria principal realmente esta mudando.

local VERSION = "0.0.4.4"
local EXPECTED_ROM_HASH = "ABE01E4AEB033B6C0836819F549C791B26CFDE83"

local FALLBACK_SIZE = 0x800000
local BLOCK_SIZE = 0x4000
local PROBE_SIZE = 0x40000
local MAX_RESULTS = 5000

local stopped = false
local busy = false
local pendingOperation = nil
local mainMemorySize = 0
local activityConfirmed = false

local snapshots = {}
local snapshotMeta = {}

local form
local statusLabel
local memoryLabel
local progressLabel
local resultLabel

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

local function setProgress(text)
    forms.settext(progressLabel, "Progresso: " .. text)
end

local function detectMainMemorySize()
    local size = nil

    if mainmemory.getcurrentmemorydomainsize then
        local ok, value = pcall(mainmemory.getcurrentmemorydomainsize)
        if ok and type(value) == "number" and value > 0 then
            size = value
        end
    end

    if not size and mainmemory.getmemorydomainsize then
        local ok, value = pcall(mainmemory.getmemorydomainsize)
        if ok and type(value) == "number" and value > 0 then
            size = value
        end
    end

    if not size then
        size = FALLBACK_SIZE
        log("Tamanho da mainmemory indisponivel; usando fallback=0x"
            .. string.format("%X", size))
    end

    if size > FALLBACK_SIZE then
        size = FALLBACK_SIZE
    end

    if size < 0x400000 then
        error("MainMemory pequena demais: 0x"
            .. string.format("%X", size))
    end

    mainMemorySize = size

    forms.settext(memoryLabel,
        "MainMemory: tamanho=0x" .. string.format("%X", mainMemorySize))

    log("MainMemory selecionada | tamanho=0x"
        .. string.format("%X", mainMemorySize))
end

local function readBlock(address, length)
    if mainmemory.read_bytes_as_array then
        local ok, data = pcall(
            mainmemory.read_bytes_as_array,
            address,
            length
        )

        if ok and data and #data == length then
            return data
        end
    end

    local data = {}
    for i = 0, length - 1 do
        local ok, value = pcall(mainmemory.read_u8, address + i)
        if not ok then
            return nil, tostring(value)
        end
        data[i + 1] = value
    end

    return data
end

local function captureRange(size)
    local data = {}
    local offset = 0

    while offset < size and not stopped do
        local length = math.min(BLOCK_SIZE, size - offset)
        local block, err = readBlock(offset, length)

        if not block then
            return nil, err
        end

        for i = 1, #block do
            data[offset + i] = block[i]
        end

        offset = offset + length
        emu.yield()
    end

    return data
end

local function countDifferences(a, b)
    local changed = 0
    local limit = math.min(#a, #b)

    for i = 1, limit do
        if a[i] ~= b[i] then
            changed = changed + 1
        end
    end

    return changed
end

local function countNonZero(data)
    local count = 0

    for i = 1, #data do
        if data[i] ~= 0 then
            count = count + 1
        end
    end

    return count
end

local function testActivity()
    busy = true
    activityConfirmed = false
    setStatus("testando atividade da MainMemory")
    setProgress("amostra 1/2")

    local first, err1 = captureRange(PROBE_SIZE)
    if not first then
        busy = false
        error("Falha na primeira amostra: " .. tostring(err1))
    end

    -- O jogo precisa avancar para timers, animacoes e IA mudarem.
    for _ = 1, 10 do
        emu.frameadvance()
    end

    setProgress("amostra 2/2")
    local second, err2 = captureRange(PROBE_SIZE)
    if not second then
        busy = false
        error("Falha na segunda amostra: " .. tostring(err2))
    end

    local changed = countDifferences(first, second)
    local nonZero = countNonZero(first)

    log("Teste de atividade | bytes=" .. tostring(PROBE_SIZE)
        .. " | alterados=" .. tostring(changed)
        .. " | naoZero=" .. tostring(nonZero))

    if changed == 0 then
        busy = false
        setStatus("ERRO: MainMemory permaneceu estatica")
        forms.settext(resultLabel,
            "Teste falhou: 0 bytes alterados na MainMemory")
        return
    end

    activityConfirmed = true
    setStatus("atividade confirmada; pronto para BASELINE")
    setProgress("concluido")
    forms.settext(resultLabel,
        "MainMemory ativa | bytes alterados no probe=" .. tostring(changed))
    busy = false
end

local function captureSnapshot(name)
    if not activityConfirmed then
        setStatus("execute TESTAR ATIVIDADE primeiro")
        return
    end

    busy = true
    setStatus("capturando " .. name)
    setProgress("0%")
    log("Inicio do snapshot " .. name)

    local data = {}
    local offset = 0

    while offset < mainMemorySize and not stopped do
        local length = math.min(BLOCK_SIZE, mainMemorySize - offset)
        local block, err = readBlock(offset, length)

        if not block then
            busy = false
            error("Falha em 0x" .. string.format("%08X", offset)
                .. ": " .. tostring(err))
        end

        for i = 1, #block do
            data[offset + i] = block[i]
        end

        offset = offset + length

        setProgress(name .. ": "
            .. string.format("%.1f%%", (offset / mainMemorySize) * 100))

        emu.yield()
    end

    if stopped then
        busy = false
        return
    end

    snapshots[name] = data
    snapshotMeta[name] = {
        frame = emu.framecount(),
        time = os.date("%Y-%m-%d %H:%M:%S")
    }

    forms.settext(resultLabel,
        "Capturados: BASELINE=" .. tostring(snapshots.BASELINE ~= nil)
        .. " | HIT=" .. tostring(snapshots.HIT ~= nil)
        .. " | DEAD=" .. tostring(snapshots.DEAD ~= nil))

    setStatus(name .. " capturado")
    setProgress("100%")
    log("Snapshot concluido=" .. name
        .. " | frame=" .. tostring(emu.framecount()))
    busy = false
end

local function writeSnapshotInfo(file, name)
    local meta = snapshotMeta[name]

    file:write(name
        .. ": frame=" .. tostring(meta.frame)
        .. ", time=" .. tostring(meta.time) .. "\n")
end

local function analyze()
    if not snapshots.BASELINE or not snapshots.HIT or not snapshots.DEAD then
        setStatus("capture BASELINE, HIT e DEAD primeiro")
        return
    end

    busy = true
    setStatus("analisando snapshots")
    setProgress("0%")

    local timestamp = os.date("%Y%m%d-%H%M%S")
    local candidatesPath = OUTPUT_DIR
        .. "soldier-state-" .. timestamp .. "-candidates.csv"
    local summaryPath = OUTPUT_DIR
        .. "soldier-state-" .. timestamp .. "-summary.txt"

    local baseline = snapshots.BASELINE
    local hit = snapshots.HIT
    local dead = snapshots.DEAD

    local deathOnly = {}
    local progressive = {}
    local hitOnly = {}
    local changed = 0

    for address = 0, mainMemorySize - 1 do
        local i = address + 1
        local a = baseline[i]
        local b = hit[i]
        local c = dead[i]

        if a ~= b or b ~= c then
            changed = changed + 1

            if a == b and b ~= c then
                table.insert(deathOnly, {
                    address = address,
                    baseline = a,
                    hit = b,
                    dead = c,
                    score = 100
                })
            elseif a ~= b and b == c then
                table.insert(hitOnly, {
                    address = address,
                    baseline = a,
                    hit = b,
                    dead = c,
                    score = 70
                })
            elseif a ~= b and b ~= c then
                local monotonic =
                    (a < b and b < c) or (a > b and b > c)

                table.insert(progressive, {
                    address = address,
                    baseline = a,
                    hit = b,
                    dead = c,
                    score = monotonic and 90 or 60
                })
            end
        end

        if address % BLOCK_SIZE == 0 then
            setProgress(string.format("%.1f%%",
                (address / mainMemorySize) * 100))
            emu.yield()
        end
    end

    local function sorter(x, y)
        if x.score ~= y.score then
            return x.score > y.score
        end
        return x.address < y.address
    end

    table.sort(deathOnly, sorter)
    table.sort(progressive, sorter)
    table.sort(hitOnly, sorter)

    local csv = assert(io.open(candidatesPath, "w"))
    csv:write(
        "category,score,address_hex,address_dec,"
        .. "baseline,hit,dead\n"
    )

    local written = 0

    local function writeRows(category, rows)
        for _, row in ipairs(rows) do
            if written >= MAX_RESULTS then
                break
            end

            csv:write(
                category .. ","
                .. tostring(row.score) .. ","
                .. string.format("0x%08X", row.address) .. ","
                .. tostring(row.address) .. ","
                .. tostring(row.baseline) .. ","
                .. tostring(row.hit) .. ","
                .. tostring(row.dead) .. "\n"
            )

            written = written + 1
        end
    end

    writeRows("DEATH_ONLY", deathOnly)
    writeRows("PROGRESSIVE", progressive)
    writeRows("HIT_ONLY", hitOnly)
    csv:close()

    local summary = assert(io.open(summaryPath, "w"))
    summary:write("GoldenEyeDiagnostic " .. VERSION .. "\n")
    summary:write("ROM: " .. tostring(gameinfo.getromname()) .. "\n")
    summary:write("Hash: " .. tostring(gameinfo.getromhash()) .. "\n")
    summary:write("API: mainmemory\n")
    summary:write("Tamanho: 0x"
        .. string.format("%X", mainMemorySize) .. "\n\n")

    writeSnapshotInfo(summary, "BASELINE")
    writeSnapshotInfo(summary, "HIT")
    writeSnapshotInfo(summary, "DEAD")

    summary:write("\nBytes alterados: " .. tostring(changed) .. "\n")
    summary:write("Candidatos DEATH_ONLY: "
        .. tostring(#deathOnly) .. "\n")
    summary:write("Candidatos PROGRESSIVE: "
        .. tostring(#progressive) .. "\n")
    summary:write("Candidatos HIT_ONLY: "
        .. tostring(#hitOnly) .. "\n")
    summary:write("Linhas exportadas: "
        .. tostring(written) .. "\n")
    summary:write("CSV: " .. candidatesPath .. "\n")
    summary:close()

    forms.settext(resultLabel,
        "Alterados=" .. tostring(changed)
        .. " | DEATH_ONLY=" .. tostring(#deathOnly)
        .. " | PROGRESSIVE=" .. tostring(#progressive))

    setStatus("analise concluida")
    setProgress("100%")

    log("Analise concluida")
    log("Bytes alterados=" .. tostring(changed))
    log("CSV=" .. candidatesPath)
    log("Resumo=" .. summaryPath)

    busy = false
end

local function schedule(operation)
    if busy or pendingOperation then
        setStatus("aguarde a operacao atual")
        return
    end

    pendingOperation = operation
    setStatus("operacao agendada: " .. operation)
end

local function clearSnapshots()
    if busy then
        return
    end

    snapshots = {}
    snapshotMeta = {}
    collectgarbage("collect")

    forms.settext(resultLabel, "Nenhum snapshot capturado")
    setStatus(activityConfirmed
        and "snapshots descartados; pronto para BASELINE"
        or "snapshots descartados; teste a atividade")
    setProgress("0%")
end

form = forms.newform(
    760,
    500,
    "GoldenEyeDiagnostic " .. VERSION,
    function()
        stopped = true
    end
)

forms.label(form,
    "MainMemory Snapshot Diagnostic — somente leitura",
    12, 10, 720, 24)

statusLabel = forms.label(form,
    "Status: inicializando", 12, 40, 720, 24)

memoryLabel = forms.label(form,
    "MainMemory: detectando...", 12, 70, 720, 24)

progressLabel = forms.label(form,
    "Progresso: 0%", 12, 100, 720, 24)

resultLabel = forms.label(form,
    "Nenhum snapshot capturado",
    12, 130, 720, 42, true)

forms.button(form, "0. TESTAR ATIVIDADE",
    function()
        schedule("TEST_ACTIVITY")
    end,
    12, 190, 165, 34)

forms.button(form, "1. BASELINE",
    function()
        schedule("BASELINE")
    end,
    187, 190, 120, 34)

forms.button(form, "2. HIT",
    function()
        schedule("HIT")
    end,
    317, 190, 100, 34)

forms.button(form, "3. DEAD",
    function()
        schedule("DEAD")
    end,
    427, 190, 100, 34)

forms.button(form, "4. ANALISAR",
    function()
        schedule("ANALYZE")
    end,
    537, 190, 115, 34)

forms.button(form, "DESCARTAR SNAPSHOTS",
    clearSnapshots,
    12, 240, 180, 32)

forms.label(form,
    "Procedimento:\n"
    .. "1. Com o jogo rodando, clique em TESTAR ATIVIDADE.\n"
    .. "2. O resultado precisa mostrar mais de 0 bytes alterados.\n"
    .. "3. Capture BASELINE com o soldado vivo.\n"
    .. "4. Acerte sem matar e capture HIT.\n"
    .. "5. Mate, espere o corpo estabilizar e capture DEAD.\n"
    .. "6. Clique em ANALISAR.\n\n"
    .. "Nao recarregue o savestate entre BASELINE, HIT e DEAD.",
    12, 290, 720, 180)

console.clear()
log("Carregado | versao=" .. VERSION)
log("ROM=" .. tostring(gameinfo.getromname()))
log("Hash=" .. tostring(gameinfo.getromhash()))

local currentHash = tostring(gameinfo.getromhash())
if currentHash ~= EXPECTED_ROM_HASH then
    log("AVISO | hash esperado=" .. EXPECTED_ROM_HASH
        .. " | atual=" .. currentHash)
end

local sizeOk, sizeErr = pcall(detectMainMemorySize)

if sizeOk then
    setStatus("clique em TESTAR ATIVIDADE com o jogo rodando")
else
    setStatus("ERRO: " .. tostring(sizeErr))
    log("ERRO=" .. tostring(sizeErr))
end

event.onexit(function()
    stopped = true
end, "GoldenEyeDiagnostic-0.0.4.4-exit")

while not stopped do
    if pendingOperation and not busy then
        local operation = pendingOperation
        pendingOperation = nil

        local operationOk, operationErr = pcall(function()
            if operation == "TEST_ACTIVITY" then
                testActivity()
            elseif operation == "BASELINE" then
                captureSnapshot("BASELINE")
            elseif operation == "HIT" then
                captureSnapshot("HIT")
            elseif operation == "DEAD" then
                captureSnapshot("DEAD")
            elseif operation == "ANALYZE" then
                analyze()
            end
        end)

        if not operationOk then
            busy = false
            setStatus("ERRO: " .. tostring(operationErr))
            log("ERRO na operacao " .. operation
                .. ": " .. tostring(operationErr))
        end
    end

    gui.drawString(8, 8,
        "GoldenEyeDiagnostic " .. VERSION
        .. (busy and " | PROCESSANDO" or " | AGUARDANDO"),
        "white", "black", 12)

    emu.yield()
end
