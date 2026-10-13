#import <Foundation/Foundation.h>
#import <sqlite3.h>

static NSString * const kVersion = @"0.2-probe";
static NSString * const kAppGroup = @"group.ph.telegra.Telegraph";
static NSString * const kFolder = @"iQTele";
static dispatch_queue_t gQueue;
static NSString *gLogPath;
static NSMutableDictionary<NSString *, NSString *> *gFingerprints;

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

static NSURL *IQTeleFolderURL(void) {
    NSURL *container = [[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:kAppGroup];
    if (!container) return nil;
    return [container URLByAppendingPathComponent:kFolder isDirectory:YES];
}

static NSString *FingerprintForPath(NSString *path) {
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    if (!attrs) return @"<missing>";
    NSNumber *size = attrs[NSFileSize] ?: @0;
    NSDate *date = attrs[NSFileModificationDate] ?: [NSDate dateWithTimeIntervalSince1970:0];
    return [NSString stringWithFormat:@"%@|%.6f", size, date.timeIntervalSince1970];
}

static NSString *DescribePlistAtPath(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return @"<unreadable>";
    NSPropertyListFormat format = NSPropertyListBinaryFormat_v1_0;
    NSError *error = nil;
    id plist = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:&format error:&error];
    if (!plist) return [NSString stringWithFormat:@"<plist parse failed: %@>", error];
    if ([NSJSONSerialization isValidJSONObject:plist]) {
        NSData *json = [NSJSONSerialization dataWithJSONObject:plist options:NSJSONWritingPrettyPrinted error:nil];
        if (json) return [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    }
    return [plist description];
}

static void DumpDeletionRows(NSString *dbPath) {
    sqlite3 *db = NULL;
    int rc = sqlite3_open_v2(dbPath.UTF8String, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, NULL);
    if (rc != SQLITE_OK || !db) {
        AppendLog([NSString stringWithFormat:@"mirror-open failed rc=%d path=%@", rc, dbPath]);
        if (db) sqlite3_close(db);
        return;
    }

    const char *sql = "SELECT rowid, account, ns, peer, id, noticed, by_me FROM deletions ORDER BY rowid DESC LIMIT 50";
    sqlite3_stmt *stmt = NULL;
    rc = sqlite3_prepare_v2(db, sql, -1, &stmt, NULL);
    if (rc != SQLITE_OK || !stmt) {
        AppendLog([NSString stringWithFormat:@"deletions-query unavailable rc=%d err=%s", rc, sqlite3_errmsg(db)]);
        if (stmt) sqlite3_finalize(stmt);
        sqlite3_close(db);
        return;
    }

    NSMutableString *rows = [NSMutableString stringWithString:@"deletions-rows"];
    NSUInteger count = 0;
    while (sqlite3_step(stmt) == SQLITE_ROW) {
        long long rowid = sqlite3_column_int64(stmt, 0);
        long long account = sqlite3_column_int64(stmt, 1);
        long long ns = sqlite3_column_int64(stmt, 2);
        long long peer = sqlite3_column_int64(stmt, 3);
        long long mid = sqlite3_column_int64(stmt, 4);
        long long noticed = sqlite3_column_int64(stmt, 5);
        long long byMe = sqlite3_column_int64(stmt, 6);
        [rows appendFormat:@"\nrowid=%lld account=%lld ns=%lld peer=%lld id=%lld noticed=%lld by_me=%lld", rowid, account, ns, peer, mid, noticed, byMe];
        count++;
    }
    if (count == 0) [rows appendString:@" <empty>"];
    AppendLog(rows);
    sqlite3_finalize(stmt);
    sqlite3_close(db);
}

static void InspectChangedFile(NSString *folder, NSString *name) {
    NSString *path = [folder stringByAppendingPathComponent:name];
    NSString *fingerprint = FingerprintForPath(path);
    NSString *old = gFingerprints[name];
    if (old && [old isEqualToString:fingerprint]) return;
    gFingerprints[name] = fingerprint;
    AppendLog([NSString stringWithFormat:@"file-change name=%@ fingerprint=%@", name, fingerprint]);

    if ([name hasSuffix:@".plist"] && ![fingerprint isEqualToString:@"<missing>"]) {
        AppendLog([NSString stringWithFormat:@"plist %@\n%@", name, DescribePlistAtPath(path)]);
    }
    if ([name isEqualToString:@"mirror.sqlite"] || [name isEqualToString:@"mirror.sqlite-wal"]) {
        NSString *dbPath = [folder stringByAppendingPathComponent:@"mirror.sqlite"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:dbPath]) DumpDeletionRows(dbPath);
    }
}

static void PollState(void) {
    NSURL *folderURL = IQTeleFolderURL();
    if (!folderURL) {
        AppendLog(@"app-group-container=UNAVAILABLE");
        return;
    }
    NSString *folder = folderURL.path;
    NSArray<NSString *> *targets = @[
        @"ext-revoked.plist",
        @"keep-deleted-flag.plist",
        @"ledger.plist",
        @"mirror.sqlite",
        @"mirror.sqlite-wal",
        @"mirror.sqlite-shm"
    ];
    for (NSString *name in targets) InspectChangedFile(folder, name);
}

static void SchedulePoll(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.50 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        PollState();
        SchedulePoll();
    });
}

__attribute__((constructor)) static void ProbeInit(void) {
    @autoreleasepool {
        gQueue = dispatch_queue_create("com.lucas.iqkde-state-probe", DISPATCH_QUEUE_SERIAL);
        gFingerprints = [NSMutableDictionary dictionary];
        NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        gLogPath = [documents stringByAppendingPathComponent:@"iQKeepDeletedExceptionsProbe.log"];
        AppendLog(@"loaded mode=PASSIVE-STATE; no Telegram/iQKeepDeleted behavior is modified");
        NSURL *folder = IQTeleFolderURL();
        AppendLog([NSString stringWithFormat:@"iqtele-folder=%@", folder.path ?: @"<unavailable>"]);
        PollState();
        SchedulePoll();
    }
}
