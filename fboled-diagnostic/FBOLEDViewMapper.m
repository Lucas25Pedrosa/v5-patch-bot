#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

static NSString *gMapPath;
static dispatch_queue_t gMapQueue;
static NSMutableSet<NSString *> *gSeen;
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

static BOOL Components(UIColor *input, UITraitCollection *traits,
                       CGFloat *red, CGFloat *green, CGFloat *blue, CGFloat *alpha) {
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

static NSString *Hex(CGFloat red, CGFloat green, CGFloat blue, CGFloat alpha) {
    int r = (int)(MAX(0.0, MIN(1.0, red)) * 255.0 + 0.5);
    int g = (int)(MAX(0.0, MIN(1.0, green)) * 255.0 + 0.5);
    int b = (int)(MAX(0.0, MIN(1.0, blue)) * 255.0 + 0.5);
    int a = (int)(MAX(0.0, MIN(1.0, alpha)) * 255.0 + 0.5);
    return [NSString stringWithFormat:@"#%02X%02X%02X%02X", r, g, b, a];
}

static void RecordColor(UIView *view, UIColor *color, NSString *source, NSUInteger depth) {
    CGFloat red = 0, green = 0, blue = 0, alpha = 0;
    if (!Components(color, view.traitCollection, &red, &green, &blue, &alpha)) return;

    NSString *className = NSStringFromClass(view.class) ?: @"?";
    NSString *hex = Hex(red, green, blue, alpha);
    NSString *key = [NSString stringWithFormat:@"%@|%@|%@", source, className, hex];

    @synchronized (gSeen) {
        if ([gSeen containsObject:key]) return;
        [gSeen addObject:key];
    }

    CGFloat maximum = MAX(red, MAX(green, blue));
    CGFloat minimum = MIN(red, MIN(green, blue));
    BOOL neutralDark = alpha >= 0.90 && (maximum - minimum) <= 0.035 && maximum <= 0.40;

    CGRect bounds = view.bounds;
    Append([NSString stringWithFormat:
            @"%@,%lu,%@,%@,%@,%.6f,%.6f,%.6f,%.6f,%d,%lu,%.1f,%.1f,%.3f,%d",
            Stamp(), (unsigned long)gScanNumber, source, className, hex,
            red, green, blue, alpha, neutralDark ? 1 : 0,
            (unsigned long)depth, bounds.size.width, bounds.size.height,
            view.alpha, view.hidden ? 1 : 0]);
}

static void Walk(UIView *view, NSUInteger depth, NSUInteger *count) {
    if (!view || depth > 80 || *count > 30000) return;
    (*count)++;

    if (view.backgroundColor) {
        RecordColor(view, view.backgroundColor, @"view", depth);
    }

    CGColorRef layerColor = view.layer.backgroundColor;
    if (layerColor) {
        @try {
            RecordColor(view, [UIColor colorWithCGColor:layerColor], @"layer", depth);
        } @catch (__unused NSException *exception) {
        }
    }

    NSArray<UIView *> *children = [view.subviews copy];
    for (UIView *child in children) {
        Walk(child, depth + 1, count);
    }
}

static void Scan(void) {
    NSCAssert(NSThread.isMainThread, @"FBOLED mapper must scan on main thread");
    @autoreleasepool {
        gScanNumber++;
        NSUInteger count = 0;
        NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if ([scene isKindOfClass:UIWindowScene.class]) {
                [windows addObjectsFromArray:((UIWindowScene *)scene).windows];
            }
        }
        for (UIWindow *window in windows) {
            Walk(window, 0, &count);
        }
        Append([NSString stringWithFormat:@"# %@ scan=%lu windows=%lu views=%lu unique=%lu",
                Stamp(), (unsigned long)gScanNumber, (unsigned long)windows.count,
                (unsigned long)count, (unsigned long)gSeen.count]);
    }
}

static void StartScanner(void) {
    if (gTimer) return;
    Scan();
    gTimer = [NSTimer scheduledTimerWithTimeInterval:3.0
                                             repeats:YES
                                               block:^(__unused NSTimer *timer) {
        Scan();
    }];
    Append([NSString stringWithFormat:@"# %@ scanner started", Stamp()]);
}

__attribute__((constructor)) static void Init(void) {
    @autoreleasepool {
        gMapQueue = dispatch_queue_create("com.fboled.viewmapper", DISPATCH_QUEUE_SERIAL);
        gSeen = [NSMutableSet set];

        NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                                   NSUserDomainMask, YES).firstObject;
        NSString *directory = [documents stringByAppendingPathComponent:@"FBOLED"];
        [NSFileManager.defaultManager createDirectoryAtPath:directory
                                withIntermediateDirectories:YES
                                                 attributes:nil
                                                      error:nil];
        gMapPath = [directory stringByAppendingPathComponent:@"FBOLED_ViewMap.csv"];

        NSString *header = @"timestamp,scan,source,view_class,rgba_hex,r,g,b,a,neutral_dark_candidate,depth,width,height,view_alpha,hidden\n";
        [header writeToFile:gMapPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        Append([NSString stringWithFormat:@"# %@ START FBOLED View Mapper 0.3.0 bundle=%@",
                Stamp(), NSBundle.mainBundle.bundleIdentifier ?: @"?"]);

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            StartScanner();
        });
    }
}
