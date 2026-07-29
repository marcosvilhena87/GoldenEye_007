# GoldenEyeDiagnostic 0.0.5.8.1 — Automatic Shot Gate Diagnostic

Esta revisão corrige a falta de diagnóstico da versão 0.0.5.8.

## Modos

```text
ARM_ONLY
CAMERA_ONLY
ARM_AND_CAMERA
```

## Teste recomendado

### Primeiro: ARM_ONLY

1. Clique em `ARM_ONLY`.
2. Clique em `INICIAR SESSAO`.
3. Clique em `ATIVAR GATE`.
4. Conduza Bond até o primeiro soldado.

Nesse modo, a câmera é completamente ignorada.

### Depois: CAMERA_ONLY

1. Pare no ponto correto.
2. Clique em `CAPTURAR CAMERA`.
3. Selecione `CAMERA_ONLY`.
4. Ative o gate.

### Por fim: ARM_AND_CAMERA

Use os dois critérios ao mesmo tempo.

## Diagnóstico

A interface mostra:

```text
ARM_READY
CAMERA_READY
GATE_READY
BLOCKER
```

O bloqueador pode ser:

```text
ARM
CAMERA
ARM+CAMERA
NONE
```

## Log contínuo

O CSV registra amostras periódicas mesmo quando não há tiro.

Também registra:

- mínimo e máximo de `screen_x`;
- mínimo e máximo de `camera_max_delta`;
- número de frames com braço pronto;
- número de frames com câmera pronta;
- número de frames com gate pronto;
- contagem por bloqueador.

## Arquivos

```text
output/
├── camera-reference.csv
├── automatic-shot-gate-diagnostic-...csv
└── automatic-shot-gate-diagnostic-...-summary.txt
```
