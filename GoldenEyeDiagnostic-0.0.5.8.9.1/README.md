# GoldenEyeDiagnostic 0.0.5.8.9.1 — Auto-Aim Camera Alignment Controller

Esta versão usa o auto-aim como referência para alinhar a câmera em malha
fechada.

Ela **não dispara**.

## Sinais

```text
0x000D596C → normalized_horizontal
0x000D5968 → normalized_vertical
```

## Referência inicial

```text
target_x = 0.000
target_y = -0.070
```

O valor vertical corresponde aproximadamente à região corporal observada nos
testes anteriores.

## Estados

```text
IDLE
ACQUIRED
ALIGNING
STABLE
LOST
```

## Controle proporcional

```text
error_x = normalized_horizontal - target_x
error_y = normalized_vertical - target_y

command_x = error_x × X gain × X sign
command_y = error_y × Y gain × Y sign
```

Os comandos são limitados por `Min cmd` e `Max cmd`.

## Procedimento seguro

1. Clique em `INICIAR SESSAO`.
2. Deixe o controlador pausado.
3. Aproxime Bond do primeiro soldado.
4. Aguarde o auto-aim deslocar o braço.
5. Clique em `ATIVAR CONTROLE`.
6. Observe se a câmera se aproxima do soldado.
7. Se a câmera se afastar, clique em `PAUSAR`.
8. Inverta `X sign` ou `Y sign` entre `-1` e `1`.
9. Reinicie e teste novamente.

## Critério inicial de estabilidade

```text
|error_x| <= 0.020
|error_y| <= 0.030
por 5 frames consecutivos
```

## Configuração inicial

```text
X gain: 280
Y gain: 220
Min cmd: 4
Max cmd: 45
X sign: -1
Y sign: 1
```

## Arquivos

```text
output/
├── auto-aim-camera-alignment-...csv
└── auto-aim-camera-alignment-...-summary.txt
```

O CSV registra erro, comando, estado, velocidade do erro e tempo de
convergência.
