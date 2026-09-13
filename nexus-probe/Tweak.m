#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSString *const NPDirectoryName = @"NexusDiagnostic";
static NSString *const NPLogName = @"NexusProbe.txt";
static __weak UIViewController *NPTrackedController = nil;

static NSString *NPLogPath(void) {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documents = paths.firstObject ?: NSTemporaryDirectory();
    NSString *dir = [documents stringByAppendingPathComponent:NPDirectoryName];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:NPLogName];
}

static void NPAppend(NSString *line) {
    if (line.length == 0) return;
    NSString *payload = [line stringByAppendingString:@"\n"];
    NSData *data = [payload dataUsingEncoding:NSUTF8StringEncoding];
    NSString *path = NPLogPath();
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [data writeToFile:path atomically:YES];
        return;
    }
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) return;
    @try {
        [fh seekToEndOfFile];
        [fh writeData:data];
    } @catch (__unused NSException *e) {}
    [fh closeFile];
}

static NSString *NPRect(CGRect r) {
    return [NSString stringWithFormat:@"(%.1f,%.1f %.1fx%.1f)", r.origin.x, r.origin.y, r.size.width, r.size.height];
}

static NSString *NPSize(CGSize s) {
    return [NSString stringWithFormat:@"%.1fx%.1f", s.width, s.height];
}

static BOOL NPControllerLooksLikeIQF(UIViewController *vc) {
    if (!vc) return NO;
    NSString *name = NSStringFromClass(vc.class).lowercaseString;
    return [name containsString:@"iqf"] || [name containsString:@"iqface"];
}

static UIViewController *NPViewControllerForView(UIView *view) {
    UIResponder *r = view;
    while (r) {
        if ([r isKindOfClass:UIViewController.class]) return (UIViewController *)r;
        r = r.nextResponder;
    }
    return nil;
}

static NSArray<NSLayoutConstraint *> *NPConstraintsTouchingView(UIView *view) {
    if (!view) return @[];
    NSMutableArray *out = [NSMutableArray array];
    UIView *cursor = view;
    NSInteger depth = 0;
    while (cursor && depth < 3) {
        for (NSLayoutConstraint *c in cursor.constraints) {
            if (c.firstItem == view || c.secondItem == view || cursor == view) [out addObject:c];
        }
        cursor = cursor.superview;
        depth++;
    }
    return out;
}

static NSString *NPConstraintSummary(UILabel *label) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSLayoutConstraint *c in NPConstraintsTouchingView(label)) {
        [parts addObject:[NSString stringWithFormat:@"%@ prio=%.0f active=%@", c.description, c.priority, c.active ? @"Y" : @"N"]];
    }
    return parts.count ? [parts componentsJoinedByString:@" || "] : @"<none>";
}

static NSString *NPLabelSummary(UILabel *label, NSString *phase) {
    UIView *sp = label.superview;
    UIView *gp = sp.superview;
    UIFont *font = label.font;
    CGSize intrinsic = label.intrinsicContentSize;
    CGSize fitting = [label systemLayoutSizeFittingSize:UILayoutFittingCompressedSize];
    float hHug = [label contentHuggingPriorityForAxis:UILayoutConstraintAxisHorizontal];
    float hCR = [label contentCompressionResistancePriorityForAxis:UILayoutConstraintAxisHorizontal];
    return [NSString stringWithFormat:
            @"[%@] text=\"%@\" | class=%@ super=%@ grand=%@ | frame=%@ bounds=%@ intrinsic=%@ fitting=%@ | font=%.1f lines=%ld break=%ld fit=%@ scale=%.2f | huggingH=%.0f compressionH=%.0f | translatesMask=%@ | constraints=%@",
            phase ?: @"?", label.text ?: @"", NSStringFromClass(label.class),
            sp ? NSStringFromClass(sp.class) : @"<nil>", gp ? NSStringFromClass(gp.class) : @"<nil>",
            NPRect(label.frame), NPRect(label.bounds), NPSize(intrinsic), NPSize(fitting),
            font.pointSize, (long)label.numberOfLines, (long)label.lineBreakMode,
            label.adjustsFontSizeToFitWidth ? @"Y" : @"N", label.minimumScaleFactor,
            hHug, hCR, label.translatesAutoresizingMaskIntoConstraints ? @"Y" : @"N",
            NPConstraintSummary(label)];
}

static void NPWalk(UIView *view, NSString *phase, NSInteger depth) {
    if (!view || depth > 30) return;
    if ([view isKindOfClass:UILabel.class]) {
        UILabel *label = (UILabel *)view;
        if (label.text.length > 0) NPAppend(NPLabelSummary(label, phase));
    }
    for (UIView *sub in view.subviews) NPWalk(sub, phase, depth + 1);
}

static void NPSnapshot(UIViewController *vc, NSString *phase) {
    if (!vc || !NPControllerLooksLikeIQF(vc)) return;
    NPTrackedController = vc;
    NPAppend(@"============================================================");
    NPAppend([NSString stringWithFormat:@"SNAPSHOT %@ | controller=%@ | view=%@ | window=%@",
              phase, NSStringFromClass(vc.class), NPRect(vc.view.frame), NPRect(vc.view.window.bounds)]);
    NPWalk(vc.view, phase, 0);
}

static void (*NPOrigViewDidLayoutSubviews)(id, SEL) = NULL;
static void NPViewDidLayoutSubviews(id self, SEL _cmd) {
    if (NPOrigViewDidLayoutSubviews) NPOrigViewDidLayoutSubviews(self, _cmd);
    UIViewController *vc = (UIViewController *)self;
    NPSnapshot(vc, @"viewDidLayoutSubviews");
}

static void (*NPOrigViewDidAppear)(id, SEL, BOOL) = NULL;
static void NPViewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (NPOrigViewDidAppear) NPOrigViewDidAppear(self, _cmd, animated);
    UIViewController *vc = (UIViewController *)self;
    NPSnapshot(vc, @"viewDidAppear");
}

static void NPInstallOnClass(Class cls) {
    if (!cls) return;
    Method layout = class_getInstanceMethod(cls, @selector(viewDidLayoutSubviews));
    Method appear = class_getInstanceMethod(cls, @selector(viewDidAppear:));
    if (!layout || !appear) return;

    IMP oldLayout = method_getImplementation(layout);
    if (oldLayout != (IMP)NPViewDidLayoutSubviews) {
        NPOrigViewDidLayoutSubviews = (void (*)(id, SEL))oldLayout;
        method_setImplementation(layout, (IMP)NPViewDidLayoutSubviews);
    }
    IMP oldAppear = method_getImplementation(appear);
    if (oldAppear != (IMP)NPViewDidAppear) {
        NPOrigViewDidAppear = (void (*)(id, SEL, BOOL))oldAppear;
        method_setImplementation(appear, (IMP)NPViewDidAppear);
    }

    NPAppend([NSString stringWithFormat:@"Installed probe on %@", NSStringFromClass(cls)]);
}

static void NPTryInstall(void) {
    NSArray<NSString *> *candidates = @[@"IQFSettingsViewController", @"IQFSettingsController", @"IQFTweakSettingsViewController"];
    for (NSString *name in candidates) {
        Class cls = NSClassFromString(name);
        if (cls) {
            NPInstallOnClass(cls);
            return;
        }
    }
    static NSInteger attempts = 0;
    attempts++;
    if (attempts < 160) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ NPTryInstall(); });
    } else {
        NPAppend(@"Probe could not resolve an iQFace settings controller class.");
    }
}

static void NPDidBecomeActive(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *vc = NPTrackedController;
        if (vc && vc.view.window) NPSnapshot(vc, @"UIApplicationDidBecomeActive");
    });
}

__attribute__((constructor))
static void NPInit(void) {
    @autoreleasepool {
        if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.facebook.Facebook"] || [NSBundle.mainBundle.bundlePath hasSuffix:@".appex"]) return;
        NSString *path = NPLogPath();
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        NPAppend(@"NexusProbe 1.0 - observational iQFace settings diagnostics");
        NPAppend([NSString stringWithFormat:@"Bundle=%@ iOS=%@", NSBundle.mainBundle.bundleIdentifier, UIDevice.currentDevice.systemVersion]);
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *n) { NPDidBecomeActive(); }];
        dispatch_async(dispatch_get_main_queue(), ^{ NPTryInstall(); });
    }
}
