# GoldenEyeDiagnostic 0.0.5.8.6 — Shot Outcome Candidate Monitor

Esta versão volta à descoberta de memória para localizar um sinal confiável de
acerto e morte do primeiro soldado.

## Capturas

```text
BEFORE_SHOT
HIT
VISUAL_DEATH
MISS
```

## Procedimento

1. Use um savestate imediatamente antes do tiro.
2. Clique em `BEFORE_SHOT`.
3. Faça um disparo que acerte.
4. Clique em `HIT` no primeiro momento em que o soldado reage, mas ainda está vivo.
5. Clique em `VISUAL_DEATH` quando a morte estiver visualmente clara.
6. Recarregue o mesmo savestate.
7. Faça um disparo que erre.
8. Clique em `MISS` depois de confirmar que o soldado não foi atingido.
9. Clique em `ANALYZE`.

## Regiões monitoradas

```text
0x00030800–0x00030CFF
0x0003C900–0x0003CDFF
0x001DF000–0x001E1FFF
0x001F3000–0x001F4FFF
```

## Tipos comparados

```text
U8
U16 big-endian
U32 big-endian
F32 big-endian
```

## Padrões ranqueados

- `DEATH_SPECIFIC`: muda principalmente em `VISUAL_DEATH`;
- `HIT_PERSISTENT`: muda no `HIT` e permanece na morte;
- `ZERO_ON_DEATH`: era diferente de zero e vira zero na morte;
- `SMALL_STATE`: estado inteiro pequeno que distingue vivo e morto.

## Arquivos

```text
output/
├── shot-outcome-candidates-...csv
└── shot-outcome-candidates-...-summary.txt
```

## Observação

A qualidade da análise depende de as quatro capturas representarem realmente
o mesmo cenário-base. Evite mover Bond ou a câmera entre `BEFORE_SHOT`, `HIT`
e `VISUAL_DEATH`. Para `MISS`, recarregue exatamente o mesmo savestate.
