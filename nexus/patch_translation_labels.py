from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text(encoding="utf-8")

old = '''        NSString *translated = IQFTranslateUIString(label.text);
        if (![translated isEqualToString:label.text]) label.text = translated;'''
new = '''        NSString *translated = IQFTranslateUIString(label.text);
        if (![translated isEqualToString:label.text]) {
            label.text = translated;
            label.adjustsFontSizeToFitWidth = NO;
            [label invalidateIntrinsicContentSize];
            [label setNeedsLayout];
            [label.superview setNeedsLayout];
            [label.superview layoutIfNeeded];
            [label.window setNeedsLayout];
            [label.window layoutIfNeeded];
        }'''

if old not in s:
    raise RuntimeError("expected UILabel translation block not found")
s = s.replace(old, new, 1)
p.write_text(s, encoding="utf-8")
