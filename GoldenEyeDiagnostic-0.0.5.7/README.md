# GoldenEyeDiagnostic 0.0.5.7 — Shot Alignment Reference

Esta versão registra o estado do braço e da câmera no instante de cada tiro e
associa o tiro a um resultado manual `KILL` ou `MISS`.

## Dados registrados

- `screen_x` do braço/arma;
- diferença para o centro 160;
- `screen_x_copy`;
- `raw_horizontal`;
- `raw_offset`;
- candidato relacionado;
- valor normalizado;
- matriz 3×3 da câmera;
- frame do tiro;
- frame do resultado;
- resultado `KILL` ou `MISS`.

## Procedimento

1. Clique em `INICIAR`.
2. No instante exato do disparo, clique em `SHOT`.
3. Depois de confirmar visualmente o resultado, clique em:
   - `KILL`, quando o soldado morreu;
   - `MISS`, quando o disparo não matou.
4. Repita várias tentativas.
5. Clique em `ENCERRAR`.

## Regra importante

`KILL` ou `MISS` sempre é associado ao `SHOT` mais recente ainda pendente.

Não registre outro `SHOT` antes de classificar o anterior.

## Arquivos gerados

```text
output/
├── shot-alignment-reference-...csv
└── shot-alignment-reference-...-summary.txt
```

## Objetivo

Descobrir empiricamente:

```text
faixa de screen_x associada a KILL
faixa de screen_x associada a MISS
```

A versão não presume que o ponto correto seja o centro da tela.
