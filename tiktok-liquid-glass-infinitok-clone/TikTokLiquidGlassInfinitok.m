#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>

static NSMutableSet<NSString *> *gHooked;

static const char *SkipQualifiers(const char *t) {
    if (!t) return NULL;
    while (*t == 'r' || *t == 'n' || *t == 'N' || *t == 'o' ||
           *t == 'O' || *t == 'R' || *t == 'V') t++;
    return t;
}

static BOOL IsZeroArgBool(Method m) {
    if (!m || method_getNumberOfArguments(m) != 2) return NO;
    char *ret = method_copyReturnType(m);
    const char *t = SkipQualifiers(ret);
    BOOL ok = t && (t[0] == 'B' || t[0] == 'c');
    if (ret) free(ret);
    return ok;
}

static NSSet<NSString *> *ForceYESSelectors(void) {
    static NSSet<NSString *> *s;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s = [NSSet setWithArray:@[
            @"supportLiquidGlass",
            @"isFixEnabled",
            @"tux_liquid_glass_enabled",
            @"ttTabbarLiquidGlassFix",
            @"isTabBarIOS26LiquidGlassFixEnabled",
            @"isLiquidGlassEnabled",
            @"liquidGlassEnabled",

            // TUXExperiments — mesmos grupos expostos pelo Infinitok.
            @"isLiquidGlassButtonEnabled",
            @"isLiquidGlassMenuEnabled",
            @"isLiquidGlassIntroPanelEnabled",
            @"isIntroPanelLiquidGlassBackgroundGuardEnabled",
            @"isLiquidGlassPopoverEnabled",

            @"isLiquidGlassToastEnabled",
            @"isLiquidGlassCenterToastEnabled",
            @"isLiquidGlassBottomToastEnabled",
            @"isLiquidGlassFloatingNoticeEnabled",
            @"isLiquidGlassInAppPushEnabled",

            @"isLiquidGlassModalEnabled",
            @"isLiquidGlassSheetEnabled",
            @"isLiquidGlassDialogEnabled",
            @"isLiquidGlassStyleEnabled",

            // Outros gates Liquid Glass encontrados no TikTok 47.
            @"feedStandardButtonEnableLiquidGlass",
            @"innerPushLiquidGlassEnable",
            @"innerPushLiquidGlassEnableFlag",
            @"innerPushLiquidGlassInteractiveEnable",
            @"innerPushLiquidGlassInteractiveEnableFlag",
            @"storyFixViewerListRelationButtonLiquidGlass",
            @"enableBigCardLiquidGlass",
            @"studioTextEditorAdaptLiquidGlass",
            @"studioMusicDetailBottomButtonLiquidGlass",
            @"ecPdpStoreV2EnableLiquidGlass",
            @"ugFeedCardLiquidGlassEnable",
            @"p_enableLiquidGlass",
            @"enableLiquidGlass",
            @"isLiquidGlassEnabledForCapture",
            @"isLiquidGlassEnabledForEdit",
            @"should_survey_use_liquid_glass",
            @"live_ec_prompt_card_liquid_glass",
            @"p_isBigCardLiquidGlassEnabled",
            @"p_shouldEnableStyle4OfficialLiquidGlass"
        ]];
    });
    return s;
}

static BOOL ForceYES(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    return YES;
}

static BOOL ForceNO(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    return NO;
}

static BOOL IsLiquidGlassSwitchClass(Class cls) {
    NSString *n = NSStringFromClass(cls).lowercaseString;
    return [n containsString:@"liquidglassswitch"] ||
           [n containsString:@"liquid_glass_switch"];
}

static BOOL GenericSwitchSelector(NSString *name) {
    static NSSet<NSString *> *s;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s = [NSSet setWithArray:@[
            @"isEnabled", @"enabled", @"isOn", @"isOpen",
            @"isAvailable", @"available", @"isSupported", @"supported"
        ]];
    });
    return [s containsObject:name];
}

static void HookMethodOwner(Class owner, BOOL classMethods) {
    if (!owner) return;
    Class methodOwner = classMethods ? object_getClass(owner) : owner;
    if (!methodOwner) return;

    unsigned int count = 0;
    Method *methods = class_copyMethodList(methodOwner, &count);
    BOOL switchClass = IsLiquidGlassSwitchClass(owner);

    for (unsigned int i = 0; i < count; i++) {
        Method m = methods[i];
        if (!IsZeroArgBool(m)) continue;

        SEL sel = method_getName(m);
        NSString *name = NSStringFromSelector(sel);
        NSString *lower = name.lowercaseString;

        BOOL forceNo = [lower containsString:@"disableliquidglass"] ||
                       [lower containsString:@"disable_liquid_glass"];
        BOOL forceYes = [ForceYESSelectors() containsObject:name] ||
                        (switchClass && GenericSwitchSelector(name));

        // Compatibilidade com novos gates TUX adicionados pelo TikTok:
        // somente getters claramente ligados a Liquid Glass.
        if (!forceYes && !forceNo &&
            ([lower containsString:@"liquidglass"] || [lower containsString:@"liquid_glass"])) {
            if ([lower containsString:@"disable"] || [lower containsString:@"blocked"] || [lower containsString:@"blocklist"]) {
                forceNo = YES;
            } else if ([lower hasPrefix:@"is"] || [lower hasPrefix:@"enable"] ||
                       [lower hasPrefix:@"should"] || [lower hasPrefix:@"support"] ||
                       [lower hasSuffix:@"enabled"] || [lower hasSuffix:@"enable"]) {
                forceYes = YES;
            }
        }

        if (!forceYes && !forceNo) continue;

        NSString *key = [NSString stringWithFormat:@"%p|%@", methodOwner, name];
        @synchronized(gHooked) {
            if ([gHooked containsObject:key]) continue;
            IMP replacement = forceNo ? (IMP)ForceNO : (IMP)ForceYES;
            IMP current = method_getImplementation(m);
            if (!current || current == replacement) {
                [gHooked addObject:key];
                continue;
            }
            method_setImplementation(m, replacement);
            [gHooked addObject:key];
            NSLog(@"[TLG-Infinitok] %@ %@[%@ %@]", forceNo ? @"NO" : @"YES",
                  classMethods ? @"+" : @"-", NSStringFromClass(owner), name);
        }
    }

    free(methods);
}

static void ScanAndHook(void) {
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;

    Class *classes = (__unsafe_unretained Class *)calloc((size_t)count, sizeof(Class));
    count = objc_getClassList(classes, count);

    for (int i = 0; i < count; i++) {
        Class cls = classes[i];
        if (!cls) continue;
        HookMethodOwner(cls, NO);
        HookMethodOwner(cls, YES);
    }
    free(classes);
}

static void ImageAdded(const struct mach_header *mh, intptr_t slide) {
    (void)mh; (void)slide;
    dispatch_async(dispatch_get_main_queue(), ^{
        ScanAndHook();
    });
}

__attribute__((constructor))
static void TikTokLiquidGlassInfinitokInit(void) {
    @autoreleasepool {
        gHooked = [NSMutableSet set];

        // Primeira passagem o mais cedo possível.
        ScanAndHook();
        _dyld_register_func_for_add_image(ImageAdded);

        // Repassagens para frameworks/classes carregadas depois do construtor.
        NSArray<NSNumber *> *delays = @[@0.10, @0.35, @0.75, @1.5, @3.0, @6.0];
        for (NSNumber *delay in delays) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                ScanAndHook();
            });
        }

        NSLog(@"[TLG-Infinitok] 0.1 loaded — Liquid Glass gates only; no feed/layout patches");
    }
}
