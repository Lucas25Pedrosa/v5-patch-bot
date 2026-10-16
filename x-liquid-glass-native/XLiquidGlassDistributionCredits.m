#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// XLiquidGlassNative 3.0 - Distribution Edition
// Credits integration only.
// This file does not touch Liquid Glass activation, navigation, badges,
// sidebar, blur, tab bar, routing, or any visual/runtime behavior in X.

static IMP gXLGDistOrigNumberOfSections = NULL;
static IMP gXLGDistOrigNumberOfRows = NULL;
static IMP gXLGDistOrigViewForHeader = NULL;
static IMP gXLGDistOrigHeightForHeader = NULL;
static IMP gXLGDistOrigCellForRow = NULL;
static IMP gXLGDistOrigDidSelectRow = NULL;
static BOOL gXLGDistCreditsHooked = NO;

static BOOL XLGDistHookMethod(Class cls,
                              SEL sel,
                              IMP replacement,
                              IMP *originalOut) {
    if (!cls || !sel || !replacement) return NO;

    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return NO;

    IMP current = class_getMethodImplementation(cls, sel);
    if (current == replacement) return YES;

    const char *types = method_getTypeEncoding(method);
    if (!types) return NO;

    if (originalOut && !*originalOut) *originalOut = current;
    class_replaceMethod(cls, sel, replacement, types);
    return class_getMethodImplementation(cls, sel) == replacement;
}

static NSInteger XLGDistOriginalSectionCount(id controller,
                                              UITableView *tableView) {
    if (!gXLGDistOrigNumberOfSections) return 6;
    return ((NSInteger (*)(id, SEL, UITableView *))gXLGDistOrigNumberOfSections)(
        controller, @selector(numberOfSectionsInTableView:), tableView);
}

static NSInteger XLGDistLiquidGlassSection(id controller,
                                            UITableView *tableView) {
    return MAX((NSInteger)0, XLGDistOriginalSectionCount(controller, tableView) - 1);
}

static NSInteger XLGDistIPASourceSection(id controller,
                                         UITableView *tableView) {
    return XLGDistLiquidGlassSection(controller, tableView) + 1;
}

static NSInteger XLGDistMapSectionToOriginal(id controller,
                                             UITableView *tableView,
                                             NSInteger section) {
    NSInteger ipaSection = XLGDistIPASourceSection(controller, tableView);
    if (section > ipaSection) return section - 2;
    return section;
}

static NSArray *XLGDistLiquidGlassCreditRows(void) {
    return @[@{
        @"title": @"Lucas25Pedrosa",
        @"username": @"Lucas25Pedrosa",
        @"avatarURL": @"https://github.com/Lucas25Pedrosa.png"
    }];
}

static NSArray *XLGDistIPASourceCreditRows(void) {
    return @[@{
        @"title": @"IPA Vault",
        @"username": @"ipavault",
        @"avatarURL": @"https://github.com/927tx.png"
    }];
}

static void XLGDistOpenExternalURL(NSString *urlString) {
    NSURL *url = [NSURL URLWithString:urlString ?: @""];
    if (!url) return;

    UIApplication *application = UIApplication.sharedApplication;
    if ([application respondsToSelector:@selector(openURL:options:completionHandler:)]) {
        [application openURL:url options:@{} completionHandler:nil];
    }
}

static NSInteger XLGDistNumberOfSections(id self,
                                         SEL _cmd,
                                         UITableView *tableView) {
    (void)_cmd;
    NSInteger original = XLGDistOriginalSectionCount(self, tableView);
    return original > 0 ? original + 2 : 8;
}

static NSInteger XLGDistNumberOfRows(id self,
                                     SEL _cmd,
                                     UITableView *tableView,
                                     NSInteger section) {
    NSInteger liquidSection = XLGDistLiquidGlassSection(self, tableView);
    NSInteger ipaSection = XLGDistIPASourceSection(self, tableView);
    if (section == liquidSection || section == ipaSection) return 1;

    NSInteger mapped = XLGDistMapSectionToOriginal(self, tableView, section);
    if (!gXLGDistOrigNumberOfRows) return 0;
    return ((NSInteger (*)(id, SEL, UITableView *, NSInteger))gXLGDistOrigNumberOfRows)(
        self, _cmd, tableView, mapped);
}

static UIView *XLGDistViewForHeader(id self,
                                    SEL _cmd,
                                    UITableView *tableView,
                                    NSInteger section) {
    NSInteger liquidSection = XLGDistLiquidGlassSection(self, tableView);
    NSInteger ipaSection = XLGDistIPASourceSection(self, tableView);

    if (section == liquidSection || section == ipaSection) {
        NSString *title = section == liquidSection ? @"LiquidGlass" : @"IPA Source";
        SEL headerSEL = NSSelectorFromString(@"headerViewWithTitle:");
        if ([self respondsToSelector:headerSEL]) {
            return ((id (*)(id, SEL, id))objc_msgSend)(self, headerSEL, title);
        }
        return nil;
    }

    NSInteger mapped = XLGDistMapSectionToOriginal(self, tableView, section);
    if (!gXLGDistOrigViewForHeader) return nil;
    return ((id (*)(id, SEL, UITableView *, NSInteger))gXLGDistOrigViewForHeader)(
        self, _cmd, tableView, mapped);
}

static CGFloat XLGDistHeightForHeader(id self,
                                      SEL _cmd,
                                      UITableView *tableView,
                                      NSInteger section) {
    NSInteger liquidSection = XLGDistLiquidGlassSection(self, tableView);
    NSInteger ipaSection = XLGDistIPASourceSection(self, tableView);

    if (section == liquidSection || section == ipaSection) {
        return UITableViewAutomaticDimension;
    }

    NSInteger mapped = XLGDistMapSectionToOriginal(self, tableView, section);
    if (!gXLGDistOrigHeightForHeader) return 0.0;
    return ((CGFloat (*)(id, SEL, UITableView *, NSInteger))gXLGDistOrigHeightForHeader)(
        self, _cmd, tableView, mapped);
}

static UITableViewCell *XLGDistFallbackCreditCell(UITableView *tableView,
                                                  NSDictionary *row) {
    static NSString *identifier = @"XLiquidGlassDistributionCreditCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:identifier];
    }
    cell.textLabel.text = row[@"title"] ?: @"";
    NSString *username = row[@"username"] ?: @"";
    cell.detailTextLabel.text = username.length ? [@"@" stringByAppendingString:username] : @"";
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

static UITableViewCell *XLGDistCellForRow(id self,
                                          SEL _cmd,
                                          UITableView *tableView,
                                          NSIndexPath *indexPath) {
    NSInteger liquidSection = XLGDistLiquidGlassSection(self, tableView);
    NSInteger ipaSection = XLGDistIPASourceSection(self, tableView);

    if (indexPath.section == liquidSection || indexPath.section == ipaSection) {
        NSArray *rows = indexPath.section == liquidSection
            ? XLGDistLiquidGlassCreditRows()
            : XLGDistIPASourceCreditRows();

        SEL cellSEL = NSSelectorFromString(@"developerCellForTableView:atIndexPath:fromArray:");
        if ([self respondsToSelector:cellSEL]) {
            NSIndexPath *creditIndex = [NSIndexPath indexPathForRow:0
                                                          inSection:indexPath.section];
            id cell = ((id (*)(id, SEL, id, id, id))objc_msgSend)(
                self, cellSEL, tableView, creditIndex, rows);
            if ([cell isKindOfClass:UITableViewCell.class]) return cell;
        }

        return XLGDistFallbackCreditCell(tableView, rows.firstObject ?: @{});
    }

    NSInteger mappedSection = XLGDistMapSectionToOriginal(self, tableView, indexPath.section);
    NSIndexPath *mappedIndexPath = [NSIndexPath indexPathForRow:indexPath.row
                                                      inSection:mappedSection];
    if (!gXLGDistOrigCellForRow) return [UITableViewCell new];
    return ((id (*)(id, SEL, UITableView *, NSIndexPath *))gXLGDistOrigCellForRow)(
        self, _cmd, tableView, mappedIndexPath);
}

static void XLGDistDidSelectRow(id self,
                                SEL _cmd,
                                UITableView *tableView,
                                NSIndexPath *indexPath) {
    NSInteger liquidSection = XLGDistLiquidGlassSection(self, tableView);
    NSInteger ipaSection = XLGDistIPASourceSection(self, tableView);

    if (indexPath.section == liquidSection) {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        XLGDistOpenExternalURL(@"https://github.com/Lucas25Pedrosa");
        return;
    }

    if (indexPath.section == ipaSection) {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        XLGDistOpenExternalURL(@"https://t.me/ipavault");
        return;
    }

    NSInteger mappedSection = XLGDistMapSectionToOriginal(self, tableView, indexPath.section);
    NSIndexPath *mappedIndexPath = [NSIndexPath indexPathForRow:indexPath.row
                                                      inSection:mappedSection];
    if (gXLGDistOrigDidSelectRow) {
        ((void (*)(id, SEL, UITableView *, NSIndexPath *))gXLGDistOrigDidSelectRow)(
            self, _cmd, tableView, mappedIndexPath);
    }
}

static void XLGDistInstallCredits(void) {
    if (gXLGDistCreditsHooked) return;

    Class rootClass = NSClassFromString(@"ModernSettingsViewController");
    if (!rootClass) return;

    BOOL sectionsHooked = XLGDistHookMethod(
        rootClass,
        @selector(numberOfSectionsInTableView:),
        (IMP)XLGDistNumberOfSections,
        &gXLGDistOrigNumberOfSections);

    BOOL rowsHooked = XLGDistHookMethod(
        rootClass,
        @selector(tableView:numberOfRowsInSection:),
        (IMP)XLGDistNumberOfRows,
        &gXLGDistOrigNumberOfRows);

    BOOL headerHooked = XLGDistHookMethod(
        rootClass,
        @selector(tableView:viewForHeaderInSection:),
        (IMP)XLGDistViewForHeader,
        &gXLGDistOrigViewForHeader);

    BOOL headerHeightHooked = XLGDistHookMethod(
        rootClass,
        @selector(tableView:heightForHeaderInSection:),
        (IMP)XLGDistHeightForHeader,
        &gXLGDistOrigHeightForHeader);

    BOOL cellHooked = XLGDistHookMethod(
        rootClass,
        @selector(tableView:cellForRowAtIndexPath:),
        (IMP)XLGDistCellForRow,
        &gXLGDistOrigCellForRow);

    BOOL selectHooked = XLGDistHookMethod(
        rootClass,
        @selector(tableView:didSelectRowAtIndexPath:),
        (IMP)XLGDistDidSelectRow,
        &gXLGDistOrigDidSelectRow);

    gXLGDistCreditsHooked =
        sectionsHooked && rowsHooked && headerHooked &&
        headerHeightHooked && cellHooked && selectHooked;
}

static void XLGDistScheduleRetry(NSTimeInterval delay) {
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
        dispatch_get_main_queue(),
        ^{
            XLGDistInstallCredits();
        }
    );
}

__attribute__((constructor))
static void XLiquidGlassDistributionCreditsInit(void) {
    @autoreleasepool {
        NSLog(@"[XLiquidGlassNative] 3.0 Distribution Edition credits loaded");
        XLGDistInstallCredits();
        XLGDistScheduleRetry(0.00);
        XLGDistScheduleRetry(0.05);
        XLGDistScheduleRetry(0.20);
        XLGDistScheduleRetry(0.50);
        XLGDistScheduleRetry(1.00);
        XLGDistScheduleRetry(2.00);
        XLGDistScheduleRetry(4.00);
    }
}
