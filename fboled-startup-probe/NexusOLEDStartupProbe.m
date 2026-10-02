#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>

// Nexus OLED Startup Probe 0.2.0
// Facebook-style passive view mapper based on the proven FBOLEDViewMapper.
// No hooks, no swizzle, no method replacement and no visual modification.
// Purpose: capture the startup gray shown before Nexus OLED takes over.

static NSString *gMapPath;
static dispatch_queue_t gMapQueue;
static NSTimer *gTimer;
static NSUInteger gScanNumber = 0;
static CFTimeInterval gStartTime = 0.0;
static const CFTimeInterval kProbeDuration = 8.0;
static const CFTimeInterval kScanInterval = 0.25;

static NSString *Stamp(void) {
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

static void Append(NSString *line) {
    if (!line.length || !gMapPath.length) return;
    dispatch_async(gMapQueue, ^{
        @autoreleasepool {
            NSData *data = [[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
            NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:gMapPath];
            if (!handle) {
                [data writeToFile:gMapPath atomically:YES];
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

static BOOL ColorComponents(UIColor *input,
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

static NSString *ColorHex(UIColor *color, UITraitCollection *traits) {
    if (!color) return @"";

    CGFloat red = 0.0;
    CGFloat green = 0.0;
    CGFloat blue = 0.0;
    CGFloat alpha = 0.0;

    if (!ColorComponents(color, traits, &red, &green, &blue, &alpha)) return @"unresolved";

    int r = (int)(MAX(0.0, MIN(1.0, red)) * 255.0 + 0.5);
    int g = (int)(MAX(0.0, MIN(1.0, green)) * 255.0 + 0.5);
    int b = (int)(MAX(0.0, MIN(1.0, blue)) * 255.0 + 0.5);
    int a = (int)(MAX(0.0, MIN(1.0, alpha)) * 255.0 + 0.5);

    return [NSString stringWithFormat:@"#%02X%02X%02X%02X", r, g, b, a];
}

static BOOL IsNeutralDark(UIColor *color, UITraitCollection *traits) {
    if (!color) return NO;

    CGFloat red = 0.0;
    CGFloat green = 0.0;
    CGFloat blue = 0.0;
    CGFloat alpha = 0.0;

    if (!ColorComponents(color, traits, &red, &green, &blue, &alpha)) return NO;

    CGFloat maximum = MAX(red, MAX(green, blue));
    CGFloat minimum = MIN(red, MIN(green, blue));

    // Broad enough to catch Facebook's startup gray while excluding colorful UI.
    return alpha >= 0.80 && maximum <= 0.58 && (maximum - minimum) <= 0.12;
}

static BOOL IsKnownMappedDarkHex(NSString *hex) {
    return [hex isEqualToString:@"#101011FF"] ||
           [hex isEqualToString:@"#1F1F22FF"] ||
           [hex isEqualToString:@"#252728FF"] ||
           [hex isEqualToString:@"#28292CFF"];
}

static BOOL IsBlackHex(NSString *hex) {
    return [hex isEqualToString:@"#000000FF"];
}

static UIColor *LayerColor(UIView *view) {
    if (!view.layer.backgroundColor) return nil;
    @try {
        return [UIColor colorWithCGColor:view.layer.backgroundColor];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSArray<UIWindow *> *VisibleWindows(void) {
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];

    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        if (windowScene.activationState == UISceneActivationStateUnattached) continue;
        [windows addObjectsFromArray:windowScene.windows];
    }

    return windows;
}

static void RecordView(UIView *view,
                       NSUInteger depth,
                       NSUInteger windowIndex,
                       NSUInteger *recorded) {
    if (!view || !recorded || *recorded >= 2500) return;
    if (view.hidden || view.alpha < 0.01) return;

    UIColor *viewColor = view.backgroundColor;
    UIColor *layerColor = LayerColor(view);

    BOOL viewCandidate = IsNeutralDark(viewColor, view.traitCollection);
    BOOL layerCandidate = IsNeutralDark(layerColor, view.traitCollection);
    if (!viewCandidate && !layerCandidate) return;

    NSString *viewHex = ColorHex(viewColor, view.traitCollection);
    NSString *layerHex = ColorHex(layerColor, view.traitCollection);

    UIView *parent = view.superview;
    NSString *className = NSStringFromClass(view.class) ?: @"?";
    NSString *parentClass = parent ? (NSStringFromClass(parent.class) ?: @"?") : @"";

    CGRect bounds = view.bounds;
    CGRect screenFrame = CGRectZero;
    @try {
        screenFrame = [view convertRect:view.bounds toView:nil];
    } @catch (__unused NSException *exception) {
    }

    BOOL mappedDark = IsKnownMappedDarkHex(viewHex) || IsKnownMappedDarkHex(layerHex);
    BOOL black = IsBlackHex(viewHex) || IsBlackHex(layerHex);
    CFTimeInterval elapsed = CACurrentMediaTime() - gStartTime;

    Append([NSString stringWithFormat:
            @"%@,%.3f,%lu,%lu,%lu,%p,%@,%@,%@,%@,%.2f,%.2f,%.2f,%.2f,%.3f,%d,%d,%lu",
            Stamp(),
            elapsed,
            (unsigned long)gScanNumber,
            (unsigned long)windowIndex,
            (unsigned long)depth,
            (__bridge void *)view,
            className,
            parentClass,
            viewHex,
            layerHex,
            bounds.size.width,
            bounds.size.height,
            screenFrame.size.width,
            screenFrame.size.height,
            view.alpha,
            mappedDark ? 1 : 0,
            black ? 1 : 0,
            (unsigned long)view.subviews.count]);

    (*recorded)++;
}

static void Walk(UIView *view,
                 NSUInteger depth,
                 NSUInteger windowIndex,
                 NSUInteger *visited,
                 NSUInteger *recorded) {
    if (!view || !visited || !recorded) return;
    if (depth > 80 || *visited >= 30000 || *recorded >= 2500) return;

    (*visited)++;
    RecordView(view, depth, windowIndex, recorded);

    NSArray<UIView *> *children = [view.subviews copy];
    for (UIView *child in children) {
        Walk(child, depth + 1, windowIndex, visited, recorded);
    }
}

static void Scan(void) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ Scan(); });
        return;
    }

    @autoreleasepool {
        CFTimeInterval elapsed = CACurrentMediaTime() - gStartTime;
        if (elapsed > kProbeDuration) {
            [gTimer invalidate];
            gTimer = nil;
            Append([NSString stringWithFormat:
                    @"# %@ END Nexus OLED Startup Probe 0.2.0 scans=%lu elapsed=%.3f",
                    Stamp(),
                    (unsigned long)gScanNumber,
                    elapsed]);
            return;
        }

        gScanNumber++;

        NSUInteger visited = 0;
        NSUInteger recorded = 0;
        NSArray<UIWindow *> *windows = VisibleWindows();

        NSUInteger windowIndex = 0;
        for (UIWindow *window in windows) {
            Walk(window, 0, windowIndex, &visited, &recorded);
            windowIndex++;
        }

        Append([NSString stringWithFormat:
                @"# %@ scan=%lu elapsed=%.3f windows=%lu visited=%lu recorded=%lu",
                Stamp(),
                (unsigned long)gScanNumber,
                elapsed,
                (unsigned long)windows.count,
                (unsigned long)visited,
                (unsigned long)recorded]);
    }
}

static void StartScanner(void) {
    if (gTimer) return;

    Scan();

    gTimer = [NSTimer timerWithTimeInterval:kScanInterval
                                     repeats:YES
                                       block:^(__unused NSTimer *timer) {
        Scan();
    }];
    gTimer.tolerance = 0.02;
    [NSRunLoop.mainRunLoop addTimer:gTimer forMode:NSRunLoopCommonModes];

    Append([NSString stringWithFormat:
            @"# %@ scanner started interval=%.2fs duration=%.1fs",
            Stamp(),
            kScanInterval,
            kProbeDuration]);
}

__attribute__((constructor)) static void Init(void) {
    @autoreleasepool {
        if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.facebook.Facebook"] ||
            [NSBundle.mainBundle.bundlePath hasSuffix:@".appex"]) {
            return;
        }

        gMapQueue = dispatch_queue_create("com.nexus.oled-startup-viewmapper", DISPATCH_QUEUE_SERIAL);

        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                                       NSUserDomainMask,
                                                                       YES).firstObject
                ?: NSTemporaryDirectory();
            gMapPath = [documents stringByAppendingPathComponent:@"NexusOLEDStartupProbe.txt"];

            [[NSFileManager defaultManager] createFileAtPath:gMapPath
                                                   contents:nil
                                                 attributes:nil];

            gStartTime = CACurrentMediaTime();

            Append(@"Nexus OLED Startup Probe 0.2.0");
            Append(@"Facebook-style startup diagnostic; no UI state or colors are modified.");
            Append([NSString stringWithFormat:
                    @"%@ START bundle=%@ app=%@ build=%@ iOS=%@ device=%@",
                    Stamp(),
                    NSBundle.mainBundle.bundleIdentifier ?: @"?",
                    NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"?",
                    NSBundle.mainBundle.infoDictionary[@"CFBundleVersion"] ?: @"?",
                    UIDevice.currentDevice.systemVersion ?: @"?",
                    UIDevice.currentDevice.model ?: @"?"]);
            Append(@"timestamp,elapsed,scan,window,depth,view_ptr,view_class,parent_class,view_rgba,layer_rgba,width,height,screen_width,screen_height,view_alpha,mapped_dark,black,subview_count");

            StartScanner();
        });
    }
}
