#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

static NSString *reportPath;
static NSMutableSet<NSString *> *seenSignatures;
static dispatch_source_t timer;

static void appendLine(NSString *line) {
    if (!line.length || !reportPath.length) return;
    NSString *payload = [line stringByAppendingString:@"\n"];
    NSData *data = [payload dataUsingEncoding:NSUTF8StringEncoding];
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:reportPath];
    if (!h) return;
    [h seekToEndOfFile];
    [h writeData:data];
    [h closeFile];
}

static NSString *rectString(CGRect r) {
    return [NSString stringWithFormat:@"(%.1f,%.1f %.1fx%.1f)", r.origin.x, r.origin.y, r.size.width, r.size.height];
}

static BOOL classEquals(UIView *view, NSString *name) {
    return view && [NSStringFromClass(view.class) isEqualToString:name];
}

static BOOL hasDescendantNamed(UIView *view, NSString *name, NSUInteger depth) {
    if (!view || depth > 8) return NO;
    for (UIView *child in view.subviews) {
        if (classEquals(child, name)) return YES;
        if (hasDescendantNamed(child, name, depth + 1)) return YES;
    }
    return NO;
}

static NSUInteger countImageViews(UIView *view, NSUInteger depth) {
    if (!view || depth > 8) return 0;
    NSUInteger count = [view isKindOfClass:UIImageView.class] ? 1 : 0;
    for (UIView *child in view.subviews) count += countImageViews(child, depth + 1);
    return count;
}

static BOOL containsVisibleImage(UIView *view, NSUInteger depth) {
    if (!view || depth > 8) return NO;
    if ([view isKindOfClass:UIImageView.class]) {
        UIImageView *iv = (UIImageView *)view;
        if (iv.image && !iv.hidden && iv.alpha > 0.01) return YES;
    }
    for (UIView *child in view.subviews) if (containsVisibleImage(child, depth + 1)) return YES;
    return NO;
}

static void appendTree(UIView *view, NSMutableString *out, NSUInteger depth) {
    if (!view || depth > 7) return;
    NSString *indent = [@"" stringByPaddingToLength:depth * 2 withString:@" " startingAtIndex:0];
    CALayer *layer = view.layer;
    [out appendFormat:@"%@%@ frame=%@ bounds=%@ hidden=%@ alpha=%.2f clips=%@ masks=%@ radius=%.1f",
     indent, NSStringFromClass(view.class), rectString(view.frame), rectString(view.bounds),
     view.hidden ? @"Y" : @"N", view.alpha, view.clipsToBounds ? @"Y" : @"N",
     layer.masksToBounds ? @"Y" : @"N", layer.cornerRadius];
    if ([view isKindOfClass:UIImageView.class]) {
        UIImageView *iv = (UIImageView *)view;
        [out appendFormat:@" image=%@ mode=%ld", iv.image ? @"Y" : @"N", (long)iv.contentMode];
    }
    [out appendString:@"\n"];
    for (UIView *child in view.subviews) appendTree(child, out, depth + 1);
}

static BOOL looksLikeAvatarContainer(UIView *view) {
    if (!classEquals(view, @"FBPassthroughView")) return NO;
    CGFloat w = fabs(view.bounds.size.width);
    CGFloat h = fabs(view.bounds.size.height);
    if (w < 20.0 || h < 20.0 || w > 120.0 || h > 120.0) return NO;
    if (fabs(w - h) > 12.0) return NO;
    if (!containsVisibleImage(view, 0)) return NO;
    return YES;
}

static void inspectCandidate(UIView *view) {
    BOOL masked = hasDescendantNamed(view, @"_FBMaskedRoundedCornerView", 0);
    BOOL mrc = hasDescendantNamed(view, @"MRCImageComponentView", 0);
    BOOL animated = hasDescendantNamed(view, @"MRCAnimatedImageView", 0);
    NSUInteger images = countImageViews(view, 0);

    NSMutableString *tree = [NSMutableString string];
    appendTree(view, tree, 0);

    NSString *signature = [NSString stringWithFormat:@"%@|%@|%@|%lu|%@",
                           masked ? @"M" : @"-", mrc ? @"C" : @"-", animated ? @"A" : @"-",
                           (unsigned long)images, tree];
    if ([seenSignatures containsObject:signature]) return;
    [seenSignatures addObject:signature];

    NSString *variant = masked ? @"A(masked)" : ((mrc && animated && images >= 1) ? @"B/unmasked-or-composite" : @"C/unknown");
    appendLine(@"============================================================");
    appendLine([NSString stringWithFormat:@"AVATAR CANDIDATE variant=%@ frame=%@ images=%lu masked=%@ mrc=%@ animated=%@",
                variant, rectString(view.frame), (unsigned long)images,
                masked ? @"Y" : @"N", mrc ? @"Y" : @"N", animated ? @"Y" : @"N"]);
    appendLine(tree);
}

static void walkView(UIView *view, NSUInteger depth) {
    if (!view || depth > 30 || view.hidden || view.alpha < 0.01) return;
    if (looksLikeAvatarContainer(view)) inspectCandidate(view);
    for (UIView *child in view.subviews) walkView(child, depth + 1);
}

static NSArray<UIWindow *> *allWindows(void) {
    NSMutableArray<UIWindow *> *out = [NSMutableArray array];
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            [out addObjectsFromArray:((UIWindowScene *)scene).windows];
        }
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [out addObjectsFromArray:UIApplication.sharedApplication.windows];
#pragma clang diagnostic pop
    }
    return out;
}

static void scan(void) {
    for (UIWindow *window in allWindows()) walkView(window, 0);
}

static void prepare(void) {
    seenSignatures = [NSMutableSet set];
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject ?: NSTemporaryDirectory();
    NSString *dir = [docs stringByAppendingPathComponent:@"iQFaceProbe"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    reportPath = [dir stringByAppendingPathComponent:@"AvatarProbe.txt"];
    [[NSFileManager defaultManager] createFileAtPath:reportPath contents:nil attributes:nil];
    appendLine(@"iQFaceProbe 1.0 - avatar structure diagnostics");
    appendLine(@"Reference class: IQFSetting");
    appendLine([NSString stringWithFormat:@"Bundle=%@ iOS=%@", NSBundle.mainBundle.bundleIdentifier ?: @"?", UIDevice.currentDevice.systemVersion ?: @"?"]);
    appendLine(@"Open the feed item with the problematic community/group avatar and leave it visible for a few seconds.");
}

__attribute__((constructor))
static void ProbeInit(void) {
    @autoreleasepool {
        if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.facebook.Facebook"] ||
            [NSBundle.mainBundle.bundlePath hasSuffix:@".appex"]) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            prepare();
            timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
            dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, NSEC_PER_SEC / 5);
            dispatch_source_set_event_handler(timer, ^{ scan(); });
            dispatch_resume(timer);
        });
    }
}
