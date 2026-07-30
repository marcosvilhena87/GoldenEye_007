# GoldenEyeDiagnostic 0.0.5.8.9 — Two-Axis Shot Reference Collector

Esta versão coleta referências completas dos dois eixos no instante do tiro.

## Valores registrados

```text
screen_x
screen_y
screen_x_copy
screen_y_copy
raw_horizontal
raw_vertical
raw_vertical_copy
normalized_horizontal
normalized_vertical
```

## Detecção do tiro

O script detecta automaticamente a transição:

```text
P1 Z: false → true
```

Assim, o registro `SHOT` é criado no frame exato da pressão de Z.

Também existe o botão `MARCAR SHOT` como alternativa manual.

## Classificações

Depois de cada tiro, classifique o resultado visual:

```text
HIT
MISS
KILL
```

A classificação é vinculada ao tiro pendente mais recente.

## Procedimento

1. Clique em `INICIAR SESSAO`.
2. Clique em `GRAVAR`.
3. Faça um tiro normalmente.
4. Clique em `HIT`, `MISS` ou `KILL`.
5. Repita pelo menos cinco acertos e cinco erros.
6. Clique em `ENCERRAR`.

## Contexto temporal

Para cada tiro, o CSV inclui:

```text
12 frames anteriores
frame SHOT
20 frames posteriores
```

Os valores são configuráveis na interface.

## Arquivos

```text
output/
├── two-axis-shot-reference-...csv
└── two-axis-shot-reference-...-summary.txt
```

## Objetivo

Determinar a janela conjunta de acerto:

```text
horizontal + vertical + estabilidade do braço
```

O resumo calcula mínimo, máximo e média de cada variável para `HIT`, `MISS` e
`KILL`.
