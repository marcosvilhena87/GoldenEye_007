# GoldenEyeDiagnostic 0.0.5.8.8.2 — Vertical Candidate Live Validator

Esta versão valida ao vivo os candidatos verticais encontrados.

## Endereços monitorados

```text
0x000D3F4C → screen_y
0x000D3F60 → screen_y copy
0x000D3F50 → raw_vertical
0x000D3F64 → raw_vertical copy
0x000D5968 → normalized_vertical
0x000D596C → normalized_horizontal
```

## Marcadores

```text
HEAD
UPPER_BODY
LOWER_BODY
SHOT
HIT
MISS
TARGET_LOST
```

## Procedimento

1. Clique em `INICIAR SESSAO`.
2. Clique em `GRAVAR CONTINUO`.
3. Marque `HEAD`, `UPPER_BODY` e `LOWER_BODY` quando o braço acompanhar cada região.
4. Marque `SHOT` exatamente no disparo.
5. Depois marque `HIT` ou `MISS` conforme o resultado visual.
6. Repita várias vezes.
7. Marque `TARGET_LOST` quando o alvo desaparecer ou o braço retornar ao repouso.
8. Clique em `ENCERRAR`.

## Janela rolante

O script mantém estatísticas dos últimos 15 frames, configurável na interface:

```text
screen_y min/max/mean
normalized_vertical min/max/mean
raw_vertical min/max/mean
```

Isso ajuda a capturar o valor recente mesmo quando o braço já começou a retornar
ao centro no instante do clique.

## Arquivos

```text
output/
├── vertical-candidate-live-validator-...csv
└── vertical-candidate-live-validator-...-summary.txt
```

## Objetivo

Determinar faixas reais de `normalized_vertical` e `screen_y` associadas a:

- cabeça;
- tronco superior;
- tronco inferior;
- tiros que acertam;
- tiros que erram.
