from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text(encoding="utf-8")

pairs = [
    ("Confirmar solicitações de amizade", "Confirmar pedidos de amizade"),
    ("Confirmar ações de seguir e entrar", "Confirmar seguir e entrar"),
    ("Confirmar publicação do comentário", "Confirmar comentário"),
    ("Ocultar elementos da tela de Reels", "Ocultar elementos dos Reels"),
    ("Mostrar elementos da tela de Reels", "Mostrar elementos dos Reels"),
    ("Ocultar \\\"Pessoas que você talvez conheça\\\"", "Ocultar pessoas sugeridas"),
]

for old, new in pairs:
    if old not in s:
        raise RuntimeError(f"missing PT-BR label: {old}")
    s = s.replace(old, new, 1)

p.write_text(s, encoding="utf-8")
