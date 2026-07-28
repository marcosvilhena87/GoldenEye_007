# GoldenEyeDiagnostic 0.0.4.5 — Stable Soldier State Filter

Esta versão reduz falsos candidatos usando seis snapshots pareados.

## Capturas

```text
LIVE_A
LIVE_B
HIT_A
HIT_B
DEAD_A
DEAD_B
```

Um byte só é considerado candidato quando permanece estável dentro de cada
estado:

```text
LIVE_A = LIVE_B
HIT_A  = HIT_B
DEAD_A = DEAD_B
```

Depois disso, o diagnóstico procura diferenças entre os estados.

## Categorias

### DEATH_ONLY

```text
LIVE = HIT
HIT != DEAD
```

É a categoria mais forte para um marcador de morte.

### PROGRESSIVE

```text
LIVE != HIT
HIT  != DEAD
```

Pode representar vida, animação ou mudança de estado progressiva.

### HIT_PERSISTENT

```text
LIVE != HIT
HIT  = DEAD
```

Pode representar um efeito que começa no acerto e permanece após a morte.

### LIVE_DEAD_DIFFERENT

Categoria auxiliar para bytes estáveis que diferem entre vivo e morto, mas não
se encaixam perfeitamente nas categorias anteriores.

## Procedimento

1. Posicione Bond diante do primeiro soldado.
2. Espere a cena estabilizar.
3. Capture `LIVE_A`.
4. Sem fazer nada, capture `LIVE_B`.
5. Acerte o soldado sem matá-lo.
6. Espere estabilizar e capture `HIT_A`.
7. Sem fazer nada, capture `HIT_B`.
8. Mate o mesmo soldado.
9. Espere o corpo estabilizar e capture `DEAD_A`.
10. Sem fazer nada, capture `DEAD_B`.
11. Clique em `ANALISAR`.

Não recarregue o savestate entre as seis capturas.

## Arquivos gerados

```text
output/
├── stable-soldier-state-...-candidates.csv
└── stable-soldier-state-...-summary.txt
```

O CSV divide o limite de exportação entre as categorias, evitando que apenas
`DEATH_ONLY` ocupe todas as linhas.

## Próximo passo

Os melhores candidatos deverão ser validados em novas tentativas, observando
se permanecem coerentes quando o primeiro soldado é morto novamente.
