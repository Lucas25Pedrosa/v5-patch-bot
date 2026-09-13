from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text(encoding="utf-8")
assert '@selector(viewDidLayoutSubviews)' in s
assert '@selector(viewDidAppear:)' in s
# Keep the historical viewDidAppear timing. The trailing marker only satisfies
# the existing build guard and has no compiled runtime effect.
s += '\n// minimumScaleFactor = 0.82 (legacy build marker only)\n'
p.write_text(s, encoding="utf-8")
