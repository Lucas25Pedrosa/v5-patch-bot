#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static void (*IQTOriginalHandleLongPress)(id, SEL, UILongPressGestureRecognizer *) = NULL;

static void IQTTemporarilyCancelSupportCompletion(UILongPressGestureRecognizer *gesture) {
    UIView *view = gesture.view;
    if (view == nil) return;

    NSMutableArray<UIGestureRecognizer *> *disabledRecognizers = [NSMutableArray array];
    UIView *current = view;
    for (NSInteger level = 0; level < 5 && current != nil; level++, current = current.superview) {
        for (UIGestureRecognizer *recognizer in current.gestureRecognizers.copy) {
            if (recognizer == gesture || !recognizer.enabled) continue;
            recognizer.enabled = NO;
            [disabledRecognizers addObject:recognizer];
        }
    }

    BOOL wasInteractive = view.userInteractionEnabled;
    if (wasInteractive) view.userInteractionEnabled = NO;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        for (UIGestureRecognizer *recognizer in disabledRecognizers) {
            recognizer.enabled = YES;
        }
        if (wasInteractive) view.userInteractionEnabled = YES;
    });
}

static void IQTHandleLongPressSuppressingNativeTap(id self,
                                                    SEL _cmd,
                                                    UILongPressGestureRecognizer *gesture) {
    UIGestureRecognizerState state = gesture.state;

    if (IQTOriginalHandleLongPress != NULL) {
        IQTOriginalHandleLongPress(self, _cmd, gesture);
    }

    if (state == UIGestureRecognizerStateBegan) {
        IQTTemporarilyCancelSupportCompletion(gesture);
    }
}

__attribute__((constructor)) static void IQTInstallSupportTapSuppression(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        Class cls = NSClassFromString(@"IQTMxGestureTarget");
        SEL selector = NSSelectorFromString(@"handleLongPress:");
        Method method = cls != Nil ? class_getInstanceMethod(cls, selector) : NULL;
        if (method == NULL) return;

        IMP current = method_getImplementation(method);
        if (current == (IMP)&IQTHandleLongPressSuppressingNativeTap) return;

        IQTOriginalHandleLongPress = (void *)current;
        method_setImplementation(method, (IMP)&IQTHandleLongPressSuppressingNativeTap);
    });
}
