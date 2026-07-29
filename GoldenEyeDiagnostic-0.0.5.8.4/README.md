# GoldenEyeDiagnostic 0.0.5.8.4 — Single Target Shot Lock

Esta versão permite apenas um disparo por aquisição de alvo.

## Estados

```text
IDLE
TRACKING
CONVERGING
SHOT_READY
FIRED
TARGET_LOCKED
TARGET_LOST
```

## Fluxo

```text
IDLE
→ auto-aim detectado
→ TRACKING
→ CONVERGING
→ SHOT_READY
→ AUTO_SHOT
→ TARGET_LOCKED
```

Depois do tiro, o gate não rearma apenas porque o braço oscilou ou saiu
temporariamente da janela.

## Perda real do alvo

O estado `TARGET_LOCKED` só termina quando todas as condições abaixo permanecem
válidas por 50 frames consecutivos:

```text
158 <= screen_x <= 162
|raw_horizontal| <= 2
|normalized| <= 0.002
```

Então:

```text
TARGET_LOCKED
→ TARGET_LOST
→ IDLE
```

Somente depois disso uma nova aquisição poderá produzir outro tiro.

## Parâmetros iniciais

### Aquisição

```text
|raw_horizontal| >= 20
OU
|normalized| >= 0.020
```

### Memória

```text
45 frames
```

### Alinhamento para disparo

```text
157 <= screen_x <= 163
por 2 frames
```

### Perda do alvo

```text
158 <= screen_x <= 162
|raw_horizontal| <= 2
|normalized| <= 0.002
por 50 frames
```

## Procedimento

1. Clique em `INICIAR SESSAO`.
2. Clique em `ATIVAR GATE`.
3. Conduza Bond até o primeiro soldado.
4. O script deve disparar apenas uma vez.
5. Mesmo que o braço oscile, o estado deve permanecer `TARGET_LOCKED`.
6. O gate só poderá rearmar após uma perda prolongada do alvo.

## Arquivos

```text
output/
├── single-target-shot-lock-...csv
└── single-target-shot-lock-...-summary.txt
```
