# GoldenEyeDiagnostic 0.0.5.3 — Candidate Live Monitor

Esta versão monitora em tempo real apenas os candidatos prioritários encontrados
nas duas varreduras anteriores.

## Regiões observadas

```text
0x0006D188

0x0007994C–0x00079980
0x000F8AD0–0x000F8AD8
0x001052D0–0x001052D8

0x001F25C8–0x001F2618
```

Todos são lidos como `float32` big-endian por `mainmemory`.

## Procedimento

1. Clique em `INICIAR`.
2. Mantenha Bond parado e marque `STOPPED`.
3. Gire para a esquerda e marque `ROTATE_LEFT`.
4. Gire para a direita e marque `ROTATE_RIGHT`.
5. Ande para frente e marque `FORWARD`.
6. Ande para trás e marque `BACKWARD`.
7. Faça strafe para esquerda e marque `STRAFE_LEFT`.
8. Faça strafe para direita e marque `STRAFE_RIGHT`.
9. Volte aproximadamente ao ponto inicial e marque `RETURN_BASE`.
10. Clique em `ENCERRAR`.

## Arquivos gerados

```text
output/
├── candidate-live-monitor-...-log.csv
└── candidate-live-monitor-...-summary.txt
```

## O que procurar

Um candidato de posição real tende a:

- mudar continuamente durante o deslocamento;
- parar de mudar quando Bond para;
- inverter o sentido ao mover na direção oposta;
- retornar aproximadamente ao valor inicial;
- permanecer estável quando apenas a câmera gira.

Um candidato de rotação tende a:

- mudar ao girar;
- inverter o sentido entre esquerda e direita;
- permanecer estável ao andar em linha reta.
