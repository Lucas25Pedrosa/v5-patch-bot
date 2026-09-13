from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text(encoding="utf-8")
assert 'MSHookMessageEx' in s
assert '@selector(viewDidLayoutSubviews)' in s
assert '@selector(viewDidAppear:)' in s
# Legacy mode: intentionally do not modify Translation.m or EnhancerTweak.m.
