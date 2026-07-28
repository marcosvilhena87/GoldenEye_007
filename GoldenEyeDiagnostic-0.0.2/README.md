# GoldenEyeDiagnostic 0.0.2 — Input Replay

Reproduz no BizHawk uma demonstração gravada pelo
**GoldenEyeDiagnostic 0.0.1**.

## Demonstração incluída

O pacote já contém:

`demonstrations/session-20260727-234451-frames.csv`

A reprodução ignora os frames anteriores ao marcador `START` e termina no
frame marcado como `SOLDIER_DEAD`.

## Requisito essencial

Carregue exatamente o **mesmo savestate inicial** usado na gravação da
demonstração. O CSV registra comandos, mas não contém o estado completo do
jogo.

## Como executar

1. Extraia todo o ZIP.
2. Abra a mesma ROM americana de GoldenEye 007 no BizHawk.
3. Entre em `Dam — Agent`.
4. Carregue o mesmo savestate inicial da demonstração.
5. Abra `Tools > Lua Console`.
6. Use `Script > Open Script`.
7. Selecione `GoldenEyeDiagnostic-0.0.2.lua`.
8. Confirme que o CSV padrão foi carregado.
9. Clique em `INICIAR REPLAY`.
10. Não pressione controles durante a reprodução.
11. Observe o resultado ao final.

## Resultado esperado

A versão será validada quando o replay:

- seguir aproximadamente a mesma rota;
- chegar à região do primeiro soldado;
- mirar e disparar;
- eliminar o soldado ou reproduzir de forma suficientemente próxima para
  diagnosticar a divergência.

## Saída

A pasta `output` recebe:

`replay-AAAAMMDD-HHMMSS-log.txt`

O log informa:

- CSV usado;
- hash da ROM;
- frame inicial e final;
- quantidade de comandos aplicados;
- marcadores atingidos;
- motivo do encerramento.

## Botões

- `SELECIONAR CSV`: escolhe outra demonstração da versão 0.0.1;
- `CARREGAR`: analisa o CSV e localiza `START` e `SOLDIER_DEAD`;
- `INICIAR REPLAY`: começa a aplicação dos comandos;
- `ABORTAR`: libera os controles e encerra o teste.

## Limitações

- Não carrega savestate automaticamente.
- Não verifica pela memória se o soldado morreu.
- Não corrige divergências de rota.
- Não usa visão computacional.
- Não aprende ainda.
- O resultado pode divergir se o savestate, core, configuração do controle,
  ROM ou momento inicial forem diferentes.

## Próxima etapa

Se a reprodução for estável:

**GoldenEyeDiagnostic 0.0.3 — Replay Validation**

Se a reprodução divergir:

**GoldenEyeDiagnostic 0.0.2.1 — Synchronization Diagnostic**
