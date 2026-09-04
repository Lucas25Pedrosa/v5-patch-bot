#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static id (*IQTOriginalLongPressInit)(id, SEL, id, SEL) = NULL;

static id IQTLongPressInit(id self, SEL _cmd, id target, SEL action) {
    id recognizer = IQTOriginalLongPressInit(self, _cmd, target, action);

    if ([recognizer isKindOfClass:UILongPressGestureRecognizer.class]) {
        NSString *targetClass = target ? NSStringFromClass([target class]) : @"";
        NSString *actionName = action ? NSStringFromSelector(action) : @"";

        if ([targetClass isEqualToString:@"IQTMxGestureTarget"] &&
            [actionName isEqualToString:@"handleLongPress:"]) {
            // iQTele presents its settings without removing the native Telegram
            // support row from the active touch cycle. Cancel the underlying
            // row touch only once this long-press is recognized. Short taps are
            // unaffected because the long-press recognizer fails normally.
            ((UILongPressGestureRecognizer *)recognizer).cancelsTouchesInView = YES;
        }
    }

    return recognizer;
}

__attribute__((constructor)) static void IQTInstallLongPressTouchCancellation(void) {
    @autoreleasepool {
        Method method = class_getInstanceMethod(UILongPressGestureRecognizer.class,
                                                @selector(initWithTarget:action:));
        if (method == NULL) return;

        IMP current = method_getImplementation(method);
        if (current == (IMP)&IQTLongPressInit) return;

        IQTOriginalLongPressInit = (void *)current;
        method_setImplementation(method, (IMP)&IQTLongPressInit);
    }
}
