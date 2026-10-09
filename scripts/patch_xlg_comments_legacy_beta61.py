from pathlib import Path

p = Path('x-liquid-glass-only/XLiquidGlass.m')
s = p.read_text()

# Beta 6.1: safe, query-only comments legacy scope. Never mutates persisted
# defaults and never toggles the global T1LiquidGlassGateInstaller while a
# controller is constructing its view hierarchy.
marker = 'static NSString *const kXLGTabLabelsKey = @"XLiquidGlassTabLabelsEnabled";\n'
insert = r'''

// Beta 6.1: thread-local legacy scope used only while comments controllers
// execute loadView/viewDidLoad. This does not mutate any global persisted state.
static __thread NSUInteger gXLGCommentsLegacyScopeDepth = 0;
static BOOL XLGCommentsLegacyScopeActive(void) {
    return gXLGCommentsLegacyScopeDepth > 0;
}
'''
if 'gXLGCommentsLegacyScopeDepth' not in s:
    if marker not in s:
        raise SystemExit('constants marker not found')
    s = s.replace(marker, marker + insert, 1)

needle = '''static BOOL XLGEnabled(void) {\n    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];\n'''
replacement = '''static BOOL XLGEnabled(void) {\n    if (XLGCommentsLegacyScopeActive()) return NO;\n    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];\n'''
if needle not in s:
    raise SystemExit('XLGEnabled marker not found')
s = s.replace(needle, replacement, 1)

# During the scoped controller build, never force the global redesign gate YES.
needle = '    BOOL forwarded = XLGEnabled() ? YES : requestedState;\n'
replacement = '''    BOOL forwarded = XLGCommentsLegacyScopeActive()\n        ? NO\n        : (XLGEnabled() ? YES : requestedState);\n'''
if needle not in s:
    raise SystemExit('installGate forward marker not found')
s = s.replace(needle, replacement, 1)

helper_marker = 'static BOOL XLGReturnState(id self, SEL _cmd) {'
helper = r'''
static IMP gOrigCommentsContainerLoadView = NULL;
static IMP gOrigCommentsContainerViewDidLoad = NULL;
static IMP gOrigCommentsURTLoadView = NULL;
static IMP gOrigCommentsURTViewDidLoad = NULL;

static IMP XLGCommentsLegacyOriginalFor(id self, SEL cmd) {
    NSString *name = NSStringFromClass([self class]);
    if ([name isEqualToString:@"T1ConversationContainerViewController"]) {
        if (cmd == @selector(loadView)) return gOrigCommentsContainerLoadView;
        if (cmd == @selector(viewDidLoad)) return gOrigCommentsContainerViewDidLoad;
    }
    if ([name isEqualToString:@"T1URTViewController"]) {
        if (cmd == @selector(loadView)) return gOrigCommentsURTLoadView;
        if (cmd == @selector(viewDidLoad)) return gOrigCommentsURTViewDidLoad;
    }
    return NULL;
}

static void XLGCommentsLegacyControllerPhase(id self, SEL cmd) {
    IMP original = XLGCommentsLegacyOriginalFor(self, cmd);
    gXLGCommentsLegacyScopeDepth++;
    @try {
        if (original) ((void (*)(id, SEL))original)(self, cmd);
    } @finally {
        if (gXLGCommentsLegacyScopeDepth > 0) {
            gXLGCommentsLegacyScopeDepth--;
        }
    }
}

static void XLGInstallCommentsLegacyControllerHooks(void) {
    Class conversation = NSClassFromString(@"T1ConversationContainerViewController");
    if (conversation) {
        if (!gOrigCommentsContainerLoadView) {
            XLGHookMethod(conversation,
                          @selector(loadView),
                          NO,
                          (IMP)XLGCommentsLegacyControllerPhase,
                          &gOrigCommentsContainerLoadView);
        }
        if (!gOrigCommentsContainerViewDidLoad) {
            XLGHookMethod(conversation,
                          @selector(viewDidLoad),
                          NO,
                          (IMP)XLGCommentsLegacyControllerPhase,
                          &gOrigCommentsContainerViewDidLoad);
        }
    }

    Class urt = NSClassFromString(@"T1URTViewController");
    if (urt) {
        if (!gOrigCommentsURTLoadView) {
            XLGHookMethod(urt,
                          @selector(loadView),
                          NO,
                          (IMP)XLGCommentsLegacyControllerPhase,
                          &gOrigCommentsURTLoadView);
        }
        if (!gOrigCommentsURTViewDidLoad) {
            XLGHookMethod(urt,
                          @selector(viewDidLoad),
                          NO,
                          (IMP)XLGCommentsLegacyControllerPhase,
                          &gOrigCommentsURTViewDidLoad);
        }
    }
}

__attribute__((constructor))
static void XLGCommentsLegacyBeta61Init(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        XLGInstallCommentsLegacyControllerHooks();
        for (NSNumber *delayValue in @[@0.10, @0.30, @0.75, @1.50, @3.00]) {
            NSTimeInterval delay = delayValue.doubleValue;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(delay * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                XLGInstallCommentsLegacyControllerHooks();
            });
        }
    });
}

'''
if 'XLGCommentsLegacyBeta61Init' not in s:
    if helper_marker not in s:
        raise SystemExit('XLGReturnState insertion marker not found')
    s = s.replace(helper_marker, helper + helper_marker, 1)

# Explicitly keep the native dummy feature path from being forced ON during the
# scoped build. Outside the scope the original stable behavior remains intact.
needle = '''static BOOL XLGDummyTest1Feature(id self, SEL _cmd) {\n    if (XLGEnabled()) return YES;\n'''
replacement = '''static BOOL XLGDummyTest1Feature(id self, SEL _cmd) {\n    if (XLGCommentsLegacyScopeActive()) {\n        if (gOrigDummyFeature) {\n            return ((BOOL (*)(id, SEL))gOrigDummyFeature)(self, _cmd);\n        }\n        return NO;\n    }\n    if (XLGEnabled()) return YES;\n'''
if needle not in s:
    raise SystemExit('dummy feature marker not found')
s = s.replace(needle, replacement, 1)

p.write_text(s)
print('Applied XLiquidGlass Beta 6.1 safe query-only comments legacy patch')
