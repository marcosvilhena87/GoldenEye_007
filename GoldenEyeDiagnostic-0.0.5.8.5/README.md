# GoldenEyeDiagnostic 0.0.5.8.5 — First Soldier Outcome Gate

Esta versão substitui a tentativa de inferir `TARGET_LOST` pelo braço.

Depois do disparo, quem decide o próximo estado é o resultado observado na
memória do primeiro soldado.

## Estados

```text
IDLE
TRACKING
SHOT_READY
FIRED
WAITING_RESULT
KILL_CONFIRMED
SHOT_FAILED
COMPLETE
```

## Sinais monitorados

```text
0x001F421C — ponteiro associado ao primeiro soldado
0x00030A37 — estado A
0x00030A6B — estado B
```

## Confirmação de morte

### Kill forte

```text
ponteiro era diferente de zero
e depois virou zero
e
(stateA = 2 ou stateB = 1)
```

### Kill médio

```text
stateA = 2
e
stateB = 1
```

A condição precisa permanecer verdadeira por alguns frames consecutivos.

## Fluxo

```text
IDLE
→ TRACKING
→ SHOT_READY
→ FIRED
→ WAITING_RESULT
```

Depois:

```text
KILL_CONFIRMED
→ COMPLETE
```

ou:

```text
SHOT_FAILED
→ nova tentativa, até o limite configurado
```

## Valores iniciais

```text
screen_x: 157–163
memória do auto-aim: 45 frames
alinhamento: 2 frames
delay para avaliar resultado: 4 frames
timeout: 90 frames
confirmação de kill: 3 frames
máximo de tentativas: 2
```

## Procedimento

1. Clique em `INICIAR SESSAO`.
2. Clique em `ATIVAR GATE`.
3. Conduza Bond até o primeiro soldado.
4. O script dispara uma vez quando o braço estiver alinhado.
5. Aguarda o resultado.
6. Se a morte for confirmada, entra em `COMPLETE`.
7. Se falhar, permite no máximo mais uma tentativa.

## Arquivos

```text
output/
├── first-soldier-outcome-gate-...csv
└── first-soldier-outcome-gate-...-summary.txt
```

## Observação

Os três sinais de morte ainda são candidatos experimentais. A versão registra
todos os valores para confirmar se a combinação permanece confiável em várias
execuções.
