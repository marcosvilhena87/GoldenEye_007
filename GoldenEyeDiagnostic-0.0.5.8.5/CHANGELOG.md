# CHANGELOG

## 0.0.5.8.5

- Removida a inferência de perda do alvo pelo braço centralizado.
- Novo monitor de resultado do primeiro soldado.
- Estados WAITING_RESULT, KILL_CONFIRMED, SHOT_FAILED e COMPLETE.
- Uso combinado de ponteiro e estados candidatos de morte.
- Confirmação de kill por frames consecutivos.
- Timeout de resultado configurável.
- Número máximo de tentativas configurável.
- Encerramento definitivo após KILL_CONFIRMED.
- Log completo de mira e estado do soldado.
