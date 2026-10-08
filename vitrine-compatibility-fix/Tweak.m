#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>

static NSString *const VCFVersion = @"1.0";
static IMP VCFOriginalPresentIMP = NULL;
static IMP VCFOriginalSGModPageInitIMP = NULL;
static BOOL VCFSGModPageHookInstalled = NO;

static void VCFLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void VCFLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[VitrineCompatibilityFix %@] %@", VCFVersion, message);
}

static NSString *VCFTrimmed(NSString *value) {
    if (![value isKindOfClass:NSString.class]) return @"";
    return [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static NSString *VCFHeaderWithoutPeriod(NSString *header) {
    NSString *clean = VCFTrimmed(header);
    while ([clean hasSuffix:@"."]) {
        clean = [clean substringToIndex:clean.length - 1];
        clean = VCFTrimmed(clean);
    }
    return clean;
}

static BOOL VCFIsEeveeWarning(NSString *text) {
    return [[VCFHeaderWithoutPeriod(text) lowercaseString] isEqualToString:@"eeveespotify is injected too"];
}

static BOOL VCFIsVersionWarning(NSString *text) {
    NSString *clean = VCFHeaderWithoutPeriod(text);
    return [clean hasPrefix:@"Spotify "] &&
           [clean containsString:@" is not the version Vitrine is made for"];
}

static BOOL VCFShouldSuppressProblemHeader(NSString *header) {
    return VCFIsEeveeWarning(header) || VCFIsVersionWarning(header);
}

static BOOL VCFShouldSuppressSettingsRow(NSString *title) {
    NSString *clean = VCFTrimmed(title);
    if ([clean isEqualToString:@"EeveeSpotify is injected too"]) return YES;
    if ([clean hasPrefix:@"Made for Spotify "]) return YES;
    return NO;
}

static NSString *VCFFirstLine(NSString *paragraph) {
    NSString *clean = VCFTrimmed(paragraph);
    NSRange newline = [clean rangeOfString:@"\n"];
    if (newline.location == NSNotFound) return clean;
    return [clean substringToIndex:newline.location];
}

static NSString *VCFBodyAfterFirstLine(NSString *paragraph) {
    NSString *clean = VCFTrimmed(paragraph);
    NSRange newline = [clean rangeOfString:@"\n"];
    if (newline.location == NSNotFound) return @"";
    return VCFTrimmed([clean substringFromIndex:NSMaxRange(newline)]);
}

// Returns YES when the alert must not be presented at all.
// Otherwise it may rewrite a mixed Vitrine environment alert so unrelated warnings remain visible.
static BOOL VCFFilterEnvironmentAlert(UIAlertController *alert) {
    NSString *title = VCFTrimmed(alert.title);
    NSString *message = VCFTrimmed(alert.message);

    // Single-problem Vitrine alerts.
    if (VCFShouldSuppressProblemHeader(title)) {
        VCFLog(@"suppressed environment alert: %@", title);
        return YES;
    }

    // Vitrine combines multiple environment problems as "N things to know" with one paragraph per problem.
    if (![title hasSuffix:@" things to know"] || message.length == 0) return NO;

    NSArray<NSString *> *paragraphs = [message componentsSeparatedByString:@"\n\n"];
    if (paragraphs.count < 2) return NO;

    NSMutableArray<NSString *> *kept = [NSMutableArray arrayWithCapacity:paragraphs.count];
    NSUInteger removed = 0;

    for (NSString *paragraph in paragraphs) {
        NSString *header = VCFFirstLine(paragraph);
        if (VCFShouldSuppressProblemHeader(header)) {
            removed++;
            VCFLog(@"removed problem from combined alert: %@", VCFHeaderWithoutPeriod(header));
        } else {
            [kept addObject:VCFTrimmed(paragraph)];
        }
    }

    if (removed == 0) return NO;
    if (kept.count == 0) {
        VCFLog(@"suppressed combined environment alert (%lu hidden problem%s)",
               (unsigned long)removed, removed == 1 ? "" : "s");
        return YES;
    }

    if (kept.count == 1) {
        NSString *paragraph = kept.firstObject;
        alert.title = VCFHeaderWithoutPeriod(VCFFirstLine(paragraph));
        alert.message = VCFBodyAfterFirstLine(paragraph);
    } else {
        alert.title = [NSString stringWithFormat:@"%lu things to know", (unsigned long)kept.count];
        alert.message = [kept componentsJoinedByString:@"\n\n"];
    }

    VCFLog(@"preserved %lu unrelated Vitrine warning%s in mixed alert",
           (unsigned long)kept.count, kept.count == 1 ? "" : "s");
    return NO;
}

static void VCFPresentViewController(id self, SEL _cmd, UIViewController *controller, BOOL animated, void (^completion)(void)) {
    if ([controller isKindOfClass:UIAlertController.class]) {
        if (VCFFilterEnvironmentAlert((UIAlertController *)controller)) {
            if (completion) dispatch_async(dispatch_get_main_queue(), completion);
            return;
        }
    }

    ((void (*)(id, SEL, UIViewController *, BOOL, void (^)(void)))VCFOriginalPresentIMP)(self, _cmd, controller, animated, completion);
}

static void VCFInstallPresentationHook(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cls = UIViewController.class;
        SEL selector = @selector(presentViewController:animated:completion:);
        Method method = class_getInstanceMethod(cls, selector);
        if (!method) {
            VCFLog(@"could not find UIViewController presentation method");
            return;
        }

        VCFOriginalPresentIMP = method_getImplementation(method);
        method_setImplementation(method, (IMP)VCFPresentViewController);
        VCFLog(@"presentation filter installed");
    });
}

static void VCFFilterVitrineSections(NSArray *sections) {
    if (![sections isKindOfClass:NSArray.class]) return;

    for (id section in sections) {
        @try {
            NSArray *rows = [section valueForKey:@"rows"];
            if (![rows isKindOfClass:NSArray.class] || rows.count == 0) continue;

            NSMutableArray *kept = [NSMutableArray arrayWithCapacity:rows.count];
            NSUInteger removed = 0;
            for (id row in rows) {
                NSString *rowTitle = nil;
                @try { rowTitle = [row valueForKey:@"title"]; } @catch (__unused NSException *e) {}
                if (VCFShouldSuppressSettingsRow(rowTitle)) {
                    removed++;
                    VCFLog(@"removed settings warning row: %@", rowTitle);
                    continue;
                }
                [kept addObject:row];
            }

            if (removed) [section setValue:[kept copy] forKey:@"rows"];
        } @catch (NSException *exception) {
            VCFLog(@"settings row filter skipped a section: %@", exception.reason ?: @"unknown exception");
        }
    }
}

static id VCFSGModPageInit(id self, SEL _cmd, NSString *title, NSString *intro, NSArray *sections, NSString *footer) {
    if ([VCFTrimmed(title) isEqualToString:@"Vitrine"]) {
        VCFFilterVitrineSections(sections);
    }

    return ((id (*)(id, SEL, NSString *, NSString *, NSArray *, NSString *))VCFOriginalSGModPageInitIMP)(self, _cmd, title, intro, sections, footer);
}

static void VCFInstallSGModPageHook(void) {
    @synchronized (NSObject.class) {
        if (VCFSGModPageHookInstalled) return;

        Class cls = objc_getClass("SGModPage");
        if (!cls) return;

        SEL selector = NSSelectorFromString(@"initWithTitle:intro:sections:footer:");
        Method method = class_getInstanceMethod(cls, selector);
        if (!method) {
            VCFLog(@"SGModPage found but expected initializer is missing");
            return;
        }

        VCFOriginalSGModPageInitIMP = method_getImplementation(method);
        method_setImplementation(method, (IMP)VCFSGModPageInit);
        VCFSGModPageHookInstalled = YES;
        VCFLog(@"Vitrine settings row filter installed");
    }
}

static void VCFImageAdded(const struct mach_header *header, intptr_t slide) {
    (void)header;
    (void)slide;
    if (VCFSGModPageHookInstalled) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        VCFInstallSGModPageHook();
    });
}

__attribute__((constructor))
static void VCFInit(void) {
    @autoreleasepool {
        NSString *bundleID = NSBundle.mainBundle.bundleIdentifier ?: @"";
        if (![bundleID isEqualToString:@"com.spotify.client"]) {
            VCFLog(@"not Spotify (%@); leaving hooks disabled", bundleID.length ? bundleID : @"unknown bundle");
            return;
        }

        VCFLog(@"loaded");
        VCFInstallPresentationHook();
        _dyld_register_func_for_add_image(VCFImageAdded);
        dispatch_async(dispatch_get_main_queue(), ^{
            VCFInstallSGModPageHook();
        });
    }
}
