-- GoldenEyeDiagnostic 0.0.5.4
-- Camera Matrix Validation
-- Somente leitura via mainmemory.

local VERSION = "0.0.5.4"
local HASH = "ABE01E4AEB033B6C0836819F549C791B26CFDE83"
local ADDR = {
  0x00079950,0x00079954,0x00079958,
  0x00079960,0x00079964,0x00079968,
  0x00079970,0x00079974,0x00079978
}
local NAMES={"m11","m12","m13","m21","m22","m23","m31","m32","m33"}
local stopped=false
local pending=nil
local reference=nil
local lastResult="NONE"

local function scriptDir()
  local s=debug.getinfo(1,"S").source
  if s:sub(1,1)=="@" then s=s:sub(2) end
  return s:match("^(.*[\\/])") or ".\\"
end

local BASE=scriptDir()
local OUT=BASE.."output\\"
local REF=OUT.."camera-matrix-reference.csv"
os.execute('if not exist "'..OUT..'" mkdir "'..OUT..'"')

local function log(t) console.log("[GoldenEyeDiagnostic] "..t) end
local function readMatrix()
  local m={}
  for i,a in ipairs(ADDR) do m[i]=mainmemory.readfloat(a,true) end
  return m
end
local function matrixText(m)
  return string.format(
    "[% .6f  % .6f  % .6f]\n[% .6f  % .6f  % .6f]\n[% .6f  % .6f  % .6f]",
    m[1],m[2],m[3],m[4],m[5],m[6],m[7],m[8],m[9])
end
local function delta(a,b)
  local d={}
  for i=1,9 do d[i]=b[i]-a[i] end
  return d
end
local function maxAbs(v)
  local x=0
  for i=1,#v do x=math.max(x,math.abs(v[i])) end
  return x
end
local function norm(x,y,z)
  local l=math.sqrt(x*x+y*y+z*z)
  if l==0 then return 0,0,0 end
  return x/l,y/l,z/l
end
local function forward(m) return norm(m[3],m[6],m[9]) end

local form=forms.newform(900,610,"GoldenEyeDiagnostic "..VERSION,function() stopped=true end)
forms.label(form,"Camera Matrix Validation — antes do primeiro tiro",12,10,860,24)
local status=forms.label(form,"Status: pronto",12,40,860,24)
local matrixLabel=forms.label(form,"Matriz atual:",12,75,860,125,true)
local deltaLabel=forms.label(form,"Delta: aguardando",12,205,860,55,true)
local resultLabel=forms.label(form,"Nenhuma validacao",12,265,860,60,true)
forms.label(form,"Tolerancia por componente",12,345,160,22)
local tolBox=forms.textbox(form,"0.020",90,24,nil,175,342)
forms.label(form,"Tolerancia direcional",290,345,135,22)
local dirBox=forms.textbox(form,"0.010",90,24,nil,430,342)

local function setStatus(t) forms.settext(status,"Status: "..t) end
local function clamp(v,lo,hi,def)
  local n=tonumber(v) or def
  if n<lo then n=lo elseif n>hi then n=hi end
  return n
end

local function saveReference(m)
  local f=assert(io.open(REF,"w"))
  f:write("name,address_hex,value\n")
  for i=1,9 do
    f:write(NAMES[i]..","..string.format("0x%08X",ADDR[i])..","..tostring(m[i]).."\n")
  end
  f:close()
  reference=m
  setStatus("referencia capturada")
  forms.settext(resultLabel,"Referencia salva:\n"..REF)
  log("Referencia capturada | frame="..emu.framecount())
end

local function loadReference()
  local f=io.open(REF,"r")
  if not f then reference=nil return false end
  f:read("*l")
  local m={}
  for line in f:lines() do
    local _,_,v=line:match("^([^,]+),([^,]+),([^,]+)$")
    if v then table.insert(m,tonumber(v)) end
  end
  f:close()
  if #m~=9 then reference=nil return false end
  reference=m
  return true
end

local function classify(cur)
  local tol=clamp(forms.gettext(tolBox),0.0001,1,0.020)
  local dtol=clamp(forms.gettext(dirBox),0.0001,1,0.010)
  local d=delta(reference,cur)
  local rfx,rfy,rfz=forward(reference)
  local cfx,cfy,cfz=forward(cur)
  local dx,dy,dz=cfx-rfx,cfy-rfy,cfz-rfz
  local result
  if maxAbs(d)<=tol then
    result="CAMERA_ALIGNED"
  elseif math.abs(dx)>=math.abs(dy) and math.abs(dx)>=math.abs(dz) and math.abs(dx)>=dtol then
    result=dx<0 and "CAMERA_LEFT" or "CAMERA_RIGHT"
  elseif math.abs(dy)>=math.abs(dx) and math.abs(dy)>=math.abs(dz) and math.abs(dy)>=dtol then
    result=dy>0 and "CAMERA_UP" or "CAMERA_DOWN"
  else
    result="CAMERA_DIFFERENT"
  end
  return result,d,dx,dy,dz
end

local function validate()
  if not reference then
    setStatus("referencia ausente")
    forms.settext(resultLabel,"Capture uma referencia primeiro.")
    return
  end
  local cur=readMatrix()
  local result,d,dx,dy,dz=classify(cur)
  local ts=os.date("%Y%m%d-%H%M%S")
  local csvPath=OUT.."camera-matrix-validation-"..ts..".csv"
  local sumPath=OUT.."camera-matrix-validation-"..ts.."-summary.txt"

  local c=assert(io.open(csvPath,"w"))
  c:write("name,address_hex,reference,current,delta\n")
  for i=1,9 do
    c:write(NAMES[i]..","..string.format("0x%08X",ADDR[i])..","..
      tostring(reference[i])..","..tostring(cur[i])..","..tostring(d[i]).."\n")
  end
  c:close()

  local s=assert(io.open(sumPath,"w"))
  s:write("GoldenEyeDiagnostic "..VERSION.."\n")
  s:write("ROM: "..tostring(gameinfo.getromname()).."\n")
  s:write("Hash: "..tostring(gameinfo.getromhash()).."\n")
  s:write("Frame: "..tostring(emu.framecount()).."\n")
  s:write("Classification: "..result.."\n")
  s:write("Forward delta X: "..tostring(dx).."\n")
  s:write("Forward delta Y: "..tostring(dy).."\n")
  s:write("Forward delta Z: "..tostring(dz).."\n")
  s:write("Max component delta: "..tostring(maxAbs(d)).."\n")
  s:write("CSV: "..csvPath.."\n\nReference matrix:\n"..matrixText(reference))
  s:write("\n\nCurrent matrix:\n"..matrixText(cur))
  s:write("\n\nDelta matrix:\n"..matrixText(d).."\n")
  s:close()

  lastResult=result
  forms.settext(deltaLabel,string.format(
    "Delta frente: X=% .6f | Y=% .6f | Z=% .6f\nMaior delta: %.6f",
    dx,dy,dz,maxAbs(d)))
  forms.settext(resultLabel,"Resultado: "..result.."\nResumo: "..sumPath)
  setStatus("validacao concluida")
  log("Classificacao="..result.." | dx="..dx.." | dy="..dy.." | dz="..dz)
end

forms.button(form,"CAPTURAR REFERENCIA",function() pending="CAPTURE" end,12,390,200,38)
forms.button(form,"VALIDAR ATUAL",function() pending="VALIDATE" end,225,390,160,38)
forms.button(form,"RECARREGAR REFERENCIA",function() pending="RELOAD" end,398,390,200,38)
forms.button(form,"REMOVER REFERENCIA",function() pending="DELETE" end,611,390,180,38)

forms.label(form,
  "Procedimento:\n1. Pare imediatamente antes do primeiro tiro, com a mira correta.\n"..
  "2. Clique em CAPTURAR REFERENCIA.\n3. Recarregue o mesmo savestate e repita a rota.\n"..
  "4. Pare novamente antes do tiro e clique em VALIDAR ATUAL.\n\n"..
  "CAMERA_ALIGNED usa os nove componentes. As direcoes sao hipoteses iniciais e devem ser confirmadas visualmente.",
  12,455,860,125)

console.clear()
log("Carregado | versao="..VERSION)
log("ROM="..tostring(gameinfo.getromname()))
log("Hash="..tostring(gameinfo.getromhash()))
if tostring(gameinfo.getromhash())~=HASH then log("AVISO | hash inesperado") end
if loadReference() then setStatus("referencia carregada") else setStatus("pronto; referencia ausente") end

event.onexit(function() stopped=true end,"GoldenEyeDiagnostic-0.0.5.4-exit")

while not stopped do
  if pending then
    local task=pending
    pending=nil
    local ok,err=pcall(function()
      if task=="CAPTURE" then saveReference(readMatrix())
      elseif task=="VALIDATE" then validate()
      elseif task=="RELOAD" then
        if loadReference() then setStatus("referencia recarregada")
        else setStatus("referencia nao encontrada") end
      elseif task=="DELETE" then
        os.remove(REF); reference=nil; lastResult="NONE"
        setStatus("referencia removida")
      end
    end)
    if not ok then
      setStatus("erro")
      forms.settext(resultLabel,tostring(err))
      log("ERRO: "..tostring(err))
    end
  end

  local cur=readMatrix()
  forms.settext(matrixLabel,"Matriz atual:\n"..matrixText(cur))
  gui.drawString(8,8,"GoldenEyeDiagnostic "..VERSION,"white","black",12)
  gui.drawString(8,26,"Resultado="..lastResult,"white","black",12)
  emu.yield()
end
