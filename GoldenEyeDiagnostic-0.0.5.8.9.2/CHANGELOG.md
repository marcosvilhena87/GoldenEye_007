# CHANGELOG

## 0.0.5.8.9.2

- Controle proporcional-derivativo Kp + Kd.
- Histerese separada para entrada e saída de STABLE.
- Manutenção suave da câmera no estado STABLE.
- Comando mínimo zero na zona fina.
- Correção definitiva do limite analógico após arredondamento.
- Memória do último erro e último comando úteis.
- Novos estados TARGET_TEMPORARILY_LOST, SEARCHING_LAST_DIRECTION e REACQUIRED.
- Busca pela última direção conhecida com decaimento.
- Limite específico de comando durante busca.
- Reaquisição configurável por frames consecutivos.
- Métrica corrigida de tempo ALIGNING para STABLE.
- Sem disparo automático.
