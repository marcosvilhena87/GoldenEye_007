# GoldenEyeDiagnostic 0.0.5.8.8 — Vertical Auto-Aim Candidate Monitor

Esta versão procura valores verticais do braço e da arma.

## Capturas

```text
CENTER
AUTO_AIM_UP
AUTO_AIM_DOWN
TARGET_HEAD
TARGET_BODY
TARGET_LOST
```

## Procedimento

1. Use um savestate-base estável.
2. `CENTER`: sem alvo, braço em repouso e câmera parada.
3. `AUTO_AIM_UP`: capture quando o auto-aim puxar claramente o braço para cima.
4. `AUTO_AIM_DOWN`: capture quando o auto-aim puxar claramente o braço para baixo.
5. `TARGET_HEAD`: capture com o braço apontando para a cabeça.
6. `TARGET_BODY`: capture com o braço apontando para o tronco.
7. `TARGET_LOST`: capture depois de retirar o alvo, evitando alterar a câmera.
8. Clique em `ANALYZE`.

## Regiões monitoradas

```text
ARM_CORE:   0x000D3600–0x000D61FF
ARM_NEAR_X: 0x000D3C00–0x000D40FF
CAMERA_NEAR: 0x00079600–0x00079CFF
```

## Tipos comparados

```text
U8
U16 big-endian
U32 big-endian
F32 big-endian
```

## Categorias do ranking

- `VERTICAL_AXIS`: valores com movimentos opostos em `UP` e `DOWN`;
- `SCREEN_Y_LIKE`: possíveis coordenadas verticais de tela;
- `NORMALIZED_VERTICAL`: possíveis valores normalizados próximos de zero;
- `TARGET_HEAD_BODY`: valores que distinguem cabeça e tronco.

## Arquivos

```text
output/
├── vertical-auto-aim-candidates-...csv
└── vertical-auto-aim-candidates-...-summary.txt
```

## Observação

A qualidade do ranking depende de as capturas variarem principalmente no eixo
vertical. Movimentos grandes da câmera, de Bond ou do soldado podem introduzir
muitos falsos candidatos.
