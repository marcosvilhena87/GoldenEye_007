# CHANGELOG

## 0.0.5.8.7

- Uso principal do ponteiro validado `0x001F421C`.
- Kill confirmado quando o ponteiro passa de não zero para zero.
- Confirmação configurável por frames consecutivos.
- Removida dependência dos candidatos `0x00030A37` e `0x00030A6B`.
- Novo evento `POINTER_CHANGED`.
- Baseline, valor no tiro, valor atual e valor anterior registrados no CSV.
- `RETRY_DELAY` corrigido para bloquear efetivamente nova aquisição.
- Timeout aumentado para 120 frames.
- Encerramento definitivo após `KILL_CONFIRMED`.
