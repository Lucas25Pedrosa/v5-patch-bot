from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text(encoding="utf-8")
s = s.replace('// iQFaceOLED 0.2.0 EN', '// iQFaceOLED 0.2.0', 1)
s = s.replace('@"header": @"FERRAMENTAS"', '@"header": @"TOOLS"')
s = s.replace('@"Modo OLED"', '@"OLED Mode"')
s = s.replace('@"Separadores no feed"', '@"Feed separators"')
p.write_text(s, encoding="utf-8")
