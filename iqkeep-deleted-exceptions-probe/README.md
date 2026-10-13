# iQKeepDeleted Exceptions Probe

Probe passiva para estudar o ledger `ext-revoked.plist` produzido pelo `iqKeepDeleted.dylib` do iQTele 1.4.

## Objetivo

- não altera exclusões;
- não desativa nem modifica o `iqKeepDeleted`;
- observa `group.ph.telegra.Telegraph/iQTele/ext-revoked.plist`;
- registra cada mudança em `Documents/iQKeepDeletedExceptionsProbe.log`;
- permite identificar o formato real dos registros e os IDs usados pelo iQTele antes de implementar a lista de exceções.

## Build

```sh
make clean all FINALPACKAGE=1 THEOS=/caminho/para/theos
```

A saída esperada é `iQKeepDeletedExceptionsProbe.dylib` em `.theos/`.

## Teste

1. Injetar a dylib junto com `iQTele.dylib` e `iqKeepDeleted.dylib`.
2. Manter `Keep Deleted` habilitado.
3. Apagar uma mensagem em um chat de teste.
4. Abrir `Documents/iQKeepDeletedExceptionsProbe.log`.
5. Enviar o log para análise.

Esta build é somente diagnóstica e não implementa whitelist/exceções ainda.
