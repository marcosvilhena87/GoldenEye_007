# GoldenEyeDiagnostic 0.0.5.8 — Automatic Shot Gate

Esta versão dispara automaticamente quando a câmera e o braço entram
simultaneamente na faixa observada nos dois tiros confirmados como `KILL`.

## Critérios iniciais

```text
157 <= screen_x <= 163
camera_max_delta <= 0.020
condição válida por 3 frames consecutivos
```

A referência da câmera é a média das matrizes dos dois tiros confirmados:

```text
KILL 1: screen_x = 157.14744567871
KILL 2: screen_x = 160.87979125977
```

## O que o script faz

- monitora `0x000D3F48`;
- compara a matriz da câmera com a referência;
- bloqueia o tiro enquanto qualquer critério estiver inválido;
- pressiona `Z` automaticamente quando o gate fica pronto;
- dispara somente uma vez por aquisição;
- rearma apenas depois que as condições ficam inválidas por alguns frames;
- grava um CSV com `AUTO_SHOT` e `REARMED`.

## O que ele ainda não faz

- não reproduz a rota;
- não move Bond;
- não corrige a câmera;
- não corrige o braço;
- não detecta automaticamente `KILL` ou `MISS`;
- não tenta um segundo tiro enquanto o mesmo alinhamento permanecer ativo.

## Uso

1. Carregue uma cópia do savestate.
2. Execute o script.
3. Clique em `INICIAR SESSAO`.
4. Clique em `ATIVAR GATE`.
5. Conduza Bond normalmente até o primeiro soldado.
6. O tiro será liberado somente quando os critérios forem satisfeitos.
7. Clique em `ENCERRAR SESSAO`.

## Arquivos

```text
output/
├── automatic-shot-gate-...csv
└── automatic-shot-gate-...-summary.txt
```

## Observação sobre o botão

O script usa o nome BizHawk:

```text
P1 Z
```

Caso sua versão do BizHawk exponha outro nome para o gatilho Z, ajuste a
constante `Z_BUTTON_NAME` no início do arquivo Lua.
