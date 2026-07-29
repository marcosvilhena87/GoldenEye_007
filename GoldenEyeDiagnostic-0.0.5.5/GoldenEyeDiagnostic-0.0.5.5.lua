-- GoldenEyeDiagnostic 0.0.5.5
-- Camera Direction Calibration
--
-- Aprende os padroes reais da matriz da camera para:
-- REFERENCE, LEFT, RIGHT, UP e DOWN.
--
-- Depois, VALIDATE CURRENT compara a matriz atual com os exemplos
-- calibrados e escolhe a direcao mais semelhante.
--
-- Somente leitura via mainmemory.

local VERSION = "0.0.5.5"
local EXPECTED_ROM_HASH = "ABE01E4AEB033B6C0836819F549C791B26CFDE83"

local ADDRESSES = {
    0x00079950, 0x00079954, 0x00079958,
    0x00079960, 0x00079964, 0x00079968,
    0x00079970, 0x00079974, 0x00079978
}

local NAMES = {
    "m11", "m12", "m13",
    "m21", "m22", "m23",
    "m31", "m32", "m33"
}

local LABELS = {"LEFT", "RIGHT", "UP", "DOWN"}
local DEFAULT_ALIGNED_TOLERANCE = 0.020
local DEFAULT_MIN_CONFIDENCE = 0.55

local stopped = false
local pendingTask = nil
local reference = nil
local examples = {}
local lastResult = "NONE"

local form
local statusLabel
local matrixLabel
local scoreLabel
local resultLabel
local alignedToleranceBox
local confidenceBox

local function scriptDirectory()
    local source = debug.getinfo(1, "S").source
    if source:sub(1, 1) == "@" then
        source = source:sub(2)
    end
    return source:match("^(.*[\\/])") or ".\\"
end

local BASE_DIR = scriptDirectory()
local OUTPUT_DIR = BASE_DIR .. "output\\"
local CALIBRATION_PATH = OUTPUT_DIR .. "camera-direction-calibration.csv"

os.execute('if not exist "' .. OUTPUT_DIR .. '" mkdir "' .. OUTPUT_DIR .. '"')

local function log(text)
    console.log("[GoldenEyeDiagnostic] " .. text)
end

local function setStatus(text)
    forms.settext(statusLabel, "Status: " .. text)
end

local function clampNumber(value, minimum, maximum, defaultValue)
    local number = tonumber(value)
    if not number then
        return defaultValue
    end

    if number < minimum then number = minimum end
    if number > maximum then number = maximum end
    return number
end

local function readMatrix()
    local matrix = {}

    for i, address in ipairs(ADDRESSES) do
        matrix[i] = mainmemory.readfloat(address, true)
    end

    return matrix
end

local function matrixText(matrix)
    return string.format(
        "[% .6f  % .6f  % .6f]\n"
        .. "[% .6f  % .6f  % .6f]\n"
        .. "[% .6f  % .6f  % .6f]",
        matrix[1], matrix[2], matrix[3],
        matrix[4], matrix[5], matrix[6],
        matrix[7], matrix[8], matrix[9]
    )
end

local function subtract(a, b)
    local result = {}

    for i = 1, 9 do
        result[i] = a[i] - b[i]
    end

    return result
end

local function magnitude(vector)
    local total = 0

    for i = 1, #vector do
        total = total + vector[i] * vector[i]
    end

    return math.sqrt(total)
end

local function maxAbs(vector)
    local maximum = 0

    for i = 1, #vector do
        maximum = math.max(maximum, math.abs(vector[i]))
    end

    return maximum
end

local function normalize(vector)
    local length = magnitude(vector)
    local result = {}

    if length == 0 then
        for i = 1, #vector do
            result[i] = 0
        end
        return result
    end

    for i = 1, #vector do
        result[i] = vector[i] / length
    end

    return result
end

local function cosineSimilarity(a, b)
    local dot = 0
    local lengthA = 0
    local lengthB = 0

    for i = 1, #a do
        dot = dot + a[i] * b[i]
        lengthA = lengthA + a[i] * a[i]
        lengthB = lengthB + b[i] * b[i]
    end

    if lengthA == 0 or lengthB == 0 then
        return 0
    end

    return dot / math.sqrt(lengthA * lengthB)
end

local function saveCalibration()
    local file = assert(io.open(CALIBRATION_PATH, "w"))
    file:write("label,index,name,address_hex,value\n")

    if reference then
        for i = 1, 9 do
            file:write(
                "REFERENCE,"
                .. tostring(i) .. ","
                .. NAMES[i] .. ","
                .. string.format("0x%08X", ADDRESSES[i]) .. ","
                .. tostring(reference[i]) .. "\n"
            )
        end
    end

    for _, label in ipairs(LABELS) do
        local matrix = examples[label]

        if matrix then
            for i = 1, 9 do
                file:write(
                    label .. ","
                    .. tostring(i) .. ","
                    .. NAMES[i] .. ","
                    .. string.format("0x%08X", ADDRESSES[i]) .. ","
                    .. tostring(matrix[i]) .. "\n"
                )
            end
        end
    end

    file:close()
end

local function loadCalibration()
    local file = io.open(CALIBRATION_PATH, "r")

    if not file then
        return false
    end

    file:read("*l")
    local loaded = {}

    for line in file:lines() do
        local label, indexText, _, _, valueText =
            line:match("^([^,]+),([^,]+),([^,]+),([^,]+),([^,]+)$")

        if label and indexText and valueText then
            local index = tonumber(indexText)
            local value = tonumber(valueText)

            loaded[label] = loaded[label] or {}
            loaded[label][index] = value
        end
    end

    file:close()

    reference = loaded.REFERENCE
    examples = {}

    for _, label in ipairs(LABELS) do
        if loaded[label] and #loaded[label] == 9 then
            examples[label] = loaded[label]
        end
    end

    return reference ~= nil and #reference == 9
end

local function calibrationStatusText()
    local parts = {}

    table.insert(parts, reference and "REFERENCE=OK" or "REFERENCE=--")

    for _, label in ipairs(LABELS) do
        table.insert(parts,
            label .. "=" .. (examples[label] and "OK" or "--"))
    end

    return table.concat(parts, " | ")
end

local function capture(label)
    local matrix = readMatrix()

    if label == "REFERENCE" then
        reference = matrix
    else
        if not reference then
            setStatus("capture REFERENCE primeiro")
            return
        end

        examples[label] = matrix
    end

    saveCalibration()

    setStatus(label .. " capturado")
    forms.settext(
        resultLabel,
        label .. " capturado no frame "
        .. tostring(emu.framecount())
        .. "\n" .. calibrationStatusText()
    )

    log("Captura=" .. label
        .. " | frame=" .. tostring(emu.framecount()))
end

local function classify(current)
    if not reference then
        return "NO_REFERENCE", {}, 0, 0
    end

    local alignedTolerance = clampNumber(
        forms.gettext(alignedToleranceBox),
        0.0001,
        1.0,
        DEFAULT_ALIGNED_TOLERANCE
    )

    local minConfidence = clampNumber(
        forms.gettext(confidenceBox),
        0.0,
        1.0,
        DEFAULT_MIN_CONFIDENCE
    )

    local currentDelta = subtract(current, reference)
    local currentMax = maxAbs(currentDelta)

    if currentMax <= alignedTolerance then
        return "CAMERA_ALIGNED", {}, 1.0, currentMax
    end

    local normalizedCurrent = normalize(currentDelta)
    local scores = {}
    local bestLabel = nil
    local bestScore = -2

    for _, label in ipairs(LABELS) do
        local example = examples[label]

        if example then
            local exampleDelta = subtract(example, reference)
            local normalizedExample = normalize(exampleDelta)
            local score = cosineSimilarity(
                normalizedCurrent,
                normalizedExample
            )

            scores[label] = score

            if score > bestScore then
                bestScore = score
                bestLabel = label
            end
        end
    end

    if not bestLabel then
        return "CALIBRATION_INCOMPLETE", scores, 0, currentMax
    end

    if bestScore < minConfidence then
        return "CAMERA_UNKNOWN", scores, bestScore, currentMax
    end

    return "CAMERA_" .. bestLabel, scores, bestScore, currentMax
end

local function scoresText(scores)
    local parts = {}

    for _, label in ipairs(LABELS) do
        local score = scores[label]

        if score then
            table.insert(
                parts,
                label .. "=" .. string.format("%.4f", score)
            )
        else
            table.insert(parts, label .. "=--")
        end
    end

    return table.concat(parts, " | ")
end

local function writeValidationFiles(
    current,
    classification,
    scores,
    confidence,
    currentMax
)
    local timestamp = os.date("%Y%m%d-%H%M%S")
    local csvPath = OUTPUT_DIR
        .. "camera-direction-validation-" .. timestamp .. ".csv"
    local summaryPath = OUTPUT_DIR
        .. "camera-direction-validation-" .. timestamp
        .. "-summary.txt"

    local currentDelta = reference
        and subtract(current, reference)
        or {}

    local csv = assert(io.open(csvPath, "w"))
    csv:write(
        "name,address_hex,reference,current,delta\n"
    )

    for i = 1, 9 do
        csv:write(
            NAMES[i] .. ","
            .. string.format("0x%08X", ADDRESSES[i]) .. ","
            .. tostring(reference and reference[i] or "") .. ","
            .. tostring(current[i]) .. ","
            .. tostring(currentDelta[i] or "") .. "\n"
        )
    end

    csv:close()

    local summary = assert(io.open(summaryPath, "w"))
    summary:write("GoldenEyeDiagnostic " .. VERSION .. "\n")
    summary:write("ROM: " .. tostring(gameinfo.getromname()) .. "\n")
    summary:write("Hash: " .. tostring(gameinfo.getromhash()) .. "\n")
    summary:write("Frame: " .. tostring(emu.framecount()) .. "\n")
    summary:write("Classification: " .. classification .. "\n")
    summary:write("Confidence: " .. tostring(confidence) .. "\n")
    summary:write("Max component delta: "
        .. tostring(currentMax) .. "\n")
    summary:write("Scores: " .. scoresText(scores) .. "\n")
    summary:write("Calibration: " .. CALIBRATION_PATH .. "\n")
    summary:write("CSV: " .. csvPath .. "\n\n")

    if reference then
        summary:write("Reference matrix:\n")
        summary:write(matrixText(reference) .. "\n\n")
    end

    summary:write("Current matrix:\n")
    summary:write(matrixText(current) .. "\n\n")

    if reference then
        summary:write("Delta matrix:\n")
        summary:write(matrixText(currentDelta) .. "\n")
    end

    summary:close()

    return csvPath, summaryPath
end

local function validateCurrent()
    local current = readMatrix()

    local classification, scores, confidence, currentMax =
        classify(current)

    local _, summaryPath = writeValidationFiles(
        current,
        classification,
        scores,
        confidence,
        currentMax
    )

    lastResult = classification

    forms.settext(
        scoreLabel,
        "Scores: " .. scoresText(scores)
        .. "\nConfiança: "
        .. string.format("%.4f", confidence)
        .. " | Maior delta: "
        .. string.format("%.6f", currentMax)
    )

    forms.settext(
        resultLabel,
        "Resultado: " .. classification
        .. "\nResumo: " .. summaryPath
    )

    setStatus("validacao concluida")

    log("Classificacao=" .. classification
        .. " | confianca=" .. tostring(confidence)
        .. " | scores=" .. scoresText(scores))
end

local function clearCalibration()
    os.remove(CALIBRATION_PATH)
    reference = nil
    examples = {}
    lastResult = "NONE"

    setStatus("calibracao removida")
    forms.settext(
        resultLabel,
        "Calibracao removida.\nCapture REFERENCE novamente."
    )
end

local function processPendingTask()
    if not pendingTask then
        return
    end

    local task = pendingTask
    pendingTask = nil

    local ok, err = pcall(function()
        if task == "REFERENCE" then
            capture("REFERENCE")
        elseif task == "LEFT" then
            capture("LEFT")
        elseif task == "RIGHT" then
            capture("RIGHT")
        elseif task == "UP" then
            capture("UP")
        elseif task == "DOWN" then
            capture("DOWN")
        elseif task == "VALIDATE" then
            validateCurrent()
        elseif task == "RELOAD" then
            if loadCalibration() then
                setStatus("calibracao carregada")
                forms.settext(
                    resultLabel,
                    calibrationStatusText()
                )
            else
                setStatus("calibracao ausente ou incompleta")
            end
        elseif task == "CLEAR" then
            clearCalibration()
        end
    end)

    if not ok then
        setStatus("erro")
        forms.settext(resultLabel, tostring(err))
        log("ERRO: " .. tostring(err))
    end
end

form = forms.newform(
    930,
    680,
    "GoldenEyeDiagnostic " .. VERSION,
    function()
        stopped = true
    end
)

forms.label(
    form,
    "Camera Direction Calibration — aprendizagem por exemplos",
    12,
    10,
    890,
    24
)

statusLabel = forms.label(
    form,
    "Status: inicializando",
    12,
    40,
    890,
    24
)

matrixLabel = forms.label(
    form,
    "Matriz atual: aguardando",
    12,
    75,
    890,
    125,
    true
)

scoreLabel = forms.label(
    form,
    "Scores: aguardando",
    12,
    205,
    890,
    55,
    true
)

resultLabel = forms.label(
    form,
    "Nenhuma validacao",
    12,
    265,
    890,
    65,
    true
)

forms.label(
    form,
    "Tolerancia CAMERA_ALIGNED",
    12,
    350,
    175,
    22
)

alignedToleranceBox = forms.textbox(
    form,
    tostring(DEFAULT_ALIGNED_TOLERANCE),
    90,
    24,
    nil,
    190,
    347
)

forms.label(
    form,
    "Confianca minima",
    305,
    350,
    110,
    22
)

confidenceBox = forms.textbox(
    form,
    tostring(DEFAULT_MIN_CONFIDENCE),
    90,
    24,
    nil,
    420,
    347
)

forms.button(
    form,
    "1. REFERENCE",
    function()
        pendingTask = "REFERENCE"
    end,
    12,
    395,
    150,
    38
)

forms.button(
    form,
    "2. LEFT",
    function()
        pendingTask = "LEFT"
    end,
    175,
    395,
    130,
    38
)

forms.button(
    form,
    "3. RIGHT",
    function()
        pendingTask = "RIGHT"
    end,
    318,
    395,
    130,
    38
)

forms.button(
    form,
    "4. UP",
    function()
        pendingTask = "UP"
    end,
    461,
    395,
    130,
    38
)

forms.button(
    form,
    "5. DOWN",
    function()
        pendingTask = "DOWN"
    end,
    604,
    395,
    130,
    38
)

forms.button(
    form,
    "VALIDATE CURRENT",
    function()
        pendingTask = "VALIDATE"
    end,
    12,
    450,
    190,
    38
)

forms.button(
    form,
    "RELOAD CALIBRATION",
    function()
        pendingTask = "RELOAD"
    end,
    215,
    450,
    190,
    38
)

forms.button(
    form,
    "CLEAR CALIBRATION",
    function()
        pendingTask = "CLEAR"
    end,
    418,
    450,
    180,
    38
)

forms.label(
    form,
    "Calibracao:\n"
    .. "1. Em uma posicao qualquer, deixe a camera parada e capture REFERENCE.\n"
    .. "2. Gire um pouco para a esquerda e capture LEFT.\n"
    .. "3. Volte exatamente a REFERENCE; gire para a direita e capture RIGHT.\n"
    .. "4. Volte a REFERENCE; olhe um pouco para cima e capture UP.\n"
    .. "5. Volte a REFERENCE; olhe um pouco para baixo e capture DOWN.\n"
    .. "6. Volte a REFERENCE e use VALIDATE CURRENT para testar alinhamento.\n\n"
    .. "A classificacao usa a semelhanca entre a diferenca atual e os quatro "
    .. "exemplos medidos no seu proprio jogo.",
    12,
    515,
    890,
    140
)

console.clear()
log("Carregado | versao=" .. VERSION)
log("ROM=" .. tostring(gameinfo.getromname()))
log("Hash=" .. tostring(gameinfo.getromhash()))

if tostring(gameinfo.getromhash()) ~= EXPECTED_ROM_HASH then
    log("AVISO | hash inesperado")
end

if loadCalibration() then
    setStatus("calibracao carregada")
    forms.settext(resultLabel, calibrationStatusText())
else
    setStatus("pronto; calibracao ausente")
end

event.onexit(function()
    stopped = true
end, "GoldenEyeDiagnostic-0.0.5.5-exit")

while not stopped do
    processPendingTask()

    local current = readMatrix()

    forms.settext(
        matrixLabel,
        "Matriz atual:\n" .. matrixText(current)
    )

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
        "Resultado=" .. lastResult,
        "white",
        "black",
        12
    )

    emu.yield()
end
