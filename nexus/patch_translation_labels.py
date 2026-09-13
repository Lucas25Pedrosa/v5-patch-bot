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

helper = r'''static NSSet<NSString *> *IQFPortugueseTranslatedValues(void) {
    static NSSet<NSString *> *values;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        values = [NSSet setWithArray:IQFPortugueseUIStrings().allValues];
    });
    return values;
}

// iQFace 1.1 lays out some UIListContentView title labels using the width of
// the original English string. Translation changes intrinsicContentSize but
// the manually-sized UILabel frame can remain at the old width (for example,
// "Bloquear anúncios" needs ~141pt while the English-sized frame is ~74pt).
// Run this after iQFace's own layout and only touch known translated titles.
static void IQFFixTranslatedListLabelWidth(UILabel *label) {
    if (label == nil || label.text.length == 0) return;
    if (![IQFPortugueseTranslatedValues() containsObject:label.text]) return;

    UIView *contentView = label.superview;
    if (contentView == nil || ![NSStringFromClass(contentView.class) isEqualToString:@"UIListContentView"]) return;

    CGFloat wanted = ceil(label.intrinsicContentSize.width);
    CGFloat available = floor(CGRectGetWidth(contentView.bounds) - CGRectGetMinX(label.frame));
    if (wanted <= 0.0 || available <= 0.0) return;

    CGFloat target = MIN(wanted, available);
    if (CGRectGetWidth(label.frame) + 0.5 >= target) return;

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

# Keep the historical controller hooks. The width correction runs from the
# same post-layout translation traversal, so UIKit cannot leave the title at
# the stale English frame width after viewDidLayoutSubviews.
assert 'IQFFixTranslatedListLabelWidth(label);' in s
assert 'UIListContentView' in s
p.write_text(s, encoding="utf-8")
