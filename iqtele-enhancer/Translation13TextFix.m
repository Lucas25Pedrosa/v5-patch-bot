#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>

// Final micro-fix for iQTele 1.3 PT-BR strings.
// Keeps the working layout-final translation path untouched and only corrects
// two exact labels observed on-device.

typedef void (*IQTTextFixMSHookMessageExFunction)(Class cls, SEL selector, IMP replacement, IMP *original);

static IMP IQTTextFixOriginalLayout = NULL;
static IMP IQTTextFixOriginalAppear = NULL;
static BOOL IQTTextFixInstalled = NO;

static NSString *IQTTextFixValue(NSString *text) {
    if (text.length == 0) return nil;

    if ([text isEqualToString:@"No screenshot notification"] ||
        [text isEqualToString:@"Sem notificação de captura de tela"]) {
        return @"Sem aviso de captura";
    }

    if ([text isEqualToString:@"They stay in the chat with the trash badge. The other side still loses them."] ||
        [text isEqualToString:@"They stay in the chat with the trash icon. The other side still loses them."] ||
        [text isEqualToString:@"Elas permanecem no chat com o ícone de lixeira. Para a outra pessoa, continuam excluídas."]) {
        return @"Elas ficam no chat com o ícone de lixeira. Para a outra pessoa, somem.";
    }

    return nil;
}

static BOOL IQTTextFixViewTree(UIView *view) {
    if (view == nil) return NO;
    BOOL changed = NO;

    if ([view isKindOfClass:UILabel.class]) {
        UILabel *label = (UILabel *)view;
        NSString *replacement = IQTTextFixValue(label.text);
        if (replacement != nil && ![replacement isEqualToString:label.text]) {
            label.text = replacement;
            [label invalidateIntrinsicContentSize];
            [label setNeedsLayout];
            changed = YES;
        }
    }

    for (UIView *subview in view.subviews.copy) {
        if (IQTTextFixViewTree(subview)) changed = YES;
    }
    return changed;
}

static void IQTTextFixController(UIViewController *controller) {
    if (controller == nil || !controller.isViewLoaded) return;
    if (IQTTextFixViewTree(controller.view)) {
        [controller.view setNeedsLayout];
        [controller.view layoutIfNeeded];
    }
}

static void IQTTextFixLayout(id self, SEL command) {
    if (IQTTextFixOriginalLayout != NULL) {
        ((void (*)(id, SEL))IQTTextFixOriginalLayout)(self, command);
    }
    if ([self isKindOfClass:UIViewController.class]) {
        IQTTextFixController((UIViewController *)self);
    }
}

static void IQTTextFixAppear(id self, SEL command, BOOL animated) {
    if (IQTTextFixOriginalAppear != NULL) {
        ((void (*)(id, SEL, BOOL))IQTTextFixOriginalAppear)(self, command, animated);
    }
    if ([self isKindOfClass:UIViewController.class]) {
        IQTTextFixController((UIViewController *)self);
    }
}

static BOOL IQTTextFixInstall(void) {
    if (IQTTextFixInstalled) return YES;

    Class cls = NSClassFromString(@"IQTSettingsViewController");
    if (cls == Nil) return NO;

    IQTTextFixMSHookMessageExFunction hook = (IQTTextFixMSHookMessageExFunction)dlsym(RTLD_DEFAULT, "MSHookMessageEx");
    if (hook == NULL) return NO;

    hook(cls, @selector(viewDidLayoutSubviews), (IMP)&IQTTextFixLayout, &IQTTextFixOriginalLayout);
    hook(cls, @selector(viewDidAppear:), (IMP)&IQTTextFixAppear, &IQTTextFixOriginalAppear);

    IQTTextFixInstalled = (IQTTextFixOriginalLayout != NULL && IQTTextFixOriginalAppear != NULL);
    return IQTTextFixInstalled;
}

static void IQTTextFixRetry(NSUInteger attempt) {
    if (IQTTextFixInstall() || attempt >= 40) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        IQTTextFixRetry(attempt + 1);
    });
}

__attribute__((constructor))
static void IQTTextFixInitialize(void) {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            IQTTextFixRetry(0);
        });
    }
}
