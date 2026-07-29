# GoldenEyeDiagnostic 0.0.5.6.1 — Horizontal Arm Aim Candidate Discovery

Versão adaptada para o primeiro soldado, onde não é possível produzir
`TARGET_UP` e `TARGET_DOWN`.

## Capturas

```text
NO_TARGET
TARGET_LEFT
TARGET_RIGHT
MANUAL_AIM
```

## Procedimento

Use o mesmo savestate-base antes de cada captura.

Bond deve permanecer parado e a câmera deve ficar o mais parecida possível.

### NO_TARGET

Capture uma situação em que o soldado não esteja atraindo o auto-aim.

### TARGET_LEFT

Capture quando o soldado estiver puxando o braço/arma para a esquerda da tela.

### TARGET_RIGHT

Capture quando estiver puxando para a direita.

### MANUAL_AIM

Segure `R` e desloque a mira manualmente na horizontal.

### ANALYZE

Clique em `ANALYZE` após completar as quatro capturas.

## Arquivos gerados

```text
output/
├── arm-horizontal-candidates-...csv
└── arm-horizontal-candidates-...-summary.txt
```

## Classificações

- `ARM_HORIZONTAL_CANDIDATE`
- `ARM_LEFT_CANDIDATE`
- `ARM_RIGHT_CANDIDATE`
- `MANUAL_AIM_CANDIDATE`
- `MIXED`

O melhor candidato horizontal tende a mudar com sinais opostos entre
`TARGET_LEFT` e `TARGET_RIGHT`.

## Limitação

O scan continua restrito a `float32` big-endian alinhado a cada 4 bytes nos
8 MiB da RDRAM.
