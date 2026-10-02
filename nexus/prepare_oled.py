from pathlib import Path
import sys

src = Path(sys.argv[1])
out = Path(sys.argv[2])
s = src.read_text(encoding="utf-8")

old = '''        dispatch_async(dispatch_get_main_queue(), ^{
            IQFOLEDStartEngine();
            IQFOLEDTryInstallSettingsHook();
        });'''
assert old in s
s = s.replace(old, '''        dispatch_async(dispatch_get_main_queue(), ^{
            IQFOLEDStartEngine();
        });''', 1)

probe = r'''
// Nexus 1.0.3 Beta 1 OLED Probe ----------------------------------------------
// Diagnostic-only instrumentation for the first 10 seconds of Facebook launch.
// It never changes a color by itself. It records dark/neutral colors that reach
// UIView/CALayer so we can identify the new startup gray used by Facebook.

__attribute__((used, visibility("default")))
NSString * const NexusOLEDProbeBuild = @"1.0.3 Beta 1 OLED Probe";

static CFTimeInterval gNexusOLEDProbeStart = 0.0;
static NSMutableSet<NSString *> *gNexusOLEDProbeSeen = nil;
static NSUInteger gNexusOLEDProbeCount = 0;
static NSString *gNexusOLEDProbePath = nil;
static const NSUInteger kNexusOLEDProbeMaxEntries = 260;
static const CFTimeInterval kNexusOLEDProbeDuration = 10.0;

static NSString *NexusOLEDProbeStyleName(UITraitCollection *traits) {
    if (traits.userInterfaceStyle == UIUserInterfaceStyleDark) return @"dark";
    if (traits.userInterfaceStyle == UIUserInterfaceStyleLight) return @"light";
    return @"unspecified";
}

static BOOL NexusOLEDProbeInteresting(uint32_t rgba) {
    if (rgba == UINT32_MAX) return NO;

    uint8_t r = (uint8_t)((rgba >> 24) & 0xFF);
    uint8_t g = (uint8_t)((rgba >> 16) & 0xFF);
    uint8_t b = (uint8_t)((rgba >> 8) & 0xFF);
    uint8_t a = (uint8_t)(rgba & 0xFF);

    if (a < 0xD0) return NO;

    uint8_t maxRGB = MAX(r, MAX(g, b));
    uint8_t minRGB = MIN(r, MIN(g, b));

    // Startup/background candidates: dark and approximately neutral.
    return maxRGB <= 0x90 && (maxRGB - minRGB) <= 0x28;
}

static void NexusOLEDProbeAppend(NSString *line) {
    if (line.length == 0 || gNexusOLEDProbePath.length == 0) return;

    NSString *full = [line stringByAppendingString:@"\n"];
    NSData *data = [full dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return;

    @synchronized (gNexusOLEDProbeSeen) {
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:gNexusOLEDProbePath];
        if (handle) {
            @try {
                [handle seekToEndOfFile];
                [handle writeData:data];
            } @catch (__unused NSException *exception) {
            }
            [handle closeFile];
        }
    }

    NSLog(@"[NexusOLEDProbe] %@", line);
}

static void NexusOLEDProbeRecord(NSString *source,
                                 NSString *className,
                                 UITraitCollection *traits,
                                 CGRect frame,
                                 uint32_t rgba,
                                 BOOL inWindow) {
    if (gNexusOLEDProbeStart <= 0.0) return;

    CFTimeInterval elapsed = CACurrentMediaTime() - gNexusOLEDProbeStart;
    if (elapsed < 0.0 || elapsed > kNexusOLEDProbeDuration) return;
    if (!NexusOLEDProbeInteresting(rgba)) return;
    if (gNexusOLEDProbeCount >= kNexusOLEDProbeMaxEntries) return;

    NSString *key = [NSString stringWithFormat:@"%@|%@|%08X",
                     source ?: @"?",
                     className ?: @"?",
                     rgba];

    @synchronized (gNexusOLEDProbeSeen) {
        if ([gNexusOLEDProbeSeen containsObject:key]) return;
        [gNexusOLEDProbeSeen addObject:key];
        gNexusOLEDProbeCount += 1;
    }

    NSString *line = [NSString stringWithFormat:
        @"T=%.3f source=%@ class=%@ rgba=#%08X mapped=%@ style=%@ window=%@ frame=%.0fx%.0f",
        elapsed,
        source ?: @"?",
        className ?: @"?",
        rgba,
        IQFOLEDIsMappedDark(rgba) ? @"YES" : @"NO",
        NexusOLEDProbeStyleName(traits),
        inWindow ? @"YES" : @"NO",
        fabs(frame.size.width),
        fabs(frame.size.height)];

    NexusOLEDProbeAppend(line);
}

static void NexusOLEDProbeRecordView(UIView *view, UIColor *color, NSString *source) {
    if (!view || !color) return;
    uint32_t rgba = IQFOLEDRGBA(color, view.traitCollection);
    NexusOLEDProbeRecord(source,
                         NSStringFromClass(view.class),
                         view.traitCollection,
                         view.bounds,
                         rgba,
                         view.window != nil);
}

static void (*NexusOLEDProbeOriginalLayerSetBackgroundColor)(CALayer *, SEL, CGColorRef) = NULL;

static void NexusOLEDProbeLayerSetBackgroundColor(CALayer *layer, SEL command, CGColorRef color) {
    if (color != NULL && gNexusOLEDProbeStart > 0.0) {
        @try {
            UIColor *uiColor = [UIColor colorWithCGColor:color];
            id delegate = layer.delegate;
            if ([delegate isKindOfClass:UIView.class]) {
                UIView *view = (UIView *)delegate;
                uint32_t rgba = IQFOLEDRGBA(uiColor, view.traitCollection);
                NexusOLEDProbeRecord(@"layer-setter",
                                     NSStringFromClass(view.class),
                                     view.traitCollection,
                                     view.bounds,
                                     rgba,
                                     view.window != nil);
            } else {
                uint32_t rgba = IQFOLEDRGBA(uiColor, UITraitCollection.currentTraitCollection);
                NexusOLEDProbeRecord(@"layer-setter",
                                     NSStringFromClass(layer.class),
                                     UITraitCollection.currentTraitCollection,
                                     layer.bounds,
                                     rgba,
                                     NO);
            }
        } @catch (__unused NSException *exception) {
        }
    }

    if (NexusOLEDProbeOriginalLayerSetBackgroundColor != NULL) {
        NexusOLEDProbeOriginalLayerSetBackgroundColor(layer, command, color);
    }
}

static void NexusOLEDProbeInstallLayerHook(void) {
    Method method = class_getInstanceMethod(CALayer.class, @selector(setBackgroundColor:));
    if (!method) return;

    NexusOLEDProbeOriginalLayerSetBackgroundColor =
        (void (*)(CALayer *, SEL, CGColorRef))method_getImplementation(method);
    method_setImplementation(method, (IMP)&NexusOLEDProbeLayerSetBackgroundColor);
}

static void NexusOLEDProbeStartLogging(void) {
    gNexusOLEDProbeStart = CACurrentMediaTime();
    gNexusOLEDProbeSeen = [NSMutableSet set];
    gNexusOLEDProbeCount = 0;

    NSArray<NSString *> *dirs =
        NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *dir = dirs.firstObject ?: NSTemporaryDirectory();
    gNexusOLEDProbePath = [dir stringByAppendingPathComponent:@"NexusOLEDProbe.log"];

    [[NSFileManager defaultManager] removeItemAtPath:gNexusOLEDProbePath error:nil];

    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    NSString *version = info[@"CFBundleShortVersionString"] ?: @"?";
    NSString *build = info[@"CFBundleVersion"] ?: @"?";
    NSString *header = [NSString stringWithFormat:
        @"NEXUS_OLED_PROBE_BEGIN probe=1.0.3-beta1 app=%@ build=%@ ios=%@ path=%@\n",
        version,
        build,
        UIDevice.currentDevice.systemVersion ?: @"?",
        gNexusOLEDProbePath];

    [header writeToFile:gNexusOLEDProbePath
             atomically:YES
               encoding:NSUTF8StringEncoding
                  error:nil];

    NSLog(@"[NexusOLEDProbe] %@", [header stringByTrimmingCharactersInSet:
                                   NSCharacterSet.newlineCharacterSet]);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)((kNexusOLEDProbeDuration + 0.25) * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        NexusOLEDProbeAppend([NSString stringWithFormat:
            @"NEXUS_OLED_PROBE_END entries=%lu duration=%.1fs",
            (unsigned long)gNexusOLEDProbeCount,
            kNexusOLEDProbeDuration]);
    });
}
'''

marker = '''static BOOL IQFOLEDIsBlack(uint32_t rgba) {
    return rgba == 0x000000FF;
}
'''
assert marker in s
s = s.replace(marker, marker + probe, 1)

setter = '''    uint32_t rgba = IQFOLEDRGBA(color, self.traitCollection);

    if (gIQFOLEDEnabled && IQFOLEDIsMappedDark(rgba)) {'''
assert setter in s
s = s.replace(setter, '''    uint32_t rgba = IQFOLEDRGBA(color, self.traitCollection);
    NexusOLEDProbeRecordView(self, color, @"view-setter");

    if (gIQFOLEDEnabled && IQFOLEDIsMappedDark(rgba)) {''', 1)

transform = '''static void IQFOLEDTransformView(UIView *view) {
    if (view.hidden || view.alpha < 0.01) return;
'''
assert transform in s
s = s.replace(transform, '''static void IQFOLEDTransformView(UIView *view) {
    if (view.hidden || view.alpha < 0.01) return;

    if (view.backgroundColor) {
        NexusOLEDProbeRecordView(view, view.backgroundColor, @"pass");
    }
''', 1)

constructor = '''        gIQFOLEDEnabled = IQFOLEDLoadEnabledPreference();
        gIQFOLEDSeparatorsEnabled = IQFOLEDLoadSeparatorsPreference();
        IQFOLEDInstallInstantSetter();

        dispatch_async(dispatch_get_main_queue(), ^{'''
assert constructor in s
s = s.replace(constructor, '''        NexusOLEDProbeStartLogging();
        NexusOLEDProbeInstallLayerHook();

        gIQFOLEDEnabled = IQFOLEDLoadEnabledPreference();
        gIQFOLEDSeparatorsEnabled = IQFOLEDLoadSeparatorsPreference();
        IQFOLEDInstallInstantSetter();

        dispatch_async(dispatch_get_main_queue(), ^{''', 1)

s += '''

id NexusOLEDCreateModeSetting(void) {
    return IQFOLEDCreateNativeIconRow(@"Modo OLED", @"circle.lefthalf.filled");
}
id NexusOLEDCreateSeparatorSetting(void) {
    return IQFOLEDCreateNativeIconRow(@"Separadores no feed", @"line.3.horizontal");
}
void NexusOLEDPrepareSettingsCell(void) {
    IQFOLEDTryInstallAccessorySwitchHook();
}
'''

out.write_text(s, encoding="utf-8")
print("Prepared Nexus 1.0.3 Beta 1 OLED Probe")
