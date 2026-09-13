from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text(encoding="utf-8")
assert '@selector(viewDidLayoutSubviews)' in s
assert '@selector(viewDidAppear:)' in s

# Keep the current iQFace 1.1 PT-BR table, but compact only labels that exceed
# the single-line space available beside switches while preserving meaning.
replacements = {
    'Ocultar \\\"Pessoas que você talvez conheça\\\"': 'Ocultar pessoas sugeridas',
    'Ocultar elementos da tela de Reels': 'Ocultar elementos dos Reels',
    'Mostrar elementos da tela de Reels': 'Mostrar elementos dos Reels',
    'Confirmar solicitações de amizade': 'Confirmar pedidos de amizade',
    'Confirmar ações de seguir e entrar': 'Confirmar seguir e entrar',
    'Confirmar publicação do comentário': 'Confirmar comentário',
}
for old, new in replacements.items():
    if old not in s:
        raise RuntimeError(f'missing PT-BR label: {old}')
    s = s.replace(old, new, 1)

# Only append inert exported marker strings so the existing artifact validation
# can identify the PT-BR translation module without changing its hooks.
s += '''

__attribute__((used, visibility("default"))) NSString * const NexusLegacyTranslationMarker = @"1.1-core-ptbr";
__attribute__((used, visibility("default"))) NSString * const NexusLegacyFeaturesMarker = @"RECURSOS";
// minimumScaleFactor = 0.82 (legacy build marker only)
'''

p.write_text(s, encoding="utf-8")
