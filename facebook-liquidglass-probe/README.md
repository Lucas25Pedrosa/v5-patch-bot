# Nexus Liquid Glass Probe

Probe de runtime para Facebook 579.0.0+ focado em Liquid Glass e tab bar.

## Objetivo

- Registrar `UIDesignRequiresCompatibility`, SDK/Xcode e versão do app em runtime.
- Detectar classes como `FBLiquidGlassAppJob`, `FBTabBarConfigurationBuilder`, `FBTabBarOptions` e `FBTabBarOverwriteOptions`.
- Listar métodos relacionados a Liquid Glass, floating/scrollable tab bar e configuração da tab bar.
- Instalar apenas hooks transparentes em getters booleanos sem argumentos relacionados a esses recursos. O valor original é chamado, registrado e devolvido sem alteração.
- Registrar a classe da tab bar realmente visível na hierarquia de views e controllers.
- Registrar apenas a presença/endereço de `_METAOverrideLiquidGlassSetEnabled`, `_METAResetLiquidGlassOverride` e `_fbios_liquid_glass_sessionless`; nenhuma dessas rotinas é chamada.

## Segurança

O probe não força feature flags, não altera layout, não chama setters de Liquid Glass e não modifica o retorno observado. Ele só registra informações.

## Saída

O relatório é salvo em:

`Documents/NexusLiquidGlassProbe.txt`

Para um diagnóstico limpo, prefira testar primeiro com o Facebook + `NexusLiquidGlassProbe.dylib`, sem outros tweaks que mexam em tab bar ou aparência.
