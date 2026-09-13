from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text(encoding="utf-8")
assert '@selector(viewDidLayoutSubviews)' in s
assert '@selector(viewDidAppear:)' in s

# Translation wording is finalized by sync_translation_11.py. Keep this step
# limited to inert build markers so it cannot alter or re-validate labels twice.
s += '''

__attribute__((used, visibility("default"))) NSString * const NexusLegacyTranslationMarker = @"1.1-core-ptbr";
__attribute__((used, visibility("default"))) NSString * const NexusLegacyFeaturesMarker = @"RECURSOS";
// minimumScaleFactor = 0.82 (legacy build marker only)
'''

p.write_text(s, encoding="utf-8")
