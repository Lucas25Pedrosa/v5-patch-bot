#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// TeraBoxStorageDiagnostic 0.1.0
// Read-only storage mapper for TeraBox.
// It never deletes, moves, truncates, or modifies TeraBox data, except its own report files.

static NSString * const TBDVersion = @"0.1.0";
static NSString *gReportTXTPath = nil;
static NSString *gReportCSVPath = nil;

static NSString *TBDHumanBytes(unsigned long long bytes) {
    static NSArray<NSString *> *units;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ units = @[@"B", @"KB", @"MB", @"GB", @"TB"]; });
    double value = (double)bytes;
    NSUInteger unit = 0;
    while (value >= 1024.0 && unit + 1 < units.count) {
        value /= 1024.0;
        unit++;
    }
    return [NSString stringWithFormat:(unit == 0 ? @"%.0f %@" : @"%.2f %@"), value, units[unit]];
}

static NSString *TBDCSVQuote(NSString *value) {
    if (!value) return @"\"\"";
    NSString *escaped = [value stringByReplacingOccurrencesOfString:@"\"" withString:@"\"\""];
    return [NSString stringWithFormat:@"\"%@\"", escaped];
}

static UIViewController *TBDTopViewController(void) {
    UIApplication *app = UIApplication.sharedApplication;
    UIWindow *window = nil;

    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (scene.activationState != UISceneActivationStateForegroundActive) continue;
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
                if (candidate.isKeyWindow) { window = candidate; break; }
            }
            if (!window) {
                for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
                    if (!candidate.hidden && candidate.alpha > 0.0) { window = candidate; break; }
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
    while (vc) {
        if (vc.presentedViewController) { vc = vc.presentedViewController; continue; }
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

static void TBDPresentAlert(NSString *title, NSString *message, BOOL share, NSUInteger attempt) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *vc = TBDTopViewController();
        if (!vc || [vc isKindOfClass:UIAlertController.class]) {
            if (attempt < 20) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    TBDPresentAlert(title, message, share, attempt + 1);
                });
            }
            return;
        }

        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
        if (share) {
            [alert addAction:[UIAlertAction actionWithTitle:@"Compartilhar relatório" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
                NSMutableArray *items = [NSMutableArray array];
                if (gReportTXTPath && [NSFileManager.defaultManager fileExistsAtPath:gReportTXTPath]) [items addObject:[NSURL fileURLWithPath:gReportTXTPath]];
                if (gReportCSVPath && [NSFileManager.defaultManager fileExistsAtPath:gReportCSVPath]) [items addObject:[NSURL fileURLWithPath:gReportCSVPath]];
                if (!items.count) return;
                UIViewController *top = TBDTopViewController();
                if (!top) return;
                UIActivityViewController *shareVC = [[UIActivityViewController alloc] initWithActivityItems:items applicationActivities:nil];
                if (shareVC.popoverPresentationController) {
                    shareVC.popoverPresentationController.sourceView = top.view;
                    shareVC.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(top.view.bounds), CGRectGetMidY(top.view.bounds), 1, 1);
                }
                [top presentViewController:shareVC animated:YES completion:nil];
            }]];
        }
        [alert addAction:[UIAlertAction actionWithTitle:@"Fechar" style:UIAlertActionStyleCancel handler:nil]];
        [vc presentViewController:alert animated:YES completion:nil];
    });
}

static NSMutableDictionary *TBDStatsBucket(NSMutableDictionary<NSString *, NSMutableDictionary *> *map, NSString *key) {
    NSMutableDictionary *bucket = map[key];
    if (!bucket) {
        bucket = [@{@"logical": @0ULL, @"allocated": @0ULL, @"files": @0ULL, @"dirs": @0ULL} mutableCopy];
        map[key] = bucket;
    }
    return bucket;
}

static void TBDAddBytes(NSMutableDictionary *bucket, unsigned long long logical, unsigned long long allocated) {
    bucket[@"logical"] = @([bucket[@"logical"] unsignedLongLongValue] + logical);
    bucket[@"allocated"] = @([bucket[@"allocated"] unsignedLongLongValue] + allocated);
}

static NSString *TBDCategoryForRelativePath(NSString *relative) {
    if ([relative isEqualToString:@"Documents"] || [relative hasPrefix:@"Documents/"]) return @"Documents";
    if ([relative isEqualToString:@"tmp"] || [relative hasPrefix:@"tmp/"]) return @"tmp";
    if ([relative isEqualToString:@"Library/Caches"] || [relative hasPrefix:@"Library/Caches/"]) return @"Library/Caches";
    if ([relative isEqualToString:@"Library/Application Support"] || [relative hasPrefix:@"Library/Application Support/"]) return @"Library/Application Support";
    if ([relative isEqualToString:@"Library/WebKit"] || [relative hasPrefix:@"Library/WebKit/"]) return @"Library/WebKit";
    if ([relative isEqualToString:@"Library/HTTPStorages"] || [relative hasPrefix:@"Library/HTTPStorages/"]) return @"Library/HTTPStorages";
    if ([relative isEqualToString:@"Library/Preferences"] || [relative hasPrefix:@"Library/Preferences/"]) return @"Library/Preferences";
    if ([relative isEqualToString:@"Library"] || [relative hasPrefix:@"Library/"]) return @"Library/Other";
    return @"Sandbox/Other";
}

static void TBDTrimTopFiles(NSMutableArray<NSDictionary *> *items) {
    if (items.count <= 300) return;
    [items sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [b[@"allocated"] compare:a[@"allocated"]];
    }];
    [items removeObjectsInRange:NSMakeRange(200, items.count - 200)];
}

static void TBDWriteReport(void) {
    @autoreleasepool {
        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *home = NSHomeDirectory();
        NSString *reportDirectory = [[home stringByAppendingPathComponent:@"Documents"] stringByAppendingPathComponent:@"TeraBoxStorageDiagnostic"];
        [fm createDirectoryAtPath:reportDirectory withIntermediateDirectories:YES attributes:nil error:nil];

        NSString *statusPath = [reportDirectory stringByAppendingPathComponent:@"STATUS.txt"];
        [@"TeraBoxStorageDiagnostic: análise em andamento. Mantenha o TeraBox aberto até aparecer a mensagem de conclusão.\n" writeToFile:statusPath atomically:YES encoding:NSUTF8StringEncoding error:nil];

        NSMutableDictionary<NSString *, NSMutableDictionary *> *categories = [NSMutableDictionary dictionary];
        NSMutableDictionary<NSString *, NSMutableDictionary *> *directories = [NSMutableDictionary dictionary];
        NSMutableDictionary<NSString *, NSMutableDictionary *> *extensions = [NSMutableDictionary dictionary];
        NSMutableArray<NSDictionary *> *topFiles = [NSMutableArray array];
        __block NSUInteger enumerationErrors = 0;

        NSArray *keys = @[NSURLIsDirectoryKey, NSURLIsRegularFileKey, NSURLIsSymbolicLinkKey, NSURLFileSizeKey, NSURLFileAllocatedSizeKey, NSURLNameKey];
        NSURL *homeURL = [NSURL fileURLWithPath:home isDirectory:YES];
        NSDirectoryEnumerator<NSURL *> *enumerator = [fm enumeratorAtURL:homeURL
                                              includingPropertiesForKeys:keys
                                                                 options:0
                                                            errorHandler:^BOOL(__unused NSURL *url, __unused NSError *error) {
            enumerationErrors++;
            return YES;
        }];

        unsigned long long totalLogical = 0;
        unsigned long long totalAllocated = 0;
        NSUInteger totalFiles = 0;
        NSUInteger totalDirs = 0;
        NSUInteger processed = 0;

        for (NSURL *url in enumerator) {
            @autoreleasepool {
                NSString *path = url.path;
                if (!path.length || ![path hasPrefix:home]) continue;
                if ([path isEqualToString:reportDirectory] || [path hasPrefix:[reportDirectory stringByAppendingString:@"/"]]) {
                    NSNumber *isDir = nil;
                    [url getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:nil];
                    if (isDir.boolValue) [enumerator skipDescendants];
                    continue;
                }

                NSNumber *isDirectory = nil, *isRegular = nil, *isSymlink = nil, *fileSize = nil, *allocatedSize = nil;
                [url getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:nil];
                [url getResourceValue:&isRegular forKey:NSURLIsRegularFileKey error:nil];
                [url getResourceValue:&isSymlink forKey:NSURLIsSymbolicLinkKey error:nil];
                if (isSymlink.boolValue) {
                    if (isDirectory.boolValue) [enumerator skipDescendants];
                    continue;
                }

                NSString *relative = path.length > home.length ? [path substringFromIndex:home.length + 1] : @"";
                if (!relative.length) continue;
                NSString *category = TBDCategoryForRelativePath(relative);
                NSMutableDictionary *categoryBucket = TBDStatsBucket(categories, category);

                if (isDirectory.boolValue) {
                    categoryBucket[@"dirs"] = @([categoryBucket[@"dirs"] unsignedLongLongValue] + 1);
                    totalDirs++;
                    processed++;
                    continue;
                }
                if (!isRegular.boolValue) continue;

                [url getResourceValue:&fileSize forKey:NSURLFileSizeKey error:nil];
                [url getResourceValue:&allocatedSize forKey:NSURLFileAllocatedSizeKey error:nil];
                unsigned long long logical = fileSize.unsignedLongLongValue;
                unsigned long long allocated = allocatedSize ? allocatedSize.unsignedLongLongValue : logical;
                if (allocated == 0 && logical > 0) allocated = logical;

                totalLogical += logical;
                totalAllocated += allocated;
                totalFiles++;
                processed++;
                TBDAddBytes(categoryBucket, logical, allocated);
                categoryBucket[@"files"] = @([categoryBucket[@"files"] unsignedLongLongValue] + 1);

                NSString *ext = relative.pathExtension.lowercaseString;
                if (!ext.length) ext = @"(sem extensão)";
                NSMutableDictionary *extBucket = TBDStatsBucket(extensions, ext);
                TBDAddBytes(extBucket, logical, allocated);
                extBucket[@"files"] = @([extBucket[@"files"] unsignedLongLongValue] + 1);

                NSString *dir = [relative stringByDeletingLastPathComponent];
                while (dir.length) {
                    NSMutableDictionary *dirBucket = TBDStatsBucket(directories, dir);
                    TBDAddBytes(dirBucket, logical, allocated);
                    dirBucket[@"files"] = @([dirBucket[@"files"] unsignedLongLongValue] + 1);
                    NSString *parent = [dir stringByDeletingLastPathComponent];
                    if ([parent isEqualToString:dir]) break;
                    dir = parent;
                }

                [topFiles addObject:@{@"path": relative, @"logical": @(logical), @"allocated": @(allocated)}];
                TBDTrimTopFiles(topFiles);

                if ((processed % 5000) == 0) {
                    NSString *progress = [NSString stringWithFormat:@"TeraBoxStorageDiagnostic: analisando…\nItens processados: %lu\nTamanho encontrado até agora: %@\n", (unsigned long)processed, TBDHumanBytes(totalAllocated)];
                    [progress writeToFile:statusPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
                }
            }
        }

        [topFiles sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [b[@"allocated"] compare:a[@"allocated"]];
        }];

        NSArray<NSString *> *sortedDirectories = [directories.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
            return [directories[b][@"allocated"] compare:directories[a][@"allocated"]];
        }];
        NSArray<NSString *> *sortedExtensions = [extensions.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
            return [extensions[b][@"allocated"] compare:extensions[a][@"allocated"]];
        }];

        NSString *bundleID = NSBundle.mainBundle.bundleIdentifier ?: @"unknown";
        NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"unknown";
        NSString *build = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"unknown";
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss ZZZZZ";

        NSMutableString *summary = [NSMutableString string];
        [summary appendFormat:@"TeraBoxStorageDiagnostic %@\nREAD-ONLY: nenhum dado do TeraBox foi apagado ou alterado.\n\n", TBDVersion];
        [summary appendFormat:@"Generated: %@\nBundle: %@\nTeraBox version: %@ (%@)\n\n", [formatter stringFromDate:NSDate.date], bundleID, version, build];
        [summary appendString:@"TOTAL DA SANDBOX\n----------------\n"];
        [summary appendFormat:@"Logical size: %@ (%llu bytes)\n", TBDHumanBytes(totalLogical), totalLogical];
        [summary appendFormat:@"Allocated size: %@ (%llu bytes)\n", TBDHumanBytes(totalAllocated), totalAllocated];
        [summary appendFormat:@"Files: %lu\nDirectories: %lu\nEnumeration errors: %lu\n\n", (unsigned long)totalFiles, (unsigned long)totalDirs, (unsigned long)enumerationErrors];

        [summary appendString:@"CATEGORIAS\n----------\n"];
        NSArray *categoryOrder = @[@"Documents", @"Library/Application Support", @"Library/Caches", @"Library/WebKit", @"Library/HTTPStorages", @"Library/Preferences", @"Library/Other", @"tmp", @"Sandbox/Other"];
        for (NSString *category in categoryOrder) {
            NSDictionary *b = categories[category];
            if (!b) continue;
            [summary appendFormat:@"%@ = %@ allocated | %@ logical | files=%@ | dirs=%@\n", category, TBDHumanBytes([b[@"allocated"] unsignedLongLongValue]), TBDHumanBytes([b[@"logical"] unsignedLongLongValue]), b[@"files"], b[@"dirs"]];
        }

        [summary appendString:@"\nTOP 60 DIRETÓRIOS\n-----------------\n"];
        NSUInteger dirLimit = MIN((NSUInteger)60, sortedDirectories.count);
        for (NSUInteger i = 0; i < dirLimit; i++) {
            NSString *dir = sortedDirectories[i];
            NSDictionary *b = directories[dir];
            [summary appendFormat:@"%lu. %@ allocated | %@ logical | files=%@ | %@\n", (unsigned long)(i + 1), TBDHumanBytes([b[@"allocated"] unsignedLongLongValue]), TBDHumanBytes([b[@"logical"] unsignedLongLongValue]), b[@"files"], dir];
        }

        [summary appendString:@"\nTOP 100 ARQUIVOS\n----------------\n"];
        NSUInteger fileLimit = MIN((NSUInteger)100, topFiles.count);
        for (NSUInteger i = 0; i < fileLimit; i++) {
            NSDictionary *f = topFiles[i];
            [summary appendFormat:@"%lu. %@ allocated | %@ logical | %@\n", (unsigned long)(i + 1), TBDHumanBytes([f[@"allocated"] unsignedLongLongValue]), TBDHumanBytes([f[@"logical"] unsignedLongLongValue]), f[@"path"]];
        }

        [summary appendString:@"\nTOP 30 EXTENSÕES\n----------------\n"];
        NSUInteger extLimit = MIN((NSUInteger)30, sortedExtensions.count);
        for (NSUInteger i = 0; i < extLimit; i++) {
            NSString *ext = sortedExtensions[i];
            NSDictionary *b = extensions[ext];
            [summary appendFormat:@"%lu. .%@ = %@ allocated | files=%@\n", (unsigned long)(i + 1), ext, TBDHumanBytes([b[@"allocated"] unsignedLongLongValue]), b[@"files"]];
        }

        NSMutableString *csv = [NSMutableString stringWithString:@"type,name,allocated_bytes,allocated_human,logical_bytes,logical_human,files,directories\n"];
        for (NSString *category in categoryOrder) {
            NSDictionary *b = categories[category];
            if (!b) continue;
            [csv appendFormat:@"category,%@,%llu,%@,%llu,%@,%llu,%llu\n", TBDCSVQuote(category), [b[@"allocated"] unsignedLongLongValue], TBDCSVQuote(TBDHumanBytes([b[@"allocated"] unsignedLongLongValue])), [b[@"logical"] unsignedLongLongValue], TBDCSVQuote(TBDHumanBytes([b[@"logical"] unsignedLongLongValue])), [b[@"files"] unsignedLongLongValue], [b[@"dirs"] unsignedLongLongValue]];
        }
        for (NSUInteger i = 0; i < dirLimit; i++) {
            NSString *dir = sortedDirectories[i]; NSDictionary *b = directories[dir];
            [csv appendFormat:@"directory,%@,%llu,%@,%llu,%@,%llu,0\n", TBDCSVQuote(dir), [b[@"allocated"] unsignedLongLongValue], TBDCSVQuote(TBDHumanBytes([b[@"allocated"] unsignedLongLongValue])), [b[@"logical"] unsignedLongLongValue], TBDCSVQuote(TBDHumanBytes([b[@"logical"] unsignedLongLongValue])), [b[@"files"] unsignedLongLongValue]];
        }
        for (NSUInteger i = 0; i < fileLimit; i++) {
            NSDictionary *f = topFiles[i];
            [csv appendFormat:@"file,%@,%llu,%@,%llu,%@,1,0\n", TBDCSVQuote(f[@"path"]), [f[@"allocated"] unsignedLongLongValue], TBDCSVQuote(TBDHumanBytes([f[@"allocated"] unsignedLongLongValue])), [f[@"logical"] unsignedLongLongValue], TBDCSVQuote(TBDHumanBytes([f[@"logical"] unsignedLongLongValue]))];
        }

        gReportTXTPath = [reportDirectory stringByAppendingPathComponent:@"TeraBoxStorageDiagnostic.txt"];
        gReportCSVPath = [reportDirectory stringByAppendingPathComponent:@"TeraBoxStorageDiagnostic.csv"];
        [summary writeToFile:gReportTXTPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [csv writeToFile:gReportCSVPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [fm removeItemAtPath:statusPath error:nil];

        NSLog(@"[TeraBoxStorageDiagnostic] %@ finished: allocated=%@ logical=%@ files=%lu", TBDVersion, TBDHumanBytes(totalAllocated), TBDHumanBytes(totalLogical), (unsigned long)totalFiles);
        NSString *message = [NSString stringWithFormat:@"Relatório salvo em Documents/TeraBoxStorageDiagnostic.\n\nTotal encontrado: %@\nArquivos: %lu\n\nNenhum arquivo foi apagado.", TBDHumanBytes(totalAllocated), (unsigned long)totalFiles];
        TBDPresentAlert(@"Diagnóstico concluído", message, YES, 0);
    }
}

__attribute__((constructor))
static void TeraBoxStorageDiagnosticInit(void) {
    @autoreleasepool {
        NSString *bundleID = NSBundle.mainBundle.bundleIdentifier ?: @"";
        NSString *displayName = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleDisplayName"] ?: @"";
        NSString *bundleName = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleName"] ?: @"";
        BOOL looksLikeTeraBox = [bundleID isEqualToString:@"com.dubox.drive"] || [displayName.lowercaseString containsString:@"terabox"] || [bundleName.lowercaseString containsString:@"terabox"];
        if (!looksLikeTeraBox) return;

        NSLog(@"[TeraBoxStorageDiagnostic] %@ loaded (read-only)", TBDVersion);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            TBDPresentAlert(@"TeraBox Storage Diagnostic", @"Tweak carregado. Vou mapear o armazenamento local sem apagar nada. Mantenha o TeraBox aberto até a conclusão.", NO, 0);
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            TBDWriteReport();
        });
    }
}
