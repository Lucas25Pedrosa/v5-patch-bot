#!/usr/bin/env python3
from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: patch_xlg_comments_native_bypass.py <XLiquidGlass.m>")

path = Path(sys.argv[1])
src = path.read_text(encoding="utf-8")

function_anchor = "static void XLGScrollEdgeTreatmentLayoutSubviews(id self, SEL cmd) {"
helper_name = "XLGShouldBypassScrollEdgeTreatmentForConversation"

if function_anchor not in src:
    raise SystemExit("ScrollEdgeTreatment hook not found")
if helper_name in src:
    raise SystemExit("patch already applied")

helper = r'''static BOOL XLGShouldBypassScrollEdgeTreatmentForConversation(id object) {
    if (![object isKindOfClass:UIView.class]) return NO;

    UIView *target = (UIView *)object;
    BOOL hasURT = NO;
    BOOL hasConversation = NO;

    UIResponder *responder = target;
    for (NSUInteger depth = 0; responder && depth < 32; depth++) {
        if ([responder isKindOfClass:UIViewController.class]) {
            NSString *name = NSStringFromClass([responder class]);
            if ([name isEqualToString:@"T1URTViewController"]) {
                hasURT = YES;
            } else if ([name isEqualToString:@"T1ConversationContainerViewController"]) {
                hasConversation = YES;
            }
        }
        responder = responder.nextResponder;
    }

    if (!hasURT || !hasConversation) return NO;

    UIView *cursor = target.superview;
    for (NSUInteger depth = 0; cursor && depth < 20; depth++, cursor = cursor.superview) {
        if ([cursor isKindOfClass:UIScrollView.class] &&
            [NSStringFromClass([cursor class]) isEqualToString:@"TFNTableView"]) {
            return YES;
        }
    }

    return NO;
}

'''

src = src.replace(function_anchor, helper + function_anchor, 1)

start = src.index(function_anchor)
orig_anchor = "    if (gOrigScrollEdgeTreatmentLayoutSubviews) {"
orig_start = src.index(orig_anchor, start)
orig_end = src.index("    }\n", orig_start) + len("    }\n")

bypass = r'''

    // 2.0.2 Beta 3: comments/conversation uses X's native ScrollEdgeTreatment
    // only. The original IMP above still performs X's own layout; returning
    // here skips only XLiquidGlass's post-processing for this exact host.
    if (XLGShouldBypassScrollEdgeTreatmentForConversation(self)) {
        return;
    }
'''

src = src[:orig_end] + bypass + src[orig_end:]

if src.count(helper_name) < 2:
    raise SystemExit("patch validation failed")

path.write_text(src, encoding="utf-8")
print("Applied comments-only native ScrollEdgeTreatment bypass")
