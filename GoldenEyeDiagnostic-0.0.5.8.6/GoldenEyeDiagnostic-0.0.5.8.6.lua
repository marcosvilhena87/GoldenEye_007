-- GoldenEyeDiagnostic 0.0.5.8.6
-- Shot Outcome Candidate Monitor
--
-- Capturas:
-- BEFORE_SHOT
-- HIT
-- VISUAL_DEATH
-- MISS
--
-- Compara bytes, u16, u32 e float32 em regioes ampliadas ao redor dos
-- candidatos anteriores, procurando:
-- - valores que mudam somente na morte;
-- - valores que mudam no hit e permanecem na morte;
-- - ponteiros que zeram na morte;
-- - estados inteiros pequenos que distinguem vivo/hit/morto.
--
-- Somente leitura via mainmemory.

local VERSION = "0.0.5.8.6"
local EXPECTED_ROM_HASH = "ABE01E4AEB033B6C0836819F549C791B26CFDE83"

local REGIONS = {
    {name = "STATE_30A", startAddress = 0x00030800, endAddress = 0x00030CFF},
    {name = "STATE_3CB", startAddress = 0x0003C900, endAddress = 0x0003CDFF},
    {name = "OBJECT_1E", startAddress = 0x001DF000, endAddress = 0x001E1FFF},
    {name = "POINTER_1F", startAddress = 0x001F3000, endAddress = 0x001F4FFF}
}

local SNAPSHOT_ORDER = {
    "BEFORE_SHOT",
    "HIT",
    "VISUAL_DEATH",
    "MISS"
}

local stopped = false
local busy = false
local pendingTask = nil
local snapshots = {}
local results = {}

local form
local statusLabel
local progressLabel
local markerLabel
local resultLabel

local function scriptDirectory()
    local source = debug.getinfo(1, "S").source
    if source:sub(1, 1) == "@" then source = source:sub(2) end
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

local function updateMarkers()
    local parts = {}
    for _, name in ipairs(SNAPSHOT_ORDER) do
        table.insert(parts, name .. "=" .. (snapshots[name] and "OK" or "--"))
    end
    forms.settext(markerLabel, "Capturas: " .. table.concat(parts, " | "))
end

local function readRegion(region)
    local bytes = {}
    for address = region.startAddress, region.endAddress do
        bytes[address] = mainmemory.read_u8(address)
    end
    return bytes
end

local function captureSnapshot(name)
    busy = true
    setStatus("capturando " .. name)

    local snapshot = {
        frame = emu.framecount(),
        regions = {}
    }

    for index, region in ipairs(REGIONS) do
        forms.settext(
            progressLabel,
            string.format(
                "Captura %s: regiao %d/%d (%s)",
                name,
                index,
                #REGIONS,
                region.name
            )
        )
        snapshot.regions[region.name] = readRegion(region)
        emu.yield()
    end

    snapshots[name] = snapshot
    updateMarkers()
    forms.settext(progressLabel, "Captura " .. name .. ": concluida")
    setStatus(name .. " capturado")
    log("Snapshot=" .. name .. " | frame=" .. tostring(snapshot.frame))
    busy = false
end

local function getByte(snapshotName, regionName, address)
    return snapshots[snapshotName].regions[regionName][address]
end

local function u16FromBytes(snapshotName, regionName, address)
    local b1 = getByte(snapshotName, regionName, address)
    local b2 = getByte(snapshotName, regionName, address + 1)
    return b1 * 256 + b2
end

local function u32FromBytes(snapshotName, regionName, address)
    local b1 = getByte(snapshotName, regionName, address)
    local b2 = getByte(snapshotName, regionName, address + 1)
    local b3 = getByte(snapshotName, regionName, address + 2)
    local b4 = getByte(snapshotName, regionName, address + 3)
    return ((b1 * 256 + b2) * 256 + b3) * 256 + b4
end

local function floatFromU32(value)
    local sign = 1
    if value >= 0x80000000 then
        sign = -1
        value = value - 0x80000000
    end

    local exponent = math.floor(value / 0x800000) % 256
    local mantissa = value % 0x800000

    if exponent == 255 then
        return nil
    end

    if exponent == 0 then
        if mantissa == 0 then return 0 end
        return sign * (mantissa / 0x800000) * 2^-126
    end

    return sign * (1 + mantissa / 0x800000) * 2^(exponent - 127)
end

local function scorePattern(before, hit, death, miss, dataType)
    local deathChange = math.abs(death - before)
    local hitChange = math.abs(hit - before)
    local missChange = math.abs(miss - before)
    local hitToDeath = math.abs(death - hit)

    local deathSpecific =
        deathChange * 3
        - hitChange * 0.50
        - missChange * 2
        - hitToDeath * 0.10

    local hitPersistent =
        hitChange * 2
        + deathChange
        - hitToDeath * 1.5
        - missChange * 2

    local zeroOnDeath = 0
    if death == 0 and before ~= 0 and miss == before then
        zeroOnDeath = math.abs(before) + 1000
    end

    local smallState = 0
    if dataType ~= "F32"
        and before >= 0 and before <= 255
        and hit >= 0 and hit <= 255
        and death >= 0 and death <= 255
        and miss >= 0 and miss <= 255
        and death ~= before then
        smallState = 500 - missChange * 10
    end

    local bestScore = deathSpecific
    local kind = "DEATH_SPECIFIC"

    if hitPersistent > bestScore then
        bestScore = hitPersistent
        kind = "HIT_PERSISTENT"
    end

    if zeroOnDeath > bestScore then
        bestScore = zeroOnDeath
        kind = "ZERO_ON_DEATH"
    end

    if smallState > bestScore then
        bestScore = smallState
        kind = "SMALL_STATE"
    end

    return bestScore, kind, deathSpecific, hitPersistent, zeroOnDeath, smallState
end

local function addResult(regionName, address, dataType, before, hit, death, miss)
    if before == hit and before == death and before == miss then
        return
    end

    local score, kind, deathSpecific, hitPersistent, zeroOnDeath, smallState =
        scorePattern(before, hit, death, miss, dataType)

    table.insert(results, {
        region = regionName,
        address = address,
        dataType = dataType,
        kind = kind,
        score = score,
        before = before,
        hit = hit,
        death = death,
        miss = miss,
        deathSpecific = deathSpecific,
        hitPersistent = hitPersistent,
        zeroOnDeath = zeroOnDeath,
        smallState = smallState
    })
end

local function analyze()
    for _, name in ipairs(SNAPSHOT_ORDER) do
        if not snapshots[name] then
            setStatus("faltando " .. name)
            return
        end
    end

    busy = true
    setStatus("analisando")
    results = {}

    for regionIndex, region in ipairs(REGIONS) do
        forms.settext(
            progressLabel,
            string.format(
                "Analise: regiao %d/%d (%s)",
                regionIndex,
                #REGIONS,
                region.name
            )
        )

        for address = region.startAddress, region.endAddress do
            addResult(
                region.name,
                address,
                "U8",
                getByte("BEFORE_SHOT", region.name, address),
                getByte("HIT", region.name, address),
                getByte("VISUAL_DEATH", region.name, address),
                getByte("MISS", region.name, address)
            )
        end

        for address = region.startAddress, region.endAddress - 1, 2 do
            addResult(
                region.name,
                address,
                "U16_BE",
                u16FromBytes("BEFORE_SHOT", region.name, address),
                u16FromBytes("HIT", region.name, address),
                u16FromBytes("VISUAL_DEATH", region.name, address),
                u16FromBytes("MISS", region.name, address)
            )
        end

        for address = region.startAddress, region.endAddress - 3, 4 do
            local beforeU32 = u32FromBytes("BEFORE_SHOT", region.name, address)
            local hitU32 = u32FromBytes("HIT", region.name, address)
            local deathU32 = u32FromBytes("VISUAL_DEATH", region.name, address)
            local missU32 = u32FromBytes("MISS", region.name, address)

            addResult(
                region.name,
                address,
                "U32_BE",
                beforeU32,
                hitU32,
                deathU32,
                missU32
            )

            local beforeF = floatFromU32(beforeU32)
            local hitF = floatFromU32(hitU32)
            local deathF = floatFromU32(deathU32)
            local missF = floatFromU32(missU32)

            if beforeF and hitF and deathF and missF
                and math.abs(beforeF) < 10000000
                and math.abs(hitF) < 10000000
                and math.abs(deathF) < 10000000
                and math.abs(missF) < 10000000 then

                addResult(
                    region.name,
                    address,
                    "F32_BE",
                    beforeF,
                    hitF,
                    deathF,
                    missF
                )
            end
        end

        emu.yield()
    end

    table.sort(results, function(a, b)
        if a.score == b.score then
            if a.address == b.address then
                return a.dataType < b.dataType
            end
            return a.address < b.address
        end
        return a.score > b.score
    end)

    local timestamp = os.date("%Y%m%d-%H%M%S")
    local csvPath = OUTPUT_DIR
        .. "shot-outcome-candidates-" .. timestamp .. ".csv"
    local summaryPath = OUTPUT_DIR
        .. "shot-outcome-candidates-" .. timestamp .. "-summary.txt"

    local csv = assert(io.open(csvPath, "w"))
    csv:write(
        "rank,region,address_hex,data_type,kind,score,"
        .. "before_shot,hit,visual_death,miss,"
        .. "death_specific_score,hit_persistent_score,"
        .. "zero_on_death_score,small_state_score\n"
    )

    local exportCount = math.min(#results, 30000)

    for rank = 1, exportCount do
        local row = results[rank]
        csv:write(
            tostring(rank) .. ","
            .. row.region .. ","
            .. string.format("0x%08X", row.address) .. ","
            .. row.dataType .. ","
            .. row.kind .. ","
            .. tostring(row.score) .. ","
            .. tostring(row.before) .. ","
            .. tostring(row.hit) .. ","
            .. tostring(row.death) .. ","
            .. tostring(row.miss) .. ","
            .. tostring(row.deathSpecific) .. ","
            .. tostring(row.hitPersistent) .. ","
            .. tostring(row.zeroOnDeath) .. ","
            .. tostring(row.smallState)
            .. "\n"
        )
    end
    csv:close()

    local summary = assert(io.open(summaryPath, "w"))
    summary:write("GoldenEyeDiagnostic " .. VERSION .. "\n")
    summary:write("ROM: " .. tostring(gameinfo.getromname()) .. "\n")
    summary:write("Hash: " .. tostring(gameinfo.getromhash()) .. "\n")
    summary:write("Candidates found: " .. tostring(#results) .. "\n")
    summary:write("Candidates exported: " .. tostring(exportCount) .. "\n")
    summary:write("CSV: " .. csvPath .. "\n\n")

    summary:write("Snapshots:\n")
    for _, name in ipairs(SNAPSHOT_ORDER) do
        summary:write(
            name .. " | frame=" .. tostring(snapshots[name].frame) .. "\n"
        )
    end

    summary:write("\nRegions:\n")
    for _, region in ipairs(REGIONS) do
        summary:write(
            region.name .. " | "
            .. string.format("0x%08X", region.startAddress)
            .. "-"
            .. string.format("0x%08X", region.endAddress)
            .. "\n"
        )
    end

    summary:write("\nTop 150:\n")
    for rank = 1, math.min(150, #results) do
        local row = results[rank]
        summary:write(
            tostring(rank)
            .. " | region=" .. row.region
            .. " | address=" .. string.format("0x%08X", row.address)
            .. " | type=" .. row.dataType
            .. " | kind=" .. row.kind
            .. " | score=" .. tostring(row.score)
            .. " | before=" .. tostring(row.before)
            .. " | hit=" .. tostring(row.hit)
            .. " | death=" .. tostring(row.death)
            .. " | miss=" .. tostring(row.miss)
            .. "\n"
        )
    end
    summary:close()

    forms.settext(progressLabel, "Analise concluida")
    forms.settext(
        resultLabel,
        "CSV: " .. csvPath .. "\nResumo: " .. summaryPath
    )
    setStatus("analise concluida")
    log("Analise concluida | candidatos=" .. tostring(#results))
    busy = false
end

local function clearAll()
    snapshots = {}
    results = {}
    updateMarkers()
    forms.settext(progressLabel, "Progresso: aguardando")
    forms.settext(resultLabel, "Nenhum arquivo gerado")
    setStatus("limpo")
end

local function processTask()
    if busy or not pendingTask then return end

    local task = pendingTask
    pendingTask = nil

    local ok, err = pcall(function()
        if task == "ANALYZE" then
            analyze()
        elseif task == "CLEAR" then
            clearAll()
        else
            captureSnapshot(task)
        end
    end)

    if not ok then
        busy = false
        setStatus("erro")
        forms.settext(resultLabel, tostring(err))
        log("ERRO: " .. tostring(err))
    end
end

form = forms.newform(
    1000,
    720,
    "GoldenEyeDiagnostic " .. VERSION,
    function() stopped = true end
)

forms.label(
    form,
    "Shot Outcome Candidate Monitor — primeiro soldado",
    12, 10, 960, 24
)

statusLabel = forms.label(
    form,
    "Status: pronto",
    12, 40, 960, 24
)

progressLabel = forms.label(
    form,
    "Progresso: aguardando",
    12, 70, 960, 24
)

markerLabel = forms.label(
    form,
    "Capturas: nenhuma",
    12, 100, 960, 45, true
)

resultLabel = forms.label(
    form,
    "Nenhum arquivo gerado",
    12, 150, 960, 65, true
)

forms.button(
    form,
    "1. BEFORE_SHOT",
    function() if not busy then pendingTask = "BEFORE_SHOT" end end,
    12, 235, 175, 40
)

forms.button(
    form,
    "2. HIT",
    function() if not busy then pendingTask = "HIT" end end,
    200, 235, 140, 40
)

forms.button(
    form,
    "3. VISUAL_DEATH",
    function() if not busy then pendingTask = "VISUAL_DEATH" end end,
    353, 235, 185, 40
)

forms.button(
    form,
    "4. MISS",
    function() if not busy then pendingTask = "MISS" end end,
    551, 235, 140, 40
)

forms.button(
    form,
    "5. ANALYZE",
    function() if not busy then pendingTask = "ANALYZE" end end,
    12, 290, 175, 40
)

forms.button(
    form,
    "CLEAR",
    function() if not busy then pendingTask = "CLEAR" end end,
    200, 290, 140, 40
)

forms.label(
    form,
    "Procedimento recomendado:\n"
    .. "1. Use um savestate imediatamente antes do tiro.\n"
    .. "2. BEFORE_SHOT: capture antes de pressionar Z.\n"
    .. "3. Faça uma tentativa de acerto. HIT: capture no primeiro frame em que "
    .. "o soldado reage ao tiro, mas ainda está vivo.\n"
    .. "4. VISUAL_DEATH: capture quando a morte estiver visualmente clara.\n"
    .. "5. Recarregue o mesmo savestate e erre o tiro. MISS: capture após confirmar "
    .. "que o soldado não foi atingido.\n"
    .. "6. Clique em ANALYZE.\n\n"
    .. "Importante: use o mesmo savestate-base e tente manter a câmera e Bond na "
    .. "mesma posição. O diagnóstico compara U8, U16, U32 e F32 nas regiões "
    .. "ampliadas dos candidatos anteriores.",
    12, 360, 960, 210
)

forms.label(
    form,
    "Regiões: 0x00030800–0x00030CFF | 0x0003C900–0x0003CDFF | "
    .. "0x001DF000–0x001E1FFF | 0x001F3000–0x001F4FFF",
    12, 590, 960, 45, true
)

forms.label(
    form,
    "Depois de ANALYZE, envie o CSV e o resumo da pasta output.",
    12, 650, 960, 24
)

console.clear()
log("Carregado | versao=" .. VERSION)
log("ROM=" .. tostring(gameinfo.getromname()))
log("Hash=" .. tostring(gameinfo.getromhash()))

if tostring(gameinfo.getromhash()) ~= EXPECTED_ROM_HASH then
    log("AVISO | hash inesperado")
end

updateMarkers()

event.onexit(function()
    stopped = true
end, "GoldenEyeDiagnostic-0.0.5.8.6-exit")

while not stopped do
    processTask()

    gui.drawString(
        8, 8,
        "GoldenEyeDiagnostic " .. VERSION,
        "white", "black", 12
    )

    emu.yield()
end
