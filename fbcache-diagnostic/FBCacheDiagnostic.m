#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// FBCacheDiagnostic 0.2.0
// Read-only cache mapper for Facebook.
// This version intentionally scans only cache-like roots first so results appear quickly.
// It never deletes, moves, truncates, or modifies Facebook data (except its own report files).

typedef struct {
    unsigned long long bytes;
    NSUInteger files;
    NSUInteger directories;
} FBCDStats;

static NSString *gReportTXTPath = nil;
static NSString *gReportCSVPath = nil;

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

static UIViewController *FBCDTopViewController(void) {
    UIApplication *app = UIApplication.sharedApplication;
    UIWindow *window = nil;

    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (scene.activationState != UISceneActivationStateForegroundActive) continue;
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            for (UIWindow *candidate in windowScene.windows) {
                if (candidate.isKeyWindow) {
                    window = candidate;
                    break;
                }
            }
            if (!window) {
                for (UIWindow *candidate in windowScene.windows) {
                    if (!candidate.hidden && candidate.alpha > 0.0) {
                        window = candidate;
                        break;
                    }
                }
            }
            if (window) break;
        }
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (!window) window = app.keyWindow;
#pragma clang diagnostic pop

    UIViewController *vc = window.rootViewController;
    if (!vc) return nil;

    while (YES) {
        if (vc.presentedViewController) {
            vc = vc.presentedViewController;
            continue;
        }
        if ([vc isKindOfClass:UINavigationController.class]) {
            UIViewController *next = ((UINavigationController *)vc).visibleViewController;
            if (next) { vc = next; continue; }
        }
        if ([vc isKindOfClass:UITabBarController.class]) {
            UIViewController *next = ((UITabBarController *)vc).selectedViewController;
            if (next) { vc = next; continue; }
        }
        break;
    }
    return vc;
}

static void FBCDPresentLoadedNotice(NSUInteger attempt) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *vc = FBCDTopViewController();
        if (!vc) {
            if (attempt < 8) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    FBCDPresentLoadedNotice(attempt + 1);
                });
            }
            return;
        }

        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"FBCacheDiagnostic 0.2"
                                                                       message:@"Tweak carregado. Analisando o cache do Facebook sem apagar nenhum arquivo."
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [vc presentViewController:alert animated:YES completion:nil];
    });
}

static FBCDStats FBCDStatsForItem(NSString *path) {
    FBCDStats result = {0, 0, 0};
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDirectory = NO;
    if (![fm fileExistsAtPath:path isDirectory:&isDirectory]) return result;

    if (!isDirectory) {
        NSError *error = nil;
        NSDictionary *attrs = [fm attributesOfItemAtPath:path error:&error];
        if (attrs && !error && [attrs[NSFileType] isEqual:NSFileTypeRegular]) {
            result.bytes = [attrs[NSFileSize] unsignedLongLongValue];
            result.files = 1;
        }
        return result;
    }

    result.directories = 1;
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:path];
    for (NSString *relative in enumerator) {
        @autoreleasepool {
            NSString *fullPath = [path stringByAppendingPathComponent:relative];
            NSError *error = nil;
            NSDictionary *attrs = [fm attributesOfItemAtPath:fullPath error:&error];
            if (!attrs || error) continue;
            NSString *type = attrs[NSFileType];
            if ([type isEqual:NSFileTypeSymbolicLink]) continue;
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

static FBCDStats FBCDScanRoot(NSMutableString *csv,
                              NSMutableArray<NSDictionary *> *ranked,
                              NSString *home,
                              NSString *relativeRoot,
                              NSString *classification) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *root = [home stringByAppendingPathComponent:relativeRoot];
    BOOL isDirectory = NO;
    FBCDStats total = {0, 0, 0};
    if (![fm fileExistsAtPath:root isDirectory:&isDirectory]) return total;

    if (!isDirectory) {
        total = FBCDStatsForItem(root);
        return total;
    }

    total.directories = 1;
    NSError *listError = nil;
    NSArray<NSString *> *children = [fm contentsOfDirectoryAtPath:root error:&listError];
    if (!children || listError) return total;

    children = [children sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    for (NSString *child in children) {
        @autoreleasepool {
            NSString *childPath = [root stringByAppendingPathComponent:child];
            FBCDStats stats = FBCDStatsForItem(childPath);
            total.bytes += stats.bytes;
            total.files += stats.files;
            total.directories += stats.directories;

            [csv appendFormat:@"%@,%@,%@,%llu,%@,%lu,%lu\n",
             FBCDCSVQuote(classification), FBCDCSVQuote(relativeRoot), FBCDCSVQuote(child),
             stats.bytes, FBCDCSVQuote(FBCDHumanBytes(stats.bytes)),
             (unsigned long)stats.files, (unsigned long)stats.directories];

            [ranked addObject:@{@"class": classification,
                                @"root": relativeRoot,
                                @"item": child,
                                @"bytes": @(stats.bytes)}];
        }
    }
    return total;
}

static void FBCDShareReports(UIViewController *vc) {
    NSMutableArray *items = [NSMutableArray array];
    if (gReportTXTPath && [NSFileManager.defaultManager fileExistsAtPath:gReportTXTPath]) {
        [items addObject:[NSURL fileURLWithPath:gReportTXTPath]];
    }
    if (gReportCSVPath && [NSFileManager.defaultManager fileExistsAtPath:gReportCSVPath]) {
        [items addObject:[NSURL fileURLWithPath:gReportCSVPath]];
    }
    if (!items.count) return;

    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:items applicationActivities:nil];
    if (share.popoverPresentationController) {
        share.popoverPresentationController.sourceView = vc.view;
        share.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(vc.view.bounds), CGRectGetMidY(vc.view.bounds), 1, 1);
    }
    [vc presentViewController:share animated:YES completion:nil];
}

static void FBCDPresentResult(NSString *message, NSUInteger attempt) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *vc = FBCDTopViewController();
        if (!vc || [vc isKindOfClass:UIAlertController.class]) {
            if (attempt < 20) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    FBCDPresentResult(message, attempt + 1);
                });
            }
            return;
        }

        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Diagnóstico concluído"
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Compartilhar relatório" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            dispatch_async(dispatch_get_main_queue(), ^{
                UIViewController *top = FBCDTopViewController();
                if (top) FBCDShareReports(top);
            });
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Fechar" style:UIAlertActionStyleCancel handler:nil]];
        [vc presentViewController:alert animated:YES completion:nil];
    });
}

static void FBCDWriteReport(void) {
    @autoreleasepool {
        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *home = NSHomeDirectory();
        NSString *reportDirectory = [[home stringByAppendingPathComponent:@"Documents"] stringByAppendingPathComponent:@"FBCacheDiagnostic"];
        [fm createDirectoryAtPath:reportDirectory withIntermediateDirectories:YES attributes:nil error:nil];

        NSMutableString *csv = [NSMutableString stringWithString:@"classification,root,item,bytes,human_size,files,directories\n"];
        NSMutableArray<NSDictionary *> *ranked = [NSMutableArray array];
        NSMutableArray<NSDictionary *> *rootTotals = [NSMutableArray array];

        NSArray<NSDictionary *> *roots = @[
            @{@"path": @"Library/Caches", @"class": @"cache_candidate"},
            @{@"path": @"tmp", @"class": @"cache_candidate"},
            @{@"path": @"Library/WebKit", @"class": @"inspect_only"},
            @{@"path": @"Library/HTTPStorages", @"class": @"inspect_only"}
        ];

        unsigned long long candidateBytes = 0;
        for (NSDictionary *entry in roots) {
            NSString *relativeRoot = entry[@"path"];
            NSString *classification = entry[@"class"];
            FBCDStats stats = FBCDScanRoot(csv, ranked, home, relativeRoot, classification);
            if ([classification isEqualToString:@"cache_candidate"]) candidateBytes += stats.bytes;
            [rootTotals addObject:@{@"path": relativeRoot,
                                    @"classification": classification,
                                    @"bytes": @(stats.bytes),
                                    @"files": @(stats.files),
                                    @"directories": @(stats.directories)}];
        }

        [ranked sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [b[@"bytes"] compare:a[@"bytes"]];
        }];

        NSString *bundleID = NSBundle.mainBundle.bundleIdentifier ?: @"unknown";
        NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"unknown";
        NSString *build = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"unknown";

        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss ZZZZZ";

        NSMutableString *summary = [NSMutableString string];
        [summary appendString:@"FBCacheDiagnostic 0.2.0\nREAD-ONLY: no Facebook data was deleted.\n\n"];
        [summary appendFormat:@"Generated: %@\nBundle: %@\nFacebook version: %@ (%@)\n\n",
         [formatter stringFromDate:NSDate.date], bundleID, version, build];
        [summary appendString:@"ROOT TOTALS\n-----------\n"];
        for (NSDictionary *entry in rootTotals) {
            [summary appendFormat:@"%@ = %@ | files=%@ | dirs=%@ | %@\n",
             entry[@"path"], FBCDHumanBytes([entry[@"bytes"] unsignedLongLongValue]),
             entry[@"files"], entry[@"directories"], entry[@"classification"]];
        }

        [summary appendString:@"\nTOP 40 ITEMS\n------------\n"];
        NSUInteger limit = MIN((NSUInteger)40, ranked.count);
        for (NSUInteger i = 0; i < limit; i++) {
            NSDictionary *entry = ranked[i];
            [summary appendFormat:@"%lu. %@ | %@/%@ | %@\n",
             (unsigned long)(i + 1), FBCDHumanBytes([entry[@"bytes"] unsignedLongLongValue]),
             entry[@"root"], entry[@"item"], entry[@"class"]];
        }

        gReportCSVPath = [reportDirectory stringByAppendingPathComponent:@"FBCacheDiagnostic.csv"];
        gReportTXTPath = [reportDirectory stringByAppendingPathComponent:@"FBCacheDiagnostic.txt"];
        [csv writeToFile:gReportCSVPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [summary writeToFile:gReportTXTPath atomically:YES encoding:NSUTF8StringEncoding error:nil];

        NSString *resultMessage = [NSString stringWithFormat:@"Cache candidato: %@\n\nLibrary/Caches + tmp. WebKit e HTTPStorages foram apenas medidos. Nenhum arquivo foi apagado.", FBCDHumanBytes(candidateBytes)];
        NSLog(@"[FBCacheDiagnostic] 0.2.0 finished. Candidate cache=%@", FBCDHumanBytes(candidateBytes));
        FBCDPresentResult(resultMessage, 0);
    }
}

__attribute__((constructor))
static void FBCacheDiagnosticInit(void) {
    @autoreleasepool {
        NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
        if (![bundleID isEqualToString:@"com.facebook.Facebook"]) return;

        NSLog(@"[FBCacheDiagnostic] 0.2.0 loaded (read-only)");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            FBCDPresentLoadedNotice(0);
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            FBCDWriteReport();
        });
    }
}
