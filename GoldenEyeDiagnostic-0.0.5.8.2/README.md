# GoldenEyeDiagnostic 0.0.5.8.2 — Auto-Aim Acquisition Gate

Esta versão evita disparos quando o braço está apenas centralizado em repouso.

## Regra principal

```text
ARM_READY
e
ACQUISITION_READY
```

### ARM_READY

```text
157 <= screen_x <= 163
```

### ACQUISITION_READY

```text
|raw_horizontal| >= 4
OU
|normalized| >= 0.004
```

## Modos

```text
ARM_ONLY
ACQUISITION_ONLY
ARM_AND_ACQUISITION
```

O modo recomendado é:

```text
ARM_AND_ACQUISITION
```

## Procedimento

1. Selecione `ARM_AND_ACQUISITION`.
2. Clique em `INICIAR SESSAO`.
3. Clique em `ATIVAR GATE`.
4. Conduza Bond até o primeiro soldado.
5. O script só pressionará `Z` quando:
   - o braço estiver na janela horizontal;
   - houver sinal de auto-aim ativo;
   - as condições permanecerem válidas pelo número configurado de frames.

## Diagnóstico

A interface mostra:

```text
ARM_READY
RAW_ACTIVE
NORMALIZED_ACTIVE
ACQUISITION_READY
GATE_READY
BLOCKER
```

Os bloqueadores possíveis são:

```text
ARM
ACQUISITION
ARM+ACQUISITION
NONE
```

## Arquivos

```text
output/
├── auto-aim-acquisition-gate-...csv
└── auto-aim-acquisition-gate-...-summary.txt
```

## Observação

Os limites de aquisição são iniciais. O CSV permitirá ajustar os valores com
base no comportamento real do primeiro soldado.
