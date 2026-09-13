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

helper = r'''// iQFace 1.1 sizes some UIListContentView instances from the original
// English title. After PT-BR translation the UILabel intrinsic width grows,
// but both the label and its UIListContentView may keep that stale width.
// Measure against the UITableViewCell itself instead of the already-stale
// UIListContentView bounds.
static void IQFFixTranslatedListLabelWidth(UILabel *label) {
    if (label == nil || label.text.length == 0) return;

    UIView *listContent = label.superview;
    if (listContent == nil || ![NSStringFromClass(listContent.class) isEqualToString:@"UIListContentView"]) return;
    if (label.font.pointSize < 16.0) return;

    UITableViewCell *cell = nil;
    UIView *ancestor = listContent.superview;
    while (ancestor != nil) {
        if ([ancestor isKindOfClass:UITableViewCell.class]) {
            cell = (UITableViewCell *)ancestor;
            break;
        }
        ancestor = ancestor.superview;
    }
    if (cell == nil) return;

    CGFloat wanted = ceil(label.intrinsicContentSize.width);
    CGFloat current = CGRectGetWidth(label.frame);
    if (wanted <= 0.0 || current + 0.5 >= wanted) return;

    // Convert the label's left edge into the cell contentView coordinate space.
    CGRect labelRectInCell = [listContent convertRect:label.frame toView:cell.contentView];
    CGFloat rightLimit = CGRectGetWidth(cell.contentView.bounds) - 16.0;

    // Respect controls/accessories placed on the right side of the row.
    for (UIView *subview in cell.contentView.subviews.copy) {
        if (subview == listContent || subview.hidden || subview.alpha <= 0.01) continue;
        CGRect r = [subview.superview convertRect:subview.frame toView:cell.contentView];
        if (CGRectGetMinX(r) <= CGRectGetMinX(labelRectInCell)) continue;

        BOOL isTrailingControl = [subview isKindOfClass:UISwitch.class] ||
                                 [subview isKindOfClass:UIButton.class] ||
                                 [subview isKindOfClass:UISegmentedControl.class] ||
                                 [NSStringFromClass(subview.class) containsString:@"Accessory"];
        if (isTrailingControl) {
            rightLimit = MIN(rightLimit, CGRectGetMinX(r) - 12.0);
        }
    }

    CGFloat availableInCell = floor(rightLimit - CGRectGetMinX(labelRectInCell));
    if (availableInCell <= current + 0.5) return;

    CGFloat target = MIN(wanted, availableInCell);
    CGRect frame = label.frame;
    frame.size.width = target;
    label.frame = frame;

    // If the parent list content itself was measured to the old English width,
    // grow it enough to contain the corrected title without changing the row.
    CGFloat neededListWidth = CGRectGetMinX(label.frame) + target;
    if (CGRectGetWidth(listContent.frame) + 0.5 < neededListWidth) {
        CGRect listFrame = listContent.frame;
        CGFloat maxListWidth = CGRectGetWidth(cell.contentView.bounds) - CGRectGetMinX(listFrame) - 16.0;
        listFrame.size.width = MIN(neededListWidth, maxListWidth);
        listContent.frame = listFrame;
    }
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
assert 'UITableViewCell *cell = nil;' in s
assert 'availableInCell' in s
p.write_text(s, encoding="utf-8")
