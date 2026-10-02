# BHTwitter 7.0.1 PT-BR

Build provisória baseada no NeoFreeBird v7 enquanto não houver uma nova release oficial após a v7.0.0.

## Base fixada

- Upstream: `orionblur/NeoFreeBird`
- Branch de origem: `v7`
- Commit: `3f6119b5be0cd18cf596545df8e28756cbc244dd`
- Versão local de build: `7.0.1`
- A versão 7.0.1 é apenas a identificação desta build provisória; não representa uma release oficial do Orion.

## Alterações locais

- Tradução completa do BHTwitter/NeoFreeBird para Português (Brasil), em `pt-BR.lproj`.
- Nenhum crédito adicional.
- Nenhuma alteração funcional no código do NeoFreeBird.
- Todas as correções e recursos presentes no snapshot `3f6119b` são preservados.

## XLiquidGlass 2.0.1

A XLiquidGlass continua sendo uma dylib independente e não é incorporada ao BHTwitter.

Referência validada:
- Branch: `xlg-2.0.1-stable-x12.31-beta4-validated-20261001`
- Fonte: `x-liquid-glass-only/XLiquidGlass.m`

O workflow verifica automaticamente os pontos de integração usados pela XLiquidGlass 2.0.1 com o NeoFreeBird:
- `ModernSettingsViewController`
- `setupSections`
- `AppearanceSettingsViewController`

Essa checagem confirma compatibilidade estrutural/ABI dos pontos de integração. A confirmação final de comportamento em runtime é feita no teste da dupla de dylibs no X.

## Artefatos esperados

- `BHTwitter-7.0.1-PTBR.dylib`
- `libbhFLEX.dylib`
- `BHTwitter.bundle.zip`
- pacote `.deb` gerado pelo Theos
- `COMPATIBILITY.txt`
- `SHA256SUMS.txt`
