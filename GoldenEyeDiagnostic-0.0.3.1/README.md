# GoldenEyeDiagnostic 0.0.3.1 — Combat Isolation

Esta versão preserva a rota da demonstração e substitui o combate original por
uma sequência controlada de testes.

## Objetivo

Descobrir uma combinação simples que elimine o primeiro soldado de forma mais
confiável:

- atraso antes do tiro;
- pequeno ajuste lateral;
- múltiplos tiros;
- duração de cada pressionamento de `Z`;
- intervalo entre disparos.

## Configuração inicial recomendada

Use primeiro:

- Corte da rota: `820`
- Espera: `0`
- Direção: `NONE`
- Frames de ajuste: `0`
- Quantidade de tiros: `2`
- Frames com Z: `5`
- Intervalo entre tiros: `5`

O índice 820 foi escolhido porque ocorre pouco antes do tiro observado na
validação anterior.

## Como usar

1. Extraia todo o ZIP.
2. Abra a mesma ROM e o mesmo savestate da demonstração.
3. Abra `GoldenEyeDiagnostic-0.0.3.1.lua` na Lua Console.
4. Clique em `INICIAR TESTE`.
5. Não pressione controles durante a execução.
6. Ao final, classifique:
   - `MATOU`;
   - `ACERTOU, NÃO MATOU`;
   - `ERROU O TIRO`;
   - `NÃO CHEGOU`.
7. Envie os arquivos gerados na pasta `output`.

## Sequência sugerida de testes

Teste 1:
- `NONE`, 0 ajuste, 2 tiros, Z=5, intervalo=5.

Teste 2:
- `NONE`, 0 ajuste, 3 tiros, Z=5, intervalo=5.

Teste 3:
- `LEFT`, 2 frames de ajuste, 2 tiros.

Teste 4:
- `RIGHT`, 2 frames de ajuste, 2 tiros.

Teste 5:
- espera de 5 frames, sem ajuste, 2 tiros.

Faça um teste por vez, sempre recarregando o mesmo savestate antes de iniciar.

## Limitações

- A validação continua visual.
- O script ainda não sabe automaticamente se o soldado morreu.
- O ponto de corte pode precisar ser refinado.
- Pequenas diferenças de posição podem exigir ajustes específicos.

## Próximo passo

Quando uma configuração matar o soldado de modo repetível:

`GoldenEyeDiagnostic 0.0.4 — Soldier State Memory Diagnostic`
