# GoldenEyeDiagnostic 0.0.5.1 — Replay Alignment Validation

Esta versão diferencia um erro de tiro de um desvio de rota.

## Conceito

Primeiro, capture uma execução de referência. Depois, recarregue o mesmo
savestate e valide uma nova tentativa.

Os checkpoints são:

```text
START
SOLDIER_VISIBLE
BEFORE_SHOT_1
AFTER_SHOT_1
BEFORE_SHOT_2
AFTER_SHOT_2
END
```

Em cada checkpoint, o script compara:

```text
state
death
hitSignal
pointer
aux
```

## Procedimento

### Capturar referência

1. Recarregue o savestate.
2. Abra o script.
3. Clique em `CAPTURAR REFERENCIA`.
4. Não toque no controle.
5. Aguarde terminar.

A referência será salva em:

```text
output/replay-alignment-reference.csv
```

### Validar tentativa

1. Recarregue exatamente o mesmo savestate.
2. Clique em `VALIDAR TENTATIVA`.
3. Não toque no controle.

## Resultados

- `KILL`: matou o soldado;
- `MISS`: terminou sem matar e sem desvio detectado;
- `ROUTE_DESYNC`: algum checkpoint divergiu da referência;
- `TIMEOUT`: execução interrompida ou limite excedido.

## Limitação importante

Os endereços monitorados ainda não incluem posição e orientação de Bond ou do
soldado. Portanto, este diagnóstico detecta divergências nos candidatos já
conhecidos, mas pode não perceber pequenos desvios espaciais.

O próximo passo, se necessário, será localizar coordenadas e ângulos.
