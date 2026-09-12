#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <string.h>

// iQFaceEnhancer 0.3.0 / iQFace 1.1 localization layer.
// The stable Wordmark/No-Flash activation code is intentionally left unchanged.
// Primary path: hook iQFace's own IQFLoc function when MSHookFunction is available.
// Fallback: translate only visible IQFSettingsViewController trees.

__attribute__((visibility("default"))) NSString * const IQFEnhancerLocalizationVersion = @"1.1";

typedef NSString *(*IQFLocFunction)(NSString *key);
typedef void (*MSHookFunctionType)(void *symbol, void *replacement, void **original);

static IQFLocFunction IQFOriginalLoc11 = NULL;
static BOOL IQFLocalizationHookInstalled11 = NO;
static NSInteger IQFLocalizationInstallAttempts11 = 0;
static dispatch_source_t IQFLocalizationScanner11 = nil;

static void *IQF11FindSymbol(const char *name) {
    void *symbol = dlsym(RTLD_DEFAULT, name);
    if (symbol != NULL) return symbol;

    char underscored[128] = {0};
    if (strlen(name) + 2 >= sizeof(underscored)) return NULL;
    underscored[0] = '_';
    strlcpy(underscored + 1, name, sizeof(underscored) - 1);
    return dlsym(RTLD_DEFAULT, underscored);
}

static BOOL IQF11UsePortuguese(void) {
    id forced = [[NSUserDefaults standardUserDefaults] objectForKey:@"IQFEnhancerForcePortuguese"];
    if (forced != nil) return [forced boolValue];

    NSString *language = NSLocale.preferredLanguages.firstObject.lowercaseString;
    return [language hasPrefix:@"pt"];
}

static NSDictionary<NSString *, NSString *> *IQF11Translations(void) {
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
            @"English": @"Inglês",

            @"General": @"Geral",
            @"Feed": @"Feed",
            @"Stories": @"Stories",
            @"Reels": @"Reels",
            @"Confirmations": @"Confirmações",
            @"Features": @"Recursos",
            @"FEATURES": @"RECURSOS",
            @"Appearance": @"Aparência",
            @"APPEARANCE": @"APARÊNCIA",
            @"Tools": @"Ferramentas",
            @"Developer": @"Desenvolvedor",
            @"DEV": @"DESENVOLVEDOR",
            @"Join Telegram channel": @"Entrar no canal do Telegram",
            @"About": @"Sobre",
            @"ABOUT": @"SOBRE",

            @"Open links in Safari": @"Abrir links no Safari",
            @"Block ads": @"Bloquear anúncios",
            @"Download videos": @"Baixar vídeos",
            @"Block in-stream video ads": @"Bloquear anúncios em vídeos",

            @"Hide suggested Reels": @"Ocultar Reels sugeridos",
            @"Hide group suggestions": @"Ocultar sugestões de grupos",
            @"Hide \"People You May Know\"": @"Ocultar \"Pessoas que você talvez conheça\"",
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
            @"Hide video buttons": @"Ocultar botões do vídeo",
            @"Show video buttons": @"Mostrar botões do vídeo",
            @"Auto-advance on": @"Avanço automático ativado",
            @"Auto-advance off": @"Avanço automático desativado",

            @"Download": @"Baixar",
            @"Save photo": @"Salvar foto",
            @"Save full-resolution photo": @"Salvar foto em resolução máxima",
            @"Copy caption": @"Copiar legenda",
            @"Caption copied": @"Legenda copiada",
            @"Nothing to copy": @"Não há nada para copiar",
            @"Saved to Photos": @"Salvo no app Fotos",
            @"Download failed": @"Falha no download",
            @"Photos refused the file.": @"O app Fotos recusou o arquivo.",
            @"Downloading": @"Baixando",
            @"Converting": @"Convertendo",
            @"Merging": @"Combinando",
            @"Saving…": @"Salvando…",
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
            @"Nothing to download here.": @"Não há nada para baixar aqui.",
            @"This video cannot be downloaded.": @"Este vídeo não pode ser baixado.",
            @"No video found here.": @"Nenhum vídeo foi encontrado aqui.",
            @"Photos access is denied for Facebook.": @"O acesso do Facebook ao app Fotos foi negado.",

            @"Marked as seen": @"Marcado como visto",
            @"Already marked as seen": @"Já estava marcado como visto",
            @"They can already see you": @"Essa pessoa já pode ver que você assistiu",
            @"Nothing to send for this story": @"Não há nada para enviar neste story",

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
            @"Blocks sponsored posts in the feed, and ads inside stories and Reels.": @"Bloqueia publicações patrocinadas no feed e anúncios dentro de stories e Reels.",
            @"Removes these cards from the feed entirely — nothing is left in their place. Each is off until you turn it on.": @"Remove completamente esses cartões do feed, sem deixar espaços no lugar. Cada opção fica desativada até você ativá-la.",
            @"OK": @"OK"
        };
    });
    return translations;
}

static NSString *IQF11Translate(NSString *text) {
    if (!IQF11UsePortuguese() || text.length == 0) return nil;
    return IQF11Translations()[text];
}

static NSString *IQF11LocReplacement(NSString *key) {
    NSString *translated = IQF11Translate(key);
    if (translated != nil) return translated;
    return IQFOriginalLoc11 != NULL ? IQFOriginalLoc11(key) : key;
}

static BOOL IQF11InstallLocalizationHook(void) {
    if (IQFLocalizationHookInstalled11) return YES;

    void *loc = IQF11FindSymbol("IQFLoc");
    MSHookFunctionType hook = (MSHookFunctionType)IQF11FindSymbol("MSHookFunction");
    if (loc == NULL || hook == NULL) return NO;

    hook(loc, (void *)&IQF11LocReplacement, (void **)&IQFOriginalLoc11);
    IQFLocalizationHookInstalled11 = IQFOriginalLoc11 != NULL;
    return IQFLocalizationHookInstalled11;
}

static void IQF11ScheduleHookInstall(void) {
    IQFLocalizationInstallAttempts11 += 1;
    if (IQF11InstallLocalizationHook() || IQFLocalizationInstallAttempts11 >= 80) return;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        IQF11ScheduleHookInstall();
    });
}

static void IQF11TranslateView(UIView *view) {
    if (view == nil) return;

    if ([view isKindOfClass:UILabel.class]) {
        UILabel *label = (UILabel *)view;
        NSString *translated = IQF11Translate(label.text);
        if (translated != nil && ![translated isEqualToString:label.text]) label.text = translated;
    } else if ([view isKindOfClass:UIButton.class]) {
        UIButton *button = (UIButton *)view;
        NSString *title = [button titleForState:UIControlStateNormal] ?: button.currentTitle;
        NSString *translated = IQF11Translate(title);
        if (translated != nil && ![translated isEqualToString:title]) {
            [button setTitle:translated forState:UIControlStateNormal];
        }
    } else if ([view isKindOfClass:UITextField.class]) {
        UITextField *field = (UITextField *)view;
        NSString *translated = IQF11Translate(field.text);
        if (translated != nil) field.text = translated;
        translated = IQF11Translate(field.placeholder);
        if (translated != nil) field.placeholder = translated;
    } else if ([view isKindOfClass:UITextView.class]) {
        UITextView *textView = (UITextView *)view;
        NSString *translated = IQF11Translate(textView.text);
        if (translated != nil) textView.text = translated;
    } else if ([view isKindOfClass:UISegmentedControl.class]) {
        UISegmentedControl *control = (UISegmentedControl *)view;
        for (NSInteger index = 0; index < control.numberOfSegments; index++) {
            NSString *title = [control titleForSegmentAtIndex:index];
            NSString *translated = IQF11Translate(title);
            if (translated != nil) [control setTitle:translated forSegmentAtIndex:index];
        }
    }

    for (UIView *subview in view.subviews) IQF11TranslateView(subview);
}

static void IQF11TranslateSettingsController(UIViewController *controller) {
    if (controller == nil) return;

    NSString *className = NSStringFromClass(controller.class);
    if ([className isEqualToString:@"IQFSettingsViewController"]) {
        NSString *translated = IQF11Translate(controller.title);
        if (translated != nil) controller.title = translated;

        translated = IQF11Translate(controller.navigationItem.title);
        if (translated != nil) controller.navigationItem.title = translated;

        if (controller.isViewLoaded) IQF11TranslateView(controller.view);

        UINavigationController *navigation = controller.navigationController;
        if (navigation != nil && navigation.isViewLoaded) IQF11TranslateView(navigation.navigationBar);

        UIViewController *presented = controller.presentedViewController;
        if (presented != nil && presented.isViewLoaded) IQF11TranslateView(presented.view);
    }

    if (controller.presentedViewController != nil) {
        IQF11TranslateSettingsController(controller.presentedViewController);
    }
    for (UIViewController *child in controller.childViewControllers) {
        IQF11TranslateSettingsController(child);
    }
}

static void IQF11ScanSettings(void) {
    if (!IQF11UsePortuguese() || UIApplication.sharedApplication.applicationState == UIApplicationStateBackground) return;

    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                IQF11TranslateSettingsController(window.rootViewController);
            }
        }
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        for (UIWindow *window in UIApplication.sharedApplication.windows) {
            IQF11TranslateSettingsController(window.rootViewController);
        }
#pragma clang diagnostic pop
    }
}

static void IQF11StartFallbackScanner(void) {
    if (IQFLocalizationScanner11 != nil) return;

    IQFLocalizationScanner11 = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(IQFLocalizationScanner11,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                              (uint64_t)(0.75 * NSEC_PER_SEC),
                              (uint64_t)(0.1 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(IQFLocalizationScanner11, ^{
        IQF11ScanSettings();
    });
    dispatch_resume(IQFLocalizationScanner11);
}

__attribute__((constructor))
static void IQFEnhancerLocalization11Initialize(void) {
    @autoreleasepool {
        NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier;
        if (![bundleIdentifier isEqualToString:@"com.facebook.Facebook"] ||
            [NSBundle.mainBundle.bundlePath hasSuffix:@".appex"]) return;

        dispatch_async(dispatch_get_main_queue(), ^{
            IQF11ScheduleHookInstall();
            IQF11StartFallbackScanner();
        });
    }
}
