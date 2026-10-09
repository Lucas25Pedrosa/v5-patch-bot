from pathlib import Path

p = Path('x-liquid-glass-only/XLiquidGlass.m')
s = p.read_text()

# Keep the legacy gate active for the whole visible lifetime of comments.
marker = 'static NSString *const kXLGTabLabelsKey = @"XLiquidGlassTabLabelsEnabled";\n'
insert = r'''

// Beta 6.2: global visibility-scoped legacy mode for comments.
// This is intentionally in-memory only: no persisted gate writes and no
// installer toggles while the comments screen is active.
static volatile BOOL gXLGCommentsLegacyVisible = NO;
static BOOL XLGCommentsLegacyVisibleActive(void) {
    return gXLGCommentsLegacyVisible;
}
'''
if 'gXLGCommentsLegacyVisible' not in s:
    if marker not in s:
        raise SystemExit('constants marker not found')
    s = s.replace(marker, marker + insert, 1)

needle = '''static BOOL XLGEnabled(void) {\n    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];\n'''
replacement = '''static BOOL XLGEnabled(void) {\n    if (XLGCommentsLegacyVisibleActive()) return NO;\n    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];\n'''
if needle not in s:
    raise SystemExit('XLGEnabled marker not found')
s = s.replace(needle, replacement, 1)

helper_marker = 'static BOOL XLGReturnState(id self, SEL _cmd) {'
helper = r'''
static IMP gOrigCommentsContainerLoadView62 = NULL;
static IMP gOrigCommentsContainerViewWillAppear62 = NULL;
static IMP gOrigCommentsContainerViewDidDisappear62 = NULL;

static void XLGCommentsContainerLoadView62(id self, SEL _cmd) {
    // Set before native construction so every XLG-backed feature getter sees
    // legacy state during hierarchy creation. Keep it active afterwards so
    // async XColorEngine/Combine queries on any thread also see legacy state.
    gXLGCommentsLegacyVisible = YES;
    if (gOrigCommentsContainerLoadView62) {
        ((void (*)(id, SEL))gOrigCommentsContainerLoadView62)(self, _cmd);
    }
}

static void XLGCommentsContainerViewWillAppear62(id self, SEL _cmd, BOOL animated) {
    gXLGCommentsLegacyVisible = YES;
    if (gOrigCommentsContainerViewWillAppear62) {
        ((void (*)(id, SEL, BOOL))gOrigCommentsContainerViewWillAppear62)(self, _cmd, animated);
    }
}

static void XLGCommentsContainerViewDidDisappear62(id self, SEL _cmd, BOOL animated) {
    if (gOrigCommentsContainerViewDidDisappear62) {
        ((void (*)(id, SEL, BOOL))gOrigCommentsContainerViewDidDisappear62)(self, _cmd, animated);
    }
    gXLGCommentsLegacyVisible = NO;
}

static void XLGInstallCommentsVisibleLegacyHooks62(void) {
    Class conversation = NSClassFromString(@"T1ConversationContainerViewController");
    if (!conversation) return;

    if (!gOrigCommentsContainerLoadView62) {
        XLGHookMethod(conversation,
                      @selector(loadView),
                      NO,
                      (IMP)XLGCommentsContainerLoadView62,
                      &gOrigCommentsContainerLoadView62);
    }
    if (!gOrigCommentsContainerViewWillAppear62) {
        XLGHookMethod(conversation,
                      @selector(viewWillAppear:),
                      NO,
                      (IMP)XLGCommentsContainerViewWillAppear62,
                      &gOrigCommentsContainerViewWillAppear62);
    }
    if (!gOrigCommentsContainerViewDidDisappear62) {
        XLGHookMethod(conversation,
                      @selector(viewDidDisappear:),
                      NO,
                      (IMP)XLGCommentsContainerViewDidDisappear62,
                      &gOrigCommentsContainerViewDidDisappear62);
    }
}

__attribute__((constructor))
static void XLGCommentsVisibleLegacyBeta62Init(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        XLGInstallCommentsVisibleLegacyHooks62();
        for (NSNumber *delayValue in @[@0.10, @0.30, @0.75, @1.50, @3.00]) {
            NSTimeInterval delay = delayValue.doubleValue;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(delay * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                XLGInstallCommentsVisibleLegacyHooks62();
            });
        }
    });
}

'''
if 'XLGCommentsVisibleLegacyBeta62Init' not in s:
    if helper_marker not in s:
        raise SystemExit('XLGReturnState insertion marker not found')
    s = s.replace(helper_marker, helper + helper_marker, 1)

p.write_text(s)
print('Applied XLiquidGlass Beta 6.2 comments visible legacy patch')
