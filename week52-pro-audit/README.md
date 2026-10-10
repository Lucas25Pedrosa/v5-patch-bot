# Week52ProAudit 0.1

PoC de auditoria autorizada para **52 Week Challenge 5.1.1 (build 1)**.

## Escopo analisado

- Bundle ID: `com.raffaelps.52semanas`
- App: `Economy.app`
- Executável principal: `Economy`
- Arquitetura: arm64
- RevenueCat entitlement usado pelo app: `pro`
- Estado interno: `EntitlementState = unknown / free / pro`
- Predicate central de acesso Pro: `Economy + 0x23E3AC`
- Assinatura original esperada: `ff0301d1f65701a9f44f02a9fd7b03a9`

## Descoberta

A função em `+0x23E3AC` lê o estado publicado de `Subscriptions._entitlementState`, compara o byte com `2` (caso `pro`) e devolve um `Bool`. Foram encontrados pelo menos sete call sites diretos no executável.

A PoC intercepta exclusivamente essa função e devolve `true`. Isso permite testar se os recursos Pro dependem apenas dessa decisão local.

Ela **não** falsifica recibo da App Store, não altera servidor da RevenueCat e não conclui transação StoreKit.

## Proteção contra versão errada

Antes do hook, a dylib verifica:

1. que o executável principal termina em `/Economy.app/Economy`;
2. que os 16 bytes originais no alvo correspondem exatamente à build analisada.

Se qualquer verificação falhar, a dylib não altera nada.

## Interpretação do teste

- Se interface e recursos Pro forem liberados, fica demonstrado que esses recursos aceitam uma decisão de autorização manipulável no cliente.
- Se apenas a interface mudar, mas operações protegidas no servidor continuarem negadas, a proteção server-side está funcionando e a falha fica limitada ao cliente/UI.
- Se nada mudar, validar primeiro carregamento da dylib e disponibilidade do backend de hook.

## Backend de hook

A dylib procura `MSHookFunction` dinamicamente, aproveitando o CydiaSubstrate presente no fluxo `zx-compat` do Injector. Há fallback opcional para `DobbyHook`. Nenhuma dependência rígida de Substrate/Dobby é adicionada ao Mach-O da PoC.
