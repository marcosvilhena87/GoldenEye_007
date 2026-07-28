# GoldenEyeDiagnostic 0.0.1

Primeiro diagnóstico do projeto de aprendizado por demonstração para
**GoldenEye 007 (Nintendo 64)** usando o **BizHawk**.

## Objetivo

Gravar, quadro a quadro, os comandos executados pelo jogador entre um ponto
inicial fixo e a eliminação do primeiro soldado em *Dam — Agent*.

Esta versão:

- grava os controles físicos do jogador 1;
- registra frame, lag, contador de lag e marcadores;
- cria um CSV por sessão;
- cria um resumo ao encerrar;
- não lê e não escreve na memória do jogo;
- não reproduz comandos ainda.

## Requisitos

- BizHawk com suporte ao Nintendo 64;
- ROM própria de GoldenEye 007 carregada;
- Lua Console do EmuHawk.

A API Lua atual do BizHawk pode ser consultada dentro do próprio EmuHawk em:

`Tools > Lua Console > Help > Lua Functions List`

## Como usar

1. Extraia o ZIP para uma pasta normal.
2. Abra o BizHawk e carregue GoldenEye 007.
3. Entre em `Dam`, dificuldade `Agent`.
4. Crie ou carregue um savestate inicial fixo.
5. Abra `Tools > Lua Console`.
6. Clique em `Script > Open Script`.
7. Selecione `GoldenEyeDiagnostic-0.0.1.lua`.
8. Jogue normalmente até eliminar o primeiro soldado.
9. Use os botões da janela para marcar eventos.
10. Clique em `FIM`.

Os resultados serão criados na pasta `output`.

## Marcadores

- `START`: início escolhido da demonstração;
- `SOLDIER_VISIBLE`: primeiro soldado visível;
- `SHOT`: disparo relevante;
- `SOLDIER_DEAD`: soldado eliminado;
- `ROUTE_ERROR`: execução saiu da rota pretendida;
- `STOP_BUTTON`: encerramento normal pelo botão FIM.

## Arquivo CSV

Colunas:

- `frame`: frame absoluto do emulador;
- `relative_frame`: distância desde o início do script;
- `is_lagged`: 1 quando o frame é de lag;
- `lag_count`: contador acumulado de lag;
- `event`: marcador manual;
- `input_state`: todos os controles retornados pelo core, em formato
  `nome=valor;nome=valor`.

O uso de `input_state` genérico evita depender dos nomes exatos dos eixos e
botões, que podem variar conforme o core e a configuração do BizHawk.

## Teste mínimo recomendado

Faça três sessões a partir do mesmo savestate:

1. execução normal;
2. execução deliberadamente mais lenta;
3. execução tentando economizar munição.

Isso começará a formar um conjunto de demonstrações comparáveis.

## Próxima versão

**GoldenEyeDiagnostic 0.0.2 — Input Replay**

Ela deverá:

- carregar um CSV da versão 0.0.1;
- aplicar os controles gravados quadro a quadro;
- medir se a reprodução chega ao mesmo ponto;
- detectar divergências de sincronização.
