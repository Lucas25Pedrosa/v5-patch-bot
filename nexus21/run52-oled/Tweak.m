#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <math.h>

// iQFaceOLED 0.1.1
// Standalone replacement for FBOLED with an iQFace control row.
// Does not modify iQFace, iQFaceEnhancer, iQFaceIcons, iQFaceCache or FBOLED.
// OLED engine is based on the validated FBOLED 0.2.0 behavior for Facebook 577+.

static NSString *const IQFOLEDPreferenceKey = @"iQFaceOLEDEnabled";

static const void *kIQFOLEDOriginalViewColorKey = &kIQFOLEDOriginalViewColorKey;
static const void *kIQFOLEDOriginalLayerColorKey = &kIQFOLEDOriginalLayerColorKey;
static const void *kIQFOLEDRowInstalledKey = &kIQFOLEDRowInstalledKey;

static NSTimer *gIQFOLEDTimer;
static id gIQFOLEDActiveObserver;
static BOOL gIQFOLEDModeKnown;
static BOOL gIQFOLEDDarkMode;
static BOOL gIQFOLEDEnabled = YES;

static void (*IQFOLEDOriginalViewDidAppear)(UIViewController *, SEL, BOOL) = NULL;
static BOOL gIQFOLEDSettingsHookInstalled = NO;
static NSInteger gIQFOLEDSettingsHookAttempts = 0;

static BOOL IQFOLEDLoadEnabledPreference(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults objectForKey:IQFOLEDPreferenceKey] == nil) {
        return YES;
    }
    return [defaults boolForKey:IQFOLEDPreferenceKey];
}

static void IQFOLEDSaveEnabledPreference(BOOL enabled) {
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:IQFOLEDPreferenceKey];
}

static uint32_t IQFOLEDRGBA(UIColor *color, UITraitCollection *traits) {
    if (!color) return UINT32_MAX;

    UIColor *resolved = color;
    @try {
        if (traits) resolved = [color resolvedColorWithTraitCollection:traits];
    } @catch (__unused NSException *exception) {
        return UINT32_MAX;
    }

    CGFloat red = 0.0, green = 0.0, blue = 0.0, alpha = 0.0;
    if (![resolved getRed:&red green:&green blue:&blue alpha:&alpha]) {
        CGFloat white = 0.0;
        if (![resolved getWhite:&white alpha:&alpha]) return UINT32_MAX;
        red = green = blue = white;
    }

    uint32_t r = (uint32_t)llround(MAX(0.0, MIN(1.0, red)) * 255.0);
    uint32_t g = (uint32_t)llround(MAX(0.0, MIN(1.0, green)) * 255.0);
    uint32_t b = (uint32_t)llround(MAX(0.0, MIN(1.0, blue)) * 255.0);
    uint32_t a = (uint32_t)llround(MAX(0.0, MIN(1.0, alpha)) * 255.0);
    return (r << 24) | (g << 16) | (b << 8) | a;
}

static BOOL IQFOLEDIsMappedDark(uint32_t rgba) {
    switch (rgba) {
        case 0x101011FF:
        case 0x1F1F22FF:
        case 0x252728FF:
        case 0x28292CFF:
            return YES;
        default:
            return NO;
    }
}

static BOOL IQFOLEDIsLightAnchor(uint32_t rgba) {
    switch (rgba) {
        case 0xFFFFFFFF:
        case 0xC9CCD1FF:
        case 0xF8F9FBFF:
            return YES;
        default:
            return NO;
    }
}

static BOOL IQFOLEDIsBlack(uint32_t rgba) {
    return rgba == 0x000000FF;
}

@interface UIView (iQFaceOLEDInstant)
- (void)iqfoled_setBackgroundColor:(UIColor *)color;
@end

@implementation UIView (iQFaceOLEDInstant)

- (void)iqfoled_setBackgroundColor:(UIColor *)color {
    UIColor *original = objc_getAssociatedObject(self, kIQFOLEDOriginalViewColorKey);
    uint32_t rgba = IQFOLEDRGBA(color, self.traitCollection);

    if (gIQFOLEDEnabled && IQFOLEDIsMappedDark(rgba)) {
        objc_setAssociatedObject(self,
                                 kIQFOLEDOriginalViewColorKey,
                                 color,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [self iqfoled_setBackgroundColor:UIColor.blackColor];
        return;
    }

    if (!(original && IQFOLEDIsBlack(rgba))) {
        objc_setAssociatedObject(self,
                                 kIQFOLEDOriginalViewColorKey,
                                 nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [self iqfoled_setBackgroundColor:color];
}

@end

static void IQFOLEDInstallInstantSetter(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method original = class_getInstanceMethod(UIView.class, @selector(setBackgroundColor:));
        Method replacement = class_getInstanceMethod(UIView.class, @selector(iqfoled_setBackgroundColor:));
        if (original && replacement) {
            method_exchangeImplementations(original, replacement);
        }
    });
}

static BOOL IQFOLEDIsThemeAnchor(UIView *view) {
    NSString *name = NSStringFromClass(view.class);
    return [name isEqualToString:@"FBTopBarAndContentView"] ||
           [name isEqualToString:@"FBTabBarAndContentView"] ||
           [name isEqualToString:@"FBMovableNavigationBarView"] ||
           [name isEqualToString:@"FBNewsFeedView"] ||
           [name isEqualToString:@"FBNewsFeedCollectionView"] ||
           [name isEqualToString:@"FBTabBar"];
}

static UIColor *IQFOLEDSourceViewColor(UIView *view) {
    UIColor *current = view.backgroundColor;
    UIColor *original = objc_getAssociatedObject(view, kIQFOLEDOriginalViewColorKey);
    if (!original) return current;

    uint32_t currentRGBA = IQFOLEDRGBA(current, view.traitCollection);
    if (IQFOLEDIsBlack(currentRGBA)) return original;

    objc_setAssociatedObject(view,
                             kIQFOLEDOriginalViewColorKey,
                             nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return current;
}

static void IQFOLEDCountThemeAnchors(UIView *view, NSUInteger *dark, NSUInteger *light) {
    if (view.hidden || view.alpha < 0.01) return;

    if (IQFOLEDIsThemeAnchor(view)) {
        uint32_t rgba = IQFOLEDRGBA(IQFOLEDSourceViewColor(view), view.traitCollection);
        if (IQFOLEDIsMappedDark(rgba)) (*dark)++;
        if (IQFOLEDIsLightAnchor(rgba)) (*light)++;
    }

    for (UIView *child in view.subviews) {
        IQFOLEDCountThemeAnchors(child, dark, light);
    }
}

static NSArray<UIWindow *> *IQFOLEDWindows(void) {
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    UIApplication *application = UIApplication.sharedApplication;

    for (UIScene *scene in application.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        if (windowScene.activationState == UISceneActivationStateUnattached) continue;
        [windows addObjectsFromArray:windowScene.windows];
    }

    return windows;
}

static void IQFOLEDResolveMode(NSArray<UIWindow *> *windows) {
    NSUInteger dark = 0;
    NSUInteger light = 0;

    for (UIWindow *window in windows) {
        IQFOLEDCountThemeAnchors(window, &dark, &light);
    }

    if (dark > light) {
        gIQFOLEDDarkMode = YES;
        gIQFOLEDModeKnown = YES;
    } else if (light > dark) {
        gIQFOLEDDarkMode = NO;
        gIQFOLEDModeKnown = YES;
    } else if (!gIQFOLEDModeKnown) {
        for (UIWindow *window in windows) {
            if (window.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) {
                gIQFOLEDDarkMode = YES;
                gIQFOLEDModeKnown = YES;
                break;
            }
        }
    }
}

static void IQFOLEDTransformView(UIView *view) {
    if (view.hidden || view.alpha < 0.01) return;

    UIColor *original = objc_getAssociatedObject(view, kIQFOLEDOriginalViewColorKey);

    if (gIQFOLEDEnabled && gIQFOLEDDarkMode) {
        UIColor *source = IQFOLEDSourceViewColor(view);
        original = objc_getAssociatedObject(view, kIQFOLEDOriginalViewColorKey);

        if (IQFOLEDIsMappedDark(IQFOLEDRGBA(source, view.traitCollection))) {
            if (!original) {
                objc_setAssociatedObject(view,
                                         kIQFOLEDOriginalViewColorKey,
                                         source,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            if (!IQFOLEDIsBlack(IQFOLEDRGBA(view.backgroundColor, view.traitCollection))) {
                view.backgroundColor = UIColor.blackColor;
            }
        }
    } else if (original) {
        view.backgroundColor = original;
        objc_setAssociatedObject(view,
                                 kIQFOLEDOriginalViewColorKey,
                                 nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    if (!view.backgroundColor && view.layer.backgroundColor) {
        UIColor *layerCurrent = [UIColor colorWithCGColor:view.layer.backgroundColor];
        UIColor *layerOriginal = objc_getAssociatedObject(view.layer, kIQFOLEDOriginalLayerColorKey);

        if (gIQFOLEDEnabled && gIQFOLEDDarkMode) {
            UIColor *source = layerOriginal ?: layerCurrent;
            if (IQFOLEDIsMappedDark(IQFOLEDRGBA(source, view.traitCollection))) {
                if (!layerOriginal) {
                    objc_setAssociatedObject(view.layer,
                                             kIQFOLEDOriginalLayerColorKey,
                                             source,
                                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                }
                view.layer.backgroundColor = UIColor.blackColor.CGColor;
            }
        } else if (layerOriginal) {
            view.layer.backgroundColor = layerOriginal.CGColor;
            objc_setAssociatedObject(view.layer,
                                     kIQFOLEDOriginalLayerColorKey,
                                     nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }

    for (UIView *child in view.subviews) {
        IQFOLEDTransformView(child);
    }
}

static void IQFOLEDRunPass(void) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            IQFOLEDRunPass();
        });
        return;
    }

    @autoreleasepool {
        @try {
            NSArray<UIWindow *> *windows = IQFOLEDWindows();

            if (gIQFOLEDEnabled) {
                IQFOLEDResolveMode(windows);
                if (!gIQFOLEDModeKnown) return;
            }

            for (UIWindow *window in windows) {
                IQFOLEDTransformView(window);
            }
        } @catch (__unused NSException *exception) {
            // A transient Facebook view-tree mutation must never terminate the app.
        }
    }
}

static void IQFOLEDStartEngine(void) {
    IQFOLEDRunPass();

    if (!gIQFOLEDTimer) {
        gIQFOLEDTimer = [NSTimer timerWithTimeInterval:0.75
                                               repeats:YES
                                                 block:^(__unused NSTimer *timer) {
            IQFOLEDRunPass();
        }];
        gIQFOLEDTimer.tolerance = 0.15;
        [NSRunLoop.mainRunLoop addTimer:gIQFOLEDTimer forMode:NSRunLoopCommonModes];
    }

    if (!gIQFOLEDActiveObserver) {
        gIQFOLEDActiveObserver = [NSNotificationCenter.defaultCenter
            addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(__unused NSNotification *notification) {
            IQFOLEDRunPass();
        }];
    }
}

static BOOL IQFOLEDClassImplementsSelector(Class cls, SEL selector) {
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

static BOOL IQFOLEDIsToolsHeader(NSString *header) {
    if (![header isKindOfClass:NSString.class]) return NO;
    NSString *normalized = header.lowercaseString;
    return [normalized isEqualToString:@"tools"] ||
           [normalized isEqualToString:@"ferramentas"] ||
           [normalized isEqualToString:@"herramientas"];
}

static NSString *IQFOLEDRowTitle(id row) {
    NSString *title = nil;
    @try {
        title = [row valueForKey:@"title"];
    } @catch (__unused NSException *exception) {
        title = nil;
    }
    return [title isKindOfClass:NSString.class] ? title : nil;
}

static BOOL IQFOLEDIsOwnRowTitle(NSString *title) {
    return [title isEqualToString:@"Modo OLED"] || [title isEqualToString:@"OLED Mode"];
}

static NSArray *IQFOLEDSections(UIViewController *controller) {
    NSArray *sections = nil;
    @try {
        sections = [controller valueForKey:@"sections"];
    } @catch (__unused NSException *exception) {
        sections = nil;
    }
    return [sections isKindOfClass:NSArray.class] ? sections : nil;
}

static id IQFOLEDFindToolsSection(NSArray *sections) {
    for (id section in sections) {
        NSString *header = nil;
        @try {
            header = [section valueForKey:@"header"];
        } @catch (__unused NSException *exception) {
            header = nil;
        }
        if (IQFOLEDIsToolsHeader(header)) return section;
    }
    return nil;
}

static id IQFOLEDFindOwnRow(NSArray *sections) {
    for (id section in sections) {
        NSArray *rows = nil;
        @try {
            rows = [section valueForKey:@"rows"];
        } @catch (__unused NSException *exception) {
            rows = nil;
        }
        if (![rows isKindOfClass:NSArray.class]) continue;

        for (id row in rows) {
            if (IQFOLEDIsOwnRowTitle(IQFOLEDRowTitle(row))) return row;
        }
    }
    return nil;
}

static NSString *IQFOLEDStatusText(void) {
    return gIQFOLEDEnabled ? @"Ativado" : @"Desativado";
}

static void IQFOLEDRefreshSettingsRow(UIViewController *controller) {
    NSArray *sections = IQFOLEDSections(controller);
    id row = IQFOLEDFindOwnRow(sections);

    if (row != nil) {
        @try {
            [row setValue:IQFOLEDStatusText() forKey:@"detail"];
        } @catch (__unused NSException *exception) {
        }
    }

    if ([controller isKindOfClass:UITableViewController.class]) {
        [((UITableViewController *)controller).tableView reloadData];
    }
}

static void IQFOLEDSetEnabled(BOOL enabled, UIViewController *controller) {
    if (gIQFOLEDEnabled == enabled) return;

    gIQFOLEDEnabled = enabled;
    IQFOLEDSaveEnabledPreference(enabled);

    UISelectionFeedbackGenerator *feedback = [UISelectionFeedbackGenerator new];
    [feedback selectionChanged];

    IQFOLEDRefreshSettingsRow(controller);
    IQFOLEDRunPass();
}

static void IQFOLEDPresentControlMenu(UIViewController *controller) {
    if (controller == nil || controller.presentedViewController != nil) return;

    NSString *message = gIQFOLEDEnabled ? @"O modo OLED está ativado." : @"O modo OLED está desativado.";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Modo OLED"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:@"Cancelar"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    __weak UIViewController *weakController = controller;
    BOOL currentlyEnabled = gIQFOLEDEnabled;
    NSString *actionTitle = currentlyEnabled ? @"Desativar" : @"Ativar";
    UIAlertActionStyle actionStyle = currentlyEnabled ? UIAlertActionStyleDestructive : UIAlertActionStyleDefault;

    [alert addAction:[UIAlertAction actionWithTitle:actionTitle
                                              style:actionStyle
                                            handler:^(__unused UIAlertAction *action) {
        UIViewController *presenter = weakController;
        if (presenter == nil) return;
        IQFOLEDSetEnabled(!currentlyEnabled, presenter);
    }]];

    [controller presentViewController:alert animated:YES completion:nil];
}

static id IQFOLEDCreateNativeRow(UIViewController *controller) {
    SEL selector = NSSelectorFromString(@"valueRowWithTitle:icon:detail:tap:");
    if (controller == nil || ![controller respondsToSelector:selector]) return nil;

    __weak UIViewController *weakController = controller;
    void (^tapBlock)(void) = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            UIViewController *presenter = weakController;
            if (presenter == nil) return;
            IQFOLEDPresentControlMenu(presenter);
        });
    };

    typedef id (*IQFOLEDNativeRowBuilder)(id, SEL, id, id, id, id);
    IQFOLEDNativeRowBuilder builder = (IQFOLEDNativeRowBuilder)(void *)objc_msgSend;
    return builder(controller,
                   selector,
                   @"Modo OLED",
                   @"circle.lefthalf.filled",
                   IQFOLEDStatusText(),
                   [tapBlock copy]);
}

static void IQFOLEDInstallSettingsRow(UIViewController *controller) {
    if (controller == nil || objc_getAssociatedObject(controller, kIQFOLEDRowInstalledKey) != nil) return;

    NSArray *sections = IQFOLEDSections(controller);
    if (sections.count == 0) return;

    if (IQFOLEDFindOwnRow(sections) != nil) {
        objc_setAssociatedObject(controller,
                                 kIQFOLEDRowInstalledKey,
                                 @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        IQFOLEDRefreshSettingsRow(controller);
        return;
    }

    id toolsSection = IQFOLEDFindToolsSection(sections);
    if (toolsSection == nil) {
        NSLog(@"[iQFaceOLED] seção Ferramentas não encontrada; tela mantida intacta");
        return;
    }

    NSArray *rows = nil;
    @try {
        rows = [toolsSection valueForKey:@"rows"];
    } @catch (__unused NSException *exception) {
        rows = nil;
    }
    if (![rows isKindOfClass:NSArray.class]) return;

    id nativeRow = IQFOLEDCreateNativeRow(controller);
    Class rowClass = NSClassFromString(@"IQFRow");
    if (nativeRow == nil || rowClass == Nil || ![nativeRow isKindOfClass:rowClass]) {
        NSLog(@"[iQFaceOLED] construtor nativo de IQFRow indisponível");
        return;
    }

    NSMutableArray *updatedRows = [rows mutableCopy];
    NSUInteger insertionIndex = updatedRows.count;

    for (NSUInteger i = 0; i < updatedRows.count; i++) {
        NSString *title = IQFOLEDRowTitle(updatedRows[i]);
        if ([title isEqualToString:@"Limpar cache"] || [title isEqualToString:@"Clear cache"]) {
            insertionIndex = i + 1;
            break;
        }
    }

    if (insertionIndex == updatedRows.count) {
        for (NSUInteger i = 0; i < updatedRows.count; i++) {
            NSString *title = IQFOLEDRowTitle(updatedRows[i]);
            if ([title isEqualToString:@"Alterar ícone"] || [title isEqualToString:@"Change Icon"]) {
                insertionIndex = i + 1;
                break;
            }
        }
    }

    [updatedRows insertObject:nativeRow atIndex:MIN(insertionIndex, updatedRows.count)];

    @try {
        [toolsSection setValue:[updatedRows copy] forKey:@"rows"];
        objc_setAssociatedObject(controller,
                                 kIQFOLEDRowInstalledKey,
                                 @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        if ([controller isKindOfClass:UITableViewController.class]) {
            [((UITableViewController *)controller).tableView reloadData];
        }

        NSLog(@"[iQFaceOLED] linha Modo OLED adicionada (%@)", IQFOLEDStatusText());
    } @catch (__unused NSException *exception) {
        NSLog(@"[iQFaceOLED] não foi possível adicionar a linha; tela mantida intacta");
    }
}

static void IQFOLEDSettingsViewDidAppear(UIViewController *self, SEL command, BOOL animated) {
    if (IQFOLEDOriginalViewDidAppear != NULL) {
        IQFOLEDOriginalViewDidAppear(self, command, animated);
    }
    IQFOLEDInstallSettingsRow(self);
}

static void IQFOLEDTryInstallSettingsHook(void) {
    if (gIQFOLEDSettingsHookInstalled) return;

    gIQFOLEDSettingsHookAttempts += 1;
    Class target = NSClassFromString(@"IQFSettingsViewController");

    if (target != Nil) {
        SEL selector = @selector(viewDidAppear:);
        Method method = class_getInstanceMethod(target, selector);

        if (method != NULL) {
            IQFOLEDOriginalViewDidAppear = (void (*)(UIViewController *, SEL, BOOL))method_getImplementation(method);
            const char *types = method_getTypeEncoding(method);

            if (IQFOLEDClassImplementsSelector(target, selector)) {
                method_setImplementation(method, (IMP)&IQFOLEDSettingsViewDidAppear);
                gIQFOLEDSettingsHookInstalled = YES;
            } else if (class_addMethod(target, selector, (IMP)&IQFOLEDSettingsViewDidAppear, types)) {
                gIQFOLEDSettingsHookInstalled = YES;
            }
        }
    }

    if (!gIQFOLEDSettingsHookInstalled && gIQFOLEDSettingsHookAttempts < 120) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            IQFOLEDTryInstallSettingsHook();
        });
    }
}

__attribute__((constructor))
static void IQFOLEDInitialize(void) {
    @autoreleasepool {
        NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier;
        if (![bundleIdentifier isEqualToString:@"com.facebook.Facebook"] ||
            [NSBundle.mainBundle.bundlePath hasSuffix:@".appex"]) {
            return;
        }

        gIQFOLEDEnabled = IQFOLEDLoadEnabledPreference();
        IQFOLEDInstallInstantSetter();

        dispatch_async(dispatch_get_main_queue(), ^{
            IQFOLEDStartEngine();
            IQFOLEDTryInstallSettingsHook();
        });
    }
}
