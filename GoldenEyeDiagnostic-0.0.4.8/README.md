# GoldenEyeDiagnostic 0.0.4.8 — Frame-Locked Automatic Combat

Corrige dois problemas da versão 0.0.4.7.

## 1. Um input por frame real

A versão anterior usava `emu.yield()`, permitindo que mais de uma etapa fosse
processada no mesmo frame do emulador.

Agora cada etapa usa:

```lua
joypad.set(...)
emu.frameadvance()
```

Assim:

```text
5 frames com Z
5 frames sem Z
5 frames com Z
```

correspondem realmente a 15 frames emulados.

## 2. O endereço 0x0003CB7F não prova acerto

A mudança desse endereço passa a ser registrada apenas como `hitSignal`.

Ela pode indicar:

- disparo;
- início de combate;
- animação;
- algum evento interno.

Não é mais suficiente para classificar `HIT_ONLY`.

## Resultados

### KILL

Detectado por qualquer um dos sinais fortes:

```text
death == 1
state == 2
pointer == 0
```

### MISS

Não houve morte nem mudança no sinal auxiliar.

### UNKNOWN

O `hitSignal` mudou, mas não houve morte. É necessário conferir visualmente.

### TIMEOUT

Teste abortado, estado inicial inválido ou interrupção.

## Procedimento

1. Recarregue o mesmo savestate.
2. Abra `GoldenEyeDiagnostic-0.0.4.8.lua`.
3. Mantenha os valores padrão.
4. Clique em `INICIAR TESTE`.
5. Não toque no controle.

## Arquivos

```text
output/
├── frame-locked-combat-...-log.csv
└── frame-locked-combat-...-summary.txt
```

O log registra `ROUTE_HIT_SIGNAL` ou `COMBAT_HIT_SIGNAL` quando o endereço
auxiliar muda, sem afirmar que o soldado foi atingido.
