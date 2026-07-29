# GoldenEyeDiagnostic 0.0.5.8.3 — Auto-Aim Tracking Memory Gate

Esta versão mantém em memória que o auto-aim esteve ativo recentemente.

## Problema corrigido

Na versão anterior, o tiro exigia que `raw_horizontal` ou `normalized`
continuassem altos no instante do disparo. Isso bloqueava muitas oportunidades
em que o auto-aim já havia terminado de alinhar o braço.

## Estados

```text
IDLE
AUTO_AIM_DETECTED
CONVERGING
SHOT_READY
FIRED
```

## Regra inicial

### Detectar auto-aim

```text
|raw_horizontal| >= 20
OU
|normalized| >= 0.020
```

### Manter aquisição em memória

```text
45 frames
```

### Liberar tiro

```text
157 <= screen_x <= 163
por 2 frames
```

## Fluxo

```text
IDLE
→ auto-aim desloca o braço
→ AUTO_AIM_DETECTED
→ memória permanece ativa
→ CONVERGING
→ braço entra na janela
→ SHOT_READY
→ AUTO_SHOT
```

## Procedimento

1. Clique em `INICIAR SESSAO`.
2. Clique em `ATIVAR GATE`.
3. Conduza Bond até o primeiro soldado.
4. O script detectará o deslocamento do braço.
5. Mesmo que os valores voltem a zero, a aquisição continuará válida por até
   45 frames.
6. Quando o braço convergir para a janela central, o script pressionará `Z`.

## Arquivos

```text
output/
├── auto-aim-tracking-memory-gate-...csv
└── auto-aim-tracking-memory-gate-...-summary.txt
```

## Observação

Os valores de 20, 0.020, 45 frames e janela 157–163 são iniciais e podem ser
ajustados com base no próximo log.
