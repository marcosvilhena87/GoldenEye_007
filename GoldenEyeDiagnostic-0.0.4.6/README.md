# GoldenEyeDiagnostic 0.0.4.6 — Soldier Candidate Validation

Esta versão observa em tempo real apenas os candidatos prioritários encontrados
na etapa anterior.

## Candidatos monitorados

```text
0x00030A37  u8     possível estado vivo/atingido/morto
0x00030A6B  u8     possível marcador de morte
0x0003CB7F  u8     possível marcador de acerto
0x001F421C  u32be  possível ponteiro zerado na morte
0x001E015C  u8     candidato auxiliar
```

## Procedimento

1. Carregue o mesmo savestate usado anteriormente.
2. Abra `GoldenEyeDiagnostic-0.0.4.6.lua`.
3. Clique em `1. INICIAR`.
4. Com o soldado vivo e a cena estabilizada, clique em `2. MARCAR LIVE`.
5. Acerte o soldado sem matar.
6. Espere estabilizar e clique em `3. MARCAR HIT`.
7. Mate o mesmo soldado.
8. Espere estabilizar e clique em `4. MARCAR DEAD`.
9. Clique em `5. ENCERRAR`.

## Arquivos gerados

```text
output/
├── candidate-validation-...-log.csv
└── candidate-validation-...-summary.txt
```

## Avaliação automática

A versão pontua os padrões esperados:

```text
0x00030A37 = 0 / 1 / 2
0x00030A6B = 0 / 0 / 1
0x0003CB7F = 0 / 1 / 1
0x001F421C = não-zero / não-zero / zero
```

Vereditos possíveis:

- `VALIDADO_FORTE`
- `VALIDADO_PARCIAL`
- `REPROVADO_OU_INSTAVEL`
- `INCONCLUSIVO`

## Repetição

Uma única validação ainda não prova estabilidade entre execuções. Faça pelo
menos três tentativas, sempre recarregando o mesmo savestate antes de iniciar
uma nova gravação.
