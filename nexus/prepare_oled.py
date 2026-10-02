from pathlib import Path
import sys

src = Path(sys.argv[1])
out = Path(sys.argv[2])
s = src.read_text(encoding="utf-8")

old = '''        dispatch_async(dispatch_get_main_queue(), ^{
            IQFOLEDStartEngine();
            IQFOLEDTryInstallSettingsHook();
        });'''
assert old in s
s = s.replace(old, '''        dispatch_async(dispatch_get_main_queue(), ^{
            NexusOLEDStartupProbePrepare();
            IQFOLEDStartEngine();
        });''', 1)

probe = r'''
// Nexus 1.0.3 Beta 3 — integrated OLED startup probe -------------------------
// Same passive Facebook-style view mapper used by the proven diagnostics.
// No swizzle, no method replacement, no visual modification.

__attribute__((used, visibility("default")))
NSString * const NexusOLEDIntegratedProbeVersion = @"1.0.3 Beta 3";

static NSString *gNexusOLEDProbePath = nil;
static dispatch_queue_t gNexusOLEDProbeQueue;
static NSTimer *gNexusOLEDProbeTimer;
static NSUInteger gNexusOLEDProbeScanNumber = 0;
static CFTimeInterval gNexusOLEDProbeStart = 0.0;
static BOOL gNexusOLEDProbeDialogShown = NO;
static const CFTimeInterval kNexusOLEDProbeDuration = 8.0;
static const CFTimeInterval kNexusOLEDProbeInterval = 0.25;

static NSString *NexusOLEDProbeStamp(void) {
    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [NSDateFormatter new];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    });
    @synchronized (formatter) {
        return [formatter stringFromDate:[NSDate date]];
    }
}

static void NexusOLEDProbeAppend(NSString *line) {
    if (!line.length || !gNexusOLEDProbePath.length) return;
    dispatch_async(gNexusOLEDProbeQueue, ^{
        @autoreleasepool {
            NSData *data = [[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
            NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:gNexusOLEDProbePath];
            if (!handle) {
                [data writeToFile:gNexusOLEDProbePath atomically:YES];
                return;
            }
            @try {
                [handle seekToEndOfFile];
                [handle writeData:data];
            } @catch (__unused NSException *exception) {
            }
            [handle closeFile];
        }
    });
}

static BOOL NexusOLEDProbeColorComponents(UIColor *input,
                                          UITraitCollection *traits,
                                          CGFloat *red,
                                          CGFloat *green,
                                          CGFloat *blue,
                                          CGFloat *alpha) {
    if (!input) return NO;

    UIColor *color = input;
    @try {
        if (@available(iOS 13.0, *)) {
            color = [input resolvedColorWithTraitCollection:traits ?: UITraitCollection.currentTraitCollection];
        }
        if ([color getRed:red green:green blue:blue alpha:alpha]) return YES;

        CGFloat white = 0.0;
        if ([color getWhite:&white alpha:alpha]) {
            *red = *green = *blue = white;
            return YES;
        }
    } @catch (__unused NSException *exception) {
    }
    return NO;
}

static NSString *NexusOLEDProbeColorHex(UIColor *color, UITraitCollection *traits) {
    if (!color) return @"";
    CGFloat red = 0.0, green = 0.0, blue = 0.0, alpha = 0.0;
    if (!NexusOLEDProbeColorComponents(color, traits, &red, &green, &blue, &alpha)) {
        return @"unresolved";
    }

    int r = (int)(MAX(0.0, MIN(1.0, red)) * 255.0 + 0.5);
    int g = (int)(MAX(0.0, MIN(1.0, green)) * 255.0 + 0.5);
    int b = (int)(MAX(0.0, MIN(1.0, blue)) * 255.0 + 0.5);
    int a = (int)(MAX(0.0, MIN(1.0, alpha)) * 255.0 + 0.5);
    return [NSString stringWithFormat:@"#%02X%02X%02X%02X", r, g, b, a];
}

static BOOL NexusOLEDProbeIsNeutralDark(UIColor *color, UITraitCollection *traits) {
    if (!color) return NO;

    CGFloat red = 0.0, green = 0.0, blue = 0.0, alpha = 0.0;
    if (!NexusOLEDProbeColorComponents(color, traits, &red, &green, &blue, &alpha)) return NO;

    CGFloat maximum = MAX(red, MAX(green, blue));
    CGFloat minimum = MIN(red, MIN(green, blue));
    return alpha >= 0.80 && maximum <= 0.60 && (maximum - minimum) <= 0.14;
}

static BOOL NexusOLEDProbeMappedHex(NSString *hex) {
    return [hex isEqualToString:@"#101011FF"] ||
           [hex isEqualToString:@"#1F1F22FF"] ||
           [hex isEqualToString:@"#252728FF"] ||
           [hex isEqualToString:@"#28292CFF"];
}

static UIColor *NexusOLEDProbeLayerColor(UIView *view) {
    if (!view.layer.backgroundColor) return nil;
    @try {
        return [UIColor colorWithCGColor:view.layer.backgroundColor];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSArray<UIWindow *> *NexusOLEDProbeWindows(void) {
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        if (windowScene.activationState == UISceneActivationStateUnattached) continue;
        [windows addObjectsFromArray:windowScene.windows];
    }
    return windows;
}

static void NexusOLEDProbeRecordView(UIView *view,
                                     NSUInteger depth,
                                     NSUInteger windowIndex,
                                     NSUInteger *recorded) {
    if (!view || !recorded || *recorded >= 3000) return;
    if (view.hidden || view.alpha < 0.01) return;

    UIColor *viewColor = view.backgroundColor;
    UIColor *layerColor = NexusOLEDProbeLayerColor(view);

    BOOL viewCandidate = NexusOLEDProbeIsNeutralDark(viewColor, view.traitCollection);
    BOOL layerCandidate = NexusOLEDProbeIsNeutralDark(layerColor, view.traitCollection);
    if (!viewCandidate && !layerCandidate) return;

    NSString *viewHex = NexusOLEDProbeColorHex(viewColor, view.traitCollection);
    NSString *layerHex = NexusOLEDProbeColorHex(layerColor, view.traitCollection);
    BOOL mapped = NexusOLEDProbeMappedHex(viewHex) || NexusOLEDProbeMappedHex(layerHex);

    UIView *parent = view.superview;
    CGRect bounds = view.bounds;
    CGRect screenFrame = CGRectZero;
    @try {
        screenFrame = [view convertRect:view.bounds toView:nil];
    } @catch (__unused NSException *exception) {
    }

    CFTimeInterval elapsed = CACurrentMediaTime() - gNexusOLEDProbeStart;

    NexusOLEDProbeAppend([NSString stringWithFormat:
        @"%@,%.3f,%lu,%lu,%lu,%p,%@,%@,%@,%@,%.1f,%.1f,%.1f,%.1f,%.3f,%d,%lu",
        NexusOLEDProbeStamp(),
        elapsed,
        (unsigned long)gNexusOLEDProbeScanNumber,
        (unsigned long)windowIndex,
        (unsigned long)depth,
        (__bridge void *)view,
        NSStringFromClass(view.class) ?: @"?",
        parent ? (NSStringFromClass(parent.class) ?: @"?") : @"",
        viewHex,
        layerHex,
        bounds.size.width,
        bounds.size.height,
        screenFrame.size.width,
        screenFrame.size.height,
        view.alpha,
        mapped ? 1 : 0,
        (unsigned long)view.subviews.count]);

    (*recorded)++;
}

static void NexusOLEDProbeWalk(UIView *view,
                               NSUInteger depth,
                               NSUInteger windowIndex,
                               NSUInteger *visited,
                               NSUInteger *recorded) {
    if (!view || !visited || !recorded) return;
    if (depth > 80 || *visited >= 30000 || *recorded >= 3000) return;

    (*visited)++;
    NexusOLEDProbeRecordView(view, depth, windowIndex, recorded);

    NSArray<UIView *> *children = [view.subviews copy];
    for (UIView *child in children) {
        NexusOLEDProbeWalk(child, depth + 1, windowIndex, visited, recorded);
    }
}

static UIViewController *NexusOLEDProbeTopController(void) {
    UIWindow *bestWindow = nil;
    for (UIWindow *window in NexusOLEDProbeWindows()) {
        if (window.hidden || window.alpha <= 0.01) continue;
        if (!bestWindow || window.isKeyWindow) bestWindow = window;
        if (window.isKeyWindow) break;
    }

    UIViewController *controller = bestWindow.rootViewController;
    if (!controller) return nil;

    BOOL advanced = YES;
    while (advanced) {
        advanced = NO;

        if (controller.presentedViewController &&
            !controller.presentedViewController.isBeingDismissed) {
            controller = controller.presentedViewController;
            advanced = YES;
            continue;
        }

        if ([controller isKindOfClass:UINavigationController.class]) {
            UIViewController *visible =
                ((UINavigationController *)controller).visibleViewController;
            if (visible && visible != controller) {
                controller = visible;
                advanced = YES;
                continue;
            }
        }

        if ([controller isKindOfClass:UITabBarController.class]) {
            UIViewController *selected =
                ((UITabBarController *)controller).selectedViewController;
            if (selected && selected != controller) {
                controller = selected;
                advanced = YES;
                continue;
            }
        }
    }

    return controller;
}

static void NexusOLEDProbePresentCopyDialog(void) {
    if (gNexusOLEDProbeDialogShown) return;
    gNexusOLEDProbeDialogShown = YES;

    dispatch_async(gNexusOLEDProbeQueue, ^{
        NSString *log =
            [NSString stringWithContentsOfFile:gNexusOLEDProbePath
                                      encoding:NSUTF8StringEncoding
                                         error:nil] ?: @"";

        dispatch_async(dispatch_get_main_queue(), ^{
            UIViewController *presenter = NexusOLEDProbeTopController();
            if (!presenter) {
                gNexusOLEDProbeDialogShown = NO;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                             (int64_t)(0.75 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    NexusOLEDProbePresentCopyDialog();
                });
                return;
            }

            NSString *message = log.length > 0
                ? [NSString stringWithFormat:
                    @"Captura OLED concluída (%lu caracteres). Toque em Copiar log e envie o conteúdo no chat.",
                    (unsigned long)log.length]
                : @"A captura terminou, mas o arquivo de log ficou vazio.";

            UIAlertController *alert =
                [UIAlertController alertControllerWithTitle:@"Nexus OLED Probe"
                                                    message:message
                                             preferredStyle:UIAlertControllerStyleAlert];

            if (log.length > 0) {
                [alert addAction:
                    [UIAlertAction actionWithTitle:@"Copiar log"
                                             style:UIAlertActionStyleDefault
                                           handler:^(__unused UIAlertAction *action) {
                        UIPasteboard.generalPasteboard.string = log;
                    }]];
            }

            [alert addAction:
                [UIAlertAction actionWithTitle:@"Fechar"
                                         style:UIAlertActionStyleCancel
                                       handler:nil]];

            @try {
                [presenter presentViewController:alert animated:YES completion:nil];
            } @catch (__unused NSException *exception) {
                gNexusOLEDProbeDialogShown = NO;
            }
        });
    });
}

static void NexusOLEDStartupProbeScan(void) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ NexusOLEDStartupProbeScan(); });
        return;
    }

    CFTimeInterval elapsed = CACurrentMediaTime() - gNexusOLEDProbeStart;
    if (elapsed > kNexusOLEDProbeDuration) {
        [gNexusOLEDProbeTimer invalidate];
        gNexusOLEDProbeTimer = nil;
        NexusOLEDProbeAppend([NSString stringWithFormat:
            @"# %@ END scans=%lu elapsed=%.3f",
            NexusOLEDProbeStamp(),
            (unsigned long)gNexusOLEDProbeScanNumber,
            elapsed]);

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(0.35 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            NexusOLEDProbePresentCopyDialog();
        });
        return;
    }

    gNexusOLEDProbeScanNumber++;

    NSUInteger visited = 0;
    NSUInteger recorded = 0;
    NSArray<UIWindow *> *windows = NexusOLEDProbeWindows();

    NSUInteger windowIndex = 0;
    for (UIWindow *window in windows) {
        NexusOLEDProbeWalk(window, 0, windowIndex, &visited, &recorded);
        windowIndex++;
    }

    NexusOLEDProbeAppend([NSString stringWithFormat:
        @"# %@ scan=%lu elapsed=%.3f windows=%lu visited=%lu recorded=%lu",
        NexusOLEDProbeStamp(),
        (unsigned long)gNexusOLEDProbeScanNumber,
        elapsed,
        (unsigned long)windows.count,
        (unsigned long)visited,
        (unsigned long)recorded]);
}

static void NexusOLEDStartupProbePrepare(void) {
    if (gNexusOLEDProbePath.length > 0) return;

    gNexusOLEDProbeQueue =
        dispatch_queue_create("com.lucas.nexus.oledstartup.integrated", DISPATCH_QUEUE_SERIAL);

    NSString *documents =
        NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject
        ?: NSTemporaryDirectory();

    gNexusOLEDProbePath =
        [documents stringByAppendingPathComponent:@"NexusOLEDStartupProbe.txt"];

    [[NSFileManager defaultManager] createFileAtPath:gNexusOLEDProbePath
                                           contents:nil
                                         attributes:nil];

    gNexusOLEDProbeStart = CACurrentMediaTime();

    NexusOLEDProbeAppend(@"Nexus OLED Startup Probe — Integrated 1.0.3 Beta 3");
    NexusOLEDProbeAppend(@"Passive diagnostic inside Nexus; no probe hook or visual modification.");
    NexusOLEDProbeAppend([NSString stringWithFormat:
        @"%@ START bundle=%@ app=%@ build=%@ iOS=%@ device=%@",
        NexusOLEDProbeStamp(),
        NSBundle.mainBundle.bundleIdentifier ?: @"?",
        NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"?",
        NSBundle.mainBundle.infoDictionary[@"CFBundleVersion"] ?: @"?",
        UIDevice.currentDevice.systemVersion ?: @"?",
        UIDevice.currentDevice.model ?: @"?"]);
    NexusOLEDProbeAppend(@"timestamp,elapsed,scan,window,depth,view_ptr,view_class,parent_class,view_rgba,layer_rgba,width,height,screen_width,screen_height,view_alpha,mapped_dark,subview_count");

    // Initial snapshot before the normal OLED pass.
    NexusOLEDStartupProbeScan();

    gNexusOLEDProbeTimer = [NSTimer timerWithTimeInterval:kNexusOLEDProbeInterval
                                                  repeats:YES
                                                    block:^(__unused NSTimer *timer) {
        NexusOLEDStartupProbeScan();
    }];
    gNexusOLEDProbeTimer.tolerance = 0.02;
    [NSRunLoop.mainRunLoop addTimer:gNexusOLEDProbeTimer forMode:NSRunLoopCommonModes];
}
'''

insert_before = '__attribute__((constructor))\nstatic void IQFOLEDInitialize(void) {'
assert insert_before in s
s = s.replace(insert_before, probe + '\n' + insert_before, 1)

s += '''

id NexusOLEDCreateModeSetting(void) {
    return IQFOLEDCreateNativeIconRow(@"Modo OLED", @"circle.lefthalf.filled");
}
id NexusOLEDCreateSeparatorSetting(void) {
    return IQFOLEDCreateNativeIconRow(@"Separadores no feed", @"line.3.horizontal");
}
void NexusOLEDPrepareSettingsCell(void) {
    IQFOLEDTryInstallAccessorySwitchHook();
}
'''

out.write_text(s, encoding="utf-8")
print("Prepared Nexus integrated OLED startup probe 1.0.3 Beta 3")
