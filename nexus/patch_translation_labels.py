from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text(encoding="utf-8")

marker = '''static void IQFTranslateViewTree(UIView *view) {'''
helper = r'''static UISwitch *IQFFindNearestSwitchForLabel(UILabel *label) {
    if (label == nil) return nil;
    UIView *ancestor = label.superview;
    for (NSUInteger depth = 0; depth < 4 && ancestor != nil; depth++, ancestor = ancestor.superview) {
        NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:ancestor];
        while (stack.count > 0) {
            UIView *candidate = stack.lastObject;
            [stack removeLastObject];
            if ([candidate isKindOfClass:UISwitch.class]) {
                UISwitch *toggle = (UISwitch *)candidate;
                CGRect toggleRect = [toggle.superview convertRect:toggle.frame toView:label.superview];
                CGFloat deltaY = fabs(CGRectGetMidY(toggleRect) - CGRectGetMidY(label.frame));
                if (deltaY <= 28.0) return toggle;
            }
            for (UIView *subview in candidate.subviews) {
                [stack addObject:subview];
            }
        }
    }
    return nil;
}

static BOOL IQFIsTranslatedPortugueseValue(NSString *text) {
    if (text.length == 0) return NO;
    return [IQFPortugueseUIStrings().allValues containsObject:text];
}

static void IQFExpandTranslatedLabelToAvailableWidth(UILabel *label) {
    if (label == nil || label.superview == nil || !IQFIsTranslatedPortugueseValue(label.text)) return;

    CGRect frame = label.frame;
    if (CGRectIsEmpty(frame)) return;

    CGSize fit = [label sizeThatFits:CGSizeMake(CGFLOAT_MAX, MAX(CGRectGetHeight(frame), 1.0))];
    CGFloat desiredWidth = ceil(fit.width) + 2.0;
    if (desiredWidth <= CGRectGetWidth(frame) + 0.5) return;

    CGFloat maxRight = CGRectGetWidth(label.superview.bounds) - 12.0;
    UISwitch *toggle = IQFFindNearestSwitchForLabel(label);
    if (toggle != nil) {
        CGRect toggleRect = [toggle.superview convertRect:toggle.frame toView:label.superview];
        maxRight = MIN(maxRight, CGRectGetMinX(toggleRect) - 14.0);
    }

    CGFloat availableWidth = floor(maxRight - CGRectGetMinX(frame));
    if (availableWidth <= CGRectGetWidth(frame)) return;

    frame.size.width = MIN(desiredWidth, availableWidth);
    label.frame = frame;
    label.adjustsFontSizeToFitWidth = NO;
    [label setContentCompressionResistancePriority:760.0 forAxis:UILayoutConstraintAxisHorizontal];
    [label invalidateIntrinsicContentSize];
}

static void IQFTranslateViewTree(UIView *view) {'''

if marker not in s:
    raise RuntimeError("IQFTranslateViewTree marker not found")
s = s.replace(marker, helper, 1)

old = '''    if ([view isKindOfClass:UILabel.class]) {
        UILabel *label = (UILabel *)view;
        NSString *translated = IQFTranslateUIString(label.text);
        if (![translated isEqualToString:label.text]) label.text = translated;
    } else if ([view isKindOfClass:UIButton.class]) {'''
new = '''    if ([view isKindOfClass:UILabel.class]) {
        UILabel *label = (UILabel *)view;
        NSString *translated = IQFTranslateUIString(label.text);
        if (![translated isEqualToString:label.text]) label.text = translated;
        IQFExpandTranslatedLabelToAvailableWidth(label);
    } else if ([view isKindOfClass:UIButton.class]) {'''

if old not in s:
    raise RuntimeError("expected UILabel translation block not found")
s = s.replace(old, new, 1)

p.write_text(s, encoding="utf-8")
