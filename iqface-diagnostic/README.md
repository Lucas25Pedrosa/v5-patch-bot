# iQFace Diagnostic

Dylib de diagnóstico, sem hooks e sem alterações na interface do Facebook.

Ela registra:

- chegada ao construtor da dylib;
- bundle, versão do app, versão do iOS e caminho do container;
- presença de `iQFace.dylib`, `CydiaSubstrate.framework`, `zxPluginsInject.dylib` e do enhancer;
- presença em memória de iQFace, ElleKit/Substrate e zxPluginsInject;
- resolução dos símbolos `IQFLoc`, `IQFPresentSettings`, `IQFSettingsVisible` e `MSHookFunction`;
- chegada à fila principal, ativação do aplicativo e sinais fatais comuns.

O arquivo é salvo em:

`Documents/iQFaceDiagnostic/iQFaceDiagnostic.log`

Ao conseguir abrir o Facebook, a dylib mostra um painel para copiar ou compartilhar o log. Para também navegar até o arquivo diretamente pelo app Arquivos, habilite **Suporte ao app Arquivos** nas opções de assinatura do Feather.

## Teste correto

Use o Facebook que já contém o iQFace e injete somente:

`@rpath/iQFaceDiagnostic.dylib`

Destino:

`Payload/Facebook.app/Frameworks/iQFaceDiagnostic.dylib`

Remova `iQFaceEnhancer.dylib` antes do teste. Não injete a dylib de diagnóstico nas extensões.
