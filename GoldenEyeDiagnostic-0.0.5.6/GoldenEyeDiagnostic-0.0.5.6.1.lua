-- GoldenEyeDiagnostic 0.0.5.6.1
-- Horizontal Arm Aim Candidate Discovery
--
-- Adaptacao para o primeiro soldado:
-- NO_TARGET
-- TARGET_LEFT
-- TARGET_RIGHT
-- MANUAL_AIM
--
-- Objetivo:
-- descobrir variaveis relacionadas ao deslocamento horizontal do braco/arma
-- e separar auto-aim de mira manual.
--
-- Somente leitura via mainmemory.

local VERSION = "0.0.5.6.1"
local EXPECTED_ROM_HASH = "ABE01E4AEB033B6C0836819F549C791B26CFDE83"

local START_ADDRESS = 0x00000000
local END_ADDRESS = 0x007FFFFC
local STEP = 4

local MIN_ABS_FLOAT = 0.000001
local MAX_ABS_FLOAT = 1000000.0
local MAX_CANDIDATES = 20000

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

local SNAPSHOT_ORDER = {
    "NO_TARGET",
    "TARGET_LEFT",
    "TARGET_RIGHT",
    "MANUAL_AIM"
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

local function isFinite(value)
    return value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local function plausibleFloat(value)
    if not isFinite(value) then
        return false
    end

    local absolute = math.abs(value)

    if absolute == 0 then
        return true
    end

    return absolute >= MIN_ABS_FLOAT
        and absolute <= MAX_ABS_FLOAT
end

local function readF32(address)
    return mainmemory.readfloat(address, true)
end

local function updateMarkers()
    local parts = {}

    for _, name in ipairs(SNAPSHOT_ORDER) do
        table.insert(
            parts,
            name .. "=" .. (snapshots[name] and "OK" or "--")
        )
    end

    forms.settext(
        markerLabel,
        "Capturas: " .. table.concat(parts, " | ")
    )
end

local function captureSnapshot(name)
    busy = true
    setStatus("capturando " .. name)

    local values = {}
    local count = 0

    for address = START_ADDRESS, END_ADDRESS, STEP do
        local ok, value = pcall(readF32, address)

        if ok and plausibleFloat(value) then
            values[address] = value
        end

        count = count + 1

        if count % 50000 == 0 then
            forms.settext(
                progressLabel,
                string.format(
                    "Captura %s: %.1f%%",
                    name,
                    (address - START_ADDRESS)
                    / (END_ADDRESS - START_ADDRESS) * 100
                )
            )

            emu.yield()
        end
    end

    snapshots[name] = {
        frame = emu.framecount(),
        values = values
    }

    updateMarkers()

    forms.settext(
        progressLabel,
        "Captura " .. name .. ": 100%"
    )

    setStatus(name .. " capturado")

    log(
        "Snapshot=" .. name
        .. " | frame=" .. tostring(emu.framecount())
        .. " | valores=" .. tostring(count)
    )

    busy = false
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

    local baseValues = snapshots.NO_TARGET.values
    local total = 0
    local checked = 0

    for _ in pairs(baseValues) do
        total = total + 1
    end

    for address, base in pairs(baseValues) do
        local left = snapshots.TARGET_LEFT.values[address]
        local right = snapshots.TARGET_RIGHT.values[address]
        local manual = snapshots.MANUAL_AIM.values[address]

        if left ~= nil
            and right ~= nil
            and manual ~= nil then

            local dLeft = left - base
            local dRight = right - base
            local dManual = manual - base

            local changedLeft = math.abs(dLeft)
            local changedRight = math.abs(dRight)
            local changedManual = math.abs(dManual)

            local opposition = math.abs(dLeft - dRight)
            local symmetry =
                math.abs(changedLeft - changedRight)

            local signOpposed =
                (dLeft < 0 and dRight > 0)
                or (dLeft > 0 and dRight < 0)

            local centeredScore =
                opposition
                - symmetry
                + (signOpposed and opposition or 0)

            local leftScore =
                changedLeft
                - changedRight * 0.50
                - changedManual * 0.10

            local rightScore =
                changedRight
                - changedLeft * 0.50
                - changedManual * 0.10

            local manualScore =
                changedManual
                - (changedLeft + changedRight) * 0.10

            local changed =
                changedLeft > 0.00001
                or changedRight > 0.00001
                or changedManual > 0.00001

            if changed then
                local score = math.max(
                    centeredScore,
                    leftScore,
                    rightScore,
                    manualScore
                )

                local kind = "MIXED"

                if score == centeredScore then
                    kind = "ARM_HORIZONTAL_CANDIDATE"
                elseif score == leftScore then
                    kind = "ARM_LEFT_CANDIDATE"
                elseif score == rightScore then
                    kind = "ARM_RIGHT_CANDIDATE"
                elseif score == manualScore then
                    kind = "MANUAL_AIM_CANDIDATE"
                end

                table.insert(results, {
                    address = address,
                    kind = kind,
                    score = score,
                    base = base,
                    left = left,
                    right = right,
                    manual = manual,
                    dLeft = dLeft,
                    dRight = dRight,
                    dManual = dManual,
                    opposition = opposition,
                    symmetry = symmetry,
                    signOpposed = signOpposed,
                    centeredScore = centeredScore,
                    leftScore = leftScore,
                    rightScore = rightScore,
                    manualScore = manualScore
                })
            end
        end

        checked = checked + 1

        if checked % 50000 == 0 then
            forms.settext(
                progressLabel,
                string.format(
                    "Analise: %d/%d (%.1f%%)",
                    checked,
                    total,
                    total > 0 and checked / total * 100 or 0
                )
            )

            emu.yield()
        end
    end

    table.sort(results, function(a, b)
        if a.score == b.score then
            return a.address < b.address
        end

        return a.score > b.score
    end)

    while #results > MAX_CANDIDATES do
        table.remove(results)
    end

    local timestamp = os.date("%Y%m%d-%H%M%S")
    local csvPath = OUTPUT_DIR
        .. "arm-horizontal-candidates-" .. timestamp .. ".csv"
    local summaryPath = OUTPUT_DIR
        .. "arm-horizontal-candidates-" .. timestamp
        .. "-summary.txt"

    local csv = assert(io.open(csvPath, "w"))

    csv:write(
        "rank,address_hex,kind,score,"
        .. "no_target,target_left,target_right,manual_aim,"
        .. "delta_left,delta_right,delta_manual,"
        .. "opposition,symmetry,sign_opposed,"
        .. "horizontal_score,left_score,right_score,manual_score\n"
    )

    for rank, row in ipairs(results) do
        csv:write(
            tostring(rank) .. ","
            .. string.format("0x%08X", row.address) .. ","
            .. row.kind .. ","
            .. tostring(row.score) .. ","
            .. tostring(row.base) .. ","
            .. tostring(row.left) .. ","
            .. tostring(row.right) .. ","
            .. tostring(row.manual) .. ","
            .. tostring(row.dLeft) .. ","
            .. tostring(row.dRight) .. ","
            .. tostring(row.dManual) .. ","
            .. tostring(row.opposition) .. ","
            .. tostring(row.symmetry) .. ","
            .. tostring(row.signOpposed) .. ","
            .. tostring(row.centeredScore) .. ","
            .. tostring(row.leftScore) .. ","
            .. tostring(row.rightScore) .. ","
            .. tostring(row.manualScore)
            .. "\n"
        )
    end

    csv:close()

    local summary = assert(io.open(summaryPath, "w"))

    summary:write("GoldenEyeDiagnostic " .. VERSION .. "\n")
    summary:write("ROM: " .. tostring(gameinfo.getromname()) .. "\n")
    summary:write("Hash: " .. tostring(gameinfo.getromhash()) .. "\n")
    summary:write("Scan range: 0x00000000-0x007FFFFC\n")
    summary:write("Step: 4 bytes\n")
    summary:write(
        "Candidates exported: "
        .. tostring(#results) .. "\n"
    )
    summary:write("CSV: " .. csvPath .. "\n\n")

    summary:write("Snapshots:\n")

    for _, name in ipairs(SNAPSHOT_ORDER) do
        summary:write(
            name
            .. " | frame="
            .. tostring(snapshots[name].frame)
            .. "\n"
        )
    end

    summary:write("\nTop 100:\n")

    for i = 1, math.min(100, #results) do
        local row = results[i]

        summary:write(
            tostring(i)
            .. " | address=0x"
            .. string.format("%08X", row.address)
            .. " | kind=" .. row.kind
            .. " | score=" .. tostring(row.score)
            .. " | base=" .. tostring(row.base)
            .. " | left=" .. tostring(row.left)
            .. " | right=" .. tostring(row.right)
            .. " | manual=" .. tostring(row.manual)
            .. " | dLeft=" .. tostring(row.dLeft)
            .. " | dRight=" .. tostring(row.dRight)
            .. " | signOpposed="
            .. tostring(row.signOpposed)
            .. "\n"
        )
    end

    summary:close()

    forms.settext(
        progressLabel,
        "Analise: 100%"
    )

    forms.settext(
        resultLabel,
        "CSV: " .. csvPath
        .. "\nResumo: " .. summaryPath
    )

    setStatus("analise concluida")

    log(
        "Analise concluida | candidatos="
        .. tostring(#results)
    )

    busy = false
end

local function clearAll()
    snapshots = {}
    results = {}

    updateMarkers()

    forms.settext(
        progressLabel,
        "Progresso: aguardando"
    )

    forms.settext(
        resultLabel,
        "Nenhum arquivo gerado"
    )

    setStatus("limpo")
end

local function runPendingTask()
    if busy or not pendingTask then
        return
    end

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

        forms.settext(
            resultLabel,
            tostring(err)
        )

        log("ERRO: " .. tostring(err))
    end
end

form = forms.newform(
    920,
    620,
    "GoldenEyeDiagnostic " .. VERSION,
    function()
        stopped = true
    end
)

forms.label(
    form,
    "Horizontal Arm Aim Candidate Discovery — primeiro soldado",
    12,
    10,
    880,
    24
)

statusLabel = forms.label(
    form,
    "Status: pronto",
    12,
    40,
    880,
    24
)

progressLabel = forms.label(
    form,
    "Progresso: aguardando",
    12,
    70,
    880,
    24
)

markerLabel = forms.label(
    form,
    "Capturas: nenhuma",
    12,
    100,
    880,
    45,
    true
)

resultLabel = forms.label(
    form,
    "Nenhum arquivo gerado",
    12,
    150,
    880,
    60,
    true
)

local buttonWidth = 160
local gap = 10

forms.button(
    form,
    "1. NO_TARGET",
    function()
        if not busy then
            pendingTask = "NO_TARGET"
        end
    end,
    12,
    230,
    buttonWidth,
    38
)

forms.button(
    form,
    "2. TARGET_LEFT",
    function()
        if not busy then
            pendingTask = "TARGET_LEFT"
        end
    end,
    12 + buttonWidth + gap,
    230,
    buttonWidth,
    38
)

forms.button(
    form,
    "3. TARGET_RIGHT",
    function()
        if not busy then
            pendingTask = "TARGET_RIGHT"
        end
    end,
    12 + 2 * (buttonWidth + gap),
    230,
    buttonWidth,
    38
)

forms.button(
    form,
    "4. MANUAL_AIM",
    function()
        if not busy then
            pendingTask = "MANUAL_AIM"
        end
    end,
    12 + 3 * (buttonWidth + gap),
    230,
    buttonWidth,
    38
)

forms.button(
    form,
    "5. ANALYZE",
    function()
        if not busy then
            pendingTask = "ANALYZE"
        end
    end,
    12,
    285,
    buttonWidth,
    38
)

forms.button(
    form,
    "CLEAR",
    function()
        if not busy then
            pendingTask = "CLEAR"
        end
    end,
    12 + buttonWidth + gap,
    285,
    buttonWidth,
    38
)

forms.label(
    form,
    "Procedimento recomendado:\n"
    .. "• Use o mesmo savestate-base antes de cada captura.\n"
    .. "• Bond deve permanecer parado.\n"
    .. "• A camera deve ficar o mais parecida possivel entre as capturas.\n"
    .. "• NO_TARGET: nenhum inimigo atraindo o auto-aim.\n"
    .. "• TARGET_LEFT: o primeiro soldado puxa o braco para a esquerda da tela.\n"
    .. "• TARGET_RIGHT: o primeiro soldado puxa o braco para a direita da tela.\n"
    .. "• MANUAL_AIM: segure R e desloque a mira manualmente na horizontal.\n"
    .. "• Depois clique em ANALYZE.\n\n"
    .. "O ranking favorece valores que mudam em sentidos opostos entre "
    .. "TARGET_LEFT e TARGET_RIGHT.",
    12,
    350,
    880,
    210
)

forms.label(
    form,
    "Depois de ANALYZE, envie o CSV e o resumo gerados em output.",
    12,
    575,
    880,
    24
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
end, "GoldenEyeDiagnostic-0.0.5.6.1-exit")

while not stopped do
    runPendingTask()

    gui.drawString(
        8,
        8,
        "GoldenEyeDiagnostic " .. VERSION,
        "white",
        "black",
        12
    )

    emu.yield()
end
