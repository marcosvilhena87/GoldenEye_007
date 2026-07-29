# GoldenEyeDiagnostic 0.0.5.4 — Camera Matrix Validation

Monitora a matriz 3×3 em:

```text
0x00079950  0x00079954  0x00079958
0x00079960  0x00079964  0x00079968
0x00079970  0x00079974  0x00079978
```

## Uso

1. Pare imediatamente antes do primeiro tiro, com a mira correta.
2. Clique em `CAPTURAR REFERENCIA`.
3. Recarregue o mesmo savestate.
4. Reproduza novamente até o mesmo instante.
5. Clique em `VALIDAR ATUAL`.

## Resultados

- `CAMERA_ALIGNED`
- `CAMERA_LEFT`
- `CAMERA_RIGHT`
- `CAMERA_UP`
- `CAMERA_DOWN`
- `CAMERA_DIFFERENT`

## Tolerâncias padrão

```text
Componente: 0.020
Direcional: 0.010
```

A referência fica em `output/camera-matrix-reference.csv`.
Cada validação gera um CSV e um resumo.
