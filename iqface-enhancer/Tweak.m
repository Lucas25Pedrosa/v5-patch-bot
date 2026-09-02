#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <stdlib.h>
#import <string.h>

typedef NSString *(*IQFLocFunction)(NSString *key);
typedef BOOL (*IQFSettingsVisibleFunction)(void);
typedef void (*IQFPresentSettingsFunction)(void);
typedef void (*MSHookFunctionType)(void *symbol, void *replacement, void **original);

static IQFLocFunction IQFOriginalLoc = NULL;
static BOOL IQFLocalizationInstalled = NO;
static NSInteger IQFInstallAttempt = 0;
static NSTimeInterval IQFLastPresentationTime = 0;

static const NSTimeInterval IQFLongPressDuration = 0.65;
static const CGFloat IQFHomeZoneWidthFraction = 0.26;
static const CGFloat IQFBottomZoneStartFraction = 0.68;

static void *IQFFindSymbol(const char *name) {
    void *symbol = dlsym(RTLD_DEFAULT, name);
    if (symbol != NULL) {
        return symbol;
    }

    char underscored[128] = {0};
    if (strlen(name) + 2 < sizeof(underscored)) {
        underscored[0] = '_';
        strlcpy(underscored + 1, name, sizeof(underscored) - 1);
        symbol = dlsym(RTLD_DEFAULT, underscored);
    }
    return symbol;
}

static BOOL IQFShouldUsePortuguese(void) {
    id forcedValue = [[NSUserDefaults standardUserDefaults] objectForKey:@"IQFEnhancerForcePortuguese"];
    if (forcedValue != nil) {
        return [forcedValue boolValue];
    }

    NSString *language = NSLocale.preferredLanguages.firstObject.lowercaseString;
    return [language hasPrefix:@"pt"];
}

static NSDictionary<NSString *, NSString *> *IQFPortugueseTranslations(void) {
    static NSDictionary<NSString *, NSString *> *translations;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        translations = @{
            @"%lu downloads": @"%lu downloads",
            @"Downloading…": @"Baixando…",
            @"Cancel": @"Cancelar",
            @"Cancelling…": @"Cancelando…",
            @"iQFace Settings": @"Ajustes do iQFace",
            @"Back": @"Voltar",
            @"Language": @"Idioma",
            @"Follow system": @"Seguir idioma do sistema",
            @"Features": @"Recursos",
            @"Block ads": @"Bloquear anúncios",
            @"Download videos": @"Baixar vídeos",
            @"Anonymous stories": @"Stories anônimos",
            @"Feed": @"Feed",
            @"Hide suggested Reels": @"Ocultar Reels sugeridos",
            @"Hide group suggestions": @"Ocultar sugestões de grupos",
            @"Hide \"People You May Know\"": @"Ocultar \"Pessoas que você talvez conheça\"",
            @"Confirmations": @"Confirmações",
            @"Tools": @"Ferramentas",
            @"Developer": @"Desenvolvedor",
            @"Join Telegram channel": @"Entrar no canal do Telegram",
            @"About": @"Sobre",
            @"English": @"Inglês",
            @"Cancelled": @"Cancelado",
            @"Could not write the file": @"Não foi possível salvar o arquivo",
            @"Download ended with no file": @"O download terminou sem gerar um arquivo",
            @"The downloaded video has no readable video track": @"O vídeo baixado não possui uma faixa de vídeo legível",
            @"This video cannot be exported on this device": @"Este vídeo não pode ser exportado neste dispositivo",
            @"Merging failed": @"Falha ao combinar os arquivos",
            @"Nothing to save": @"Não há nada para salvar",
            @"This quality cannot be converted on this device (%@)": @"Esta qualidade não pode ser convertida neste dispositivo (%@)",
            @"Nothing to download": @"Não há nada para baixar",
            @"Facebook returned an unreadable stream for this quality": @"O Facebook retornou um fluxo ilegível para esta qualidade",
            @"Could not combine the video and audio": @"Não foi possível combinar o vídeo e o áudio",
            @"Confirm posting a comment": @"Confirmar publicação do comentário",
            @"Post this comment?": @"Publicar este comentário?",
            @"Confirm": @"Confirmar",
            @"Yes": @"Sim",
            @"Confirm friend requests": @"Confirmar solicitações de amizade",
            @"Confirm follow and join": @"Confirmar ações de seguir e entrar",
            @"Confirm sending a message": @"Confirmar envio de mensagens",
            @"Confirm likes": @"Confirmar curtidas",
            @"Confirm sharing": @"Confirmar compartilhamento",
            @"Confirm publishing": @"Confirmar publicação",
            @"Confirm reporting": @"Confirmar denúncia",
            @"Send or cancel this friend request?": @"Enviar ou cancelar esta solicitação de amizade?",
            @"Follow, unfollow or join?": @"Seguir, deixar de seguir ou entrar?",
            @"Send this message?": @"Enviar esta mensagem?",
            @"Send this like?": @"Enviar esta curtida?",
            @"Remove this like?": @"Remover esta curtida?",
            @"Share this?": @"Compartilhar isto?",
            @"Publish this?": @"Publicar isto?",
            @"Send this report?": @"Enviar esta denúncia?",
            @"Asks before an action that is easy to tap by accident. Everything here is off until you turn it on.": @"Pede confirmação antes de ações que podem ser tocadas por engano. Todas ficam desativadas até você ativá-las.",
            @"Nothing to download here.": @"Não há nada para baixar aqui.",
            @"Marked as seen": @"Marcado como visto",
            @"Already marked as seen": @"Já estava marcado como visto",
            @"They can already see you": @"Essa pessoa já pode ver que você assistiu",
            @"Nothing to send for this story": @"Não há nada para enviar neste story",
            @"Downloading": @"Baixando",
            @"Converting": @"Convertendo",
            @"Merging": @"Combinando",
            @"Saving…": @"Salvando…",
            @"This video cannot be downloaded.": @"Este vídeo não pode ser baixado.",
            @"No video found here.": @"Nenhum vídeo foi encontrado aqui.",
            @"Photos access is denied for Facebook.": @"O acesso do Facebook ao app Fotos foi negado.",
            @"Download": @"Baixar",
            @"Auto-advance": @"Avanço automático",
            @"Hide video buttons": @"Ocultar botões do vídeo",
            @"Show video buttons": @"Mostrar botões do vídeo",
            @"Auto-advance on": @"Avanço automático ativado",
            @"Auto-advance off": @"Avanço automático desativado",
            @"Copy caption": @"Copiar legenda",
            @"Caption copied": @"Legenda copiada",
            @"Nothing to copy": @"Não há nada para copiar",
            @"Saved to Photos": @"Salvo no app Fotos",
            @"Download failed": @"Falha no download",
            @"Photos refused the file.": @"O app Fotos recusou o arquivo.",
            @"Blocks sponsored posts in the feed, and ads inside stories and Reels.": @"Bloqueia publicações patrocinadas no feed e anúncios dentro de stories e Reels.",
            @"Removes these cards from the feed entirely — nothing is left in their place. Each is off until you turn it on.": @"Remove completamente esses cartões do feed, sem deixar espaços no lugar. Cada opção fica desativada até você ativá-la.",
            @"OK": @"OK"
        };
    });
    return translations;
}

static NSString *IQFLocalizedPortuguese(NSString *key) {
    if (key.length == 0 || !IQFShouldUsePortuguese()) {
        return nil;
    }
    return IQFPortugueseTranslations()[key];
}

static NSString *IQFLocReplacement(NSString *key) {
    NSString *translation = IQFLocalizedPortuguese(key);
    if (translation != nil) {
        return translation;
    }
    return IQFOriginalLoc != NULL ? IQFOriginalLoc(key) : key;
}

static BOOL IQFInstallLocalizationHook(void) {
    if (IQFLocalizationInstalled) {
        return YES;
    }

    void *locSymbol = IQFFindSymbol("IQFLoc");
    MSHookFunctionType hookFunction = (MSHookFunctionType)IQFFindSymbol("MSHookFunction");
    if (locSymbol == NULL || hookFunction == NULL) {
        return NO;
    }

    hookFunction(locSymbol, (void *)&IQFLocReplacement, (void **)&IQFOriginalLoc);
    IQFLocalizationInstalled = IQFOriginalLoc != NULL;
    return IQFLocalizationInstalled;
}

static BOOL IQFIsSettingsItem(UIBarButtonItem *item) {
    if (![item isKindOfClass:UIBarButtonItem.class]) {
        return NO;
    }
    SEL action = item.action;
    return action != NULL && [NSStringFromSelector(action) isEqualToString:@"iqf_tapped"];
}

static BOOL IQFIsTopSettingsButton(UIView *view) {
    if (![view isKindOfClass:UIButton.class]) {
        return NO;
    }

    UIButton *button = (UIButton *)view;
    if (![button.accessibilityLabel isEqualToString:@"iQFace"]) {
        return NO;
    }

    for (id target in button.allTargets) {
        NSArray<NSString *> *actions = [button actionsForTarget:target
                                                forControlEvent:UIControlEventTouchUpInside];
        if ([actions containsObject:@"iqf_tapped"]) {
            return YES;
        }
    }
    return NO;
}

static NSArray<UIBarButtonItem *> *IQFFilterSettingsItems(NSArray<UIBarButtonItem *> *items) {
    if (items.count == 0) {
        return items;
    }

    NSMutableArray<UIBarButtonItem *> *filtered = [NSMutableArray arrayWithCapacity:items.count];
    for (UIBarButtonItem *item in items) {
        if (!IQFIsSettingsItem(item)) {
            [filtered addObject:item];
        }
    }
    return filtered;
}

static void (*IQFOriginalSetLeftItem)(UINavigationItem *, SEL, UIBarButtonItem *) = NULL;
static void (*IQFOriginalSetLeftItemAnimated)(UINavigationItem *, SEL, UIBarButtonItem *, BOOL) = NULL;
static void (*IQFOriginalSetLeftItems)(UINavigationItem *, SEL, NSArray<UIBarButtonItem *> *) = NULL;
static void (*IQFOriginalSetLeftItemsAnimated)(UINavigationItem *, SEL, NSArray<UIBarButtonItem *> *, BOOL) = NULL;
static void (*IQFOriginalAddSubview)(UIView *, SEL, UIView *) = NULL;

static void IQFSetLeftItem(UINavigationItem *self, SEL command, UIBarButtonItem *item) {
    if (IQFIsSettingsItem(item)) {
        return;
    }
    IQFOriginalSetLeftItem(self, command, item);
}

static void IQFSetLeftItemAnimated(UINavigationItem *self, SEL command, UIBarButtonItem *item, BOOL animated) {
    if (IQFIsSettingsItem(item)) {
        return;
    }
    IQFOriginalSetLeftItemAnimated(self, command, item, animated);
}

static void IQFSetLeftItems(UINavigationItem *self, SEL command, NSArray<UIBarButtonItem *> *items) {
    NSArray<UIBarButtonItem *> *filtered = IQFFilterSettingsItems(items);
    if (items.count > 0 && filtered.count == 0) {
        return;
    }
    IQFOriginalSetLeftItems(self, command, filtered);
}

static void IQFSetLeftItemsAnimated(UINavigationItem *self, SEL command, NSArray<UIBarButtonItem *> *items, BOOL animated) {
    NSArray<UIBarButtonItem *> *filtered = IQFFilterSettingsItems(items);
    if (items.count > 0 && filtered.count == 0) {
        return;
    }
    IQFOriginalSetLeftItemsAnimated(self, command, filtered, animated);
}

static void IQFAddSubview(UIView *self, SEL command, UIView *view) {
    if (IQFIsTopSettingsButton(view)) {
        return;
    }
    IQFOriginalAddSubview(self, command, view);
}

static void IQFReplaceMethod(Class targetClass, SEL selector, IMP replacement, IMP *original) {
    Method method = class_getInstanceMethod(targetClass, selector);
    if (method == NULL) {
        return;
    }
    *original = method_setImplementation(method, replacement);
}

static void IQFInstallNavigationItemHooks(void) {
    IQFReplaceMethod(UINavigationItem.class,
                     @selector(setLeftBarButtonItem:),
                     (IMP)&IQFSetLeftItem,
                     (IMP *)&IQFOriginalSetLeftItem);
    IQFReplaceMethod(UINavigationItem.class,
                     @selector(setLeftBarButtonItem:animated:),
                     (IMP)&IQFSetLeftItemAnimated,
                     (IMP *)&IQFOriginalSetLeftItemAnimated);
    IQFReplaceMethod(UINavigationItem.class,
                     @selector(setLeftBarButtonItems:),
                     (IMP)&IQFSetLeftItems,
                     (IMP *)&IQFOriginalSetLeftItems);
    IQFReplaceMethod(UINavigationItem.class,
                     @selector(setLeftBarButtonItems:animated:),
                     (IMP)&IQFSetLeftItemsAnimated,
                     (IMP *)&IQFOriginalSetLeftItemsAnimated);
    IQFReplaceMethod(UIView.class,
                     @selector(addSubview:),
                     (IMP)&IQFAddSubview,
                     (IMP *)&IQFOriginalAddSubview);
}

static void IQFCleanTopSettingsButtons(UIView *view) {
    for (UIView *subview in view.subviews.copy) {
        if (IQFIsTopSettingsButton(subview)) {
            [subview removeFromSuperview];
        } else {
            IQFCleanTopSettingsButtons(subview);
        }
    }
}

static void IQFCleanSettingsItemFromController(UIViewController *controller) {
    if (controller == nil) {
        return;
    }

    UINavigationItem *navigationItem = controller.navigationItem;
    NSArray<UIBarButtonItem *> *items = navigationItem.leftBarButtonItems;
    NSArray<UIBarButtonItem *> *filtered = IQFFilterSettingsItems(items);
    if (filtered.count != items.count) {
        navigationItem.leftBarButtonItems = filtered;
    } else if (IQFIsSettingsItem(navigationItem.leftBarButtonItem)) {
        navigationItem.leftBarButtonItem = nil;
    }

    for (UIViewController *child in controller.childViewControllers) {
        IQFCleanSettingsItemFromController(child);
    }
    IQFCleanSettingsItemFromController(controller.presentedViewController);
}

static void IQFCleanVisibleSettingsItems(void) {
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        IQFCleanSettingsItemFromController(window.rootViewController);
        IQFCleanTopSettingsButtons(window);
    }
}

static BOOL IQFSettingsAreVisible(void) {
    IQFSettingsVisibleFunction visible = (IQFSettingsVisibleFunction)IQFFindSymbol("IQFSettingsVisible");
    return visible != NULL && visible();
}

static void IQFOpenSettings(void) {
    NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
    if (now - IQFLastPresentationTime < 0.9 || IQFSettingsAreVisible()) {
        return;
    }

    IQFPresentSettingsFunction present = (IQFPresentSettingsFunction)IQFFindSymbol("IQFPresentSettings");
    if (present == NULL) {
        return;
    }

    IQFLastPresentationTime = now;
    UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [feedback prepare];
    [feedback impactOccurred];
    present();
}

@interface IQFEnhancerGestureTarget : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)sharedTarget;
- (void)handleLongPress:(UILongPressGestureRecognizer *)recognizer;
@end

@implementation IQFEnhancerGestureTarget

+ (instancetype)sharedTarget {
    static IQFEnhancerGestureTarget *target;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        target = [IQFEnhancerGestureTarget new];
    });
    return target;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
        shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateBegan) {
        return;
    }

    UIView *view = recognizer.view;
    UIWindow *window = view.window;
    if (window == nil || window.bounds.size.width <= 0 || window.bounds.size.height <= 0) {
        return;
    }

    CGPoint point = [recognizer locationInView:window];
    BOOL isBottomZone = point.y >= CGRectGetHeight(window.bounds) * IQFBottomZoneStartFraction;
    UIUserInterfaceLayoutDirection direction = [UIView userInterfaceLayoutDirectionForSemanticContentAttribute:view.semanticContentAttribute];
    BOOL isHomeZone;
    if (direction == UIUserInterfaceLayoutDirectionRightToLeft) {
        isHomeZone = point.x >= CGRectGetWidth(window.bounds) * (1.0 - IQFHomeZoneWidthFraction);
    } else {
        isHomeZone = point.x <= CGRectGetWidth(window.bounds) * IQFHomeZoneWidthFraction;
    }

    if (isBottomZone && isHomeZone) {
        dispatch_async(dispatch_get_main_queue(), ^{
            IQFOpenSettings();
        });
    }
}

@end

static const void *IQFGestureAssociationKey = &IQFGestureAssociationKey;
static const void *IQFOriginalDidMoveAssociationKey = &IQFOriginalDidMoveAssociationKey;

static void IQFAttachLongPress(UIView *view) {
    if (view == nil || objc_getAssociatedObject(view, IQFGestureAssociationKey) != nil) {
        return;
    }

    UILongPressGestureRecognizer *recognizer = [[UILongPressGestureRecognizer alloc]
        initWithTarget:IQFEnhancerGestureTarget.sharedTarget
                action:@selector(handleLongPress:)];
    recognizer.minimumPressDuration = IQFLongPressDuration;
    recognizer.allowableMovement = 16.0;
    recognizer.cancelsTouchesInView = NO;
    recognizer.delegate = IQFEnhancerGestureTarget.sharedTarget;
    [view addGestureRecognizer:recognizer];
    objc_setAssociatedObject(view, IQFGestureAssociationKey, recognizer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static IMP IQFOriginalDidMoveForView(UIView *view) {
    Class currentClass = object_getClass(view);
    while (currentClass != Nil) {
        NSValue *value = objc_getAssociatedObject(currentClass, IQFOriginalDidMoveAssociationKey);
        if (value != nil) {
            return value.pointerValue;
        }
        currentClass = class_getSuperclass(currentClass);
    }
    return NULL;
}

static void IQFTabBarDidMoveToWindow(UIView *self, SEL command) {
    IMP original = IQFOriginalDidMoveForView(self);
    if (original != NULL && original != (IMP)&IQFTabBarDidMoveToWindow) {
        ((void (*)(id, SEL))original)(self, command);
    }
    IQFAttachLongPress(self);
}

static BOOL IQFClassImplementsSelector(Class targetClass, SEL selector) {
    unsigned int methodCount = 0;
    Method *methods = class_copyMethodList(targetClass, &methodCount);
    BOOL found = NO;
    for (unsigned int index = 0; index < methodCount; index++) {
        if (method_getName(methods[index]) == selector) {
            found = YES;
            break;
        }
    }
    free(methods);
    return found;
}

static BOOL IQFHookTabBarClass(Class targetClass) {
    if (targetClass == Nil) {
        return NO;
    }

    Class superclass = targetClass;
    while (superclass != Nil && superclass != UIView.class) {
        superclass = class_getSuperclass(superclass);
    }
    if (superclass != UIView.class) {
        return NO;
    }

    SEL selector = @selector(didMoveToWindow);
    Method inheritedMethod = class_getInstanceMethod(targetClass, selector);
    if (inheritedMethod == NULL) {
        return NO;
    }

    IMP original = method_getImplementation(inheritedMethod);
    if (original == (IMP)&IQFTabBarDidMoveToWindow) {
        return YES;
    }
    objc_setAssociatedObject(targetClass,
                             IQFOriginalDidMoveAssociationKey,
                             [NSValue valueWithPointer:original],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    const char *types = method_getTypeEncoding(inheritedMethod);
    if (IQFClassImplementsSelector(targetClass, selector)) {
        method_setImplementation(inheritedMethod, (IMP)&IQFTabBarDidMoveToWindow);
    } else {
        class_addMethod(targetClass, selector, (IMP)&IQFTabBarDidMoveToWindow, types);
    }
    return YES;
}

static void IQFInstallTabBarHooks(void) {
    NSArray<NSString *> *classNames = @[
        @"FBTabBarItemDefaultView",
        @"FBTabBar",
        @"FBNativeTabBar",
        @"FBFloatingTabBar"
    ];

    BOOL installedFacebookHook = NO;
    for (NSString *className in classNames) {
        installedFacebookHook |= IQFHookTabBarClass(NSClassFromString(className));
    }

    if (!installedFacebookHook) {
        IQFHookTabBarClass(UITabBar.class);
    }
}

static void IQFApplicationDidBecomeActive(NSNotification *notification) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        IQFCleanVisibleSettingsItems();
    });
}

static void IQFTryInstallIQFaceHooks(void) {
    IQFInstallAttempt += 1;
    if (!IQFInstallLocalizationHook() && IQFInstallAttempt < 20) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            IQFTryInstallIQFaceHooks();
        });
    }
}

__attribute__((constructor))
static void IQFEnhancerInitialize(void) {
    @autoreleasepool {
        NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier;
        if (![bundleIdentifier isEqualToString:@"com.facebook.Facebook"] ||
            [NSBundle.mainBundle.bundlePath hasSuffix:@".appex"]) {
            return;
        }

        IQFInstallNavigationItemHooks();
        IQFInstallTabBarHooks();
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                        object:nil
                                                         queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(NSNotification *notification) {
            IQFApplicationDidBecomeActive(notification);
        }];
        dispatch_async(dispatch_get_main_queue(), ^{
            IQFTryInstallIQFaceHooks();
            IQFCleanVisibleSettingsItems();
        });
    }
}
