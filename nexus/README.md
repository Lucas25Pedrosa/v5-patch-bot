# Nexus

Nexus is the combined PT-BR build for the validated iQFace 1.1 companion modules.

## Nexus 1.0.1

- Enhancer 0.3.5
- Cache 0.2.2
- Icons 1.1.0
- OLED 0.2.5

The four modules remain separated internally, while Nexus owns a single `IQFTweakSettings` sections hook for the FERRAMENTAS section.

The original iQFace launcher is blocked before its first rendered frame using the exact settings matcher (`iQFace` + `iqf_tapped`). The fallback scanner also matches `iqf_tapped` specifically, preserving `iqfDismiss` and unrelated Reels controls.

FERRAMENTAS order:

1. Alterar ícone
2. Modo OLED
3. Separadores no feed
4. Limpar cache
5. Limpar cache automaticamente

The standalone tweaks remain unchanged and available for rollback/testing.

Build workflow: `.github/workflows/nexus.yml`

Artifact: `Nexus.dylib`
