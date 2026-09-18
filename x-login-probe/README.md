# XLoginProbe

Diagnóstico seguro do fluxo de login do X em sideload.

Ele registra somente:
- presença de classes internas de conta/Keychain;
- seletores e assinaturas de métodos de login;
- classes do X que implementam o fluxo de login;
- versão do app e do iOS.

Ele não lê, registra ou persiste valores de cookies, senha, tokens ou credenciais.

Saída no aparelho:
`Documents/XLoginProbe.txt`

Referência inicial: X 12.27.1.


Build trigger: branch x-login-fix-1.0.
