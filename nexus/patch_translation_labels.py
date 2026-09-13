from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text(encoding="utf-8")

old = '''        NSString *translated = IQFTranslateUIString(label.text);
        if (![translated isEqualToString:label.text]) label.text = translated;'''
new = '''        NSString *translated = IQFTranslateUIString(label.text);
        if (![translated isEqualToString:label.text]) {
            label.text = translated;
            // PT-BR strings are often wider than their English source. Let the
            // native one-line settings labels use the available width instead
            // of immediately truncating the translated title with an ellipsis.
            if (label.numberOfLines == 1) {
                label.adjustsFontSizeToFitWidth = YES;
                label.minimumScaleFactor = 0.82;
                label.baselineAdjustment = UIBaselineAdjustmentAlignCenters;
            }
            [label invalidateIntrinsicContentSize];
            [label setNeedsLayout];
            [label.superview setNeedsLayout];
        }'''

if old not in s:
    raise RuntimeError("expected UILabel translation block not found")
s = s.replace(old, new, 1)
p.write_text(s, encoding="utf-8")
