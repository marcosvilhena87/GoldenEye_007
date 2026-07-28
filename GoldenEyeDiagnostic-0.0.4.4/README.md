# GoldenEyeDiagnostic 0.0.4.4 — MainMemory Snapshot Diagnostic

Esta versão abandona completamente o domínio `System Bus` e usa a API
`mainmemory` do BizHawk.

## Objetivo

Confirmar que a memória principal está ativa e, depois, comparar três estados
do primeiro soldado:

- `BASELINE`: vivo;
- `HIT`: atingido, mas ainda vivo;
- `DEAD`: morto.

## Primeiro teste obrigatório

Antes dos snapshots:

1. deixe o jogo rodando;
2. clique em `0. TESTAR ATIVIDADE`;
3. aguarde duas amostras;
4. confira o console.

Resultado esperado:

```text
Teste de atividade | bytes=262144 | alterados=valor_maior_que_zero
```

Se o valor for zero, não faça os snapshots.

## Procedimento completo

1. Carregue o mesmo savestate usado nos testes anteriores.
2. Abra `GoldenEyeDiagnostic-0.0.4.4.lua`.
3. Clique em `TESTAR ATIVIDADE`.
4. Confirme atividade maior que zero.
5. Posicione Bond diante do primeiro soldado.
6. Capture `BASELINE`.
7. Acerte o soldado sem matá-lo.
8. Espere a animação estabilizar e capture `HIT`.
9. Mate o mesmo soldado.
10. Espere o corpo estabilizar e capture `DEAD`.
11. Clique em `ANALISAR`.

Não recarregue o savestate entre os três snapshots.

## Arquivos gerados

Na pasta `output`:

- `soldier-state-...-candidates.csv`
- `soldier-state-...-summary.txt`

## Categorias

- `DEATH_ONLY`: mudou apenas depois da morte;
- `PROGRESSIVE`: mudou em ambas as transições;
- `HIT_ONLY`: mudou no acerto e permaneceu igual depois.

## Limitações

Uma única sessão ainda produz falsos positivos. Os melhores candidatos deverão
ser observados em novas execuções na próxima versão.
