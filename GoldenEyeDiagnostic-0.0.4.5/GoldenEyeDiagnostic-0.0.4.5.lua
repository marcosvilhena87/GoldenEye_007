-- GoldenEyeDiagnostic 0.0.4.5
-- Stable Soldier State Filter
-- Somente leitura de memoria via mainmemory.
--
-- Capturas:
--   LIVE_A, LIVE_B
--   HIT_A, HIT_B
--   DEAD_A, DEAD_B
--
-- Mantem apenas bytes estaveis dentro de cada estado e diferentes
-- entre os estados relevantes.

local VERSION = "0.0.4.5"
local EXPECTED_ROM_HASH = "ABE01E4AEB033B6C0836819F549C791B26CFDE83"

local MEMORY_SIZE = 0x800000
local BLOCK_SIZE = 0x4000
local MAX_RESULTS = 10000

local stopped = false
local busy = false
local pendingOperation = nil
local snapshots = {}
local snapshotMeta = {}

local form
local statusLabel
local progressLabel
local captureLabel
local resultLabel

local CAPTURE_ORDER = {
    "LIVE_A", "LIVE_B",
    "HIT_A", "HIT_B",
    "DEAD_A", "DEAD_B"
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

local function setProgress(text)
    forms.settext(progressLabel, "Progresso: " .. text)
end

local function updateCaptureLabel()
    local parts = {}
    for _, name in ipairs(CAPTURE_ORDER) do
        table.insert(parts, name .. "=" .. tostring(snapshots[name] ~= nil))
    end
    forms.settext(captureLabel, table.concat(parts, " | "))
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

local function captureSnapshot(name)
    busy = true
    setStatus("capturando " .. name)
    setProgress("0%")
    log("Inicio do snapshot " .. name)

    local data = {}
    local offset = 0

    while offset < MEMORY_SIZE and not stopped do
        local length = math.min(BLOCK_SIZE, MEMORY_SIZE - offset)
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
            .. string.format("%.1f%%", (offset / MEMORY_SIZE) * 100))
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

    updateCaptureLabel()
    setStatus(name .. " capturado")
    setProgress("100%")
    log("Snapshot concluido=" .. name
        .. " | frame=" .. tostring(emu.framecount()))
    busy = false
end

local function allSnapshotsPresent()
    for _, name in ipairs(CAPTURE_ORDER) do
        if not snapshots[name] then
            return false, name
        end
    end
    return true, nil
end

local function analyze()
    local complete, missing = allSnapshotsPresent()
    if not complete then
        setStatus("snapshot ausente: " .. tostring(missing))
        return
    end

    busy = true
    setStatus("analisando estabilidade")
    setProgress("0%")

    local timestamp = os.date("%Y%m%d-%H%M%S")
    local candidatesPath = OUTPUT_DIR
        .. "stable-soldier-state-" .. timestamp .. "-candidates.csv"
    local summaryPath = OUTPUT_DIR
        .. "stable-soldier-state-" .. timestamp .. "-summary.txt"

    local liveA = snapshots.LIVE_A
    local liveB = snapshots.LIVE_B
    local hitA = snapshots.HIT_A
    local hitB = snapshots.HIT_B
    local deadA = snapshots.DEAD_A
    local deadB = snapshots.DEAD_B

    local deathOnly = {}
    local progressive = {}
    local hitPersistent = {}
    local liveDeadDifferent = {}

    local stableLive = 0
    local stableHit = 0
    local stableDead = 0
    local stableAll = 0

    for address = 0, MEMORY_SIZE - 1 do
        local i = address + 1

        local la, lb = liveA[i], liveB[i]
        local ha, hb = hitA[i], hitB[i]
        local da, db = deadA[i], deadB[i]

        local liveStable = la == lb
        local hitStable = ha == hb
        local deadStable = da == db

        if liveStable then stableLive = stableLive + 1 end
        if hitStable then stableHit = stableHit + 1 end
        if deadStable then stableDead = stableDead + 1 end

        if liveStable and hitStable and deadStable then
            stableAll = stableAll + 1

            local live = la
            local hit = ha
            local dead = da

            if live == hit and hit ~= dead then
                table.insert(deathOnly, {
                    address = address,
                    live = live,
                    hit = hit,
                    dead = dead,
                    score = 100
                })
            elseif live ~= hit and hit ~= dead then
                local monotonic =
                    (live < hit and hit < dead)
                    or (live > hit and hit > dead)

                table.insert(progressive, {
                    address = address,
                    live = live,
                    hit = hit,
                    dead = dead,
                    score = monotonic and 95 or 75
                })
            elseif live ~= hit and hit == dead then
                table.insert(hitPersistent, {
                    address = address,
                    live = live,
                    hit = hit,
                    dead = dead,
                    score = 85
                })
            elseif live ~= dead then
                table.insert(liveDeadDifferent, {
                    address = address,
                    live = live,
                    hit = hit,
                    dead = dead,
                    score = 70
                })
            end
        end

        if address % BLOCK_SIZE == 0 then
            setProgress(string.format("%.1f%%",
                (address / MEMORY_SIZE) * 100))
            emu.yield()
        end
    end

    local function sorter(a, b)
        if a.score ~= b.score then
            return a.score > b.score
        end
        return a.address < b.address
    end

    table.sort(deathOnly, sorter)
    table.sort(progressive, sorter)
    table.sort(hitPersistent, sorter)
    table.sort(liveDeadDifferent, sorter)

    local csv = assert(io.open(candidatesPath, "w"))
    csv:write(
        "category,score,address_hex,address_dec,live,hit,dead\n"
    )

    local written = 0

    local function writeRows(category, rows, perCategoryLimit)
        local count = 0

        for _, row in ipairs(rows) do
            if written >= MAX_RESULTS then break end
            if count >= perCategoryLimit then break end

            csv:write(
                category .. ","
                .. tostring(row.score) .. ","
                .. string.format("0x%08X", row.address) .. ","
                .. tostring(row.address) .. ","
                .. tostring(row.live) .. ","
                .. tostring(row.hit) .. ","
                .. tostring(row.dead) .. "\n"
            )

            written = written + 1
            count = count + 1
        end
    end

    -- Divide o limite para nao deixar uma categoria dominar todo o CSV.
    writeRows("DEATH_ONLY", deathOnly, 4000)
    writeRows("PROGRESSIVE", progressive, 2500)
    writeRows("HIT_PERSISTENT", hitPersistent, 2500)
    writeRows("LIVE_DEAD_DIFFERENT", liveDeadDifferent, 1000)

    csv:close()

    local summary = assert(io.open(summaryPath, "w"))
    summary:write("GoldenEyeDiagnostic " .. VERSION .. "\n")
    summary:write("ROM: " .. tostring(gameinfo.getromname()) .. "\n")
    summary:write("Hash: " .. tostring(gameinfo.getromhash()) .. "\n")
    summary:write("API: mainmemory\n")
    summary:write("Tamanho: 0x"
        .. string.format("%X", MEMORY_SIZE) .. "\n\n")

    for _, name in ipairs(CAPTURE_ORDER) do
        local meta = snapshotMeta[name]
        summary:write(name
            .. ": frame=" .. tostring(meta.frame)
            .. ", time=" .. tostring(meta.time) .. "\n")
    end

    summary:write("\nBytes estaveis em LIVE: "
        .. tostring(stableLive) .. "\n")
    summary:write("Bytes estaveis em HIT: "
        .. tostring(stableHit) .. "\n")
    summary:write("Bytes estaveis em DEAD: "
        .. tostring(stableDead) .. "\n")
    summary:write("Bytes estaveis nos tres estados: "
        .. tostring(stableAll) .. "\n\n")

    summary:write("Candidatos DEATH_ONLY: "
        .. tostring(#deathOnly) .. "\n")
    summary:write("Candidatos PROGRESSIVE: "
        .. tostring(#progressive) .. "\n")
    summary:write("Candidatos HIT_PERSISTENT: "
        .. tostring(#hitPersistent) .. "\n")
    summary:write("Candidatos LIVE_DEAD_DIFFERENT: "
        .. tostring(#liveDeadDifferent) .. "\n")
    summary:write("Linhas exportadas: "
        .. tostring(written) .. "\n")
    summary:write("CSV: " .. candidatesPath .. "\n")
    summary:close()

    forms.settext(resultLabel,
        "DEATH_ONLY=" .. tostring(#deathOnly)
        .. " | PROGRESSIVE=" .. tostring(#progressive)
        .. " | HIT_PERSISTENT=" .. tostring(#hitPersistent))

    setStatus("analise concluida")
    setProgress("100%")

    log("Analise concluida")
    log("Estaveis nos tres estados=" .. tostring(stableAll))
    log("DEATH_ONLY=" .. tostring(#deathOnly))
    log("PROGRESSIVE=" .. tostring(#progressive))
    log("HIT_PERSISTENT=" .. tostring(#hitPersistent))
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
    updateCaptureLabel()
    forms.settext(resultLabel, "Nenhum resultado")
    setStatus("snapshots descartados")
    setProgress("0%")
end

form = forms.newform(
    820,
    560,
    "GoldenEyeDiagnostic " .. VERSION,
    function()
        stopped = true
    end
)

forms.label(form,
    "Stable Soldier State Filter — seis snapshots pareados",
    12, 10, 780, 24)

statusLabel = forms.label(form,
    "Status: inicializando", 12, 40, 780, 24)

progressLabel = forms.label(form,
    "Progresso: 0%", 12, 70, 780, 24)

captureLabel = forms.label(form,
    "", 12, 100, 780, 54, true)

resultLabel = forms.label(form,
    "Nenhum resultado", 12, 155, 780, 38, true)

forms.button(form, "1. LIVE_A",
    function() schedule("LIVE_A") end,
    12, 210, 110, 34)

forms.button(form, "2. LIVE_B",
    function() schedule("LIVE_B") end,
    132, 210, 110, 34)

forms.button(form, "3. HIT_A",
    function() schedule("HIT_A") end,
    252, 210, 110, 34)

forms.button(form, "4. HIT_B",
    function() schedule("HIT_B") end,
    372, 210, 110, 34)

forms.button(form, "5. DEAD_A",
    function() schedule("DEAD_A") end,
    492, 210, 110, 34)

forms.button(form, "6. DEAD_B",
    function() schedule("DEAD_B") end,
    612, 210, 110, 34)

forms.button(form, "7. ANALISAR",
    function() schedule("ANALYZE") end,
    12, 260, 130, 34)

forms.button(form, "DESCARTAR SNAPSHOTS",
    clearSnapshots,
    152, 260, 190, 34)

forms.label(form,
    "Procedimento:\n"
    .. "• LIVE_A: soldado vivo e cena estabilizada.\n"
    .. "• LIVE_B: sem fazer nada, capture novamente.\n"
    .. "• HIT_A: acerte sem matar e espere estabilizar.\n"
    .. "• HIT_B: sem fazer nada, capture novamente.\n"
    .. "• DEAD_A: mate o mesmo soldado e espere o corpo estabilizar.\n"
    .. "• DEAD_B: sem fazer nada, capture novamente.\n"
    .. "• ANALISAR: mantem apenas bytes estaveis dentro de cada estado.\n\n"
    .. "Nao recarregue o savestate entre as seis capturas.",
    12, 320, 780, 210)

console.clear()
log("Carregado | versao=" .. VERSION)
log("ROM=" .. tostring(gameinfo.getromname()))
log("Hash=" .. tostring(gameinfo.getromhash()))
log("MainMemory | tamanho=0x" .. string.format("%X", MEMORY_SIZE))

local currentHash = tostring(gameinfo.getromhash())
if currentHash ~= EXPECTED_ROM_HASH then
    log("AVISO | hash esperado=" .. EXPECTED_ROM_HASH
        .. " | atual=" .. currentHash)
end

updateCaptureLabel()
setStatus("pronto para LIVE_A")

event.onexit(function()
    stopped = true
end, "GoldenEyeDiagnostic-0.0.4.5-exit")

while not stopped do
    if pendingOperation and not busy then
        local operation = pendingOperation
        pendingOperation = nil

        local operationOk, operationErr = pcall(function()
            if operation == "ANALYZE" then
                analyze()
            else
                captureSnapshot(operation)
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
