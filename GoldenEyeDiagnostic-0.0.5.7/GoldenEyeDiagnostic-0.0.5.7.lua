-- GoldenEyeDiagnostic 0.0.5.7
-- Shot Alignment Reference
--
-- Registra em cada tentativa:
-- - screen_x do braco/arma
-- - raw_horizontal
-- - normalized
-- - copia screen_x
-- - matriz 3x3 da camera
-- - marcadores SHOT, KILL e MISS
--
-- Objetivo:
-- descobrir a faixa de alinhamento horizontal que realmente acerta
-- o primeiro soldado.
--
-- Somente leitura via mainmemory.

local VERSION = "0.0.5.7"
local EXPECTED_ROM_HASH = "ABE01E4AEB033B6C0836819F549C791B26CFDE83"

local ARM = {
    raw_horizontal = 0x000D3998,
    raw_offset = 0x000D3D40,
    related = 0x000D3DD0,
    screen_x = 0x000D3F48,
    screen_x_copy = 0x000D3F5C,
    normalized = 0x000D596C
}

local CAMERA = {
    0x00079950, 0x00079954, 0x00079958,
    0x00079960, 0x00079964, 0x00079968,
    0x00079970, 0x00079974, 0x00079978
}

local CAMERA_NAMES = {
    "m11", "m12", "m13",
    "m21", "m22", "m23",
    "m31", "m32", "m33"
}

local SCREEN_CENTER_X = 160.0
local stopped = false
local recording = false
local pendingAction = nil
local session = nil
local lastShot = nil
local attemptNumber = 0

local form
local statusLabel
local liveLabel
local shotLabel
local filesLabel

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

local function readState()
    local camera = {}

    for i, address in ipairs(CAMERA) do
        camera[i] = mainmemory.readfloat(address, true)
    end

    return {
        frame = emu.framecount(),
        raw_horizontal = mainmemory.readfloat(ARM.raw_horizontal, true),
        raw_offset = mainmemory.readfloat(ARM.raw_offset, true),
        related = mainmemory.readfloat(ARM.related, true),
        screen_x = mainmemory.readfloat(ARM.screen_x, true),
        screen_x_copy = mainmemory.readfloat(ARM.screen_x_copy, true),
        normalized = mainmemory.readfloat(ARM.normalized, true),
        camera = camera
    }
end

local function classifyArm(state)
    local delta = state.screen_x - SCREEN_CENTER_X

    if math.abs(delta) <= 3.0 then
        return "ARM_CENTERED"
    elseif delta < 0 then
        return "ARM_LEFT"
    else
        return "ARM_RIGHT"
    end
end

local function cameraText(camera)
    return string.format(
        "[% .6f % .6f % .6f]\n[% .6f % .6f % .6f]\n[% .6f % .6f % .6f]",
        camera[1], camera[2], camera[3],
        camera[4], camera[5], camera[6],
        camera[7], camera[8], camera[9]
    )
end

local function liveText(state)
    return string.format(
        "frame=%d | %s\n"
        .. "screen_x=% .6f | desvio=% .6f | copy=% .6f\n"
        .. "raw=% .6f | raw_offset=% .6f | related=% .6f | normalized=% .6f\n"
        .. "Camera:\n%s",
        state.frame,
        classifyArm(state),
        state.screen_x,
        state.screen_x - SCREEN_CENTER_X,
        state.screen_x_copy,
        state.raw_horizontal,
        state.raw_offset,
        state.related,
        state.normalized,
        cameraText(state.camera)
    )
end

local function writeHeader(file)
    file:write(
        "attempt,event,result,frame,arm_classification,"
        .. "screen_x,screen_delta,screen_x_copy,"
        .. "raw_horizontal,raw_offset,related,normalized"
    )

    for _, name in ipairs(CAMERA_NAMES) do
        file:write("," .. name)
    end

    file:write("\n")
end

local function writeStateRow(eventName, resultName, state)
    if not session or not session.csv then
        return
    end

    session.csv:write(
        tostring(attemptNumber) .. ","
        .. tostring(eventName or "") .. ","
        .. tostring(resultName or "") .. ","
        .. tostring(state.frame) .. ","
        .. classifyArm(state) .. ","
        .. tostring(state.screen_x) .. ","
        .. tostring(state.screen_x - SCREEN_CENTER_X) .. ","
        .. tostring(state.screen_x_copy) .. ","
        .. tostring(state.raw_horizontal) .. ","
        .. tostring(state.raw_offset) .. ","
        .. tostring(state.related) .. ","
        .. tostring(state.normalized)
    )

    for i = 1, 9 do
        session.csv:write("," .. tostring(state.camera[i]))
    end

    session.csv:write("\n")
    session.csv:flush()
end

local function startRecording()
    if recording then
        setStatus("gravacao ja ativa")
        return
    end

    local timestamp = os.date("%Y%m%d-%H%M%S")
    local csvPath = OUTPUT_DIR
        .. "shot-alignment-reference-" .. timestamp .. ".csv"
    local summaryPath = OUTPUT_DIR
        .. "shot-alignment-reference-" .. timestamp .. "-summary.txt"

    local csv = assert(io.open(csvPath, "w"))
    writeHeader(csv)

    session = {
        csv = csv,
        csvPath = csvPath,
        summaryPath = summaryPath,
        startedFrame = emu.framecount(),
        shots = {},
        kills = 0,
        misses = 0
    }

    recording = true
    lastShot = nil
    attemptNumber = 0

    forms.settext(
        filesLabel,
        "CSV: " .. csvPath
        .. "\nResumo: " .. summaryPath
    )

    setStatus("gravando")
    log("Gravacao iniciada | frame=" .. tostring(emu.framecount()))
end

local function registerShot()
    if not recording or not session then
        setStatus("inicie a gravacao")
        return
    end

    attemptNumber = attemptNumber + 1
    lastShot = readState()

    writeStateRow("SHOT", "", lastShot)

    table.insert(session.shots, {
        attempt = attemptNumber,
        shot = lastShot,
        result = "PENDING",
        resultFrame = nil
    })

    forms.settext(
        shotLabel,
        string.format(
            "Tentativa %d aguardando resultado\n"
            .. "frame=%d | screen_x=% .3f | desvio=% .3f | normalized=% .6f",
            attemptNumber,
            lastShot.frame,
            lastShot.screen_x,
            lastShot.screen_x - SCREEN_CENTER_X,
            lastShot.normalized
        )
    )

    setStatus("SHOT registrado; marque KILL ou MISS")
    log(
        "SHOT | tentativa=" .. tostring(attemptNumber)
        .. " | frame=" .. tostring(lastShot.frame)
        .. " | screen_x=" .. tostring(lastShot.screen_x)
    )
end

local function registerResult(resultName)
    if not recording or not session then
        setStatus("inicie a gravacao")
        return
    end

    if not lastShot or #session.shots == 0 then
        setStatus("registre SHOT antes do resultado")
        return
    end

    local current = readState()
    local entry = session.shots[#session.shots]

    if entry.result ~= "PENDING" then
        setStatus("esta tentativa ja possui resultado")
        return
    end

    entry.result = resultName
    entry.resultFrame = current.frame

    if resultName == "KILL" then
        session.kills = session.kills + 1
    elseif resultName == "MISS" then
        session.misses = session.misses + 1
    end

    writeStateRow("RESULT", resultName, current)

    forms.settext(
        shotLabel,
        string.format(
            "Tentativa %d = %s\n"
            .. "SHOT frame=%d | screen_x=% .3f | desvio=% .3f\n"
            .. "RESULT frame=%d",
            entry.attempt,
            resultName,
            entry.shot.frame,
            entry.shot.screen_x,
            entry.shot.screen_x - SCREEN_CENTER_X,
            current.frame
        )
    )

    setStatus(resultName .. " registrado")
    log(
        resultName
        .. " | tentativa=" .. tostring(entry.attempt)
        .. " | shotFrame=" .. tostring(entry.shot.frame)
        .. " | resultFrame=" .. tostring(current.frame)
    )

    lastShot = nil
end

local function stopRecording()
    if not recording or not session then
        setStatus("nenhuma gravacao ativa")
        return
    end

    session.csv:close()
    session.csv = nil

    local summary = assert(io.open(session.summaryPath, "w"))

    summary:write("GoldenEyeDiagnostic " .. VERSION .. "\n")
    summary:write("ROM: " .. tostring(gameinfo.getromname()) .. "\n")
    summary:write("Hash: " .. tostring(gameinfo.getromhash()) .. "\n")
    summary:write("Started frame: "
        .. tostring(session.startedFrame) .. "\n")
    summary:write("Stopped frame: "
        .. tostring(emu.framecount()) .. "\n")
    summary:write("Attempts: "
        .. tostring(#session.shots) .. "\n")
    summary:write("Kills: " .. tostring(session.kills) .. "\n")
    summary:write("Misses: " .. tostring(session.misses) .. "\n")
    summary:write("CSV: " .. tostring(session.csvPath) .. "\n\n")

    summary:write("Attempts:\n")

    local killMin = nil
    local killMax = nil
    local missMin = nil
    local missMax = nil

    for _, entry in ipairs(session.shots) do
        local shot = entry.shot
        local x = shot.screen_x

        summary:write(
            tostring(entry.attempt)
            .. " | result=" .. tostring(entry.result)
            .. " | shotFrame=" .. tostring(shot.frame)
            .. " | resultFrame=" .. tostring(entry.resultFrame)
            .. " | arm=" .. classifyArm(shot)
            .. " | screen_x=" .. tostring(x)
            .. " | delta=" .. tostring(x - SCREEN_CENTER_X)
            .. " | raw=" .. tostring(shot.raw_horizontal)
            .. " | normalized=" .. tostring(shot.normalized)
            .. "\n"
        )

        if entry.result == "KILL" then
            killMin = killMin and math.min(killMin, x) or x
            killMax = killMax and math.max(killMax, x) or x
        elseif entry.result == "MISS" then
            missMin = missMin and math.min(missMin, x) or x
            missMax = missMax and math.max(missMax, x) or x
        end
    end

    summary:write("\nObserved ranges:\n")
    summary:write(
        "KILL screen_x: "
        .. tostring(killMin) .. " to " .. tostring(killMax) .. "\n"
    )
    summary:write(
        "MISS screen_x: "
        .. tostring(missMin) .. " to " .. tostring(missMax) .. "\n"
    )

    summary:close()

    recording = false
    lastShot = nil

    setStatus("gravacao encerrada")
    log(
        "Gravacao encerrada | tentativas="
        .. tostring(#session.shots)
        .. " | kills=" .. tostring(session.kills)
        .. " | misses=" .. tostring(session.misses)
    )
end

local function processPendingAction()
    if not pendingAction then
        return
    end

    local action = pendingAction
    pendingAction = nil

    local ok, err = pcall(function()
        if action == "START" then
            startRecording()
        elseif action == "SHOT" then
            registerShot()
        elseif action == "KILL" then
            registerResult("KILL")
        elseif action == "MISS" then
            registerResult("MISS")
        elseif action == "STOP" then
            stopRecording()
        end
    end)

    if not ok then
        setStatus("erro")
        forms.settext(shotLabel, tostring(err))
        log("ERRO: " .. tostring(err))
    end
end

form = forms.newform(
    950,
    690,
    "GoldenEyeDiagnostic " .. VERSION,
    function()
        stopped = true
    end
)

forms.label(
    form,
    "Shot Alignment Reference — primeiro soldado",
    12,
    10,
    910,
    24
)

statusLabel = forms.label(
    form,
    "Status: pronto",
    12,
    40,
    910,
    24
)

liveLabel = forms.label(
    form,
    "Estado atual: aguardando",
    12,
    75,
    910,
    215,
    true
)

shotLabel = forms.label(
    form,
    "Nenhum tiro registrado",
    12,
    295,
    910,
    75,
    true
)

filesLabel = forms.label(
    form,
    "Nenhum arquivo aberto",
    12,
    375,
    910,
    55,
    true
)

forms.button(
    form,
    "INICIAR",
    function()
        pendingAction = "START"
    end,
    12,
    450,
    130,
    40
)

forms.button(
    form,
    "SHOT",
    function()
        pendingAction = "SHOT"
    end,
    155,
    450,
    130,
    40
)

forms.button(
    form,
    "KILL",
    function()
        pendingAction = "KILL"
    end,
    298,
    450,
    130,
    40
)

forms.button(
    form,
    "MISS",
    function()
        pendingAction = "MISS"
    end,
    441,
    450,
    130,
    40
)

forms.button(
    form,
    "ENCERRAR",
    function()
        pendingAction = "STOP"
    end,
    584,
    450,
    140,
    40
)

forms.label(
    form,
    "Procedimento:\n"
    .. "1. Clique em INICIAR antes das tentativas.\n"
    .. "2. No exato momento de cada disparo, clique em SHOT.\n"
    .. "3. Quando confirmar visualmente o resultado, clique em KILL ou MISS.\n"
    .. "4. Repita varias vezes, idealmente alternando acertos e erros.\n"
    .. "5. Clique em ENCERRAR e envie o CSV e o resumo.\n\n"
    .. "Importante: KILL ou MISS sempre se aplica ao SHOT mais recente ainda pendente. "
    .. "O objetivo e descobrir a faixa de screen_x associada aos acertos, sem assumir "
    .. "que o valor correto seja 160.",
    12,
    515,
    910,
    145
)

console.clear()
log("Carregado | versao=" .. VERSION)
log("ROM=" .. tostring(gameinfo.getromname()))
log("Hash=" .. tostring(gameinfo.getromhash()))

if tostring(gameinfo.getromhash()) ~= EXPECTED_ROM_HASH then
    log("AVISO | hash inesperado")
end

event.onexit(function()
    if recording then
        pcall(stopRecording)
    end
    stopped = true
end, "GoldenEyeDiagnostic-0.0.5.7-exit")

while not stopped do
    processPendingAction()

    local state = readState()
    forms.settext(liveLabel, "Estado atual:\n" .. liveText(state))

    gui.drawString(
        8,
        8,
        "GoldenEyeDiagnostic " .. VERSION,
        "white",
        "black",
        12
    )

    gui.drawString(
        8,
        26,
        classifyArm(state),
        "white",
        "black",
        12
    )

    emu.yield()
end
