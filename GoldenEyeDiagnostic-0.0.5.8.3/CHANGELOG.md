# CHANGELOG

## 0.0.5.8.3

- Memória temporal de aquisição do auto-aim.
- Máquina de estados IDLE, AUTO_AIM_DETECTED, CONVERGING, SHOT_READY e FIRED.
- Detecção inicial por raw_horizontal ou normalized.
- Aquisição mantida mesmo após convergência para zero.
- Janela configurável de memória.
- Tiro após frames alinhados consecutivos.
- Rearme após período inválido.
- Log contínuo e contagem por estado.
