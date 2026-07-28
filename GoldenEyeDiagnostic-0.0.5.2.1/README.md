# GoldenEyeDiagnostic 0.0.5.2.1

Correção da versão 0.0.5.2.

## Erro corrigido

A versão anterior executava `analyze()` diretamente no callback do botão
`ANALISAR`. Durante a análise, o código chamava `emu.yield()`, causando:

```text
System.NullReferenceException
BizHawk.Client.EmuHawk.LuaLibraries.EmuYield()
```

Agora os callbacks apenas registram uma tarefa pendente. A captura e a análise
são executadas pelo loop principal do script, onde `emu.yield()` é seguro.

## Sobre os snapshots já feitos

Os snapshots da versão que falhou ficam apenas na memória daquele script e são
perdidos quando ele encerra. Portanto, será necessário capturar novamente:

1. BASE
2. MOVE_X
3. MOVE_Z
4. ROTATE
5. ANALISAR

## Procedimento

Use exatamente o mesmo procedimento da 0.0.5.2.
