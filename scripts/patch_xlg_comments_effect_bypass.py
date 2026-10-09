from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

helper = r'''
static BOOL XLGCommentsNativeEffectContext(UIView *view) {
    if (!view) return NO;

    BOOL hasURT = NO;
    BOOL hasConversation = NO;
    UIResponder *responder = view;
    for (NSUInteger i = 0; responder && i < 32; i++) {
        if ([responder isKindOfClass:UIViewController.class]) {
            NSString *name = NSStringFromClass([responder class]);
            if ([name isEqualToString:@"T1URTViewController"]) hasURT = YES;
            if ([name isEqualToString:@"T1ConversationContainerViewController"]) hasConversation = YES;
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

marker = 'static void XLGVisualEffectViewSetEffect(\n'
if marker not in text:
    raise SystemExit('setEffect function marker not found')
text = text.replace(marker, helper + marker, 1)

needle = '''        BOOL scrollEdgeProtected=\n            XLGScrollEdgeEffectViewIsProtected(effectView);\n\n        if (searchProtected ||\n'''
replacement = '''        BOOL scrollEdgeProtected=\n            XLGScrollEdgeEffectViewIsProtected(effectView);\n\n        // Comments/replies use a very hot XColorEngine path. In this exact\n        // hierarchy, forcing the incoming effect to nil makes X immediately\n        // request it again, causing continuous effect/layout churn. Let the\n        // native X effect pass through only here.\n        if (scrollEdgeProtected &&\n            XLGCommentsNativeEffectContext(effectView)) {\n            ((void(*)(id,SEL,id))\n                gOrigVisualEffectViewSetEffect)(\n                    self,cmd,effect);\n            return;\n        }\n\n        if (searchProtected ||\n'''
if needle not in text:
    raise SystemExit('scrollEdgeProtected anchor not found')
text = text.replace(needle, replacement, 1)

path.write_text(text)
print('patched comments setEffect native bypass')
