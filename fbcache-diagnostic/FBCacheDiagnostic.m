#import <Foundation/Foundation.h>

// FBCacheDiagnostic 0.1.0
// Read-only sandbox size mapper for Facebook.
// It never deletes, moves, truncates, or modifies Facebook data.

typedef struct {
    unsigned long long bytes;
    NSUInteger files;
    NSUInteger directories;
} FBCDStats;

static NSString *FBCDCSVQuote(NSString *value) {
    if (!value) return @"\"\"";
    NSString *escaped = [value stringByReplacingOccurrencesOfString:@"\"" withString:@"\"\""];
    return [NSString stringWithFormat:@"\"%@\"", escaped];
}

static NSString *FBCDHumanBytes(unsigned long long bytes) {
    static NSArray<NSString *> *units;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        units = @[@"B", @"KB", @"MB", @"GB", @"TB"];
    });

    double value = (double)bytes;
    NSUInteger unit = 0;
    while (value >= 1024.0 && unit + 1 < units.count) {
        value /= 1024.0;
        unit++;
    }
    return [NSString stringWithFormat:(unit == 0 ? @"%.0f %@" : @"%.2f %@"), value, units[unit]];
}

static FBCDStats FBCDStatsForItem(NSString *path) {
    FBCDStats result = {0, 0, 0};
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDirectory = NO;

    if (![fm fileExistsAtPath:path isDirectory:&isDirectory]) {
        return result;
    }

    if (!isDirectory) {
        NSError *error = nil;
        NSDictionary<NSFileAttributeKey, id> *attrs = [fm attributesOfItemAtPath:path error:&error];
        if (attrs && !error && [attrs[NSFileType] isEqual:NSFileTypeRegular]) {
            result.bytes = [attrs[NSFileSize] unsignedLongLongValue];
            result.files = 1;
        }
        return result;
    }

    result.directories = 1;
    NSDirectoryEnumerator<NSString *> *enumerator = [fm enumeratorAtPath:path];
    for (NSString *relative in enumerator) {
        @autoreleasepool {
            NSString *fullPath = [path stringByAppendingPathComponent:relative];
            NSError *error = nil;
            NSDictionary<NSFileAttributeKey, id> *attrs = [fm attributesOfItemAtPath:fullPath error:&error];
            if (!attrs || error) continue;

            NSString *type = attrs[NSFileType];
            if ([type isEqual:NSFileTypeSymbolicLink]) {
                continue;
            }
            if ([type isEqual:NSFileTypeDirectory]) {
                result.directories++;
            } else if ([type isEqual:NSFileTypeRegular]) {
                result.files++;
                result.bytes += [attrs[NSFileSize] unsignedLongLongValue];
            }
        }
    }
    return result;
}

static void FBCDAppendRow(NSMutableString *csv,
                          NSMutableArray<NSDictionary *> *ranked,
                          NSString *classification,
                          NSString *rootName,
                          NSString *relativePath,
                          NSString *fullPath,
                          FBCDStats stats) {
    [csv appendFormat:@"%@,%@,%@,%llu,%@,%lu,%lu\n",
     FBCDCSVQuote(classification),
     FBCDCSVQuote(rootName),
     FBCDCSVQuote(relativePath),
     stats.bytes,
     FBCDCSVQuote(FBCDHumanBytes(stats.bytes)),
     (unsigned long)stats.files,
     (unsigned long)stats.directories];

    [ranked addObject:@{
        @"classification": classification ?: @"",
        @"root": rootName ?: @"",
        @"path": relativePath ?: @"",
        @"fullPath": fullPath ?: @"",
        @"bytes": @(stats.bytes),
        @"files": @(stats.files),
        @"directories": @(stats.directories)
    }];
}

static FBCDStats FBCDScanRoot(NSMutableString *csv,
                              NSMutableArray<NSDictionary *> *ranked,
                              NSString *home,
                              NSString *relativeRoot,
                              NSString *classification) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *root = [home stringByAppendingPathComponent:relativeRoot];
    BOOL isDirectory = NO;
    FBCDStats total = {0, 0, 0};

    if (![fm fileExistsAtPath:root isDirectory:&isDirectory]) {
        return total;
    }

    if (!isDirectory) {
        total = FBCDStatsForItem(root);
        FBCDAppendRow(csv, ranked, classification, relativeRoot, @"(root file)", root, total);
        return total;
    }

    total.directories = 1;
    NSError *listError = nil;
    NSArray<NSString *> *children = [fm contentsOfDirectoryAtPath:root error:&listError];
    if (!children || listError) {
        return total;
    }

    children = [children sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    for (NSString *child in children) {
        @autoreleasepool {
            NSString *childPath = [root stringByAppendingPathComponent:child];
            FBCDStats stats = FBCDStatsForItem(childPath);
            total.bytes += stats.bytes;
            total.files += stats.files;
            total.directories += stats.directories;
            FBCDAppendRow(csv, ranked, classification, relativeRoot, child, childPath, stats);
        }
    }

    return total;
}

static void FBCDWriteReport(void) {
    @autoreleasepool {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *home = NSHomeDirectory();
        NSString *documents = [home stringByAppendingPathComponent:@"Documents"];
        NSString *reportDirectory = [documents stringByAppendingPathComponent:@"FBCacheDiagnostic"];

        NSError *mkdirError = nil;
        [fm createDirectoryAtPath:reportDirectory
      withIntermediateDirectories:YES
                       attributes:nil
                            error:&mkdirError];
        if (mkdirError) {
            NSLog(@"[FBCacheDiagnostic] Could not create report directory: %@", mkdirError);
            return;
        }

        NSMutableString *csv = [NSMutableString stringWithString:@"classification,root,item,bytes,human_size,files,directories\n"];
        NSMutableArray<NSDictionary *> *ranked = [NSMutableArray array];
        NSMutableArray<NSDictionary *> *rootTotals = [NSMutableArray array];

        NSArray<NSDictionary *> *roots = @[
            @{@"path": @"Library/Caches", @"class": @"cache_candidate"},
            @{@"path": @"tmp", @"class": @"cache_candidate"},
            @{@"path": @"Library/WebKit", @"class": @"inspect_only"},
            @{@"path": @"Library/HTTPStorages", @"class": @"inspect_only"},
            @{@"path": @"Library/Cookies", @"class": @"keep_session_data"},
            @{@"path": @"Library/Application Support", @"class": @"inspect_only"},
            @{@"path": @"Library/Preferences", @"class": @"keep_preferences"},
            @{@"path": @"Documents", @"class": @"user_data"}
        ];

        for (NSDictionary *entry in roots) {
            NSString *relativeRoot = entry[@"path"];
            NSString *classification = entry[@"class"];
            FBCDStats stats = FBCDScanRoot(csv, ranked, home, relativeRoot, classification);
            [rootTotals addObject:@{
                @"path": relativeRoot,
                @"classification": classification,
                @"bytes": @(stats.bytes),
                @"files": @(stats.files),
                @"directories": @(stats.directories)
            }];
        }

        [ranked sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [b[@"bytes"] compare:a[@"bytes"]];
        }];

        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";
        NSString *version = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"unknown";
        NSString *build = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"unknown";

        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss ZZZZZ";
        NSString *timestamp = [formatter stringFromDate:[NSDate date]];

        NSMutableString *summary = [NSMutableString string];
        [summary appendString:@"FBCacheDiagnostic 0.1.0\n"];
        [summary appendString:@"READ-ONLY: no files were deleted or modified.\n\n"];
        [summary appendFormat:@"Generated: %@\n", timestamp];
        [summary appendFormat:@"Bundle: %@\n", bundleID];
        [summary appendFormat:@"Facebook version: %@ (%@)\n\n", version, build];

        [summary appendString:@"ROOT TOTALS\n"];
        [summary appendString:@"-----------\n"];
        for (NSDictionary *entry in rootTotals) {
            [summary appendFormat:@"%-28@  %10@  files=%@  dirs=%@  [%@]\n",
             entry[@"path"],
             FBCDHumanBytes([entry[@"bytes"] unsignedLongLongValue]),
             entry[@"files"],
             entry[@"directories"],
             entry[@"classification"]];
        }

        [summary appendString:@"\nTOP 40 FIRST-LEVEL ITEMS\n"];
        [summary appendString:@"------------------------\n"];
        NSUInteger limit = MIN((NSUInteger)40, ranked.count);
        for (NSUInteger i = 0; i < limit; i++) {
            NSDictionary *entry = ranked[i];
            [summary appendFormat:@"%2lu. %10@  %@/%@  [%@]\n",
             (unsigned long)(i + 1),
             FBCDHumanBytes([entry[@"bytes"] unsignedLongLongValue]),
             entry[@"root"],
             entry[@"path"],
             entry[@"classification"]];
        }

        [summary appendString:@"\nCLASSIFICATION GUIDE\n"];
        [summary appendString:@"--------------------\n"];
        [summary appendString:@"cache_candidate   = likely disposable, but this diagnostic does not delete it.\n"];
        [summary appendString:@"inspect_only       = measure first; may contain state/session data.\n"];
        [summary appendString:@"keep_session_data  = do not clear blindly; may affect login/session.\n"];
        [summary appendString:@"keep_preferences   = settings; do not clear.\n"];
        [summary appendString:@"user_data          = user/app documents; do not clear blindly.\n"];

        NSString *csvPath = [reportDirectory stringByAppendingPathComponent:@"FBCacheDiagnostic.csv"];
        NSString *txtPath = [reportDirectory stringByAppendingPathComponent:@"FBCacheDiagnostic.txt"];
        NSError *csvError = nil;
        NSError *txtError = nil;
        [csv writeToFile:csvPath atomically:YES encoding:NSUTF8StringEncoding error:&csvError];
        [summary writeToFile:txtPath atomically:YES encoding:NSUTF8StringEncoding error:&txtError];

        if (csvError || txtError) {
            NSLog(@"[FBCacheDiagnostic] Report write error. CSV=%@ TXT=%@", csvError, txtError);
        } else {
            NSLog(@"[FBCacheDiagnostic] Report written to %@", reportDirectory);
            NSLog(@"[FBCacheDiagnostic] No Facebook data was deleted or modified.");
        }
    }
}

__attribute__((constructor))
static void FBCacheDiagnosticInit(void) {
    @autoreleasepool {
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        if (![bundleID isEqualToString:@"com.facebook.Facebook"]) {
            return;
        }

        NSLog(@"[FBCacheDiagnostic] 0.1.0 loaded (read-only)");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            FBCDWriteReport();
        });
    }
}
