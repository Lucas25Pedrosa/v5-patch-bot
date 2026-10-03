from pathlib import Path

p = Path("Tweak.m")
s = p.read_text(encoding="utf-8")


def rep(old: str, new: str, label: str) -> None:
    global s
    n = s.count(old)
    if n != 1:
        raise SystemExit(f"{label}: expected exactly 1 match, found {n}")
    s = s.replace(old, new, 1)


rep("// iQFaceOLED 0.2.1 — iQFace 1.1",
    "// iQFaceOLED 0.2.5 — iQFace 1.1 native-icon switches",
    "version")

rep('''static BOOL IQFOLEDLoadEnabledPreference(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults objectForKey:IQFOLEDPreferenceKey] == nil) {
        return YES;
    }
    return [defaults boolForKey:IQFOLEDPreferenceKey];
}
''', '''static BOOL IQFOLEDLoadEnabledPreference(void) {
    Class prefs = NSClassFromString(@"IQFPrefs");
    SEL selector = NSSelectorFromString(@"boolForKey:defaultValue:");
    if (prefs != Nil && [prefs respondsToSelector:selector]) {
        typedef BOOL (*Getter)(id, SEL, id, BOOL);
        return ((Getter)(void *)objc_msgSend)(prefs, selector, IQFOLEDPreferenceKey, YES);
    }
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults objectForKey:IQFOLEDPreferenceKey] == nil) return YES;
    return [defaults boolForKey:IQFOLEDPreferenceKey];
}
''', "OLED pref reader")

rep('''static BOOL IQFOLEDLoadSeparatorsPreference(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults objectForKey:IQFOLEDSeparatorsPreferenceKey] == nil) return NO;
    return [defaults boolForKey:IQFOLEDSeparatorsPreferenceKey];
}
''', '''static BOOL IQFOLEDLoadSeparatorsPreference(void) {
    Class prefs = NSClassFromString(@"IQFPrefs");
    SEL selector = NSSelectorFromString(@"boolForKey:defaultValue:");
    if (prefs != Nil && [prefs respondsToSelector:selector]) {
        typedef BOOL (*Getter)(id, SEL, id, BOOL);
        return ((Getter)(void *)objc_msgSend)(prefs, selector, IQFOLEDSeparatorsPreferenceKey, NO);
    }
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults objectForKey:IQFOLEDSeparatorsPreferenceKey] == nil) return NO;
    return [defaults boolForKey:IQFOLEDSeparatorsPreferenceKey];
}
''', "separator pref reader")

old_factory = r'''static id IQFOLEDCreateNativeSwitch(NSString *title,
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
'''

new_factory = r'''static id IQFOLEDCreateNativeIconRow(NSString *title, NSString *icon) {
    Class settingClass = NSClassFromString(@"IQFSetting");
    SEL selector = NSSelectorFromString(@"staticCellWithTitle:subtitle:icon:");
    if (settingClass == Nil || ![settingClass respondsToSelector:selector]) return nil;

    // ABI confirmed by the iQFace 1.1 probe:
    // @40@0:8@16@24@32
    typedef id (*IQFOLEDStaticFactory)(id, SEL, id, id, id);
    IQFOLEDStaticFactory factory = (IQFOLEDStaticFactory)(void *)objc_msgSend;
    return factory(settingClass, selector, title, nil, icon);
}
'''
rep(old_factory, new_factory, "native row factory")

rep('''IQFOLEDCreateNativeSwitch(@"Modo OLED",
                                                               IQFOLEDPreferenceKey,
                                                               YES)''', '''IQFOLEDCreateNativeIconRow(@"Modo OLED",
                                                                @"circle.lefthalf.filled")''', "OLED row")

rep('''IQFOLEDCreateNativeSwitch(@"Separadores no feed",
                                                                          IQFOLEDSeparatorsPreferenceKey,
                                                                          NO)''', '''IQFOLEDCreateNativeIconRow(@"Separadores no feed",
                                                                     @"line.3.horizontal")''', "separator row")

# Install the accessory hook only when the iQFace settings model is actually requested.
decl = "static NSArray *IQFOLEDTweakSections(id self, SEL command) {"
if decl not in s:
    raise SystemExit("IQFOLEDTweakSections declaration not found")
s = s.replace(decl,
              "static void IQFOLEDTryInstallAccessorySwitchHook(void);\n\n" + decl,
              1)

rep('''    return IQFOLEDSectionsWithControls(sections);
}''', '''    IQFOLEDTryInstallAccessorySwitchHook();
    return IQFOLEDSectionsWithControls(sections);
}''', "install accessory hook")

marker = '''__attribute__((constructor))
static void IQFOLEDInitialize(void) {'''
if marker not in s:
    raise SystemExit("constructor marker not found")

bridge = r'''static void IQFOLEDSetBoolPreference(NSString *key, BOOL value) {
    if (key.length == 0) return;

    Class prefs = NSClassFromString(@"IQFPrefs");
    SEL selector = NSSelectorFromString(@"setBool:forKey:");
    if (prefs != Nil && [prefs respondsToSelector:selector]) {
        typedef void (*Setter)(id, SEL, BOOL, id);
        ((Setter)(void *)objc_msgSend)(prefs, selector, value, key);
        return;
    }

    [NSUserDefaults.standardUserDefaults setBool:value forKey:key];
}

@interface IQFOLEDSwitchAccessoryBridge : NSObject
+ (instancetype)sharedBridge;
- (void)switchChanged:(UISwitch *)sender;
@end

@implementation IQFOLEDSwitchAccessoryBridge
+ (instancetype)sharedBridge {
    static IQFOLEDSwitchAccessoryBridge *bridge = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ bridge = [IQFOLEDSwitchAccessoryBridge new]; });
    return bridge;
}

- (void)switchChanged:(UISwitch *)sender {
    if (sender.tag == 9101) {
        IQFOLEDSetBoolPreference(IQFOLEDPreferenceKey, sender.isOn);
    } else if (sender.tag == 9102) {
        IQFOLEDSetBoolPreference(IQFOLEDSeparatorsPreferenceKey, sender.isOn);
    }
}
@end

static UITableViewCell *(*IQFOLEDOriginalCellForRow)(id, SEL, UITableView *, NSIndexPath *) = NULL;
static BOOL gIQFOLEDAccessoryHookInstalled = NO;
static NSInteger gIQFOLEDAccessoryHookAttempts = 0;

static UITableViewCell *IQFOLEDCellForRowWithAccessory(id self,
                                                       SEL command,
                                                       UITableView *tableView,
                                                       NSIndexPath *indexPath) {
    UITableViewCell *cell = IQFOLEDOriginalCellForRow != NULL
        ? IQFOLEDOriginalCellForRow(self, command, tableView, indexPath)
        : nil;
    if (cell == nil || indexPath == nil) return cell;

    SEL settingSelector = NSSelectorFromString(@"settingForIndexPath:");
    if (![self respondsToSelector:settingSelector]) return cell;

    typedef id (*SettingGetter)(id, SEL, id);
    id setting = ((SettingGetter)(void *)objc_msgSend)(self, settingSelector, indexPath);
    NSString *title = IQFOLEDSettingTitle(setting);

    NSInteger tag = 0;
    BOOL on = NO;
    if (IQFOLEDIsOLEDTitle(title)) {
        tag = 9101;
        on = IQFOLEDLoadEnabledPreference();
    } else if (IQFOLEDIsSeparatorTitle(title)) {
        tag = 9102;
        on = IQFOLEDLoadSeparatorsPreference();
    } else {
        return cell;
    }

    UISwitch *toggle = [UISwitch new];
    toggle.tag = tag;
    toggle.on = on;
    [toggle addTarget:[IQFOLEDSwitchAccessoryBridge sharedBridge]
               action:@selector(switchChanged:)
     forControlEvents:UIControlEventValueChanged];

    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.accessoryView = toggle;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}

static void IQFOLEDTryInstallAccessorySwitchHook(void) {
    if (gIQFOLEDAccessoryHookInstalled) return;
    gIQFOLEDAccessoryHookAttempts += 1;

    Class target = NSClassFromString(@"IQFSettingsViewController");
    SEL selector = NSSelectorFromString(@"tableView:cellForRowAtIndexPath:");
    Method method = target != Nil ? class_getInstanceMethod(target, selector) : NULL;

    if (method != NULL) {
        IQFOLEDOriginalCellForRow =
            (UITableViewCell *(*)(id, SEL, UITableView *, NSIndexPath *))method_getImplementation(method);
        method_setImplementation(method, (IMP)&IQFOLEDCellForRowWithAccessory);
        gIQFOLEDAccessoryHookInstalled = YES;
    }

    if (!gIQFOLEDAccessoryHookInstalled && gIQFOLEDAccessoryHookAttempts < 120) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ IQFOLEDTryInstallAccessorySwitchHook(); });
    }
}

'''

s = s.replace(marker, bridge + marker, 1)
p.write_text(s, encoding="utf-8")
print("Adapted iQFaceOLED 0.2.5: native icon rows + UISwitch accessory bridge")
