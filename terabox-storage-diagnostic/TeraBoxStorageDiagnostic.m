#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <sys/stat.h>
#import <errno.h>
#import <string.h>

// TeraBoxStorageDiagnostic 0.2.0
// Read-only storage mapper for TeraBox.
// It never deletes, moves, truncates, or modifies TeraBox data, except its own report files.

static NSString * const TBDVersion = @"0.2.0";
static NSString *gReportTXTPath = nil;
static NSString *gReportCSVPath = nil;

static NSString *TBDHumanBytes(unsigned long long bytes) {
    static NSArray<NSString *> *units;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ units = @[@"B", @"KB", @"MB", @"GB", @"TB"]; });
    double value = (double)bytes;
    NSUInteger unit = 0;
    while (value >= 1024.0 && unit + 1 < units.count) { value /= 1024.0; unit++; }
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
            if (scene.activationState != UISceneActivationStateForegroundActive || ![scene isKindOfClass:UIWindowScene.class]) continue;
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
            if (attempt < 25) {
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
                NSFileManager *fm = NSFileManager.defaultManager;
                if (gReportTXTPath && [fm fileExistsAtPath:gReportTXTPath]) [items addObject:[NSURL fileURLWithPath:gReportTXTPath]];
                if (gReportCSVPath && [fm fileExistsAtPath:gReportCSVPath]) [items addObject:[NSURL fileURLWithPath:gReportCSVPath]];
                UIViewController *top = TBDTopViewController();
                if (!top || !items.count) return;
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

static BOOL TBDIsOwnReportPath(NSString *relative) {
    return [relative isEqualToString:@"Documents/TeraBoxStorageDiagnostic"] || [relative hasPrefix:@"Documents/TeraBoxStorageDiagnostic/"];
}

static void TBDRecordError(NSMutableArray<NSString *> *errors, NSString *relative, NSString *message) {
    if (errors.count >= 100) return;
    [errors addObject:[NSString stringWithFormat:@"%@ | %@", relative ?: @"(unknown)", message ?: @"unknown error"]];
}

static void TBDTrimTopFiles(NSMutableArray<NSDictionary *> *items) {
    if (items.count <= 400) return;
    [items sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [b[@"allocated"] compare:a[@"allocated"]];
    }];
    [items removeObjectsInRange:NSMakeRange(250, items.count - 250)];
}

static void TBDWriteReport(void) {
    @autoreleasepool {
        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *home = NSHomeDirectory();
        NSString *reportDirectory = [[home stringByAppendingPathComponent:@"Documents"] stringByAppendingPathComponent:@"TeraBoxStorageDiagnostic"];
        [fm createDirectoryAtPath:reportDirectory withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *statusPath = [reportDirectory stringByAppendingPathComponent:@"STATUS.txt"];
        [@"TeraBoxStorageDiagnostic 0.2.0: análise em andamento. Mantenha o TeraBox aberto até a conclusão.\n" writeToFile:statusPath atomically:YES encoding:NSUTF8StringEncoding error:nil];

        NSMutableDictionary<NSString *, NSMutableDictionary *> *categories = [NSMutableDictionary dictionary];
        NSMutableDictionary<NSString *, NSMutableDictionary *> *directories = [NSMutableDictionary dictionary];
        NSMutableDictionary<NSString *, NSMutableDictionary *> *extensions = [NSMutableDictionary dictionary];
        NSMutableArray<NSDictionary *> *topFiles = [NSMutableArray array];
        NSMutableArray<NSString *> *errors = [NSMutableArray array];
        NSMutableArray<NSString *> *stack = [NSMutableArray array];

        NSError *rootError = nil;
        NSArray<NSString *> *rootChildren = [fm contentsOfDirectoryAtPath:home error:&rootError];
        if (!rootChildren) {
            TBDRecordError(errors, @"/", rootError.localizedDescription ?: @"failed to list sandbox root");
        } else {
            for (NSString *child in rootChildren) {
                if (child.length) [stack addObject:child];
            }
        }

        unsigned long long totalLogical = 0, totalAllocated = 0;
        NSUInteger totalFiles = 0, totalDirs = 0, processed = 0;

        while (stack.count) {
            @autoreleasepool {
                NSString *relative = stack.lastObject;
                [stack removeLastObject];
                if (!relative.length || TBDIsOwnReportPath(relative)) continue;
                NSString *fullPath = [home stringByAppendingPathComponent:relative];

                struct stat st;
                if (lstat(fullPath.fileSystemRepresentation, &st) != 0) {
                    TBDRecordError(errors, relative, [NSString stringWithFormat:@"lstat: %s", strerror(errno)]);
                    continue;
                }
                if (S_ISLNK(st.st_mode)) continue;

                NSString *category = TBDCategoryForRelativePath(relative);
                NSMutableDictionary *categoryBucket = TBDStatsBucket(categories, category);

                if (S_ISDIR(st.st_mode)) {
                    totalDirs++;
                    processed++;
                    categoryBucket[@"dirs"] = @([categoryBucket[@"dirs"] unsignedLongLongValue] + 1);
                    NSError *listError = nil;
                    NSArray<NSString *> *children = [fm contentsOfDirectoryAtPath:fullPath error:&listError];
                    if (!children) {
                        TBDRecordError(errors, relative, listError.localizedDescription ?: @"failed to list directory");
                    } else {
                        for (NSString *child in children) {
                            if (!child.length) continue;
                            [stack addObject:[relative stringByAppendingPathComponent:child]];
                        }
                    }
                    continue;
                }
                if (!S_ISREG(st.st_mode)) continue;

                unsigned long long logical = (unsigned long long)st.st_size;
                unsigned long long allocated = (unsigned long long)st.st_blocks * 512ULL;
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
                while (dir.length && ![dir isEqualToString:@"."]) {
                    NSMutableDictionary *dirBucket = TBDStatsBucket(directories, dir);
                    TBDAddBytes(dirBucket, logical, allocated);
                    dirBucket[@"files"] = @([dirBucket[@"files"] unsignedLongLongValue] + 1);
                    NSString *parent = [dir stringByDeletingLastPathComponent];
                    if ([parent isEqualToString:dir] || [parent isEqualToString:@"."]) break;
                    dir = parent;
                }

                [topFiles addObject:@{@"path": relative, @"logical": @(logical), @"allocated": @(allocated)}];
                TBDTrimTopFiles(topFiles);

                if ((processed % 3000) == 0) {
                    NSString *progress = [NSString stringWithFormat:@"TeraBoxStorageDiagnostic 0.2.0: analisando…\nItens processados: %lu\nEncontrado até agora: %@\nErros: %lu\n", (unsigned long)processed, TBDHumanBytes(totalAllocated), (unsigned long)errors.count];
                    [progress writeToFile:statusPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
                }
            }
        }

        [topFiles sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [b[@"allocated"] compare:a[@"allocated"]]; }];
        NSArray<NSString *> *sortedDirectories = [directories.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) { return [directories[b][@"allocated"] compare:directories[a][@"allocated"]]; }];
        NSArray<NSString *> *sortedExtensions = [extensions.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) { return [extensions[b][@"allocated"] compare:extensions[a][@"allocated"]]; }];

        NSString *bundleID = NSBundle.mainBundle.bundleIdentifier ?: @"unknown";
        NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"unknown";
        NSString *build = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"unknown";
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss ZZZZZ";

        NSMutableString *summary = [NSMutableString string];
        [summary appendFormat:@"TeraBoxStorageDiagnostic %@\nREAD-ONLY: nenhum dado do TeraBox foi apagado ou alterado.\n\n", TBDVersion];
        [summary appendFormat:@"Generated: %@\nBundle: %@\nTeraBox version: %@ (%@)\nSandbox home: %@\n\n", [formatter stringFromDate:NSDate.date], bundleID, version, build, home];
        [summary appendString:@"TOTAL DA SANDBOX\n----------------\n"];
        [summary appendFormat:@"Logical size: %@ (%llu bytes)\nAllocated size: %@ (%llu bytes)\nFiles: %lu\nDirectories: %lu\nEnumeration errors: %lu\n", TBDHumanBytes(totalLogical), totalLogical, TBDHumanBytes(totalAllocated), totalAllocated, (unsigned long)totalFiles, (unsigned long)totalDirs, (unsigned long)errors.count];
        [summary appendString:@"Nota: este total mede o container de dados do app; não inclui o tamanho do próprio IPA/app bundle.\n\n"];

        [summary appendString:@"CATEGORIAS\n----------\n"];
        NSArray *categoryOrder = @[@"Documents", @"Library/Application Support", @"Library/Caches", @"Library/WebKit", @"Library/HTTPStorages", @"Library/Preferences", @"Library/Other", @"tmp", @"Sandbox/Other"];
        for (NSString *category in categoryOrder) {
            NSDictionary *b = categories[category];
            if (!b) continue;
            [summary appendFormat:@"%@ = %@ allocated | %@ logical | files=%@ | dirs=%@\n", category, TBDHumanBytes([b[@"allocated"] unsignedLongLongValue]), TBDHumanBytes([b[@"logical"] unsignedLongLongValue]), b[@"files"], b[@"dirs"]];
        }

        [summary appendString:@"\nTOP 60 DIRETÓRIOS\n-----------------\n"];
        for (NSUInteger i = 0; i < MIN((NSUInteger)60, sortedDirectories.count); i++) {
            NSString *dir = sortedDirectories[i]; NSDictionary *b = directories[dir];
            [summary appendFormat:@"%lu. %@ allocated | %@ logical | files=%@ | %@\n", (unsigned long)(i + 1), TBDHumanBytes([b[@"allocated"] unsignedLongLongValue]), TBDHumanBytes([b[@"logical"] unsignedLongLongValue]), b[@"files"], dir];
        }

        [summary appendString:@"\nTOP 100 ARQUIVOS\n----------------\n"];
        for (NSUInteger i = 0; i < MIN((NSUInteger)100, topFiles.count); i++) {
            NSDictionary *f = topFiles[i];
            [summary appendFormat:@"%lu. %@ allocated | %@ logical | %@\n", (unsigned long)(i + 1), TBDHumanBytes([f[@"allocated"] unsignedLongLongValue]), TBDHumanBytes([f[@"logical"] unsignedLongLongValue]), f[@"path"]];
        }

        [summary appendString:@"\nTOP 30 EXTENSÕES\n----------------\n"];
        for (NSUInteger i = 0; i < MIN((NSUInteger)30, sortedExtensions.count); i++) {
            NSString *ext = sortedExtensions[i]; NSDictionary *b = extensions[ext];
            [summary appendFormat:@"%lu. %@ allocated | %@ logical | files=%@ | %@\n", (unsigned long)(i + 1), TBDHumanBytes([b[@"allocated"] unsignedLongLongValue]), TBDHumanBytes([b[@"logical"] unsignedLongLongValue]), b[@"files"], ext];
        }

        [summary appendString:@"\nERROS DE ENUMERAÇÃO (máx. 100)\n------------------------------\n"];
        if (!errors.count) [summary appendString:@"Nenhum.\n"];
        else for (NSString *error in errors) [summary appendFormat:@"- %@\n", error];

        NSMutableString *csv = [NSMutableString stringWithString:@"type,name,allocated_bytes,allocated_human,logical_bytes,logical_human,files,directories\n"];
        for (NSString *category in categoryOrder) {
            NSDictionary *b = categories[category]; if (!b) continue;
            [csv appendFormat:@"category,%@,%llu,%@,%llu,%@,%@,%@\n", TBDCSVQuote(category), [b[@"allocated"] unsignedLongLongValue], TBDCSVQuote(TBDHumanBytes([b[@"allocated"] unsignedLongLongValue])), [b[@"logical"] unsignedLongLongValue], TBDCSVQuote(TBDHumanBytes([b[@"logical"] unsignedLongLongValue])), b[@"files"], b[@"dirs"]];
        }
        for (NSUInteger i = 0; i < MIN((NSUInteger)100, sortedDirectories.count); i++) {
            NSString *dir = sortedDirectories[i]; NSDictionary *b = directories[dir];
            [csv appendFormat:@"directory,%@,%llu,%@,%llu,%@,%@,%@\n", TBDCSVQuote(dir), [b[@"allocated"] unsignedLongLongValue], TBDCSVQuote(TBDHumanBytes([b[@"allocated"] unsignedLongLongValue])), [b[@"logical"] unsignedLongLongValue], TBDCSVQuote(TBDHumanBytes([b[@"logical"] unsignedLongLongValue])), b[@"files"], b[@"dirs"]];
        }
        for (NSUInteger i = 0; i < MIN((NSUInteger)150, topFiles.count); i++) {
            NSDictionary *f = topFiles[i];
            [csv appendFormat:@"file,%@,%llu,%@,%llu,%@,1,0\n", TBDCSVQuote(f[@"path"]), [f[@"allocated"] unsignedLongLongValue], TBDCSVQuote(TBDHumanBytes([f[@"allocated"] unsignedLongLongValue])), [f[@"logical"] unsignedLongLongValue], TBDCSVQuote(TBDHumanBytes([f[@"logical"] unsignedLongLongValue]))];
        }
        for (NSUInteger i = 0; i < MIN((NSUInteger)50, sortedExtensions.count); i++) {
            NSString *ext = sortedExtensions[i]; NSDictionary *b = extensions[ext];
            [csv appendFormat:@"extension,%@,%llu,%@,%llu,%@,%@,0\n", TBDCSVQuote(ext), [b[@"allocated"] unsignedLongLongValue], TBDCSVQuote(TBDHumanBytes([b[@"allocated"] unsignedLongLongValue])), [b[@"logical"] unsignedLongLongValue], TBDCSVQuote(TBDHumanBytes([b[@"logical"] unsignedLongLongValue])), b[@"files"]];
        }

        gReportTXTPath = [reportDirectory stringByAppendingPathComponent:@"TeraBoxStorageDiagnostic.txt"];
        gReportCSVPath = [reportDirectory stringByAppendingPathComponent:@"TeraBoxStorageDiagnostic.csv"];
        [summary writeToFile:gReportTXTPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [csv writeToFile:gReportCSVPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [[NSString stringWithFormat:@"Concluído.\nSandbox: %@\nArquivos: %lu\nPastas: %lu\nErros: %lu\n", TBDHumanBytes(totalAllocated), (unsigned long)totalFiles, (unsigned long)totalDirs, (unsigned long)errors.count] writeToFile:statusPath atomically:YES encoding:NSUTF8StringEncoding error:nil];

        NSString *message = [NSString stringWithFormat:@"Sandbox encontrada: %@\nArquivos: %lu\nPastas: %lu\nErros: %lu\n\nRelatórios salvos em Documents/TeraBoxStorageDiagnostic.", TBDHumanBytes(totalAllocated), (unsigned long)totalFiles, (unsigned long)totalDirs, (unsigned long)errors.count];
        NSLog(@"[TeraBoxStorageDiagnostic] %@ finished: %@, files=%lu dirs=%lu errors=%lu", TBDVersion, TBDHumanBytes(totalAllocated), (unsigned long)totalFiles, (unsigned long)totalDirs, (unsigned long)errors.count);
        TBDPresentAlert(@"Diagnóstico concluído", message, YES, 0);
    }
}

__attribute__((constructor))
static void TeraBoxStorageDiagnosticInit(void) {
    @autoreleasepool {
        NSString *bundleID = NSBundle.mainBundle.bundleIdentifier ?: @"";
        NSString *displayName = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleDisplayName"] ?: [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleName"] ?: @"";
        BOOL isTeraBox = [bundleID isEqualToString:@"com.dubox.drive"] || [displayName rangeOfString:@"TeraBox" options:NSCaseInsensitiveSearch].location != NSNotFound;
        if (!isTeraBox) return;
        NSLog(@"[TeraBoxStorageDiagnostic] %@ loaded for %@", TBDVersion, bundleID);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            TBDPresentAlert(@"TeraBoxStorageDiagnostic 0.2", @"Tweak carregado. Vou mapear o container de dados do TeraBox sem apagar nada.", NO, 0);
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            TBDWriteReport();
        });
    }
}
