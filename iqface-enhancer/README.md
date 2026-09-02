# iQFace Enhancer

Complemento independente para o iQFace no Facebook. A versão 0.1.0 oferece:

- tradução automática para português brasileiro quando o idioma principal do iOS começa com `pt`;
- ocultação seletiva do botão superior criado pelo iQFace, identificado simultaneamente pelo rótulo `iQFace` e pela ação `iqf_tapped`;
- abertura do painel nativo do iQFace mantendo pressionado o ícone **Início**, no canto inferior esquerdo, por 0,65 segundo;
- preservação do comportamento normal do toque na tab bar;
- fallback para os textos originais quando uma chave nova ainda não tiver tradução.

## Compatibilidade inicial

- Facebook 577.0.0;
- iQFace 1.0, build `20260829.213621`;
- iOS 14 ou posterior;
- arquitetura arm64.

O projeto não modifica `iQFace.dylib`. Ele chama os símbolos públicos encontrados no binário:

- `IQFLoc`;
- `IQFPresentSettings`;
- `IQFSettingsVisible`.

Para localizar a tab bar, a versão inicial reconhece estas classes do Facebook 577:

- `FBTabBarItemDefaultView`;
- `FBTabBar`;
- `FBNativeTabBar`;
- `FBFloatingTabBar`.

## Build local com Theos

```bash
export THEOS=/caminho/para/theos
make clean all FINALPACKAGE=1
find .theos -name iQFaceEnhancer.dylib -print
```

O projeto usa somente frameworks públicos do iOS. A ligação com `MSHookFunction` é resolvida dinamicamente em tempo de execução pela implementação de Substrate/ElleKit já carregada pelo iQFace.

## Ordem no Injector

O executável principal do Facebook deve receber as dylibs nesta ordem:

1. `iQFace.dylib`;
2. `iQFaceEnhancer.dylib`;
3. `zxPluginsInject.dylib` modificado, na etapa do IPA Patch.

`iQFaceEnhancer.dylib` não deve ser injetada nas extensões. Apenas o `zxPluginsInject.dylib` modificado deve ser aplicado ao main e às extensões.

## Forçar ou desativar a tradução

Por padrão, o complemento segue o idioma do iOS. Para testes, a preferência booleana `IQFEnhancerForcePortuguese` pode forçar (`true`) ou desativar (`false`) a tradução.

## Observações de segurança

- A remoção exige simultaneamente um `UIButton`, o rótulo de acessibilidade `iQFace` e a ação `iqf_tapped`; os controles originais do Facebook não são removidos.
- O gesto não cancela o toque normal da tab bar e aceita reconhecimento simultâneo.
- `IQFSettingsVisible` impede que o painel seja apresentado duas vezes.
- O complemento retorna os textos originais do iQFace para chaves desconhecidas.
