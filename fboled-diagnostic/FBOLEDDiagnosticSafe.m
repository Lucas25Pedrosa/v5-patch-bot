#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSString *gLogPath;
static dispatch_queue_t gLogQueue;
static NSMutableSet *gSeen;
static BOOL gInstalled = NO;
static NSInteger gAttempt = 0;
static __thread BOOL gInside = NO;

typedef UIColor *(*ColorIMP)(id, SEL, NSInteger);
static ColorIMP gOriginal = NULL;

static NSString *Stamp(void) {
    static NSDateFormatter *f;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        f = [NSDateFormatter new];
        f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        f.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    });
    @synchronized (f) { return [f stringFromDate:[NSDate date]]; }
}

static void Log(NSString *line) {
    if (!line.length || !gLogPath.length) return;
    dispatch_async(gLogQueue, ^{
        NSData *d = [[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
        NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:gLogPath];
        if (!h) { [d writeToFile:gLogPath atomically:YES]; return; }
        @try { [h seekToEndOfFile]; [h writeData:d]; } @catch (__unused NSException *e) {}
        [h closeFile];
    });
}

static NSString *Hex(UIColor *c, CGFloat *r, CGFloat *g, CGFloat *b, CGFloat *a) {
    if (!c) return @"<nil>";
    BOOL ok = NO;
    @try {
        ok = [c getRed:r green:g blue:b alpha:a];
        if (!ok) {
            CGFloat w = 0;
            if ([c getWhite:&w alpha:a]) { *r = *g = *b = w; ok = YES; }
        }
    } @catch (__unused NSException *e) { ok = NO; }
    if (!ok) return @"<unresolved>";
    int R=(int)(MAX(0,MIN(1,*r))*255+0.5), G=(int)(MAX(0,MIN(1,*g))*255+0.5);
    int B=(int)(MAX(0,MIN(1,*b))*255+0.5), A=(int)(MAX(0,MIN(1,*a))*255+0.5);
    return [NSString stringWithFormat:@"#%02X%02X%02X%02X",R,G,B,A];
}

static void Record(NSInteger usage, UIColor *color, id theme) {
    NSString *key = [NSString stringWithFormat:@"%ld|%@",(long)usage,NSStringFromClass([theme class])];
    @synchronized (gSeen) { if ([gSeen containsObject:key]) return; [gSeen addObject:key]; }
    CGFloat r=0,g=0,b=0,a=0;
    NSString *hex = Hex(color,&r,&g,&b,&a);
    BOOL candidate = a >= .90 && r <= .40 && g <= .40 && b <= .40;
    Log([NSString stringWithFormat:@"%@,%ld,%@,%.6f,%.6f,%.6f,%.6f,%d,%@,%@",
         Stamp(),(long)usage,hex,r,g,b,a,candidate,
         NSStringFromClass([theme class]), color ? NSStringFromClass([color class]) : @"<nil>"]);
}

static UIColor *Replacement(id self, SEL cmd, NSInteger usage) {
    UIColor *result = gOriginal ? gOriginal(self,cmd,usage) : nil;
    if (gInside) return result;
    gInside = YES;
    @try { @autoreleasepool { Record(usage,result,self); } }
    @catch (__unused NSException *e) {}
    @finally { gInside = NO; }
    return result;
}

static void TryInstall(void);
static void Retry(void) {
    if (gInstalled || gAttempt >= 30) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.75*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ TryInstall(); });
}

static void TryInstall(void) {
    if (gInstalled) return;
    gAttempt++;
    Class cls = NSClassFromString(@"FDSTheme");
    SEL sel = NSSelectorFromString(@"colorForUsageColor:");
    Method m = cls ? class_getInstanceMethod(cls,sel) : NULL;
    if (!m) { Log([NSString stringWithFormat:@"# %@ attempt=%ld FDSTheme/colorForUsageColor unavailable",Stamp(),(long)gAttempt]); Retry(); return; }
    char *ret = method_copyReturnType(m);
    BOOL safe = ret && ret[0]=='@' && method_getNumberOfArguments(m)==3;
    NSString *enc = [NSString stringWithUTF8String:method_getTypeEncoding(m) ?: "?"];
    if (ret) free(ret);
    Log([NSString stringWithFormat:@"# %@ candidate encoding=%@ safe=%d",Stamp(),enc,safe]);
    if (!safe) return;
    gOriginal = (ColorIMP)method_getImplementation(m);
    method_setImplementation(m,(IMP)Replacement);
    gInstalled = YES;
    Log([NSString stringWithFormat:@"# %@ SAFE SWIZZLE INSTALLED",Stamp()]);
}

__attribute__((constructor)) static void Init(void) {
    @autoreleasepool {
        gLogQueue = dispatch_queue_create("com.fboled.safe",DISPATCH_QUEUE_SERIAL);
        gSeen = [NSMutableSet set];
        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
        NSString *dir = [docs stringByAppendingPathComponent:@"FBOLED"];
        [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        gLogPath = [dir stringByAppendingPathComponent:@"FBOLED_Diagnostic.csv"];
        [@"timestamp,usage_color,rgba_hex,r,g,b,a,dark_surface_candidate,theme_class,color_class\n" writeToFile:gLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        Log([NSString stringWithFormat:@"# %@ START FBOLED 0.2.0-safe bundle=%@",Stamp(),NSBundle.mainBundle.bundleIdentifier ?: @"?"]);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(2.5*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ TryInstall(); });
    }
}
