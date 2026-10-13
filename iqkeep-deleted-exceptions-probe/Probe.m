#import <Foundation/Foundation.h>

static NSString * const kVersion = @"0.1-probe";
static NSString * const kAppGroup = @"group.ph.telegra.Telegraph";
static NSString * const kFolder = @"iQTele";
static NSString * const kLedger = @"ext-revoked.plist";

static dispatch_queue_t gQueue;
static NSString *gLogPath;
static NSData *gLastData;

static NSString *Timestamp(void) {
    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    });
    @synchronized (formatter) {
        return [formatter stringFromDate:[NSDate date]];
    }
}

static void AppendLog(NSString *message) {
    if (!message) return;
    NSString *line = [NSString stringWithFormat:@"%@ [iQKDE %@] %@", Timestamp(), kVersion, message];
    NSLog(@"%@", line);
    if (!gQueue || !gLogPath) return;

    dispatch_async(gQueue, ^{
        @autoreleasepool {
            NSData *data = [[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
            if (![[NSFileManager defaultManager] fileExistsAtPath:gLogPath]) {
                [data writeToFile:gLogPath atomically:YES];
                return;
            }
            NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:gLogPath];
            if (!handle) return;
            @try {
                [handle seekToEndOfFile];
                [handle writeData:data];
                [handle synchronizeFile];
            } @catch (__unused NSException *e) {
            }
            [handle closeFile];
        }
    });
}

static NSURL *LedgerURL(void) {
    NSURL *container = [[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:kAppGroup];
    if (!container) return nil;
    NSURL *folder = [container URLByAppendingPathComponent:kFolder isDirectory:YES];
    return [folder URLByAppendingPathComponent:kLedger isDirectory:NO];
}

static NSString *DescribeObject(id object) {
    if (!object) return @"<nil>";
    if ([NSJSONSerialization isValidJSONObject:object]) {
        NSData *json = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingPrettyPrinted error:nil];
        if (json) {
            NSString *text = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
            if (text) return text;
        }
    }
    return [object description];
}

static void PollLedger(void) {
    NSURL *url = LedgerURL();
    if (!url) {
        AppendLog(@"app-group-container=UNAVAILABLE");
        return;
    }

    NSData *data = [NSData dataWithContentsOfURL:url];
    if (!data) return;
    if (gLastData && [gLastData isEqualToData:data]) return;
    gLastData = [data copy];

    NSError *error = nil;
    NSPropertyListFormat format = NSPropertyListBinaryFormat_v1_0;
    id plist = [NSPropertyListSerialization propertyListWithData:data
                                                        options:NSPropertyListImmutable
                                                         format:&format
                                                          error:&error];
    if (!plist) {
        AppendLog([NSString stringWithFormat:@"ledger-change parse=FAILED path=%@ error=%@", url.path, error]);
        return;
    }

    NSUInteger count = [plist respondsToSelector:@selector(count)] ? (NSUInteger)[plist count] : 0;
    AppendLog([NSString stringWithFormat:@"ledger-change path=%@ class=%@ count=%lu\n%@",
               url.path,
               NSStringFromClass([plist class]),
               (unsigned long)count,
               DescribeObject(plist)]);
}

static void SchedulePoll(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.50 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        PollLedger();
        SchedulePoll();
    });
}

__attribute__((constructor)) static void ProbeInit(void) {
    @autoreleasepool {
        gQueue = dispatch_queue_create("com.lucas.iqkde-ledger-probe", DISPATCH_QUEUE_SERIAL);
        NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        gLogPath = [documents stringByAppendingPathComponent:@"iQKeepDeletedExceptionsProbe.log"];
        AppendLog(@"loaded mode=PASSIVE-LEDGER; no Telegram/iQKeepDeleted behavior is modified");
        NSURL *url = LedgerURL();
        AppendLog([NSString stringWithFormat:@"ledger=%@", url.path ?: @"<unavailable>"]);
        PollLedger();
        SchedulePoll();
    }
}
