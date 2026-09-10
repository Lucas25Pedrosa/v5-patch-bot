#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>

// FBOLED View Mapper 0.5.0
// Read-only avatar layer/image diagnostic for Facebook.
// IMPORTANT: no hooks, no swizzling, no visual modifications.

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

static NSString *CSVSafe(NSString *value) {
    if (!value.length) return @"";
    NSString *s = [value stringByReplacingOccurrencesOfString:@"\"" withString:@"\"\""];
    if ([s containsString:@","] || [s containsString:@"\""] || [s containsString:@"\n"]) {
        return [NSString stringWithFormat:@"\"%@\"", s];
    }
    return s;
}

static NSString *F2(CGFloat value) {
    return isfinite(value) ? [NSString stringWithFormat:@"%.2f", value] : @"";
}

static NSString *F3(CGFloat value) {
    return isfinite(value) ? [NSString stringWithFormat:@"%.3f", value] : @"";
}

static NSString *UL(NSUInteger value) {
    return [NSString stringWithFormat:@"%lu", (unsigned long)value];
}

static NSString *UI(unsigned int value) {
    return [NSString stringWithFormat:@"%u", value];
}

static NSString *LI(NSInteger value) {
    return [NSString stringWithFormat:@"%ld", (long)value];
}

static NSString *Ptr(const void *value) {
    return value ? [NSString stringWithFormat:@"%p", value] : @"";
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
    CGFloat r = 0.0, g = 0.0, b = 0.0, a = 0.0;
    if (!ColorComponents(color, traits, &r, &g, &b, &a)) return @"unresolved";
    int ri = (int)(MAX(0.0, MIN(1.0, r)) * 255.0 + 0.5);
    int gi = (int)(MAX(0.0, MIN(1.0, g)) * 255.0 + 0.5);
    int bi = (int)(MAX(0.0, MIN(1.0, b)) * 255.0 + 0.5);
    int ai = (int)(MAX(0.0, MIN(1.0, a)) * 255.0 + 0.5);
    return [NSString stringWithFormat:@"#%02X%02X%02X%02X", ri, gi, bi, ai];
}

static NSString *CGColorHex(CGColorRef color, UITraitCollection *traits) {
    if (!color) return @"";
    @try {
        return ColorHex([UIColor colorWithCGColor:color], traits);
    } @catch (__unused NSException *exception) {
        return @"unresolved";
    }
}

static BOOL IsAvatarClassName(NSString *name) {
    if (!name.length) return NO;
    NSArray<NSString *> *tokens = @[
        @"ProfilePhoto", @"Image", @"MaskedRounded", @"Passthrough", @"Avatar", @"Ring"
    ];
    for (NSString *token in tokens) {
        if ([name rangeOfString:token options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return YES;
        }
    }
    return NO;
}

static BOOL ContainsImageView(UIView *view, NSUInteger depth) {
    if (!view || depth > 6) return NO;
    for (UIView *child in view.subviews) {
        if ([child isKindOfClass:UIImageView.class]) return YES;
        if (ContainsImageView(child, depth + 1)) return YES;
    }
    return NO;
}

static BOOL IsAvatarCandidate(UIView *view) {
    if (!view || view.hidden || view.alpha < 0.01) return NO;

    CGRect b = view.bounds;
    CGFloat w = fabs(b.size.width);
    CGFloat h = fabs(b.size.height);
    if (!isfinite(w) || !isfinite(h)) return NO;
    if (w < 16.0 || h < 16.0 || w > 72.0 || h > 72.0) return NO;
    if (fabs(w - h) > 12.0) return NO;

    NSString *className = NSStringFromClass(view.class) ?: @"";
    if ([view isKindOfClass:UIImageView.class]) return YES;
    if (IsAvatarClassName(className)) return YES;
    if (ContainsImageView(view, 0)) return YES;
    if (view.layer.cornerRadius >= MIN(w, h) * 0.35) return YES;
    return NO;
}

static NSString *PixelHex(const uint8_t *p) {
    if (!p) return @"";
    return [NSString stringWithFormat:@"#%02X%02X%02X%02X", p[0], p[1], p[2], p[3]];
}

static NSDictionary<NSString *, NSString *> *ImageSamples(UIImage *image) {
    CGImageRef cg = image.CGImage;
    if (!cg) return @{};

    const size_t width = 5;
    const size_t height = 5;
    const size_t bytesPerPixel = 4;
    const size_t bytesPerRow = width * bytesPerPixel;
    uint8_t pixels[5 * 5 * 4];
    memset(pixels, 0, sizeof(pixels));

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    if (!colorSpace) return @{};

    CGBitmapInfo bitmapInfo = kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big;
    CGContextRef context = CGBitmapContextCreate(pixels,
                                                 width,
                                                 height,
                                                 8,
                                                 bytesPerRow,
                                                 colorSpace,
                                                 bitmapInfo);
    CGColorSpaceRelease(colorSpace);
    if (!context) return @{};

    CGContextSetBlendMode(context, kCGBlendModeCopy);
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), cg);
    CGContextRelease(context);

    return @{
        @"tl": PixelHex(&pixels[(0 * width + 0) * 4]),
        @"tr": PixelHex(&pixels[(0 * width + 4) * 4]),
        @"bl": PixelHex(&pixels[(4 * width + 0) * 4]),
        @"br": PixelHex(&pixels[(4 * width + 4) * 4]),
        @"center": PixelHex(&pixels[(2 * width + 2) * 4])
    };
}

static void EmitRow(NSArray<NSString *> *columns) {
    NSMutableArray<NSString *> *safe = [NSMutableArray arrayWithCapacity:columns.count];
    for (NSString *column in columns) {
        [safe addObject:CSVSafe(column ?: @"")];
    }
    Append([safe componentsJoinedByString:@","]);
}

static NSArray<NSString *> *BaseColumns(NSString *recordType,
                                        NSUInteger windowIndex,
                                        UIView *view,
                                        CALayer *layer,
                                        NSUInteger layerDepth) {
    CGRect screenFrame = CGRectZero;
    @try {
        screenFrame = [view convertRect:view.bounds toView:nil];
    } @catch (__unused NSException *exception) {
    }

    NSString *viewClass = NSStringFromClass(view.class) ?: @"?";
    NSString *parentClass = view.superview ? (NSStringFromClass(view.superview.class) ?: @"?") : @"";
    NSString *layerClass = layer ? (NSStringFromClass(layer.class) ?: @"?") : @"";

    CGRect layerFrame = layer ? layer.frame : CGRectZero;
    CGRect layerBounds = layer ? layer.bounds : CGRectZero;

    return @[
        Stamp(),
        UL(gScanNumber),
        recordType ?: @"",
        UL(windowIndex),
        Ptr((__bridge void *)view),
        viewClass,
        parentClass,
        F2(screenFrame.origin.x),
        F2(screenFrame.origin.y),
        F2(screenFrame.size.width),
        F2(screenFrame.size.height),
        Ptr((__bridge void *)layer),
        layerClass,
        UL(layerDepth),
        layer ? CGColorHex(layer.backgroundColor, view.traitCollection) : @"",
        layer ? F3(layer.cornerRadius) : @"",
        layer ? (layer.masksToBounds ? @"1" : @"0") : @"",
        layer ? F3(layer.opacity) : @"",
        layer ? (layer.hidden ? @"1" : @"0") : @"",
        layer ? F2(layerFrame.origin.x) : @"",
        layer ? F2(layerFrame.origin.y) : @"",
        layer ? F2(layerBounds.size.width) : @"",
        layer ? F2(layerBounds.size.height) : @"",
        layer ? (layer.contents ? @"1" : @"0") : @""
    ];
}

static void RecordLayerTree(CALayer *layer,
                            UIView *owner,
                            NSUInteger layerDepth,
                            NSUInteger windowIndex,
                            NSUInteger *recorded) {
    if (!layer || !owner || !recorded || *recorded >= 12000 || layerDepth > 5) return;

    NSMutableArray<NSString *> *row =
        [BaseColumns(@"LAYER", windowIndex, owner, layer, layerDepth) mutableCopy];

    [row addObjectsFromArray:@[
        @"", @"", @"", @"", @"", @"", @"", @"", @"", @"", @"", @"", @""
    ]];

    EmitRow(row);
    (*recorded)++;

    for (CALayer *child in [layer.sublayers copy]) {
        RecordLayerTree(child, owner, layerDepth + 1, windowIndex, recorded);
    }
}

static void RecordImage(UIImageView *imageView,
                        NSUInteger windowIndex,
                        NSUInteger *recorded) {
    if (!imageView || !recorded || *recorded >= 12000) return;

    UIImage *image = imageView.image;
    if (!image) return;

    NSMutableArray<NSString *> *row =
        [BaseColumns(@"IMAGE", windowIndex, imageView, imageView.layer, 0) mutableCopy];

    CGImageRef cg = image.CGImage;
    size_t cgWidth = cg ? CGImageGetWidth(cg) : 0;
    size_t cgHeight = cg ? CGImageGetHeight(cg) : 0;
    CGImageAlphaInfo alphaInfo = cg ? CGImageGetAlphaInfo(cg) : kCGImageAlphaNone;
    NSDictionary<NSString *, NSString *> *samples = ImageSamples(image);

    [row addObjectsFromArray:@[
        @"1",
        F2(image.size.width),
        F2(image.size.height),
        F3(image.scale),
        LI(image.renderingMode),
        UL(cgWidth),
        UL(cgHeight),
        UI((unsigned int)alphaInfo),
        samples[@"tl"] ?: @"",
        samples[@"tr"] ?: @"",
        samples[@"bl"] ?: @"",
        samples[@"br"] ?: @"",
        samples[@"center"] ?: @""
    ]];

    EmitRow(row);
    (*recorded)++;
}

static void RecordCandidate(UIView *view,
                            NSUInteger windowIndex,
                            NSUInteger *recorded) {
    if (!IsAvatarCandidate(view) || !recorded || *recorded >= 12000) return;

    RecordLayerTree(view.layer, view, 0, windowIndex, recorded);

    if ([view isKindOfClass:UIImageView.class]) {
        RecordImage((UIImageView *)view, windowIndex, recorded);
    }
}

static void Walk(UIView *view,
                 NSUInteger depth,
                 NSUInteger windowIndex,
                 NSUInteger *visited,
                 NSUInteger *recorded) {
    if (!view || !visited || !recorded) return;
    if (depth > 80 || *visited >= 30000 || *recorded >= 12000) return;

    (*visited)++;
    RecordCandidate(view, windowIndex, recorded);

    for (UIView *child in [view.subviews copy]) {
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
    NSCAssert(NSThread.isMainThread, @"FBOLED layer mapper must scan on main thread");

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
    gTimer = [NSTimer scheduledTimerWithTimeInterval:2.5
                                             repeats:YES
                                               block:^(__unused NSTimer *timer) {
        Scan();
    }];
    gTimer.tolerance = 0.25;

    Append([NSString stringWithFormat:@"# %@ scanner started interval=2.5s", Stamp()]);
}

__attribute__((constructor)) static void Init(void) {
    @autoreleasepool {
        gMapQueue = dispatch_queue_create("com.fboled.avatar-layer-mapper", DISPATCH_QUEUE_SERIAL);

        NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                                   NSUserDomainMask,
                                                                   YES).firstObject;
        NSString *directory = [documents stringByAppendingPathComponent:@"FBOLED"];
        [NSFileManager.defaultManager createDirectoryAtPath:directory
                                withIntermediateDirectories:YES
                                                 attributes:nil
                                                      error:nil];

        gMapPath = [directory stringByAppendingPathComponent:@"FBOLED_AvatarLayers.csv"];

        NSString *header =
        @"timestamp,scan,record_type,window,view_ptr,view_class,parent_class,screen_x,screen_y,screen_width,screen_height,layer_ptr,layer_class,layer_depth,layer_bg_rgba,layer_corner_radius,layer_masks_to_bounds,layer_opacity,layer_hidden,layer_frame_x,layer_frame_y,layer_width,layer_height,layer_contents_present,image_present,image_width,image_height,image_scale,image_rendering_mode,cg_width,cg_height,cg_alpha_info,pixel_tl,pixel_tr,pixel_bl,pixel_br,pixel_center\n";

        [header writeToFile:gMapPath
                 atomically:YES
                   encoding:NSUTF8StringEncoding
                      error:nil];

        Append([NSString stringWithFormat:
                @"# %@ START FBOLED View Mapper 0.5.0 layer-image-focus bundle=%@",
                Stamp(),
                NSBundle.mainBundle.bundleIdentifier ?: @"?"]);

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            StartScanner();
        });
    }
}
