-- GoldenEyeDiagnostic 0.0.1
-- Gravador de demonstracoes para GoldenEye 007 (Nintendo 64) no BizHawk.
-- Somente leitura de controles; nao le nem altera a memoria do jogo.

local VERSION = "0.0.1"
local CONTROLLER = 1
local FLUSH_INTERVAL = 60

local stopped = false
local pendingEvent = ""
local rowsWritten = 0
local sessionStartFrame = emu.framecount()

local function scriptDirectory()
    local source = debug.getinfo(1, "S").source
    if string.sub(source, 1, 1) == "@" then
        source = string.sub(source, 2)
    end
    return source:match("^(.*[\\/])") or ".\\"
end

local BASE_DIR = scriptDirectory()
local OUTPUT_DIR = BASE_DIR .. "output\\"

-- Cria a pasta no Windows. Se ela ja existir, o comando e inofensivo.
os.execute('if not exist "' .. OUTPUT_DIR .. '" mkdir "' .. OUTPUT_DIR .. '"')

local timestamp = os.date("%Y%m%d-%H%M%S")
local sessionName = "session-" .. timestamp
local csvPath = OUTPUT_DIR .. sessionName .. "-frames.csv"
local summaryPath = OUTPUT_DIR .. sessionName .. "-summary.txt"

local csv = assert(io.open(csvPath, "w"))
csv:write("frame,relative_frame,is_lagged,lag_count,event,input_state\n")

local function csvEscape(value)
    value = tostring(value or "")
    value = value:gsub('"', '""')
    return '"' .. value .. '"'
end

local function sortedKeys(t)
    local keys = {}
    for k, _ in pairs(t or {}) do
        table.insert(keys, tostring(k))
    end
    table.sort(keys)
    return keys
end

local function serializeInputs(inputs)
    local parts = {}
    local keys = sortedKeys(inputs)
    for _, key in ipairs(keys) do
        local value = inputs[key]
        if value == true then
            value = "1"
        elseif value == false then
            value = "0"
        else
            value = tostring(value)
        end
        table.insert(parts, key .. "=" .. value)
    end
    return table.concat(parts, ";")
end

local function writeSummary(reason)
    local f = io.open(summaryPath, "w")
    if not f then return end
    f:write("GoldenEyeDiagnostic " .. VERSION .. "\n")
    f:write("Motivo do encerramento: " .. tostring(reason) .. "\n")
    f:write("ROM: " .. tostring(gameinfo.getromname()) .. "\n")
    f:write("SHA-1/Hash: " .. tostring(gameinfo.getromhash()) .. "\n")
    f:write("Sistema: " .. tostring(emu.getsystemid()) .. "\n")
    f:write("Frame inicial: " .. tostring(sessionStartFrame) .. "\n")
    f:write("Frame final: " .. tostring(emu.framecount()) .. "\n")
    f:write("Quadros gravados: " .. tostring(rowsWritten) .. "\n")
    f:write("CSV: " .. csvPath .. "\n")
    f:close()
end

local function mark(name)
    pendingEvent = name
    console.log("[GoldenEyeDiagnostic] Marcador: " .. name ..
        " | frame=" .. tostring(emu.framecount()))
end

local function stop(reason)
    if stopped then return end
    stopped = true
    reason = reason or "STOP"
    mark(reason)
    csv:flush()
    csv:close()
    writeSummary(reason)
    console.log("[GoldenEyeDiagnostic] Gravacao encerrada.")
    console.log("[GoldenEyeDiagnostic] CSV: " .. csvPath)
    console.log("[GoldenEyeDiagnostic] Resumo: " .. summaryPath)
end

local form = forms.newform(430, 245, "GoldenEyeDiagnostic " .. VERSION, function()
    stop("FORM_CLOSED")
end)

forms.label(form, "Gravacao quadro a quadro - Controle 1", 12, 10, 390, 24)
local statusLabel = forms.label(form, "Status: GRAVANDO", 12, 36, 390, 24)

forms.button(form, "INICIO", function() mark("START") end, 12, 68, 90, 30)
forms.button(form, "SOLDADO VISIVEL", function() mark("SOLDIER_VISIBLE") end, 110, 68, 135, 30)
forms.button(form, "TIRO", function() mark("SHOT") end, 253, 68, 70, 30)
forms.button(form, "SOLDADO MORTO", function() mark("SOLDIER_DEAD") end, 12, 106, 135, 30)
forms.button(form, "ERRO DE ROTA", function() mark("ROUTE_ERROR") end, 155, 106, 120, 30)
forms.button(form, "FIM", function()
    stop("STOP_BUTTON")
    forms.settext(statusLabel, "Status: ENCERRADO")
end, 283, 106, 70, 30)

forms.label(form,
    "Use os botoes apenas como marcadores.\n" ..
    "O script grava automaticamente os controles a cada frame.\n" ..
    "Fechar a janela ou parar o script tambem fecha os arquivos.",
    12, 150, 395, 65)

console.clear()
console.log("[GoldenEyeDiagnostic] Carregado | versao=" .. VERSION)
console.log("[GoldenEyeDiagnostic] ROM=" .. tostring(gameinfo.getromname()))
console.log("[GoldenEyeDiagnostic] Sistema=" .. tostring(emu.getsystemid()))
console.log("[GoldenEyeDiagnostic] Gravando em: " .. csvPath)

-- Marca automaticamente o primeiro quadro da sessao.
pendingEvent = "SESSION_START"

event.onexit(function()
    stop("SCRIPT_EXIT")
end, "GoldenEyeDiagnostic-0.0.1-exit")

while not stopped do
    local frame = emu.framecount()
    -- getimmediate captura o que o jogador esta fisicamente pressionando.
    local inputs = joypad.getimmediate(CONTROLLER) or {}
    local lagged = emu.islagged() and 1 or 0
    local eventName = pendingEvent
    pendingEvent = ""

    csv:write(
        tostring(frame) .. "," ..
        tostring(frame - sessionStartFrame) .. "," ..
        tostring(lagged) .. "," ..
        tostring(emu.lagcount()) .. "," ..
        csvEscape(eventName) .. "," ..
        csvEscape(serializeInputs(inputs)) .. "\n"
    )

    rowsWritten = rowsWritten + 1
    if rowsWritten % FLUSH_INTERVAL == 0 then
        csv:flush()
        forms.settext(statusLabel,
            "Status: GRAVANDO | frames=" .. tostring(rowsWritten))
    end

    gui.drawString(8, 8,
        "GoldenEyeDiagnostic " .. VERSION ..
        " | REC | frames=" .. tostring(rowsWritten),
        "white", "black", 12)

    emu.frameadvance()
end
