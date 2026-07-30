-- GoldenEyeDiagnostic 0.0.5.8.8.1
-- First Soldier Vertical Candidate Monitor
--
-- Capturas:
-- CENTER
-- AUTO_AIM_DOWN
-- TARGET_HEAD
-- TARGET_UPPER_BODY
-- TARGET_LOWER_BODY
-- TARGET_LOST
--
-- Objetivo:
-- localizar candidatos verticais do braco/arma usando apenas estados
-- realmente observaveis no primeiro soldado.
--
-- O ranking favorece:
-- - progressao monotonicamente coerente entre HEAD, UPPER_BODY e LOWER_BODY;
-- - diferenca clara em AUTO_AIM_DOWN;
-- - retorno proximo de CENTER em TARGET_LOST;
-- - valores F32 com aparencia de coordenada de tela ou normalizados.
--
-- Somente leitura via mainmemory.

local VERSION = "0.0.5.8.8.1"
local EXPECTED_ROM_HASH = "ABE01E4AEB033B6C0836819F549C791B26CFDE83"

local REGIONS = {
    {name = "ARM_CORE", startAddress = 0x000D3600, endAddress = 0x000D61FF},
    {name = "ARM_NEAR_X", startAddress = 0x000D3C00, endAddress = 0x000D40FF},
    {name = "CAMERA_NEAR", startAddress = 0x00079600, endAddress = 0x00079CFF}
}

local SNAPSHOT_ORDER = {
    "CENTER",
    "AUTO_AIM_DOWN",
    "TARGET_HEAD",
    "TARGET_UPPER_BODY",
    "TARGET_LOWER_BODY",
    "TARGET_LOST"
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
                name, index, #REGIONS, region.name
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

    if exponent == 255 then return nil end

    if exponent == 0 then
        if mantissa == 0 then return 0 end
        return sign * (mantissa / 0x800000) * 2^-126
    end

    return sign * (1 + mantissa / 0x800000) * 2^(exponent - 127)
end

local function finiteReasonable(value)
    return value ~= nil
        and value == value
        and math.abs(value) < 10000000
end

local function monotonicAscending(a, b, c)
    return a < b and b < c
end

local function monotonicDescending(a, b, c)
    return a > b and b > c
end

local function addResult(regionName, address, dataType, values)
    local center = values.CENTER
    local down = values.AUTO_AIM_DOWN
    local head = values.TARGET_HEAD
    local upper = values.TARGET_UPPER_BODY
    local lower = values.TARGET_LOWER_BODY
    local lost = values.TARGET_LOST

    if center == down
        and center == head
        and center == upper
        and center == lower
        and center == lost then
        return
    end

    local headUpper = upper - head
    local upperLower = lower - upper
    local headLower = lower - head
    local downDelta = down - center
    local lostDelta = lost - center

    local ascending = monotonicAscending(head, upper, lower)
    local descending = monotonicDescending(head, upper, lower)
    local monotonic = ascending or descending

    local spacingBalance =
        math.abs(math.abs(headUpper) - math.abs(upperLower))

    local progressionMagnitude =
        math.abs(headUpper) + math.abs(upperLower) + math.abs(headLower)

    local progressionScore =
        progressionMagnitude * 5
        - spacingBalance * 1.5
        - math.abs(lostDelta) * 2

    if monotonic then
        progressionScore = progressionScore + 1500 + progressionMagnitude * 5
    end

    local downExtensionScore =
        math.abs(downDelta) * 4
        + math.abs(down - lower) * 2
        - math.abs(lostDelta) * 2

    local screenLikeScore = 0
    if dataType == "F32_BE"
        and center >= -1000 and center <= 1000
        and down >= -1000 and down <= 1000
        and head >= -1000 and head <= 1000
        and upper >= -1000 and upper <= 1000
        and lower >= -1000 and lower <= 1000 then

        screenLikeScore =
            progressionMagnitude * 6
            + math.abs(downDelta) * 4
            - math.abs(lostDelta) * 2

        if center >= 60 and center <= 180 then
            screenLikeScore = screenLikeScore + 600
        end

        if monotonic then
            screenLikeScore = screenLikeScore + 800
        end
    end

    local normalizedScore = 0
    if dataType == "F32_BE"
        and math.abs(center) <= 2
        and math.abs(down) <= 2
        and math.abs(head) <= 2
        and math.abs(upper) <= 2
        and math.abs(lower) <= 2
        and math.abs(lost) <= 2 then

        normalizedScore =
            progressionMagnitude * 1200
            + math.abs(downDelta) * 800
            - math.abs(lostDelta) * 400

        if monotonic then
            normalizedScore = normalizedScore + 1200
        end
    end

    local returnToCenterScore =
        (math.abs(downDelta) + progressionMagnitude) * 2
        - math.abs(lostDelta) * 8

    local bestScore = progressionScore
    local kind = "BODY_PROGRESSION"

    if downExtensionScore > bestScore then
        bestScore = downExtensionScore
        kind = "AUTO_AIM_DOWN"
    end

    if screenLikeScore > bestScore then
        bestScore = screenLikeScore
        kind = "SCREEN_Y_LIKE"
    end

    if normalizedScore > bestScore then
        bestScore = normalizedScore
        kind = "NORMALIZED_VERTICAL"
    end

    if returnToCenterScore > bestScore then
        bestScore = returnToCenterScore
        kind = "RETURN_TO_CENTER"
    end

    table.insert(results, {
        region = regionName,
        address = address,
        dataType = dataType,
        kind = kind,
        score = bestScore,
        center = center,
        down = down,
        head = head,
        upper = upper,
        lower = lower,
        lost = lost,
        headUpper = headUpper,
        upperLower = upperLower,
        headLower = headLower,
        downDelta = downDelta,
        lostDelta = lostDelta,
        ascending = ascending,
        descending = descending,
        monotonic = monotonic,
        progressionScore = progressionScore,
        downExtensionScore = downExtensionScore,
        screenLikeScore = screenLikeScore,
        normalizedScore = normalizedScore,
        returnToCenterScore = returnToCenterScore
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
                regionIndex, #REGIONS, region.name
            )
        )

        for address = region.startAddress, region.endAddress do
            local values = {}
            for _, name in ipairs(SNAPSHOT_ORDER) do
                values[name] = getByte(name, region.name, address)
            end
            addResult(region.name, address, "U8", values)
        end

        for address = region.startAddress, region.endAddress - 1, 2 do
            local values = {}
            for _, name in ipairs(SNAPSHOT_ORDER) do
                values[name] = u16FromBytes(name, region.name, address)
            end
            addResult(region.name, address, "U16_BE", values)
        end

        for address = region.startAddress, region.endAddress - 3, 4 do
            local valuesU32 = {}
            local valuesF32 = {}
            local allFloatsValid = true

            for _, name in ipairs(SNAPSHOT_ORDER) do
                local u32 = u32FromBytes(name, region.name, address)
                valuesU32[name] = u32
                valuesF32[name] = floatFromU32(u32)
                if not finiteReasonable(valuesF32[name]) then
                    allFloatsValid = false
                end
            end

            addResult(region.name, address, "U32_BE", valuesU32)

            if allFloatsValid then
                addResult(region.name, address, "F32_BE", valuesF32)
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
        .. "first-soldier-vertical-candidates-" .. timestamp .. ".csv"
    local summaryPath = OUTPUT_DIR
        .. "first-soldier-vertical-candidates-" .. timestamp .. "-summary.txt"

    local csv = assert(io.open(csvPath, "w"))
    csv:write(
        "rank,region,address_hex,data_type,kind,score,"
        .. "center,auto_aim_down,target_head,target_upper_body,target_lower_body,target_lost,"
        .. "head_upper_delta,upper_lower_delta,head_lower_delta,down_delta,lost_delta,"
        .. "ascending,descending,monotonic,"
        .. "progression_score,down_extension_score,screen_like_score,"
        .. "normalized_score,return_to_center_score\n"
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
            .. tostring(row.center) .. ","
            .. tostring(row.down) .. ","
            .. tostring(row.head) .. ","
            .. tostring(row.upper) .. ","
            .. tostring(row.lower) .. ","
            .. tostring(row.lost) .. ","
            .. tostring(row.headUpper) .. ","
            .. tostring(row.upperLower) .. ","
            .. tostring(row.headLower) .. ","
            .. tostring(row.downDelta) .. ","
            .. tostring(row.lostDelta) .. ","
            .. tostring(row.ascending) .. ","
            .. tostring(row.descending) .. ","
            .. tostring(row.monotonic) .. ","
            .. tostring(row.progressionScore) .. ","
            .. tostring(row.downExtensionScore) .. ","
            .. tostring(row.screenLikeScore) .. ","
            .. tostring(row.normalizedScore) .. ","
            .. tostring(row.returnToCenterScore)
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

    summary:write("\nTop 200:\n")
    for rank = 1, math.min(200, #results) do
        local row = results[rank]
        summary:write(
            tostring(rank)
            .. " | region=" .. row.region
            .. " | address=" .. string.format("0x%08X", row.address)
            .. " | type=" .. row.dataType
            .. " | kind=" .. row.kind
            .. " | score=" .. tostring(row.score)
            .. " | center=" .. tostring(row.center)
            .. " | down=" .. tostring(row.down)
            .. " | head=" .. tostring(row.head)
            .. " | upper=" .. tostring(row.upper)
            .. " | lower=" .. tostring(row.lower)
            .. " | lost=" .. tostring(row.lost)
            .. " | monotonic=" .. tostring(row.monotonic)
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
    1060,
    810,
    "GoldenEyeDiagnostic " .. VERSION,
    function() stopped = true end
)

forms.label(
    form,
    "First Soldier Vertical Candidate Monitor",
    12, 10, 1020, 24
)

statusLabel = forms.label(
    form,
    "Status: pronto",
    12, 40, 1020, 24
)

progressLabel = forms.label(
    form,
    "Progresso: aguardando",
    12, 70, 1020, 24
)

markerLabel = forms.label(
    form,
    "Capturas: nenhuma",
    12, 100, 1020, 65, true
)

resultLabel = forms.label(
    form,
    "Nenhum arquivo gerado",
    12, 170, 1020, 65, true
)

forms.button(
    form,
    "1. CENTER",
    function() if not busy then pendingTask = "CENTER" end end,
    12, 255, 145, 40
)

forms.button(
    form,
    "2. AUTO_AIM_DOWN",
    function() if not busy then pendingTask = "AUTO_AIM_DOWN" end end,
    170, 255, 190, 40
)

forms.button(
    form,
    "3. TARGET_HEAD",
    function() if not busy then pendingTask = "TARGET_HEAD" end end,
    373, 255, 170, 40
)

forms.button(
    form,
    "4. TARGET_UPPER_BODY",
    function() if not busy then pendingTask = "TARGET_UPPER_BODY" end end,
    556, 255, 220, 40
)

forms.button(
    form,
    "5. TARGET_LOWER_BODY",
    function() if not busy then pendingTask = "TARGET_LOWER_BODY" end end,
    789, 255, 220, 40
)

forms.button(
    form,
    "6. TARGET_LOST",
    function() if not busy then pendingTask = "TARGET_LOST" end end,
    12, 310, 170, 40
)

forms.button(
    form,
    "7. ANALYZE",
    function() if not busy then pendingTask = "ANALYZE" end end,
    195, 310, 160, 40
)

forms.button(
    form,
    "CLEAR",
    function() if not busy then pendingTask = "CLEAR" end end,
    368, 310, 140, 40
)

forms.label(
    form,
    "Procedimento recomendado:\n"
    .. "1. CENTER: sem alvo, braco em repouso e camera parada.\n"
    .. "2. AUTO_AIM_DOWN: capture quando o auto-aim puxar claramente o braco para baixo.\n"
    .. "3. TARGET_HEAD: capture com o braco apontando para a cabeca.\n"
    .. "4. TARGET_UPPER_BODY: capture na regiao do peito/ombros.\n"
    .. "5. TARGET_LOWER_BODY: capture na regiao inferior do tronco/pernas.\n"
    .. "6. TARGET_LOST: retire o alvo sem mudar desnecessariamente a camera.\n"
    .. "7. ANALYZE.\n\n"
    .. "O ranking procura uma progressao coerente HEAD -> UPPER_BODY -> LOWER_BODY, "
    .. "em ordem crescente ou decrescente, sem exigir AUTO_AIM_UP.",
    12, 380, 1020, 220
)

forms.label(
    form,
    "Regioes: ARM_CORE 0x000D3600–0x000D61FF | "
    .. "ARM_NEAR_X 0x000D3C00–0x000D40FF | "
    .. "CAMERA_NEAR 0x00079600–0x00079CFF",
    12, 620, 1020, 55, true
)

forms.label(
    form,
    "Depois de ANALYZE, envie o CSV e o resumo da pasta output.",
    12, 695, 1020, 24
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
end, "GoldenEyeDiagnostic-0.0.5.8.8.1-exit")

while not stopped do
    processTask()

    gui.drawString(
        8, 8,
        "GoldenEyeDiagnostic " .. VERSION,
        "white", "black", 12
    )

    emu.yield()
end
