# GoldenEyeDiagnostic 0.0.5.8.7 — First Soldier Pointer Death Gate

Esta versão usa o candidato validado `0x001F421C` como sinal principal de morte
do primeiro soldado.

## Padrão observado

```text
BEFORE_SHOT   = 0x801FABDC
HIT           = 0x801FABDC
VISUAL_DEATH  = 0x00000000
MISS          = 0x801FABDC
```

## Regra de morte

```text
baselinePointer != 0
e
currentPointer == 0
por 3 frames consecutivos
```

## Estados

```text
IDLE
TRACKING
SHOT_READY
FIRED
WAITING_RESULT
KILL_CONFIRMED
SHOT_FAILED
RETRY_DELAY
COMPLETE
```

## Fluxo de sucesso

```text
IDLE
→ TRACKING
→ SHOT_READY
→ FIRED
→ WAITING_RESULT
→ KILL_CONFIRMED
→ COMPLETE
```

Depois de `COMPLETE`, nenhum novo tiro é permitido.

## Fluxo de falha

```text
WAITING_RESULT
→ SHOT_FAILED
→ RETRY_DELAY
→ IDLE
```

O `RETRY_DELAY` agora bloqueia realmente uma nova aquisição pelo número
configurado de frames.

## Valores iniciais

```text
screen_x: 157–163
memória do auto-aim: 45 frames
alinhamento: 2 frames
delay de resultado: 4 frames
timeout: 120 frames
confirmação da morte: 3 frames
máximo de tentativas: 2
retry delay: 20 frames
```

## Procedimento

1. Clique em `INICIAR SESSAO`.
2. Clique em `ATIVAR GATE`.
3. Conduza Bond até o primeiro soldado.
4. O script dispara quando o braço estiver alinhado.
5. Observe `WAITING_RESULT`.
6. Quando `0x001F421C` zerar por três frames, o script deve entrar em
   `KILL_CONFIRMED`.
7. Em seguida, deve entrar em `COMPLETE` e parar de atirar.

## Arquivos

```text
output/
├── first-soldier-pointer-death-gate-...csv
└── first-soldier-pointer-death-gate-...-summary.txt
```

## Diagnóstico adicional

O CSV registra toda mudança do ponteiro com o evento `POINTER_CHANGED`, além
de manter baseline, valor no tiro, valor atual e valor anterior.
