#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static NSString * const kSoccerGamedayKey = @"x_sports_soccer_gameday_enabled";

static void XSGForceFlag(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:YES forKey:kSoccerGamedayKey];
    [defaults setObject:@YES forKey:kSoccerGamedayKey];

    // Also seed common app/domain suites when available. Harmless if X ignores them.
    NSArray<NSString *> *suites = @[@"com.atebits.Tweetie2", @"com.twitter.twitter"];
    for (NSString *suiteName in suites) {
        NSUserDefaults *suite = [[NSUserDefaults alloc] initWithSuiteName:suiteName];
        [suite setBool:YES forKey:kSoccerGamedayKey];
    }

    NSLog(@"[XSoccerGameday] forced %@ = YES", kSoccerGamedayKey);
}

static void XSGInstallRuntimeOverrides(void) {
    // The first build intentionally stays narrow: force the exact persisted key
    // discovered in X 12.37 without touching the older Live Sports scorecard.
    XSGForceFlag();

    // Re-apply after frameworks/account configuration have had time to initialize.
    NSArray<NSNumber *> *delays = @[@0.05, @0.20, @0.50, @1.0, @2.0, @4.0];
    for (NSNumber *delay in delays) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            XSGForceFlag();
        });
    }
}

__attribute__((constructor))
static void XSoccerGamedayInit(void) {
    @autoreleasepool {
        NSLog(@"[XSoccerGameday] 1.0.0 loaded - X 12.37 soccer gameday flag enabler");
        XSGInstallRuntimeOverrides();
    }
}
