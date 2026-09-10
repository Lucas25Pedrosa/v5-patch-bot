#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>

// FBOLED View Mapper 0.4.0
// Avatar-focused diagnostic for Facebook.
// IMPORTANT: this mapper does not hook methods and does not modify visual state.

static NSString *gMapPath;
static dispatch_queue_t gMapQueue;
static NSTimer *gTimer;
static NSUInteger gScanNumber = 0;

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
    return alpha >= 0.90 && (maximum - minimum) <= 0.035 && maximum <= 0.40;
}

static UIColor *LayerColor(UIView *view) {
    if (!view.layer.backgroundColor) return nil;
    @try {
        return [UIColor colorWithCGColor:view.layer.backgroundColor];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static BOOL ContainsImageView(UIView *view, NSUInteger depth) {
    if (!view || depth > 6) return NO;

    for (UIView *child in view.subviews) {
        if ([child isKindOfClass:UIImageView.class]) return YES;
        if (ContainsImageView(child, depth + 1)) return YES;
    }

    return NO;
}

static NSUInteger DirectImageViewCount(UIView *view) {
    NSUInteger count = 0;
    for (UIView *child in view.subviews) {
        if ([child isKindOfClass:UIImageView.class]) count++;
    }
    return count;
}

static BOOL IsCandidateSize(CGRect bounds) {
    CGFloat width = fabs(bounds.size.width);
    CGFloat height = fabs(bounds.size.height);

    if (!isfinite(width) || !isfinite(height)) return NO;
    if (width < 8.0 || height < 8.0) return NO;
    if (width > 180.0 || height > 180.0) return NO;
    return YES;
}

static void RecordView(UIView *view,
                       NSUInteger depth,
                       NSUInteger windowIndex,
                       NSUInteger *recorded) {
    if (!view || !recorded || *recorded >= 5000) return;
    if (view.hidden || view.alpha < 0.01) return;
    if (!IsCandidateSize(view.bounds)) return;

    UIView *parent = view.superview;
    UIView *grandparent = parent.superview;

    NSString *className = NSStringFromClass(view.class) ?: @"?";
    NSString *parentClass = parent ? (NSStringFromClass(parent.class) ?: @"?") : @"";
    NSString *grandparentClass = grandparent ? (NSStringFromClass(grandparent.class) ?: @"?") : @"";

    UIColor *viewColor = view.backgroundColor;
    UIColor *layerColor = LayerColor(view);

    NSString *viewHex = ColorHex(viewColor, view.traitCollection);
    NSString *layerHex = ColorHex(layerColor, view.traitCollection);

    BOOL neutralDark = IsNeutralDark(viewColor, view.traitCollection) ||
                       IsNeutralDark(layerColor, view.traitCollection);

    CGRect frame = view.frame;
    CGRect bounds = view.bounds;
    CGRect screenFrame = CGRectZero;
    @try {
        screenFrame = [view convertRect:view.bounds toView:nil];
    } @catch (__unused NSException *exception) {
    }

    CGFloat radius = view.layer.cornerRadius;
    BOOL isImageView = [view isKindOfClass:UIImageView.class];
    BOOL imagePresent = NO;
    if (isImageView) {
        imagePresent = ((UIImageView *)view).image != nil;
    }

    NSUInteger directImages = DirectImageViewCount(view);
    BOOL descendantImage = ContainsImageView(view, 0);

    BOOL approximatelySquare = fabs(bounds.size.width - bounds.size.height) <= 12.0;
    BOOL approximatelyCircular = approximatelySquare &&
                                 radius > 0.0 &&
                                 radius >= (MIN(fabs(bounds.size.width), fabs(bounds.size.height)) * 0.35);

    Append([NSString stringWithFormat:
            @"%@,%lu,%lu,%p,%p,%@,%@,%@,%@,%@,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%d,%d,%.3f,%d,%d,%d,%lu,%d,%d,%d,%lu,%lu",
            Stamp(),
            (unsigned long)gScanNumber,
            (unsigned long)windowIndex,
            (__bridge void *)view,
            (__bridge void *)parent,
            className,
            parentClass,
            grandparentClass,
            viewHex,
            layerHex,
            frame.origin.x,
            frame.origin.y,
            bounds.size.width,
            bounds.size.height,
            screenFrame.origin.x,
            screenFrame.origin.y,
            screenFrame.size.width,
            screenFrame.size.height,
            radius,
            view.layer.masksToBounds ? 1 : 0,
            view.clipsToBounds ? 1 : 0,
            view.alpha,
            isImageView ? 1 : 0,
            imagePresent ? 1 : 0,
            descendantImage ? 1 : 0,
            (unsigned long)directImages,
            neutralDark ? 1 : 0,
            approximatelySquare ? 1 : 0,
            approximatelyCircular ? 1 : 0,
            (unsigned long)view.subviews.count,
            (unsigned long)depth]);

    (*recorded)++;
}

static void Walk(UIView *view,
                 NSUInteger depth,
                 NSUInteger windowIndex,
                 NSUInteger *visited,
                 NSUInteger *recorded) {
    if (!view || !visited || !recorded) return;
    if (depth > 80 || *visited >= 30000 || *recorded >= 5000) return;

    (*visited)++;
    RecordView(view, depth, windowIndex, recorded);

    NSArray<UIView *> *children = [view.subviews copy];
    for (UIView *child in children) {
        Walk(child, depth + 1, windowIndex, visited, recorded);
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

static void Scan(void) {
    NSCAssert(NSThread.isMainThread, @"FBOLED avatar mapper must scan on main thread");

    @autoreleasepool {
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
                @"# %@ scan=%lu windows=%lu visited=%lu recorded=%lu",
                Stamp(),
                (unsigned long)gScanNumber,
                (unsigned long)windows.count,
                (unsigned long)visited,
                (unsigned long)recorded]);
    }
}

static void StartScanner(void) {
    if (gTimer) return;

    Scan();
    gTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                             repeats:YES
                                               block:^(__unused NSTimer *timer) {
        Scan();
    }];
    gTimer.tolerance = 0.20;

    Append([NSString stringWithFormat:@"# %@ scanner started interval=2.0s", Stamp()]);
}

__attribute__((constructor)) static void Init(void) {
    @autoreleasepool {
        gMapQueue = dispatch_queue_create("com.fboled.avatar-viewmapper", DISPATCH_QUEUE_SERIAL);

        NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                                   NSUserDomainMask,
                                                                   YES).firstObject;
        NSString *directory = [documents stringByAppendingPathComponent:@"FBOLED"];
        [NSFileManager.defaultManager createDirectoryAtPath:directory
                                withIntermediateDirectories:YES
                                                 attributes:nil
                                                      error:nil];

        gMapPath = [directory stringByAppendingPathComponent:@"FBOLED_AvatarMap.csv"];

        NSString *header = @"timestamp,scan,window,view_ptr,parent_ptr,view_class,parent_class,grandparent_class,view_rgba,layer_rgba,frame_x,frame_y,width,height,screen_x,screen_y,screen_width,screen_height,corner_radius,masks_to_bounds,clips_to_bounds,view_alpha,is_image_view,image_present,contains_image_view,direct_image_views,neutral_dark_candidate,approximately_square,approximately_circular,subview_count,depth\n";
        [header writeToFile:gMapPath
                 atomically:YES
                   encoding:NSUTF8StringEncoding
                      error:nil];

        Append([NSString stringWithFormat:
                @"# %@ START FBOLED View Mapper 0.4.0 avatar-focus bundle=%@",
                Stamp(),
                NSBundle.mainBundle.bundleIdentifier ?: @"?"]);

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            StartScanner();
        });
    }
}
