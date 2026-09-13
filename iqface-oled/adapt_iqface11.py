from pathlib import Path

path = Path("Tweak.m")
text = path.read_text(encoding="utf-8")


def replace_once(old: str, new: str, label: str) -> None:
    global text
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly 1 match, found {count}")
    text = text.replace(old, new, 1)


replace_once(
    "// iQFaceOLED 0.2.0",
    "// iQFaceOLED 0.2.1 — iQFace 1.1",
    "version",
)

# The 1.1 settings bridge no longer mutates IQFSettingsViewController rows.
text = text.replace(
    "static const void *kIQFOLEDRowInstalledKey = &kIQFOLEDRowInstalledKey;\n",
    "",
    1,
)

replace_once(
    "static void (*IQFOLEDOriginalViewDidAppear)(UIViewController *, SEL, BOOL) = NULL;",
    "static NSArray *(*IQFOLEDOriginalTweakSections)(id, SEL) = NULL;",
    "settings hook IMP",
)

# These helpers are retained only so the validated 0.2.0 engine diff stays tiny.
text = text.replace(
    "static void IQFOLEDSaveEnabledPreference(BOOL enabled) {",
    "__attribute__((unused)) static void IQFOLEDSaveEnabledPreference(BOOL enabled) {",
    1,
)
text = text.replace(
    "static void IQFOLEDSaveSeparatorsPreference(BOOL enabled) {",
    "__attribute__((unused)) static void IQFOLEDSaveSeparatorsPreference(BOOL enabled) {",
    1,
)

# Native IQFSetting switches write the preference keys. Re-read them on every
# existing OLED pass so the visual engine reacts without any risky switchAction ABI.
replace_once(
    '''        @try {
            NSArray<UIWindow *> *windows = IQFOLEDWindows();

            if (gIQFOLEDEnabled) {''',
    '''        @try {
            gIQFOLEDEnabled = IQFOLEDLoadEnabledPreference();
            gIQFOLEDSeparatorsEnabled = IQFOLEDLoadSeparatorsPreference();

            NSArray<UIWindow *> *windows = IQFOLEDWindows();

            if (gIQFOLEDEnabled) {''',
    "live preference refresh",
)

start_marker = "static BOOL IQFOLEDClassImplementsSelector(Class cls, SEL selector) {"
end_marker = "__attribute__((constructor))\nstatic void IQFOLEDInitialize(void) {"
start = text.find(start_marker)
end = text.find(end_marker)
if start < 0 or end < 0 or end <= start:
    raise SystemExit("settings integration block markers not found")

new_settings = r'''static NSString *IQFOLEDSettingTitle(id setting) {
    NSString *title = nil;
    @try {
        title = [setting valueForKey:@"title"];
    } @catch (__unused NSException *exception) {
        title = nil;
    }
    return [title isKindOfClass:NSString.class] ? title : nil;
}

static BOOL IQFOLEDIsToolsHeader(NSString *header) {
    if (![header isKindOfClass:NSString.class]) return NO;
    NSString *normalized = header.lowercaseString;
    return [normalized isEqualToString:@"tools"] ||
           [normalized isEqualToString:@"ferramentas"] ||
           [normalized isEqualToString:@"herramientas"];
}

static BOOL IQFOLEDIsOLEDTitle(NSString *title) {
    return [title isEqualToString:@"Modo OLED"] ||
           [title isEqualToString:@"OLED Mode"];
}

static BOOL IQFOLEDIsSeparatorTitle(NSString *title) {
    return [title isEqualToString:@"Separadores no feed"] ||
           [title isEqualToString:@"Feed separators"];
}

static id IQFOLEDCreateNativeSwitch(NSString *title,
                                    NSString *defaultsKey,
                                    BOOL defaultOn) {
    Class settingClass = NSClassFromString(@"IQFSetting");
    SEL selector = NSSelectorFromString(@"switchCellWithTitle:subtitle:defaultsKey:defaultOn:");
    if (settingClass == Nil || ![settingClass respondsToSelector:selector]) return nil;

    // ABI confirmed by the iQFace 1.1 probe:
    // @44@0:8@16@24@32B40
    typedef id (*IQFOLEDSwitchFactory)(id, SEL, id, id, id, BOOL);
    IQFOLEDSwitchFactory factory = (IQFOLEDSwitchFactory)(void *)objc_msgSend;
    return factory(settingClass, selector, title, nil, defaultsKey, defaultOn);
}

static NSUInteger IQFOLEDPreferredOLEDIndex(NSArray *rows) {
    for (NSUInteger i = 0; i < rows.count; i++) {
        NSString *title = IQFOLEDSettingTitle(rows[i]);
        if ([title isEqualToString:@"Alterar ícone"] ||
            [title isEqualToString:@"Change Icon"]) {
            return i + 1;
        }
    }

    for (NSUInteger i = 0; i < rows.count; i++) {
        NSString *title = IQFOLEDSettingTitle(rows[i]);
        if ([title isEqualToString:@"Limpar cache"] ||
            [title isEqualToString:@"Clear cache"] ||
            [title isEqualToString:@"Limpar cache automaticamente"] ||
            [title isEqualToString:@"Clear cache automatically"]) {
            return i;
        }
    }

    return rows.count;
}

static NSArray *IQFOLEDSectionsWithControls(NSArray *sections) {
    if (![sections isKindOfClass:NSArray.class] || sections.count == 0) return sections;

    BOOL hasOLED = NO;
    BOOL hasSeparator = NO;
    NSInteger toolsIndex = NSNotFound;

    for (NSUInteger i = 0; i < sections.count; i++) {
        id rawSection = sections[i];
        if (![rawSection isKindOfClass:NSDictionary.class]) continue;

        NSString *header = [rawSection[@"header"] isKindOfClass:NSString.class]
            ? rawSection[@"header"]
            : nil;
        if (IQFOLEDIsToolsHeader(header)) toolsIndex = (NSInteger)i;

        NSArray *rows = [rawSection[@"rows"] isKindOfClass:NSArray.class]
            ? rawSection[@"rows"]
            : @[];
        for (id row in rows) {
            NSString *title = IQFOLEDSettingTitle(row);
            if (IQFOLEDIsOLEDTitle(title)) hasOLED = YES;
            if (IQFOLEDIsSeparatorTitle(title)) hasSeparator = YES;
        }
    }

    if (hasOLED && hasSeparator) return sections;

    id oledSetting = hasOLED ? nil : IQFOLEDCreateNativeSwitch(@"Modo OLED",
                                                               IQFOLEDPreferenceKey,
                                                               YES);
    id separatorSetting = hasSeparator ? nil : IQFOLEDCreateNativeSwitch(@"Separadores no feed",
                                                                          IQFOLEDSeparatorsPreferenceKey,
                                                                          NO);
    if ((!hasOLED && oledSetting == nil) || (!hasSeparator && separatorSetting == nil)) {
        return sections;
    }

    NSMutableArray *updatedSections = [sections mutableCopy];

    if (toolsIndex == NSNotFound) {
        NSMutableArray *rows = [NSMutableArray array];
        if (oledSetting != nil) [rows addObject:oledSetting];
        if (separatorSetting != nil) [rows addObject:separatorSetting];
        if (rows.count == 0) return sections;

        NSDictionary *toolsSection = @{
            @"header": @"FERRAMENTAS",
            @"rows": [rows copy]
        };

        NSUInteger insertionIndex = updatedSections.count;
        for (NSUInteger i = 0; i < updatedSections.count; i++) {
            id rawSection = updatedSections[i];
            if (![rawSection isKindOfClass:NSDictionary.class]) continue;
            NSString *header = [rawSection[@"header"] isKindOfClass:NSString.class]
                ? rawSection[@"header"]
                : nil;
            if ([header caseInsensitiveCompare:@"DEV"] == NSOrderedSame ||
                [header caseInsensitiveCompare:@"ABOUT"] == NSOrderedSame) {
                insertionIndex = i;
                break;
            }
        }

        [updatedSections insertObject:toolsSection
                              atIndex:MIN(insertionIndex, updatedSections.count)];
        return [updatedSections copy];
    }

    NSDictionary *existingSection = updatedSections[(NSUInteger)toolsIndex];
    NSMutableDictionary *updatedSection = [existingSection mutableCopy];
    NSArray *existingRows = [existingSection[@"rows"] isKindOfClass:NSArray.class]
        ? existingSection[@"rows"]
        : @[];
    NSMutableArray *updatedRows = [existingRows mutableCopy];

    if (oledSetting != nil) {
        NSUInteger index = IQFOLEDPreferredOLEDIndex(updatedRows);
        [updatedRows insertObject:oledSetting atIndex:MIN(index, updatedRows.count)];
    }

    if (separatorSetting != nil) {
        NSUInteger index = updatedRows.count;
        for (NSUInteger i = 0; i < updatedRows.count; i++) {
            if (IQFOLEDIsOLEDTitle(IQFOLEDSettingTitle(updatedRows[i]))) {
                index = i + 1;
                break;
            }
        }
        [updatedRows insertObject:separatorSetting atIndex:MIN(index, updatedRows.count)];
    }

    updatedSection[@"rows"] = [updatedRows copy];
    updatedSections[(NSUInteger)toolsIndex] = [updatedSection copy];
    return [updatedSections copy];
}

static NSArray *IQFOLEDTweakSections(id self, SEL command) {
    NSArray *sections = IQFOLEDOriginalTweakSections != NULL
        ? IQFOLEDOriginalTweakSections(self, command)
        : nil;
    return IQFOLEDSectionsWithControls(sections);
}

static void IQFOLEDTryInstallSettingsHook(void) {
    if (gIQFOLEDSettingsHookInstalled) return;

    gIQFOLEDSettingsHookAttempts += 1;
    Class target = NSClassFromString(@"IQFTweakSettings");
    SEL selector = NSSelectorFromString(@"sections");
    Method method = target != Nil ? class_getClassMethod(target, selector) : NULL;

    if (method != NULL) {
        IQFOLEDOriginalTweakSections = (NSArray *(*)(id, SEL))method_getImplementation(method);
        method_setImplementation(method, (IMP)&IQFOLEDTweakSections);
        gIQFOLEDSettingsHookInstalled = YES;
    }

    if (!gIQFOLEDSettingsHookInstalled && gIQFOLEDSettingsHookAttempts < 120) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            IQFOLEDTryInstallSettingsHook();
        });
    }
}

'''

text = text[:start] + new_settings + text[end:]

path.write_text(text, encoding="utf-8")
print("Adapted iQFaceOLED 0.2.1 settings to iQFace 1.1 IQFSetting switches")
