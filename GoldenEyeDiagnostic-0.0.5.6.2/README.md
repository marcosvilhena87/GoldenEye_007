# GoldenEyeDiagnostic 0.0.5.6.2 — Arm Aim Live Validation

Esta versão monitora ao vivo os seis candidatos encontrados para o braço,
arma e auto-aim horizontal.

## Endereços

```text
0x000D3998
0x000D3D40
0x000D3DD0
0x000D3F48
0x000D3F5C
0x000D596C
```

O candidato principal é:

```text
0x000D3F48
```

Interpretação provisória:

```text
aproximadamente 160 = braço centralizado
menor que 160       = braço para a esquerda
maior que 160       = braço para a direita
```

## Procedimento

1. Carregue o savestate anterior ao primeiro soldado.
2. Clique em `INICIAR`.
3. Marque `CENTER` com o braço centralizado.
4. Marque `AUTO_AIM_LEFT` quando o auto-aim puxar o braço para a esquerda.
5. Marque `AUTO_AIM_RIGHT` quando puxar para a direita.
6. Marque `TARGET_LOST` quando o alvo sair do auto-aim.
7. Marque `SHOT` no disparo.
8. Clique em `ENCERRAR`.

## Arquivos

```text
output/
├── arm-aim-live-...csv
└── arm-aim-live-...-summary.txt
```

O CSV registra apenas mudanças nos candidatos e os marcadores manuais.

## Objetivo da validação

Confirmar se `0x000D3F48`:

- acompanha suavemente o deslocamento horizontal do braço;
- permanece próximo de 160 no centro;
- diminui à esquerda;
- aumenta à direita;
- retorna ao centro quando o alvo é perdido.
