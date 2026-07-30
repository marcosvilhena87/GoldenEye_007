# GoldenEyeDiagnostic 0.0.5.8.8.1 — First Soldier Vertical Candidate Monitor

Versão adaptada às limitações reais do primeiro soldado.

Ela não exige `AUTO_AIM_UP`.

## Capturas

```text
CENTER
AUTO_AIM_DOWN
TARGET_HEAD
TARGET_UPPER_BODY
TARGET_LOWER_BODY
TARGET_LOST
```

## Procedimento

1. Use um savestate-base estável.
2. `CENTER`: sem alvo, braço em repouso e câmera parada.
3. `AUTO_AIM_DOWN`: capture quando o auto-aim puxar o braço para baixo.
4. `TARGET_HEAD`: capture com a mira na cabeça.
5. `TARGET_UPPER_BODY`: capture no peito ou ombros.
6. `TARGET_LOWER_BODY`: capture na parte inferior do tronco ou pernas.
7. `TARGET_LOST`: retire o alvo sem girar desnecessariamente a câmera.
8. Clique em `ANALYZE`.

## O ranking procura

- progressão monotônica entre cabeça, parte superior e parte inferior;
- deslocamento claro em `AUTO_AIM_DOWN`;
- retorno próximo ao centro em `TARGET_LOST`;
- possíveis coordenadas verticais de tela;
- possíveis valores verticais normalizados.

A progressão pode ser crescente ou decrescente:

```text
HEAD < UPPER_BODY < LOWER_BODY
```

ou:

```text
HEAD > UPPER_BODY > LOWER_BODY
```

## Regiões monitoradas

```text
ARM_CORE:    0x000D3600–0x000D61FF
ARM_NEAR_X:  0x000D3C00–0x000D40FF
CAMERA_NEAR: 0x00079600–0x00079CFF
```

## Arquivos

```text
output/
├── first-soldier-vertical-candidates-...csv
└── first-soldier-vertical-candidates-...-summary.txt
```
