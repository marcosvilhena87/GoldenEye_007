# GoldenEyeDiagnostic 0.0.5.8.9.2 — Damped Camera Alignment with Target Memory

Esta versão melhora o alinhamento da câmera com três mecanismos:

1. amortecimento proporcional-derivativo;
2. histerese entre `ALIGNING` e `STABLE`;
3. memória temporária da última direção conhecida.

Ela não dispara.

## Estados

```text
IDLE
ACQUIRED
ALIGNING
STABLE
TARGET_TEMPORARILY_LOST
SEARCHING_LAST_DIRECTION
REACQUIRED
LOST
```

## Controle amortecido

```text
command = Kp × error + Kd × velocidade_do_erro
```

Configuração inicial:

```text
X Kp = 280
Y Kp = 220
X Kd = 90
Y Kd = 70
```

## Histerese

Para entrar em `STABLE`:

```text
|error_x| <= 0.020
|error_y| <= 0.030
por 5 frames
```

Para sair de `STABLE`:

```text
|error_x| > 0.035
ou
|error_y| > 0.045
```

Isso evita alternância excessiva entre `ALIGNING` e `STABLE`.

## Memória do alvo

Quando o auto-aim fica quieto por alguns frames:

```text
TARGET_TEMPORARILY_LOST
→ SEARCHING_LAST_DIRECTION
```

Durante a busca, o controlador usa o último erro útil:

```text
command_x = Kp_x × remembered_error_x × decay
command_y = Kp_y × remembered_error_y × decay
```

O comando decai durante 30 frames e é limitado a 20.

Se o auto-aim reaparecer:

```text
REACQUIRED
→ ALIGNING
```

Se a memória expirar:

```text
LOST
→ IDLE
```

## Procedimento seguro

1. Clique em `INICIAR SESSAO`.
2. Deixe o controlador pausado.
3. Aproxime Bond do primeiro soldado.
4. Aguarde o braço indicar a direção do alvo.
5. Clique em `ATIVAR CONTROLE`.
6. Observe o alinhamento.
7. Permita que o soldado saia parcialmente da tela para testar a memória.
8. Confirme se a câmera continua na última direção e consegue reacquirir.
9. Pause imediatamente se a direção estiver errada.
10. Clique em `ENCERRAR`.

## Correções da versão anterior

- limite analógico aplicado depois do arredondamento;
- comandos nunca ultrapassam `-Max cmd…+Max cmd`;
- tempo medido em cada ciclo `ALIGNING → STABLE`;
- manutenção suave em `STABLE`;
- comando mínimo zero na zona fina;
- busca temporária com decaimento.
