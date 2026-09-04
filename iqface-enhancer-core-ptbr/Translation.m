#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <string.h>

typedef void (*IQFMSHookMessageExFunction)(Class cls, SEL selector, IMP replacement, IMP *original);

static IMP IQFPTOriginalViewDidLayoutSubviews = NULL;
static IMP IQFPTOriginalViewDidAppear = NULL;
static BOOL IQFPTLayoutHookInstalled = NO;
static BOOL IQFPTAppearHookInstalled = NO;

static void *IQFPTFindSymbol(const char *name) {
    void *symbol = dlsym(RTLD_DEFAULT, name);
    if (symbol != NULL) return symbol;

    char underscored[128] = {0};
    if (strlen(name) + 2 < sizeof(underscored)) {
        underscored[0] = '_';
        strlcpy(underscored + 1, name, sizeof(underscored) - 1);
        symbol = dlsym(RTLD_DEFAULT, underscored);
    }
    return symbol;
}

static NSDictionary<NSString *, NSString *> *IQFPortugueseUIStrings(void) {
    static NSDictionary<NSString *, NSString *> *translations;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        translations = @{
            @"About": @"Sobre",
            @"Anonymous stories": @"Stories anônimos",
            @"Asks before an action that is easy to tap by accident. Everything here is off until you turn it on.": @"Pede confirmação antes de ações que podem ser tocadas por engano. Todas ficam desativadas até você ativá-las.",
            @"Back": @"Voltar",
            @"Block ads": @"Bloquear anúncios",
            @"Blocks sponsored posts in the feed, and ads inside stories and Reels.": @"Bloqueia publicações patrocinadas no feed e anúncios dentro de stories e Reels.",
            @"Confirm follow and join": @"Confirmar seguir/entrar",
            @"Confirm friend requests": @"Confirmar amizades",
            @"Confirm likes": @"Confirmar curtidas",
            @"Confirm posting a comment": @"Confirmar comentário",
            @"Confirm publishing": @"Confirmar publicação",
            @"Confirm reporting": @"Confirmar denúncia",
            @"Confirm sending a message": @"Confirmar mensagem",
            @"Confirm sharing": @"Confirmar compartilhamento",
            @"Confirmations": @"Confirmações",
            @"Developer": @"Desenvolvedor",
            @"Download videos": @"Baixar vídeos",
            @"English": @"Inglês",
            @"Features": @"Recursos",
            @"Feed": @"Feed",
            @"Follow system": @"Seguir idioma do sistema",
            @"Hide \"People You May Know\"": @"Ocultar pessoas sugeridas",
            @"Hide group suggestions": @"Ocultar grupos sugeridos",
            @"Hide suggested Reels": @"Ocultar Reels sugeridos",
            @"Join Telegram channel": @"Entrar no canal do Telegram",
            @"Language": @"Idioma",
            @"Removes these cards from the feed entirely — nothing is left in their place. Each is off until you turn it on.": @"Remove completamente esses cartões do feed, sem deixar espaços no lugar. Cada opção fica desativada até você ativá-las.",
            @"Tools": @"Ferramentas",
            @"iQFace Settings": @"Ajustes do iQFace"
        };
    });
    return translations;
}

static NSString *IQFTranslateUIString(NSString *text) {
    if (text.length == 0) return text;
    NSString *translated = IQFPortugueseUIStrings()[text];
    return translated ?: text;
}

static void IQFTranslateBarButtonItem(UIBarButtonItem *item) {
    if (item == nil || item.title.length == 0) return;
    NSString *translated = IQFTranslateUIString(item.title);
    if (![translated isEqualToString:item.title]) item.title = translated;
}

static void IQFTranslateViewTree(UIView *view) {
    if (view == nil) return;

    if ([view isKindOfClass:UILabel.class]) {
        UILabel *label = (UILabel *)view;
        NSString *translated = IQFTranslateUIString(label.text);
        if (![translated isEqualToString:label.text]) label.text = translated;
    } else if ([view isKindOfClass:UIButton.class]) {
        UIButton *button = (UIButton *)view;
        UIControlState states[] = {UIControlStateNormal, UIControlStateHighlighted, UIControlStateSelected, UIControlStateDisabled};
        for (NSUInteger index = 0; index < sizeof(states) / sizeof(states[0]); index++) {
            UIControlState state = states[index];
            NSString *source = [button titleForState:state];
            if (source.length == 0) continue;
            NSString *translated = IQFTranslateUIString(source);
            if (![translated isEqualToString:source]) [button setTitle:translated forState:state];
        }
    } else if ([view isKindOfClass:UITextView.class]) {
        UITextView *textView = (UITextView *)view;
        NSString *translated = IQFTranslateUIString(textView.text);
        if (![translated isEqualToString:textView.text]) textView.text = translated;
    } else if ([view isKindOfClass:UITextField.class]) {
        UITextField *field = (UITextField *)view;
        NSString *translatedText = IQFTranslateUIString(field.text);
        if (![translatedText isEqualToString:field.text]) field.text = translatedText;
        NSString *translatedPlaceholder = IQFTranslateUIString(field.placeholder);
        if (![translatedPlaceholder isEqualToString:field.placeholder]) field.placeholder = translatedPlaceholder;
    } else if ([view isKindOfClass:UISegmentedControl.class]) {
        UISegmentedControl *segmented = (UISegmentedControl *)view;
        for (NSInteger index = 0; index < segmented.numberOfSegments; index++) {
            NSString *source = [segmented titleForSegmentAtIndex:index];
            if (source.length == 0) continue;
            NSString *translated = IQFTranslateUIString(source);
            if (![translated isEqualToString:source]) [segmented setTitle:translated forSegmentAtIndex:index];
        }
    }

    for (UIView *subview in view.subviews.copy) {
        IQFTranslateViewTree(subview);
    }
}

static void IQFTranslateSettingsController(UIViewController *controller) {
    if (controller == nil) return;

    NSString *translatedTitle = IQFTranslateUIString(controller.title);
    if (![translatedTitle isEqualToString:controller.title]) controller.title = translatedTitle;

    UINavigationItem *navigationItem = controller.navigationItem;
    NSString *translatedNavTitle = IQFTranslateUIString(navigationItem.title);
    if (![translatedNavTitle isEqualToString:navigationItem.title]) navigationItem.title = translatedNavTitle;

    IQFTranslateBarButtonItem(navigationItem.leftBarButtonItem);
    IQFTranslateBarButtonItem(navigationItem.rightBarButtonItem);
    for (UIBarButtonItem *item in navigationItem.leftBarButtonItems) IQFTranslateBarButtonItem(item);
    for (UIBarButtonItem *item in navigationItem.rightBarButtonItems) IQFTranslateBarButtonItem(item);

    if (controller.isViewLoaded) IQFTranslateViewTree(controller.view);

    for (UIViewController *child in controller.childViewControllers.copy) {
        IQFTranslateSettingsController(child);
    }
    if (controller.presentedViewController != nil) {
        IQFTranslateSettingsController(controller.presentedViewController);
    }
}

static void IQFTranslateControllerTree(UIViewController *controller, BOOL insideSettings) {
    if (controller == nil) return;

    BOOL nowInside = insideSettings || [NSStringFromClass(controller.class) isEqualToString:@"IQFSettingsViewController"];
    if (nowInside) {
        NSString *translatedTitle = IQFTranslateUIString(controller.title);
        if (![translatedTitle isEqualToString:controller.title]) controller.title = translatedTitle;

        UINavigationItem *navigationItem = controller.navigationItem;
        NSString *translatedNavTitle = IQFTranslateUIString(navigationItem.title);
        if (![translatedNavTitle isEqualToString:navigationItem.title]) navigationItem.title = translatedNavTitle;
        IQFTranslateBarButtonItem(navigationItem.leftBarButtonItem);
        IQFTranslateBarButtonItem(navigationItem.rightBarButtonItem);
        for (UIBarButtonItem *item in navigationItem.leftBarButtonItems) IQFTranslateBarButtonItem(item);
        for (UIBarButtonItem *item in navigationItem.rightBarButtonItems) IQFTranslateBarButtonItem(item);
        if (controller.isViewLoaded) IQFTranslateViewTree(controller.view);
    }

    for (UIViewController *child in controller.childViewControllers.copy) {
        IQFTranslateControllerTree(child, nowInside);
    }
    if (controller.presentedViewController != nil) {
        IQFTranslateControllerTree(controller.presentedViewController, nowInside);
    }
}

static void IQFApplyTranslationToVisibleSettings(void) {
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        IQFTranslateControllerTree(window.rootViewController, NO);
    }
}

static void IQFScheduleTranslationPasses(void) {
    const NSTimeInterval delays[] = {0.03, 0.12, 0.35, 0.75, 1.25};
    for (NSUInteger index = 0; index < sizeof(delays) / sizeof(delays[0]); index++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delays[index] * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            IQFApplyTranslationToVisibleSettings();
        });
    }
}

static void IQFSettingsViewDidLayoutSubviews(id self, SEL command) {
    if (IQFPTOriginalViewDidLayoutSubviews != NULL) {
        ((void (*)(id, SEL))IQFPTOriginalViewDidLayoutSubviews)(self, command);
    }
    if (![self isKindOfClass:UIViewController.class]) return;

    IQFTranslateSettingsController((UIViewController *)self);
    __weak UIViewController *weakController = (UIViewController *)self;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *controller = weakController;
        if (controller != nil) IQFTranslateSettingsController(controller);
    });
}

static void IQFSettingsViewDidAppear(id self, SEL command, BOOL animated) {
    if (IQFPTOriginalViewDidAppear != NULL) {
        ((void (*)(id, SEL, BOOL))IQFPTOriginalViewDidAppear)(self, command, animated);
    }
    if (![self isKindOfClass:UIViewController.class]) return;

    IQFTranslateSettingsController((UIViewController *)self);
    IQFScheduleTranslationPasses();
}

static BOOL IQFInstallCoreTranslationHooks(void) {
    Class settingsClass = NSClassFromString(@"IQFSettingsViewController");
    IQFMSHookMessageExFunction hook = (IQFMSHookMessageExFunction)IQFPTFindSymbol("MSHookMessageEx");
    if (settingsClass == Nil || hook == NULL) return NO;

    if (!IQFPTLayoutHookInstalled && class_getInstanceMethod(settingsClass, @selector(viewDidLayoutSubviews)) != NULL) {
        hook(settingsClass,
             @selector(viewDidLayoutSubviews),
             (IMP)&IQFSettingsViewDidLayoutSubviews,
             &IQFPTOriginalViewDidLayoutSubviews);
        IQFPTLayoutHookInstalled = IQFPTOriginalViewDidLayoutSubviews != NULL;
    }

    if (!IQFPTAppearHookInstalled && class_getInstanceMethod(settingsClass, @selector(viewDidAppear:)) != NULL) {
        hook(settingsClass,
             @selector(viewDidAppear:),
             (IMP)&IQFSettingsViewDidAppear,
             &IQFPTOriginalViewDidAppear);
        IQFPTAppearHookInstalled = IQFPTOriginalViewDidAppear != NULL;
    }

    return IQFPTLayoutHookInstalled && IQFPTAppearHookInstalled;
}

static void IQFRetryCoreTranslationHooks(NSUInteger attempt) {
    if (IQFInstallCoreTranslationHooks() || attempt >= 40) return;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        IQFRetryCoreTranslationHooks(attempt + 1);
    });
}

__attribute__((constructor))
static void IQFCoreTranslationInitialize(void) {
    @autoreleasepool {
        NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier ?: @"";
        if (![bundleIdentifier isEqualToString:@"com.facebook.Facebook"] ||
            [NSBundle.mainBundle.bundlePath hasSuffix:@".appex"]) {
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            IQFRetryCoreTranslationHooks(0);
        });
    }
}
