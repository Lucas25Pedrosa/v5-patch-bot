#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static void (*IQFProbeOriginalViewDidAppear)(UIViewController *, SEL, BOOL) = NULL;
static BOOL IQFProbeInstalled = NO;
static NSInteger IQFProbeAttempts = 0;

static BOOL IQFProbeClassImplementsSelector(Class cls, SEL selector) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    BOOL found = NO;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == selector) {
            found = YES;
            break;
        }
    }
    free(methods);
    return found;
}

static void IQFProbeViewDidAppear(UIViewController *self, SEL command, BOOL animated) {
    if (IQFProbeOriginalViewDidAppear != NULL) {
        IQFProbeOriginalViewDidAppear(self, command, animated);
    }

    NSString *current = self.navigationItem.title ?: self.title ?: @"iQFace Settings";
    if ([current rangeOfString:@"Hook OK"].location == NSNotFound) {
        NSString *marked = [current stringByAppendingString:@" • Hook OK"];
        self.navigationItem.title = marked;
        self.title = marked;
    }

    NSLog(@"[iQFaceSettingsProbe] IQFSettingsViewController hook reached");
}

static void IQFProbeTryInstall(void) {
    if (IQFProbeInstalled) {
        return;
    }

    IQFProbeAttempts += 1;
    Class target = NSClassFromString(@"IQFSettingsViewController");
    if (target != Nil) {
        SEL selector = @selector(viewDidAppear:);
        Method inheritedOrOwn = class_getInstanceMethod(target, selector);
        if (inheritedOrOwn != NULL) {
            IQFProbeOriginalViewDidAppear = (void (*)(UIViewController *, SEL, BOOL))method_getImplementation(inheritedOrOwn);
            const char *types = method_getTypeEncoding(inheritedOrOwn);

            if (IQFProbeClassImplementsSelector(target, selector)) {
                method_setImplementation(inheritedOrOwn, (IMP)&IQFProbeViewDidAppear);
                IQFProbeInstalled = YES;
            } else if (class_addMethod(target, selector, (IMP)&IQFProbeViewDidAppear, types)) {
                IQFProbeInstalled = YES;
            }
        }
    }

    if (!IQFProbeInstalled && IQFProbeAttempts < 120) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            IQFProbeTryInstall();
        });
    }
}

__attribute__((constructor))
static void IQFProbeInitialize(void) {
    @autoreleasepool {
        NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier;
        if (![bundleIdentifier isEqualToString:@"com.facebook.Facebook"] ||
            [NSBundle.mainBundle.bundlePath hasSuffix:@".appex"]) {
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            IQFProbeTryInstall();
        });
    }
}
