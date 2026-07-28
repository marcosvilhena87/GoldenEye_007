-- GoldenEyeDiagnostic 0.0.5.2.1
-- Position Candidate Discovery
--
-- Correcao:
-- nenhuma operacao longa ou emu.yield() roda dentro de callback de Forms.
-- Os botoes apenas definem tarefas pendentes; captura e analise rodam no loop principal.
--
-- Somente leitura via mainmemory.

local VERSION = "0.0.5.2.1"
local EXPECTED_ROM_HASH = "ABE01E4AEB033B6C0836819F549C791B26CFDE83"

local START_ADDRESS = 0x00000000
local END_ADDRESS = 0x007FFFFC
local STEP = 4

local MIN_ABS_FLOAT = 0.0001
local MAX_ABS_FLOAT = 1000000.0
local MAX_CANDIDATES = 20000

local stopped = false
local pendingTask = nil
local snapshots = {}
local busy = false
local results = {}

local form
local statusLabel
local progressLabel
local markerLabel
local resultLabel

local function scriptDirectory()
    local source = debug.getinfo(1, "S").source
    if source:sub(1,1) == "@" then source = source:sub(2) end
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

local function isFinite(v)
    return v == v and v ~= math.huge and v ~= -math.huge
end

local function readF32(address)
    return mainmemory.readfloat(address, true)
end

local function plausibleFloat(v)
    if not isFinite(v) then return false end
    local a = math.abs(v)
    if a == 0 then return true end
    return a >= MIN_ABS_FLOAT and a <= MAX_ABS_FLOAT
end

local function updateMarkers()
    forms.settext(markerLabel,
        "Marcadores: "
        .. (snapshots.BASE and "BASE " or "")
        .. (snapshots.MOVE_X and "MOVE_X " or "")
        .. (snapshots.MOVE_Z and "MOVE_Z " or "")
        .. (snapshots.ROTATE and "ROTATE " or ""))
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
            forms.settext(progressLabel,
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
    setStatus(name .. " capturado")
    forms.settext(progressLabel,
        "Captura " .. name .. ": 100%")

    log("Snapshot=" .. name
        .. " | frame=" .. tostring(emu.framecount())
        .. " | valores=" .. tostring(count))

    busy = false
end

local function scoreCandidate(base, x, z, r)
    local dx = math.abs(x - base)
    local dz = math.abs(z - base)
    local dr = math.abs(r - base)

    local scoreX = dx - dz - dr
    local scoreZ = dz - dx - dr
    local scoreR = dr - dx - dz

    return dx, dz, dr, scoreX, scoreZ, scoreR
end

local function analyze()
    if not (
        snapshots.BASE
        and snapshots.MOVE_X
        and snapshots.MOVE_Z
        and snapshots.ROTATE
    ) then
        setStatus("faltam snapshots")
        return
    end

    busy = true
    setStatus("analisando")
    results = {}

    local baseValues = snapshots.BASE.values
    local xValues = snapshots.MOVE_X.values
    local zValues = snapshots.MOVE_Z.values
    local rValues = snapshots.ROTATE.values

    local checked = 0
    local total = 0

    for _ in pairs(baseValues) do
        total = total + 1
    end

    for address, base in pairs(baseValues) do
        local x = xValues[address]
        local z = zValues[address]
        local r = rValues[address]

        if x ~= nil and z ~= nil and r ~= nil then
            local dx, dz, dr, scoreX, scoreZ, scoreR =
                scoreCandidate(base, x, z, r)

            if dx > 0.0001 or dz > 0.0001 or dr > 0.0001 then
                local kind = "MIXED"
                local score = math.max(scoreX, scoreZ, scoreR)

                if score == scoreX then
                    kind = "X_CANDIDATE"
                elseif score == scoreZ then
                    kind = "Z_CANDIDATE"
                elseif score == scoreR then
                    kind = "ROTATION_CANDIDATE"
                end

                table.insert(results, {
                    address = address,
                    base = base,
                    x = x,
                    z = z,
                    r = r,
                    dx = dx,
                    dz = dz,
                    dr = dr,
                    kind = kind,
                    score = score
                })
            end
        end

        checked = checked + 1

        if checked % 50000 == 0 then
            forms.settext(progressLabel,
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
        .. "position-candidates-" .. timestamp .. ".csv"
    local summaryPath = OUTPUT_DIR
        .. "position-candidates-" .. timestamp .. "-summary.txt"

    local csv = assert(io.open(csvPath, "w"))
    csv:write(
        "rank,address_hex,kind,score,"
        .. "base,move_x,move_z,rotate,"
        .. "delta_x,delta_z,delta_rotate\n"
    )

    for i, row in ipairs(results) do
        csv:write(
            tostring(i) .. ","
            .. string.format("0x%08X", row.address) .. ","
            .. row.kind .. ","
            .. tostring(row.score) .. ","
            .. tostring(row.base) .. ","
            .. tostring(row.x) .. ","
            .. tostring(row.z) .. ","
            .. tostring(row.r) .. ","
            .. tostring(row.dx) .. ","
            .. tostring(row.dz) .. ","
            .. tostring(row.dr) .. "\n"
        )
    end

    csv:close()

    local summary = assert(io.open(summaryPath, "w"))
    summary:write("GoldenEyeDiagnostic " .. VERSION .. "\n")
    summary:write("ROM: " .. tostring(gameinfo.getromname()) .. "\n")
    summary:write("Hash: " .. tostring(gameinfo.getromhash()) .. "\n")
    summary:write("Scan range: 0x00000000-0x007FFFFC\n")
    summary:write("Step: 4 bytes\n")
    summary:write("Candidates exported: " .. tostring(#results) .. "\n")
    summary:write("CSV: " .. csvPath .. "\n\n")

    summary:write("Snapshots:\n")
    for _, name in ipairs({"BASE", "MOVE_X", "MOVE_Z", "ROTATE"}) do
        summary:write(
            name
            .. " | frame="
            .. tostring(snapshots[name].frame)
            .. "\n"
        )
    end

    summary:write("\nTop 50:\n")

    for i = 1, math.min(50, #results) do
        local row = results[i]

        summary:write(
            tostring(i)
            .. " | address=0x"
            .. string.format("%08X", row.address)
            .. " | kind=" .. row.kind
            .. " | score=" .. tostring(row.score)
            .. " | base=" .. tostring(row.base)
            .. " | x=" .. tostring(row.x)
            .. " | z=" .. tostring(row.z)
            .. " | rot=" .. tostring(row.r)
            .. "\n"
        )
    end

    summary:close()

    setStatus("analise concluida")
    forms.settext(progressLabel, "Analise: 100%")
    forms.settext(resultLabel,
        "CSV: " .. csvPath
        .. "\nResumo: " .. summaryPath)

    log("Analise concluida | candidatos="
        .. tostring(#results))

    busy = false
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
            snapshots = {}
            results = {}
            updateMarkers()
            forms.settext(resultLabel, "Nenhum arquivo gerado")
            forms.settext(progressLabel, "Progresso: aguardando")
            setStatus("limpo")
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
    880,
    560,
    "GoldenEyeDiagnostic " .. VERSION,
    function()
        stopped = true
    end
)

forms.label(form,
    "Position Candidate Discovery — Bond ou soldado",
    12, 10, 840, 24)

statusLabel = forms.label(form,
    "Status: pronto", 12, 40, 840, 24)

progressLabel = forms.label(form,
    "Progresso: aguardando", 12, 70, 840, 24)

markerLabel = forms.label(form,
    "Marcadores: nenhum", 12, 100, 840, 24)

resultLabel = forms.label(form,
    "Nenhum arquivo gerado",
    12, 130, 840, 60, true)

forms.button(form, "1. CAPTURAR BASE",
    function()
        if not busy then pendingTask = "BASE" end
    end,
    12, 210, 170, 38)

forms.button(form, "2. CAPTURAR MOVE_X",
    function()
        if not busy then pendingTask = "MOVE_X" end
    end,
    195, 210, 180, 38)

forms.button(form, "3. CAPTURAR MOVE_Z",
    function()
        if not busy then pendingTask = "MOVE_Z" end
    end,
    388, 210, 180, 38)

forms.button(form, "4. CAPTURAR ROTATE",
    function()
        if not busy then pendingTask = "ROTATE" end
    end,
    581, 210, 180, 38)

forms.button(form, "5. ANALISAR",
    function()
        if not busy then pendingTask = "ANALYZE" end
    end,
    12, 265, 150, 38)

forms.button(form, "LIMPAR",
    function()
        if not busy then pendingTask = "CLEAR" end
    end,
    175, 265, 120, 38)

forms.label(form,
    "Procedimento recomendado — Bond:\n"
    .. "1. Pare em uma area segura e marque BASE.\n"
    .. "2. Mova apenas lateralmente e marque MOVE_X.\n"
    .. "3. Volte ao BASE; mova apenas para frente/tras e marque MOVE_Z.\n"
    .. "4. Volte ao BASE; apenas gire a camera e marque ROTATE.\n\n"
    .. "Procedimento recomendado — soldado:\n"
    .. "Use savestates ou espere o soldado mudar de posicao, mantendo Bond parado.\n"
    .. "Repita o processo em uma nova execucao do script.\n\n"
    .. "Observacao: o scan le float32 alinhado a cada 4 bytes nos 8 MiB de RDRAM.",
    12, 330, 840, 190)

console.clear()
log("Carregado | versao=" .. VERSION)
log("ROM=" .. tostring(gameinfo.getromname()))
log("Hash=" .. tostring(gameinfo.getromhash()))

if tostring(gameinfo.getromhash()) ~= EXPECTED_ROM_HASH then
    log("AVISO | hash inesperado")
end

event.onexit(function()
    stopped = true
end, "GoldenEyeDiagnostic-0.0.5.2.1-exit")

while not stopped do
    runPendingTask()

    gui.drawString(
        8, 8,
        "GoldenEyeDiagnostic " .. VERSION,
        "white", "black", 12
    )

    emu.yield()
end
