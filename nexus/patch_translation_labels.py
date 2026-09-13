from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text(encoding="utf-8")
assert 'MSHookMessageEx' in s
assert '@selector(viewDidLayoutSubviews)' in s
assert '@selector(viewDidAppear:)' in s

needle = '''static void IQFTranslateViewTree(UIView *view) {
    if (view == nil) return;
'''
assert needle in s

helper = r'''// iQFace 1.1 can keep the title UILabel at the width measured for the
// original English text even after PT-BR localization changes the intrinsic
// width. Apply the correction to title-sized labels inside UIListContentView
// regardless of which translation table produced the Portuguese text.
static void IQFFixTranslatedListLabelWidth(UILabel *label) {
    if (label == nil || label.text.length == 0) return;

    UIView *contentView = label.superview;
    if (contentView == nil || ![NSStringFromClass(contentView.class) isEqualToString:@"UIListContentView"]) return;

    // iQFace setting titles use the 17pt list title style. Keep subtitles and
    // secondary 15pt content untouched.
    if (label.font.pointSize < 16.0) return;

    CGFloat wanted = ceil(label.intrinsicContentSize.width);
    CGFloat current = CGRectGetWidth(label.frame);
    CGFloat available = floor(CGRectGetWidth(contentView.bounds) - CGRectGetMinX(label.frame));
    if (wanted <= 0.0 || available <= 0.0 || current + 0.5 >= wanted) return;

    CGFloat target = MIN(wanted, available);
    if (current + 0.5 >= target) return;

    CGRect frame = label.frame;
    frame.size.width = target;
    label.frame = frame;
}

'''

s = s.replace(needle, helper + needle, 1)

old_label = '''    if ([view isKindOfClass:UILabel.class]) {
        UILabel *label = (UILabel *)view;
        NSString *translated = IQFTranslateUIString(label.text);
        if (![translated isEqualToString:label.text]) label.text = translated;
'''
new_label = '''    if ([view isKindOfClass:UILabel.class]) {
        UILabel *label = (UILabel *)view;
        NSString *translated = IQFTranslateUIString(label.text);
        if (![translated isEqualToString:label.text]) label.text = translated;
        IQFFixTranslatedListLabelWidth(label);
'''
assert old_label in s
s = s.replace(old_label, new_label, 1)

assert 'IQFFixTranslatedListLabelWidth(label);' in s
assert 'UIListContentView' in s
assert 'label.font.pointSize < 16.0' in s
p.write_text(s, encoding="utf-8")
