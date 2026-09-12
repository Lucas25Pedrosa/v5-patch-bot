#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// Pre-display localization for iQFace 1.1.
// This deliberately avoids IQFLoc and only hooks IQFSettingsViewController.

__attribute__((used, visibility("default"))) NSString * const IQFEnhancerEarlyLocalizationVersion = @"1.1-early-layout";

static void (*IQF11OriginalViewWillAppear)(id, SEL, BOOL) = NULL;
static NSInteger IQF11InstallAttempts = 0;
static BOOL IQF11Installed = NO;

static BOOL IQF11EarlyUsePortuguese(void) {
    id forced = [[NSUserDefaults standardUserDefaults] objectForKey:@"IQFEnhancerForcePortuguese"];
    if (forced != nil) return [forced boolValue];
    NSString *language = NSLocale.preferredLanguages.firstObject.lowercaseString;
    return [language hasPrefix:@"pt"];
}

static NSDictionary<NSString *, NSString *> *IQF11EarlyTranslations(void) {
    static NSDictionary<NSString *, NSString *> *map;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        map = @{
            @"Back": @"Voltar",
            @"General": @"Geral",
            @"Feed": @"Feed",
            @"Stories": @"Stories",
            @"Reels": @"Reels",
            @"Confirmations": @"Confirmações",
            @"Features": @"Recursos",
            @"FEATURES": @"RECURSOS",
            @"Appearance": @"Aparência",
            @"APPEARANCE": @"APARÊNCIA",
            @"Developer": @"Desenvolvedor",
            @"DEV": @"DESENVOLVEDOR",
            @"About": @"Sobre",
            @"ABOUT": @"SOBRE",
            @"Language": @"Idioma",
            @"Follow system": @"Seguir idioma do sistema",
            @"English": @"Inglês",
            @"Join Telegram channel": @"Entrar no canal do Telegram",

            @"Block ads": @"Bloquear anúncios",
            @"Download videos": @"Baixar vídeos",
            @"Open links in Safari": @"Abrir links no Safari",
            @"Block in-stream video ads": @"Bloquear anúncios em vídeos",

            @"Hide suggested Reels": @"Ocultar Reels sugeridos",
            @"Hide group suggestions": @"Ocultar sugestões de grupos",
            @"Hide \"People You May Know\"": @"Ocultar pessoas que talvez conheça",
            @"Hide suggested posts": @"Ocultar publicações sugeridas",

            @"Anonymous stories": @"Stories anônimos",
            @"Hide stories": @"Ocultar stories",
            @"Ghost mode in stories": @"Modo fantasma nos stories",
            @"Watch stories locally (grey ring)": @"Assistir stories localmente (anel cinza)",

            @"Auto-advance": @"Avanço automático",
            @"Hide Reels screen elements": @"Ocultar elementos da tela de Reels",
            @"Show Reels screen elements": @"Mostrar elementos da tela de Reels",
            @"Separate buttons": @"Botões separados",
            @"Reels controls": @"Controles dos Reels",
            @"Button layout": @"Layout dos botões",
            @"One iQ button": @"Um botão iQ",
            @"Hold for Reels menu": @"Segure para abrir o menu dos Reels",
            @"Reels overlay": @"Sobreposição dos Reels",
            @"Hide action rail": @"Ocultar barra de ações",
            @"Hide Likes": @"Ocultar curtidas",
            @"Hide Comments": @"Ocultar comentários",
            @"Hide Share": @"Ocultar compartilhamento",
            @"Hide creator information": @"Ocultar informações do criador",
            @"Hide description": @"Ocultar descrição",

            @"Confirm posting a comment": @"Confirmar comentários",
            @"Confirm friend requests": @"Confirmar solicitações de amizade",
            @"Confirm follow and join": @"Confirmar seguir e entrar",
            @"Confirm sending a message": @"Confirmar envio de mensagens",
            @"Confirm likes": @"Confirmar curtidas",
            @"Confirm sharing": @"Confirmar compartilhamento",
            @"Confirm publishing": @"Confirmar publicação",
            @"Confirm reporting": @"Confirmar denúncia"
        };
    });
    return map;
}

static NSString *IQF11EarlyTranslate(NSString *text) {
    if (!IQF11EarlyUsePortuguese() || text.length == 0) return nil;
    return IQF11EarlyTranslations()[text];
}

static BOOL IQF11TranslateViewBeforeLayout(UIView *view) {
    if (view == nil) return NO;
    BOOL changed = NO;

    if ([view isKindOfClass:UILabel.class]) {
        UILabel *label = (UILabel *)view;
        NSString *translated = IQF11EarlyTranslate(label.text);
        if (translated != nil && ![translated isEqualToString:label.text]) {
            label.text = translated;
            [label invalidateIntrinsicContentSize];
            [label setNeedsLayout];
            changed = YES;
        }
    } else if ([view isKindOfClass:UIButton.class]) {
        UIButton *button = (UIButton *)view;
        NSString *title = [button titleForState:UIControlStateNormal] ?: button.currentTitle;
        NSString *translated = IQF11EarlyTranslate(title);
        if (translated != nil && ![translated isEqualToString:title]) {
            [button setTitle:translated forState:UIControlStateNormal];
            [button invalidateIntrinsicContentSize];
            [button setNeedsLayout];
            changed = YES;
        }
    } else if ([view isKindOfClass:UITextField.class]) {
        UITextField *field = (UITextField *)view;
        NSString *translated = IQF11EarlyTranslate(field.text);
        if (translated != nil && ![translated isEqualToString:field.text]) {
            field.text = translated;
            changed = YES;
        }
        translated = IQF11EarlyTranslate(field.placeholder);
        if (translated != nil && ![translated isEqualToString:field.placeholder]) {
            field.placeholder = translated;
            changed = YES;
        }
    } else if ([view isKindOfClass:UITextView.class]) {
        UITextView *textView = (UITextView *)view;
        NSString *translated = IQF11EarlyTranslate(textView.text);
        if (translated != nil && ![translated isEqualToString:textView.text]) {
            textView.text = translated;
            changed = YES;
        }
    } else if ([view isKindOfClass:UISegmentedControl.class]) {
        UISegmentedControl *control = (UISegmentedControl *)view;
        for (NSUInteger index = 0; index < (NSUInteger)control.numberOfSegments; index++) {
            NSString *title = [control titleForSegmentAtIndex:index];
            NSString *translated = IQF11EarlyTranslate(title);
            if (translated != nil && ![translated isEqualToString:title]) {
                [control setTitle:translated forSegmentAtIndex:index];
                changed = YES;
            }
        }
    }

    for (UIView *subview in view.subviews.copy) {
        if (IQF11TranslateViewBeforeLayout(subview)) changed = YES;
    }
    return changed;
}

static void IQF11TranslateControllerBeforeDisplay(UIViewController *controller) {
    if (controller == nil) return;

    NSString *translated = IQF11EarlyTranslate(controller.title);
    if (translated != nil && ![translated isEqualToString:controller.title]) controller.title = translated;

    translated = IQF11EarlyTranslate(controller.navigationItem.title);
    if (translated != nil && ![translated isEqualToString:controller.navigationItem.title]) {
        controller.navigationItem.title = translated;
    }

    UINavigationController *nav = controller.navigationController;
    if (nav != nil) {
        NSUInteger index = [nav.viewControllers indexOfObjectIdenticalTo:controller];
        if (index != NSNotFound && index > 0) {
            UIViewController *previous = nav.viewControllers[index - 1];
            previous.navigationItem.backButtonTitle = @"Voltar";
        }
    }

    if (controller.isViewLoaded) {
        BOOL changed = IQF11TranslateViewBeforeLayout(controller.view);
        if (changed) {
            [controller.view setNeedsLayout];
            [controller.view layoutIfNeeded];
        }
    }

    if (nav != nil && nav.isViewLoaded) {
        BOOL navChanged = IQF11TranslateViewBeforeLayout(nav.navigationBar);
        if (navChanged) {
            [nav.navigationBar setNeedsLayout];
            [nav.navigationBar layoutIfNeeded];
        }
    }
}

static void IQF11ViewWillAppear(id self, SEL command, BOOL animated) {
    UIViewController *controller = (UIViewController *)self;

    // Set the back title before UIKit builds the transition bar.
    UINavigationController *nav = controller.navigationController;
    if (nav != nil) {
        NSUInteger index = [nav.viewControllers indexOfObjectIdenticalTo:controller];
        if (index != NSNotFound && index > 0) {
            nav.viewControllers[index - 1].navigationItem.backButtonTitle = @"Voltar";
        }
    }

    if (IQF11OriginalViewWillAppear != NULL) {
        IQF11OriginalViewWillAppear(self, command, animated);
    }

    IQF11TranslateControllerBeforeDisplay(controller);
}

static BOOL IQF11InstallEarlyHook(void) {
    if (IQF11Installed) return YES;

    Class cls = NSClassFromString(@"IQFSettingsViewController");
    if (cls == Nil) return NO;

    SEL selector = @selector(viewWillAppear:);
    Method method = class_getInstanceMethod(cls, selector);
    if (method == NULL) return NO;

    IMP inheritedOrOwn = method_getImplementation(method);
    const char *types = method_getTypeEncoding(method);
    IQF11OriginalViewWillAppear = (void (*)(id, SEL, BOOL))inheritedOrOwn;

    if (!class_addMethod(cls, selector, (IMP)&IQF11ViewWillAppear, types)) {
        Method ownMethod = class_getInstanceMethod(cls, selector);
        IMP previous = method_setImplementation(ownMethod, (IMP)&IQF11ViewWillAppear);
        if (previous != NULL) IQF11OriginalViewWillAppear = (void (*)(id, SEL, BOOL))previous;
    }

    IQF11Installed = YES;
    return YES;
}

static void IQF11ScheduleEarlyHook(void) {
    IQF11InstallAttempts += 1;
    if (IQF11InstallEarlyHook() || IQF11InstallAttempts >= 120) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.10 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        IQF11ScheduleEarlyHook();
    });
}

__attribute__((constructor))
static void IQFEnhancerLocalization11EarlyInitialize(void) {
    @autoreleasepool {
        NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
        if (![bundleID isEqualToString:@"com.facebook.Facebook"] ||
            [NSBundle.mainBundle.bundlePath hasSuffix:@".appex"]) return;

        dispatch_async(dispatch_get_main_queue(), ^{
            IQF11ScheduleEarlyHook();
        });
    }
}
