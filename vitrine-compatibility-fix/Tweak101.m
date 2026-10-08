#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>

static NSString *const VCFVersion = @"1.0.1";
static IMP originalPresentIMP = NULL;
static IMP originalPageInitIMP = NULL;
static BOOL pageHookInstalled = NO;

static void VCFLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void VCFLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[VitrineCompatibilityFix %@] %@", VCFVersion, message);
}

static NSString *Trim(NSString *s) {
    if (![s isKindOfClass:NSString.class]) return @"";
    return [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static NSString *Header(NSString *s) {
    NSString *out = Trim(s);
    while ([out hasSuffix:@"."]) out = Trim([out substringToIndex:out.length - 1]);
    return out;
}

static BOOL IsHiddenProblem(NSString *text) {
    NSString *h = Header(text);
    if ([[h lowercaseString] isEqualToString:@"eeveespotify is injected too"]) return YES;
    if ([h hasPrefix:@"Spotify "] && [h containsString:@" is not the version Vitrine is made for"]) return YES;
    return NO;
}

static BOOL IsHiddenRow(NSString *title) {
    NSString *t = Trim(title);
    return [t isEqualToString:@"EeveeSpotify is injected too"] || [t hasPrefix:@"Made for Spotify "];
}

static NSString *FirstLine(NSString *s) {
    NSString *t = Trim(s);
    NSRange r = [t rangeOfString:@"\n"];
    return r.location == NSNotFound ? t : [t substringToIndex:r.location];
}

static NSString *AfterFirstLine(NSString *s) {
    NSString *t = Trim(s);
    NSRange r = [t rangeOfString:@"\n"];
    return r.location == NSNotFound ? @"" : Trim([t substringFromIndex:NSMaxRange(r)]);
}

static BOOL FilterAlert(UIAlertController *alert) {
    NSString *title = Trim(alert.title);
    NSString *message = Trim(alert.message);

    if (IsHiddenProblem(title)) {
        VCFLog(@"blocked alert: %@", title);
        return YES;
    }

    if (![title hasSuffix:@" things to know"] || message.length == 0) return NO;

    NSArray<NSString *> *parts = [message componentsSeparatedByString:@"\n\n"];
    if (parts.count < 2) return NO;

    NSMutableArray<NSString *> *kept = [NSMutableArray array];
    NSUInteger removed = 0;
    for (NSString *part in parts) {
        NSString *problemTitle = FirstLine(part);
        if (IsHiddenProblem(problemTitle)) {
            removed++;
            VCFLog(@"removed mixed warning: %@", Header(problemTitle));
        } else {
            [kept addObject:Trim(part)];
        }
    }

    if (removed == 0) return NO;
    if (kept.count == 0) return YES;

    if (kept.count == 1) {
        alert.title = Header(FirstLine(kept.firstObject));
        alert.message = AfterFirstLine(kept.firstObject);
    } else {
        alert.title = [NSString stringWithFormat:@"%lu things to know", (unsigned long)kept.count];
        alert.message = [kept componentsJoinedByString:@"\n\n"];
    }
    return NO;
}

static void ReplacementPresent(id self, SEL _cmd, UIViewController *vc, BOOL animated, void (^completion)(void)) {
    if ([vc isKindOfClass:UIAlertController.class] && FilterAlert((UIAlertController *)vc)) {
        if (completion) dispatch_async(dispatch_get_main_queue(), completion);
        return;
    }
    ((void (*)(id, SEL, UIViewController *, BOOL, void (^)(void)))originalPresentIMP)(self, _cmd, vc, animated, completion);
}

static void InstallPresentationHook(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method m = class_getInstanceMethod(UIViewController.class, @selector(presentViewController:animated:completion:));
        if (!m) return;
        originalPresentIMP = method_getImplementation(m);
        method_setImplementation(m, (IMP)ReplacementPresent);
        VCFLog(@"presentation hook installed");
    });
}

static void FilterSections(NSArray *sections) {
    if (![sections isKindOfClass:NSArray.class]) return;

    for (id section in sections) {
        @try {
            NSArray *rows = [section valueForKey:@"rows"];
            if (![rows isKindOfClass:NSArray.class] || rows.count == 0) continue;

            NSMutableArray *filtered = [NSMutableArray arrayWithCapacity:rows.count];
            BOOL changed = NO;
            for (id row in rows) {
                NSString *title = nil;
                @try { title = [row valueForKey:@"title"]; } @catch (__unused NSException *e) {}
                if (IsHiddenRow(title)) {
                    changed = YES;
                    VCFLog(@"removed Vitrine row: %@", title);
                } else {
                    [filtered addObject:row];
                }
            }
            if (changed) [section setValue:[filtered copy] forKey:@"rows"];
        } @catch (NSException *e) {
            VCFLog(@"section filter exception: %@", e.reason ?: @"unknown");
        }
    }
}

static id ReplacementPageInit(id self, SEL _cmd, NSString *title, NSString *intro, NSArray *sections, NSString *footer) {
    if ([Trim(title) isEqualToString:@"Vitrine"]) FilterSections(sections);
    return ((id (*)(id, SEL, NSString *, NSString *, NSArray *, NSString *))originalPageInitIMP)(self, _cmd, title, intro, sections, footer);
}

static void InstallPageHook(void) {
    @synchronized (NSObject.class) {
        if (pageHookInstalled) return;
        Class cls = objc_getClass("SGModPage");
        if (!cls) return;

        SEL sel = NSSelectorFromString(@"initWithTitle:intro:sections:footer:");
        Method m = class_getInstanceMethod(cls, sel);
        if (!m) return;

        originalPageInitIMP = method_getImplementation(m);
        method_setImplementation(m, (IMP)ReplacementPageInit);
        pageHookInstalled = YES;
        VCFLog(@"SGModPage hook installed");
    }
}

static void ImageAdded(const struct mach_header *header, intptr_t slide) {
    (void)header;
    (void)slide;
    if (pageHookInstalled) return;
    dispatch_async(dispatch_get_main_queue(), ^{ InstallPageHook(); });
}

__attribute__((constructor))
static void VCFInit(void) {
    @autoreleasepool {
        // Do NOT gate on com.spotify.client: sideload signers may rewrite the bundle identifier.
        NSString *bundleID = NSBundle.mainBundle.bundleIdentifier ?: @"unknown";
        NSString *executable = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleExecutable"] ?: @"unknown";
        VCFLog(@"loaded; bundle=%@ executable=%@", bundleID, executable);

        InstallPresentationHook();
        _dyld_register_func_for_add_image(ImageAdded);
        dispatch_async(dispatch_get_main_queue(), ^{ InstallPageHook(); });
    }
}
