# GoldenEyeDiagnostic 0.0.3 — Replay Validation

Esta versão reproduz a demonstração de referência e transforma a observação
visual em um relatório estruturado.

## O que ela valida

- se Bond chega à região do primeiro soldado;
- em qual frame o soldado fica visível;
- em qual frame o tiro observado acontece;
- em qual frame o soldado morre;
- se a mira está correta;
- se ocorre divergência de rota;
- diferença entre o checkpoint esperado e o confirmado.

## Procedimento

1. Extraia o ZIP inteiro.
2. Abra a ROM americana de GoldenEye 007 no BizHawk.
3. Carregue exatamente o mesmo savestate usado na demonstração.
4. Abra `Tools > Lua Console`.
5. Carregue `GoldenEyeDiagnostic-0.0.3.lua`.
6. Clique em `INICIAR REPLAY`.
7. Não use o controle durante o replay.
8. Quando cada fato ocorrer visualmente, clique:
   - `SOLDADO VISIVEL AGORA`;
   - `TIRO AGORA`;
   - `SOLDADO MORREU AGORA`.
9. Ao final, marque:
   - se chegou;
   - se a mira ficou correta;
   - se o soldado permaneceu vivo.
10. Escreva observações curtas e clique em `SALVAR VALIDACAO`.

## Saídas

A pasta `output` receberá:

- `replay-...-log.txt`: aplicação quadro a quadro;
- `validation-...-summary.txt`: resultado e veredito.

## Vereditos possíveis

- `APROVADO_SOLDIER_DEAD`
- `PARCIAL_ROUTE_OK_COMBAT_FAILED`
- `PARCIAL_AIM_DIVERGENCE`
- `REPROVADO_DID_NOT_ARRIVE`
- `REPROVADO_ROUTE_DIVERGENCE`
- `INCONCLUSIVO`

## Importante

A validação ainda é manual. O script não lê a memória do GoldenEye e não
confunde o marcador esperado do CSV com uma morte realmente observada.

Essa separação é intencional: primeiro validamos a reprodução; depois buscamos
um endereço de memória confiável para validar automaticamente a morte.

## Próximo passo

- Se aprovado: `0.0.4 — Soldier State Memory Diagnostic`.
- Se a rota funcionar, mas o combate falhar: `0.0.3.1 — Combat Isolation`.
- Se a rota divergir: `0.0.3.1 — Replay Synchronization Diagnostic`.
