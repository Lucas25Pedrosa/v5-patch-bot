from pathlib import Path

p = Path('x-liquid-glass-only/XLiquidGlass.m')
s = p.read_text()

helper_marker = 'static BOOL XLGScrollEdgeEffectViewIsProtected(\n    UIVisualEffectView *effectView) {'
helper = r'''
static BOOL XLGCommentsNativeIsolationContext(UIView *view) {
    if (!view) return NO;

    BOOL hasURT = NO;
    BOOL hasConversation = NO;
    UIResponder *responder = view;
    for (NSUInteger i = 0; responder && i < 32; i++) {
        if ([responder isKindOfClass:UIViewController.class]) {
            NSString *name = NSStringFromClass([responder class]);
            if ([name isEqualToString:@"T1URTViewController"]) {
                hasURT = YES;
            }
            if ([name isEqualToString:@"T1ConversationContainerViewController"]) {
                hasConversation = YES;
            }
        }
        responder = responder.nextResponder;
    }

    BOOL hasTable = NO;
    UIView *cursor = view;
    for (NSUInteger i = 0; cursor && i < 24; i++, cursor = cursor.superview) {
        if ([NSStringFromClass(cursor.class) isEqualToString:@"TFNTableView"]) {
            hasTable = YES;
            break;
        }
    }

    return hasURT && hasConversation && hasTable;
}

'''
if 'XLGCommentsNativeIsolationContext' not in s:
    if helper_marker not in s:
        raise SystemExit('helper insertion marker not found')
    s = s.replace(helper_marker, helper + helper_marker, 1)

# 1) Any ScrollEdge effect inside the exact comments context is native-only.
needle = '''static BOOL XLGScrollEdgeEffectViewIsProtected(\n    UIVisualEffectView *effectView) {\n\n    if (!XLGEnabled() || !effectView) return NO;\n'''
replacement = '''static BOOL XLGScrollEdgeEffectViewIsProtected(\n    UIVisualEffectView *effectView) {\n\n    if (!XLGEnabled() || !effectView) return NO;\n    if (XLGCommentsNativeIsolationContext(effectView)) return NO;\n'''
if needle not in s:
    raise SystemExit('effect protected marker not found')
s = s.replace(needle, replacement, 1)

# 2) Same for private UIKit BackdropView. This disables filter stripping there.
needle = '''static BOOL XLGScrollEdgeBackdropIsProtected(UIView *view) {\n    if (!XLGEnabled() || !view) return NO;\n'''
replacement = '''static BOOL XLGScrollEdgeBackdropIsProtected(UIView *view) {\n    if (!XLGEnabled() || !view) return NO;\n    if (XLGCommentsNativeIsolationContext(view)) return NO;\n'''
if needle not in s:
    raise SystemExit('backdrop protected marker not found')
s = s.replace(needle, replacement, 1)

# 3) Hard guard at the treatment post-processing entry point too. The original
#    X layout still runs; only XLiquidGlass post-processing is skipped.
needle = '''    if (![NSStringFromClass(treatment.class)\n            isEqualToString:@"XDesignSystem.ScrollEdgeTreatment"]) {\n        return;\n    }\n\n    // X 12.31 Search:'''
replacement = '''    if (![NSStringFromClass(treatment.class)\n            isEqualToString:@"XDesignSystem.ScrollEdgeTreatment"]) {\n        return;\n    }\n    if (XLGCommentsNativeIsolationContext(treatment)) return;\n\n    // X 12.31 Search:'''
if needle not in s:
    raise SystemExit('treatment isolation marker not found')
s = s.replace(needle, replacement, 1)

# 4) Belt-and-suspenders guard in the Backdrop layout hook. Native UIKit layout
#    already ran above; return before any XLiquidGlass filter removal.
needle = '''    if (![self isKindOfClass:UIView.class]) return;\n    UIView *view=(UIView *)self;\n\n    if (XLGScrollEdgeBackdropIsProtected(view) ||'''
replacement = '''    if (![self isKindOfClass:UIView.class]) return;\n    UIView *view=(UIView *)self;\n    if (XLGCommentsNativeIsolationContext(view)) return;\n\n    if (XLGScrollEdgeBackdropIsProtected(view) ||'''
if needle not in s:
    raise SystemExit('backdrop layout marker not found')
s = s.replace(needle, replacement, 1)

p.write_text(s)
print('Applied XLiquidGlass Beta 5 comments native isolation patch')
