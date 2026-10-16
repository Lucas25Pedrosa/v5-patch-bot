#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// XLiquidGlassNative 3.1 Beta 4
// Selection-state bridge only. It does not tint anything by itself.
// The Beta 3 semantic icon path remains untouched; this module only exposes
// the X 12.35 TabBarItemView selected state to the existing tint routine.

static char kXLG31SelectionStateKey;
static IMP gXLG31OrigUpdateSelection = NULL;
static IMP gXLG31OrigSetSelected = NULL;
static BOOL gXLG31SelectionBridgeInstalled = NO;

static BOOL XLG31BoolType(const char *type) {
    if (!type || !type[0]) return NO;
    return type[0] == 'B' || type[0] == 'c' || type[0] == 'C';
}

static void XLG31RememberSelection(id object, BOOL selected) {
    if (!object) return;
    objc_setAssociatedObject(object,
                             &kXLG31SelectionStateKey,
                             @(selected),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    if ([object isKindOfClass:UIView.class]) {
        UIView *view = (UIView *)object;
        dispatch_async(dispatch_get_main_queue(), ^{
            [view setNeedsLayout];
        });
    }
}

static BOOL XLG31ReadSelectionIvar(id object, BOOL *found) {
    if (found) *found = NO;
    if (!object) return NO;

    Class cls = object_getClass(object);
    while (cls && cls != UIView.class && cls != NSObject.class) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);

        for (unsigned int i = 0; i < count; i++) {
            Ivar ivar = ivars[i];
            const char *rawName = ivar_getName(ivar);
            const char *type = ivar_getTypeEncoding(ivar);
            if (!rawName || !XLG31BoolType(type)) continue;

            NSString *name = [NSString stringWithUTF8String:rawName].lowercaseString;
            BOOL exactSelectionName =
                [name isEqualToString:@"isselected"] ||
                [name isEqualToString:@"_isselected"] ||
                [name isEqualToString:@"selected"] ||
                [name isEqualToString:@"_selected"] ||
                ([name containsString:@"isselected"] &&
                 ![name containsString:@"style"] &&
                 ![name containsString:@"index"]);

            if (!exactSelectionName) continue;

            ptrdiff_t offset = ivar_getOffset(ivar);
            uint8_t *bytes = (uint8_t *)(__bridge void *)object;
            BOOL value = (*(uint8_t *)(bytes + offset)) != 0;
            if (found) *found = YES;
            free(ivars);
            return value;
        }

        free(ivars);
        cls = class_getSuperclass(cls);
    }

    return NO;
}

static BOOL XLG31SelectionState(id object) {
    NSNumber *cached = objc_getAssociatedObject(object, &kXLG31SelectionStateKey);
    if ([cached isKindOfClass:NSNumber.class]) return cached.boolValue;

    BOOL found = NO;
    BOOL value = XLG31ReadSelectionIvar(object, &found);
    if (found) {
        XLG31RememberSelection(object, value);
        return value;
    }

    return NO;
}

static BOOL XLG31SyntheticSelected(id self, SEL _cmd) {
    (void)_cmd;
    return XLG31SelectionState(self);
}

static void XLG31UpdateSelection(id self,
                                 SEL _cmd,
                                 BOOL isSelected,
                                 BOOL animated) {
    if (gXLG31OrigUpdateSelection) {
        ((void(*)(id,SEL,BOOL,BOOL))gXLG31OrigUpdateSelection)(
            self, _cmd, isSelected, animated);
    }
    XLG31RememberSelection(self, isSelected);
}

static void XLG31SetSelected(id self, SEL _cmd, BOOL selected) {
    if (gXLG31OrigSetSelected) {
        ((void(*)(id,SEL,BOOL))gXLG31OrigSetSelected)(self, _cmd, selected);
    }
    XLG31RememberSelection(self, selected);
}

static BOOL XLG31HookMethodDirect(Class cls,
                                  Method method,
                                  IMP replacement,
                                  IMP *originalOut) {
    if (!cls || !method || !replacement) return NO;
    SEL sel = method_getName(method);
    IMP current = method_getImplementation(method);
    if (originalOut && !*originalOut) *originalOut = current;
    class_replaceMethod(cls, sel, replacement, method_getTypeEncoding(method));
    return class_getMethodImplementation(cls, sel) == replacement;
}

static Method XLG31FindUpdateSelectionMethod(Class cls) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    Method result = NULL;

    for (unsigned int i = 0; i < count; i++) {
        Method method = methods[i];
        NSString *name = NSStringFromSelector(method_getName(method)).lowercaseString;
        if (![name containsString:@"updateselection"]) continue;
        if (method_getNumberOfArguments(method) != 4) continue;

        char *arg0 = method_copyArgumentType(method, 2);
        char *arg1 = method_copyArgumentType(method, 3);
        BOOL matches = XLG31BoolType(arg0) && XLG31BoolType(arg1);
        if (arg0) free(arg0);
        if (arg1) free(arg1);

        if (matches) {
            result = method;
            break;
        }
    }

    free(methods);
    return result;
}

static Method XLG31FindSetSelectedMethod(Class cls) {
    for (NSString *selectorName in @[@"setSelected:", @"setIsSelected:"]) {
        SEL sel = NSSelectorFromString(selectorName);
        Method method = class_getInstanceMethod(cls, sel);
        if (!method || method_getNumberOfArguments(method) != 3) continue;

        char *arg = method_copyArgumentType(method, 2);
        BOOL matches = XLG31BoolType(arg);
        if (arg) free(arg);
        if (matches) return method;
    }
    return NULL;
}

static Class XLG31ItemClass(void) {
    Class cls = NSClassFromString(@"XNavigation.TabBarItemView");
    if (!cls) cls = NSClassFromString(@"_TtC11XNavigation14TabBarItemView");
    return cls;
}

static void XLG31InstallSelectionBridge(void) {
    if (gXLG31SelectionBridgeInstalled) return;

    Class cls = XLG31ItemClass();
    if (!cls) return;

    // Beta 3 already asks KVC for "selected" and "isSelected". X 12.35 keeps
    // its selection state on the Swift side, so expose lightweight ObjC getters
    // backed by the captured/native Swift state when those getters do not exist.
    if (!class_getInstanceMethod(cls, @selector(selected))) {
        class_addMethod(cls, @selector(selected), (IMP)XLG31SyntheticSelected, "B@:");
    }
    if (!class_getInstanceMethod(cls, @selector(isSelected))) {
        class_addMethod(cls, @selector(isSelected), (IMP)XLG31SyntheticSelected, "B@:");
    }

    Method updateSelection = XLG31FindUpdateSelectionMethod(cls);
    if (updateSelection) {
        XLG31HookMethodDirect(cls,
                             updateSelection,
                             (IMP)XLG31UpdateSelection,
                             &gXLG31OrigUpdateSelection);
    }

    Method setSelected = XLG31FindSetSelectedMethod(cls);
    if (setSelected) {
        XLG31HookMethodDirect(cls,
                             setSelected,
                             (IMP)XLG31SetSelected,
                             &gXLG31OrigSetSelected);
    }

    gXLG31SelectionBridgeInstalled = YES;
    NSLog(@"[XLiquidGlassNative] 3.1 Beta 4 active-tab selection bridge installed");
}

static void XLG31SelectionRetry(NSTimeInterval delay) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        XLG31InstallSelectionBridge();
    });
}

__attribute__((constructor))
static void XLiquidGlass31SelectionStateInit(void) {
    @autoreleasepool {
        XLG31InstallSelectionBridge();
        XLG31SelectionRetry(0.00);
        XLG31SelectionRetry(0.05);
        XLG31SelectionRetry(0.20);
        XLG31SelectionRetry(0.50);
        XLG31SelectionRetry(1.00);
        XLG31SelectionRetry(2.00);
        XLG31SelectionRetry(4.00);
    }
}
