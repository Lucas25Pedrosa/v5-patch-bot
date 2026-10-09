from pathlib import Path

p = Path('x-liquid-glass-only/XLiquidGlass.m')
s = p.read_text()

# 1) Thread-local scope flag available before XLGEnabled().
marker = 'static NSString *const kXLGTabLabelsKey = @"XLiquidGlassTabLabelsEnabled";\n'
insert = r'''

// Beta 6: while the comments hierarchy is being constructed, expose the
// native legacy gate instead of XLiquidGlass's global YES override.
static __thread NSUInteger gXLGCommentsLegacyScopeDepth = 0;
static BOOL XLGCommentsLegacyScopeActive(void) {
    return gXLGCommentsLegacyScopeDepth > 0;
}
'''
if 'gXLGCommentsLegacyScopeDepth' not in s:
    if marker not in s:
        raise SystemExit('constants marker not found')
    s = s.replace(marker, marker + insert, 1)

# 2) Make every existing XLGEnabled()-backed feature report OFF only while
#    constructing the comments controllers.
needle = '''static BOOL XLGEnabled(void) {\n    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];\n'''
replacement = '''static BOOL XLGEnabled(void) {\n    if (XLGCommentsLegacyScopeActive()) return NO;\n    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];\n'''
if needle not in s:
    raise SystemExit('XLGEnabled marker not found')
s = s.replace(needle, replacement, 1)

# 3) Force installGateWithRedesignEnabled:NO inside the scoped construction,
#    even if the native caller passes YES.
needle = '    BOOL forwarded = XLGEnabled() ? YES : requestedState;\n'
replacement = '''    BOOL forwarded = XLGCommentsLegacyScopeActive()\n        ? NO\n        : (XLGEnabled() ? YES : requestedState);\n'''
if needle not in s:
    raise SystemExit('installGate forward marker not found')
s = s.replace(needle, replacement, 1)

# 4) Insert scoped controller hooks just before XLGReturnState.  We hook both
#    outer ConversationContainer and inner URT controller, around loadView and
#    viewDidLoad, because X can choose the ScrollEdge hierarchy in either phase.
helper_marker = 'static BOOL XLGReturnState(id self, SEL _cmd) {'
helper = r'''
static IMP gOrigCommentsContainerLoadView = NULL;
static IMP gOrigCommentsContainerViewDidLoad = NULL;
static IMP gOrigCommentsURTLoadView = NULL;
static IMP gOrigCommentsURTViewDidLoad = NULL;
static id gXLGCommentsSavedPersistedGate = nil;
static BOOL gXLGCommentsHadPersistedGate = NO;

static void XLGCommentsLegacySetNativeGate(BOOL enabled) {
    Class installer = NSClassFromString(@"T1LiquidGlassGateInstaller");
    SEL gateSEL = NSSelectorFromString(@"installGateWithRedesignEnabled:");
    if (installer && [installer respondsToSelector:gateSEL]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(installer, gateSEL, enabled);
    }
}

static void XLGCommentsLegacyBeginScope(void) {
    if (gXLGCommentsLegacyScopeDepth++ > 0) return;

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    gXLGCommentsSavedPersistedGate = [defaults objectForKey:kXLGPersistedGateKey];
    gXLGCommentsHadPersistedGate = (gXLGCommentsSavedPersistedGate != nil);
    [defaults removeObjectForKey:kXLGPersistedGateKey];

    // Depth is already >0, so our global gate hook forwards NO here.
    XLGCommentsLegacySetNativeGate(NO);
}

static void XLGCommentsLegacyEndScope(void) {
    if (gXLGCommentsLegacyScopeDepth == 0) return;
    gXLGCommentsLegacyScopeDepth--;
    if (gXLGCommentsLegacyScopeDepth > 0) return;

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (gXLGCommentsHadPersistedGate && gXLGCommentsSavedPersistedGate) {
        [defaults setObject:gXLGCommentsSavedPersistedGate forKey:kXLGPersistedGateKey];
    } else {
        [defaults removeObjectForKey:kXLGPersistedGateKey];
    }
    gXLGCommentsSavedPersistedGate = nil;
    gXLGCommentsHadPersistedGate = NO;

    if (XLGEnabled()) {
        XLGCommentsLegacySetNativeGate(YES);
    }
}

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
    XLGCommentsLegacyBeginScope();
    @try {
        if (original) ((void (*)(id, SEL))original)(self, cmd);
    } @finally {
        XLGCommentsLegacyEndScope();
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
static void XLGCommentsLegacyBeta6Init(void) {
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
if 'XLGCommentsLegacyBeta6Init' not in s:
    if helper_marker not in s:
        raise SystemExit('XLGReturnState insertion marker not found')
    s = s.replace(helper_marker, helper + helper_marker, 1)

p.write_text(s)
print('Applied XLiquidGlass Beta 6 comments legacy gate patch')
