# GoldenEyeDiagnostic 0.0.5.5 — Camera Direction Calibration

Esta versão aprende as direções da câmera usando exemplos capturados no próprio
jogo. Ela não presume quais componentes significam esquerda, direita, cima ou
baixo.

## Calibração

1. Deixe Bond parado em qualquer lugar.
2. Mantenha a câmera parada e clique em `1. REFERENCE`.
3. Gire um pouco para a esquerda e clique em `2. LEFT`.
4. Volte exatamente à posição da referência.
5. Gire um pouco para a direita e clique em `3. RIGHT`.
6. Volte à referência.
7. Olhe um pouco para cima e clique em `4. UP`.
8. Volte à referência.
9. Olhe um pouco para baixo e clique em `5. DOWN`.

Para voltar exatamente à referência, o método mais confiável é recarregar o
mesmo savestate antes de cada direção.

## Validação

Depois da calibração:

1. Recarregue o savestate da referência.
2. Mova a câmera para uma direção conhecida.
3. Clique em `VALIDATE CURRENT`.

Resultados possíveis:

```text
CAMERA_ALIGNED
CAMERA_LEFT
CAMERA_RIGHT
CAMERA_UP
CAMERA_DOWN
CAMERA_UNKNOWN
CALIBRATION_INCOMPLETE
NO_REFERENCE
```

## Método

A versão calcula a diferença entre a matriz atual e a referência. Depois,
compara essa diferença com os exemplos LEFT, RIGHT, UP e DOWN usando
similaridade de cosseno.

## Arquivos

```text
output/
├── camera-direction-calibration.csv
├── camera-direction-validation-...csv
└── camera-direction-validation-...-summary.txt
```

## Configuração padrão

```text
Tolerância CAMERA_ALIGNED: 0.020
Confiança mínima: 0.55
```

Se uma direção visualmente clara retornar `CAMERA_UNKNOWN`, reduza a confiança
mínima para `0.45`. Se pequenos ruídos forem classificados como movimento,
aumente a tolerância de alinhamento para `0.030`.
