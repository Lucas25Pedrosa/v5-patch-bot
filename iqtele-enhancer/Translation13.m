#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <string.h>
#import <stdlib.h>

// iQTeleEnhancer / iQTele 1.3 localization layer.
// Keeps the proven activation path untouched. The legacy localization map is reused,
// but its old constructor is disabled. Translation is applied from the iQTele
// controllers' final layout/appearance callbacks, matching the Nexus/iQFace fix.

// Neutralize the legacy constructor and rename its text resolver while including
// the existing file. The legacy translation table remains available in this TU.
#define constructor unused
#define IQTTranslatedText IQTLegacyTranslatedText
#include "Translation.m"
#undef IQTTranslatedText
#undef constructor

__attribute__((used, visibility("default"))) NSString * const IQTEnhancerLocalizationVersion13 = @"1.3-layout-final";

static NSDictionary<NSString *, NSString *> *IQT13ExtraTranslations(void) {
    static NSDictionary<NSString *, NSString *> *translations;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        translations = @{
            // Compact labels for fixed-width iQTele settings cells.
            @"Back": @"Voltar",
            @"Ghost mode and deleted messages": @"Modo fantasma",
            @"Ghost mode in messages": @"Modo fantasma",
            @"Keep deleted messages": @"Manter excluídas",
            @"Activity indicators": @"Atividade",
            @"Send as round video": @"Enviar vídeo circular",
            @"Hide ads in channels": @"Ocultar anúncios",
            @"Experimental feature": @"Experimental",
            @"Eye button in chats": @"Botão de olho",
            @"Scan this code from a device that is already logged in": @"Escaneie este código em um dispositivo que já esteja conectado",
            @"Open Telegram on a device that is already logged in": @"Abra o Telegram em um dispositivo que já esteja conectado",
            @"QR login is unavailable on this build": @"O login por QR não está disponível nesta versão",
            @"Which hooks are armed and what has been refused. Open this before reporting that keep deleted does not work.": @"Mostra quais hooks estão ativos e quais foram recusados. Abra esta tela antes de informar que manter mensagens excluídas não está funcionando.",
            @"The line the other side sees under your name while you are busy. Each kind is sent as its own signal, so each can be hidden on its own. Independent of ghost mode.": @"É a linha que a outra pessoa vê sob o seu nome enquanto você está ocupado. Cada atividade é enviada separadamente e pode ser ocultada por conta própria, independentemente do modo fantasma.",
            @"Translate into": @"Traduzir para",
            @"No edit history saved for this message yet.": @"Ainda não há histórico de edições salvo para esta mensagem.",
            @"Record voice and video chats": @"Gravar chamadas de voz e vídeo",
            @"What to record": @"O que gravar",
            @"Record on answer": @"Gravar ao atender",
            @"Start only when the call is answered": @"Iniciar somente quando a chamada for atendida",
            @"Record group calls": @"Gravar chamadas em grupo",
            @"Records the audio of a call straight from the call's own audio, so the recording is clean whichever side is speaking. A button appears on the call screen; turn on auto-record to start every call without tapping.": @"Grava o áudio diretamente da própria chamada, mantendo a gravação limpa independentemente de quem esteja falando. Um botão aparece na tela da chamada; ative a gravação automática para iniciar sem precisar tocar nele.",
            @"Group call": @"Chamada em grupo",
            @"Incoming Call": @"Chamada recebida",
            @"Incoming Video Call": @"Videochamada recebida",
            @"Everyone": @"Todos",
            @"People": @"Pessoas",
            @"Groups": @"Grupos",
            @"Select recordings": @"Selecionar gravações",
            @"Select all": @"Selecionar tudo",
            @"Deselect all": @"Desmarcar tudo",
            @"Current account": @"Conta atual",
            @"All accounts": @"Todas as contas",
            @"Account": @"Conta",
            @"Contact": @"Contato",
            @"Unknown": @"Desconhecido",
            @"Unknown caller": @"Chamador desconhecido",
            @"Ghost mode enabled": @"Modo fantasma ativado",
            @"Ghost mode disabled": @"Modo fantasma desativado",
            @"Ghost mode is on for this chat": @"Modo fantasma ativado neste chat",
            @"Ghost mode is off for this chat": @"Modo fantasma desativado neste chat",
            @"Marked as read": @"Marcado como lido",
            @"Toggle": @"Alternar",
            @"One tap": @"Um toque",
            @"Always on\nthe eye reveals once": @"Sempre ativo\no olho revela uma vez",
            @"Read receipt sent for this chat": @"Confirmação de leitura enviada para este chat",
            @"An eye beside the other person's avatar. It fills in while a receipt is waiting; tap it to send.": @"Um olho aparece ao lado do avatar da outra pessoa. Ele fica preenchido enquanto há uma confirmação pendente; toque para enviá-la.",
            @"Ghost mode on for this chat": @"Modo fantasma ativado neste chat",
            @"First seen": @"Visto pela primeira vez",
            @"Opening a one-time or self-destructing photo or video normally tells the sender and starts the timer that erases it. With this on, neither happens: the media stays, and you can open it again as often as you like.": @"Abrir uma foto ou vídeo de visualização única ou autodestrutivo normalmente avisa o remetente e inicia o temporizador que apaga a mídia. Com esta opção ativa, isso não acontece: a mídia permanece e pode ser aberta novamente.",
            @"Screenshotting a secret chat or a protected message normally posts a notice in the chat. With this on, no notice is ever sent.": @"Capturar a tela de um chat secreto ou de uma mensagem protegida normalmente envia um aviso no chat. Com esta opção ativa, nenhum aviso é enviado.",
            @"When someone deletes a message they already sent you, it stays in the chat instead of disappearing, and a copy is saved below. Applies to messages deleted from now on, not ones already gone. Your own deletions are unaffected.": @"Quando alguém exclui uma mensagem que já enviou para você, ela permanece no chat e uma cópia é salva abaixo. Isso vale para exclusões feitas a partir de agora; mensagens já removidas não são recuperadas. Suas próprias exclusões não são afetadas.",
            @"Saved copies, grouped by chat. Kept even when the message itself cannot be held in the chat. Text from one-to-one and small group chats only.": @"Cópias salvas, agrupadas por conversa. Elas são mantidas mesmo quando a mensagem não pode permanecer no chat. Apenas textos de conversas individuais e grupos pequenos.",
            @"Deletion log": @"Registro de exclusões",
            @"Deletions seen": @"Exclusões detectadas",
            @"Deletions seen (since launch)": @"Exclusões detectadas desde a abertura",
            @"The other person": @"A outra pessoa",
            @"Reset deletion badges and dates": @"Redefinir marcas e datas de exclusão",
            @"Reset deletion state?": @"Redefinir estado das exclusões?",
            @"This clears every recorded deletion, badge and date, and the message ledger. Saved copies are kept. It cannot be undone.": @"Isso limpa todas as exclusões registradas, marcas, datas e o histórico de mensagens. As cópias salvas são mantidas. Não é possível desfazer.",
            @"Hide the deletion from Telegram": @"Ocultar a exclusão do Telegram",
            @"Which deletion removed a message": @"Qual exclusão removeu uma mensagem",
            @"This message was deleted by the sender.": @"Esta mensagem foi excluída pelo remetente.",
            @"This only empties this list. It does not bring anything back.": @"Isso apenas esvazia esta lista. Nada será restaurado.",
            @"Search people and messages": @"Pesquisar pessoas e mensagens",
            @"You": @"Você",
            @"archived": @"arquivado",
            @"tracked ids": @"IDs monitorados",
            @"messages": @"mensagens",
            @"edited": @"editado",
            @"Copied": @"Copiado",
            @"Later": @"Depois",
            @"Off": @"Desativado",
            @"All": @"Todos",
            @"Follow interface language": @"Seguir idioma da interface",
            @"Search languages": @"Pesquisar idiomas",
            @"off": @"desativado",
            @"on": @"ativado",
            @"App group": @"Grupo do app",
            @"Push": @"Push",
            @"Extension": @"Extensão",
            @"Build": @"Build",
            @"ready": @"pronto",
            @"never started": @"nunca iniciado",
            @"not asked": @"não solicitado",
            @"switch": @"alternância",
            @"writer not installed": @"módulo de escrita não instalado",
            @"Code patching": @"Patch de código",
            @"Direct voice send": @"Envio direto de voz",
            @"Last voice send": @"Último envio de voz",
            @"Could not upload the voice message.": @"Não foi possível enviar a mensagem de voz.",
            @"Could not upload that.": @"Não foi possível enviar.",
            @"Sending the file as a voice message": @"Enviando o arquivo como mensagem de voz",
            @"Tap the button in the chat to switch it back to the microphone, then try again.": @"Toque no botão do chat para voltar ao microfone e tente novamente.",
            @"Tap the pencil to see what a message said before.": @"Toque no lápis para ver o que a mensagem dizia antes.",
            @"Hold the microphone to send it.": @"Segure o microfone para enviar.",
            @"No chat open": @"Nenhum chat aberto",
            @"Unknown chat": @"Chat desconhecido",
            @"Round video": @"Vídeo circular",
            @"Round video sent": @"Vídeo circular enviado",
            @"Preparing the round video": @"Preparando o vídeo circular",
            @"That clip is too short.": @"Esse clipe é muito curto.",
            @"That file has no video to send.": @"Esse arquivo não tem vídeo para enviar.",
            @"Video notes are up to 60 seconds.": @"Vídeos circulares podem ter até 60 segundos.",
            @"Could not read that file.": @"Não foi possível ler esse arquivo.",
            @"That file has no audio.": @"Esse arquivo não tem áudio.",
            @"That file is too long.": @"Esse arquivo é muito longo.",
            @"Telegram no longer recognises this chat. Reopen it and try again.": @"O Telegram não reconhece mais este chat. Abra-o novamente e tente de novo.",
            @"Paste a YouTube video link to send its audio as a voice message.": @"Cole o link de um vídeo do YouTube para enviar o áudio como mensagem de voz.",
            @"Clear search history?": @"Limpar histórico de pesquisa?",
            @"Clear selected videos?": @"Limpar vídeos selecionados?",
        };
    });
    return translations;
}

static NSString *IQT13TranslatedText(NSString *text) {
    if (text.length == 0 || !IQTShouldUsePortuguese()) return nil;
    NSString *translated = IQT13ExtraTranslations()[text];
    if (translated.length > 0 && ![translated isEqualToString:text]) return translated;
    return IQTLegacyTranslatedText(text);
}

static void IQT13TranslateBarButtonItem(UIBarButtonItem *item) {
    if (item == nil) return;
    NSString *translated = IQT13TranslatedText(item.title);
    if (translated != nil) item.title = translated;
}

static void IQT13TranslateNavigationItem(UINavigationItem *item) {
    if (item == nil) return;
    NSString *translated = IQT13TranslatedText(item.title);
    if (translated != nil) item.title = translated;
    translated = IQT13TranslatedText(item.prompt);
    if (translated != nil) item.prompt = translated;
    IQT13TranslateBarButtonItem(item.leftBarButtonItem);
    IQT13TranslateBarButtonItem(item.rightBarButtonItem);
    for (UIBarButtonItem *barItem in item.leftBarButtonItems) IQT13TranslateBarButtonItem(barItem);
    for (UIBarButtonItem *barItem in item.rightBarButtonItems) IQT13TranslateBarButtonItem(barItem);
}

static BOOL IQT13TranslateLabel(UILabel *label) {
    if (label == nil) return NO;
    NSString *source = label.text;
    NSString *translated = IQT13TranslatedText(source);
    if (translated == nil || [translated isEqualToString:source]) return NO;

    NSAttributedString *attributed = label.attributedText;
    if (attributed.length == source.length && attributed.length > 0) {
        NSDictionary<NSAttributedStringKey, id> *attributes =
            [attributed attributesAtIndex:0 effectiveRange:NULL];
        label.attributedText = [[NSAttributedString alloc] initWithString:translated
                                                               attributes:attributes];
    } else {
        label.text = translated;
    }

    [label invalidateIntrinsicContentSize];
    [label setNeedsLayout];
    [label.superview setNeedsLayout];
    return YES;
}

static BOOL IQT13TranslateButton(UIButton *button) {
    if (button == nil) return NO;
    BOOL changed = NO;

    UIControlState states[] = {
        UIControlStateNormal,
        UIControlStateHighlighted,
        UIControlStateSelected,
        UIControlStateDisabled
    };
    for (NSUInteger index = 0; index < sizeof(states) / sizeof(states[0]); index++) {
        UIControlState state = states[index];
        NSString *source = [button titleForState:state];
        NSString *translated = IQT13TranslatedText(source);
        if (translated != nil && ![translated isEqualToString:source]) {
            [button setTitle:translated forState:state];
            changed = YES;
        }
    }

    if (@available(iOS 15.0, *)) {
        UIButtonConfiguration *configuration = button.configuration;
        NSString *source = configuration.title;
        NSString *translated = IQT13TranslatedText(source);
        if (translated != nil && ![translated isEqualToString:source]) {
            UIButtonConfiguration *copy = [configuration copy];
            copy.title = translated;
            button.configuration = copy;
            changed = YES;
        }
    }

    if (changed) {
        [button invalidateIntrinsicContentSize];
        [button setNeedsLayout];
        [button.superview setNeedsLayout];
    }
    return changed;
}

static BOOL IQT13TranslateViewTree(UIView *view) {
    if (view == nil) return NO;
    BOOL changed = NO;

    if ([view isKindOfClass:UILabel.class]) {
        changed |= IQT13TranslateLabel((UILabel *)view);
    } else if ([view isKindOfClass:UIButton.class]) {
        changed |= IQT13TranslateButton((UIButton *)view);
    } else if ([view isKindOfClass:UITextField.class]) {
        UITextField *field = (UITextField *)view;
        NSString *translated = IQT13TranslatedText(field.text);
        if (translated != nil && ![translated isEqualToString:field.text]) {
            field.text = translated;
            changed = YES;
        }
        translated = IQT13TranslatedText(field.placeholder);
        if (translated != nil && ![translated isEqualToString:field.placeholder]) {
            field.placeholder = translated;
            changed = YES;
        }
    } else if ([view isKindOfClass:UITextView.class]) {
        UITextView *textView = (UITextView *)view;
        NSString *translated = IQT13TranslatedText(textView.text);
        if (translated != nil && ![translated isEqualToString:textView.text]) {
            textView.text = translated;
            changed = YES;
        }
    } else if ([view isKindOfClass:UISegmentedControl.class]) {
        UISegmentedControl *segmented = (UISegmentedControl *)view;
        for (NSInteger index = 0; index < segmented.numberOfSegments; index++) {
            NSString *source = [segmented titleForSegmentAtIndex:index];
            NSString *translated = IQT13TranslatedText(source);
            if (translated != nil && ![translated isEqualToString:source]) {
                [segmented setTitle:translated forSegmentAtIndex:index];
                changed = YES;
            }
        }
    } else if ([view isKindOfClass:UISearchBar.class]) {
        UISearchBar *searchBar = (UISearchBar *)view;
        NSString *translated = IQT13TranslatedText(searchBar.placeholder);
        if (translated != nil && ![translated isEqualToString:searchBar.placeholder]) {
            searchBar.placeholder = translated;
            changed = YES;
        }
        translated = IQT13TranslatedText(searchBar.prompt);
        if (translated != nil && ![translated isEqualToString:searchBar.prompt]) {
            searchBar.prompt = translated;
            changed = YES;
        }
    }

    for (UIView *subview in view.subviews.copy) {
        if (IQT13TranslateViewTree(subview)) changed = YES;
    }
    return changed;
}

typedef void (*IQT13MSHookMessageExFunction)(Class cls, SEL selector, IMP replacement, IMP *original);

static NSMutableDictionary<NSString *, NSValue *> *IQT13LayoutOriginals(void) {
    static NSMutableDictionary<NSString *, NSValue *> *map;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ map = [NSMutableDictionary dictionary]; });
    return map;
}

static NSMutableDictionary<NSString *, NSValue *> *IQT13AppearOriginals(void) {
    static NSMutableDictionary<NSString *, NSValue *> *map;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ map = [NSMutableDictionary dictionary]; });
    return map;
}

static BOOL IQT13HooksInstalled = NO;

static void *IQT13FindSymbol(const char *name) {
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

static IMP IQT13OriginalForObject(id object, NSMutableDictionary<NSString *, NSValue *> *map) {
    if (object == nil || map == nil) return NULL;
    Class cls = [object class];
    while (cls != Nil) {
        NSValue *value = map[NSStringFromClass(cls)];
        if (value != nil) return [value pointerValue];
        cls = class_getSuperclass(cls);
    }
    return NULL;
}

static void IQT13TranslateBackButton(UIViewController *controller) {
    UINavigationController *navigation = controller.navigationController;
    if (navigation == nil) return;

    NSUInteger index = [navigation.viewControllers indexOfObjectIdenticalTo:controller];
    if (index != NSNotFound && index > 0) {
        UIViewController *previous = navigation.viewControllers[index - 1];
        previous.navigationItem.backButtonTitle = @"Voltar";
    }

    IQT13TranslateNavigationItem(controller.navigationItem);

    if (navigation.isViewLoaded) {
        IQT13TranslateViewTree(navigation.navigationBar);
        [navigation.navigationBar setNeedsLayout];
    }
}

static BOOL IQT13TranslateController(UIViewController *controller) {
    if (controller == nil) return NO;
    BOOL changed = NO;

    NSString *translated = IQT13TranslatedText(controller.title);
    if (translated != nil && ![translated isEqualToString:controller.title]) {
        controller.title = translated;
        changed = YES;
    }

    NSString *navTitle = controller.navigationItem.title;
    translated = IQT13TranslatedText(navTitle);
    if (translated != nil && ![translated isEqualToString:navTitle]) {
        controller.navigationItem.title = translated;
        changed = YES;
    }

    IQT13TranslateNavigationItem(controller.navigationItem);
    for (UIBarButtonItem *item in controller.toolbarItems) IQT13TranslateBarButtonItem(item);
    IQT13TranslateBackButton(controller);

    if (controller.isViewLoaded) {
        if (IQT13TranslateViewTree(controller.view)) changed = YES;
    }

    for (UIViewController *child in controller.childViewControllers.copy) {
        NSString *className = NSStringFromClass(child.class);
        if ([className hasPrefix:@"IQT"] && IQT13TranslateController(child)) changed = YES;
    }

    UIViewController *presented = controller.presentedViewController;
    if (presented != nil) {
        NSString *className = NSStringFromClass(presented.class);
        if ([className hasPrefix:@"IQT"] ||
            [presented isKindOfClass:UINavigationController.class]) {
            if (IQT13TranslateController(presented)) changed = YES;
        }
    }

    return changed;
}

static void IQT13RelayoutControllerSoon(UIViewController *controller) {
    if (controller == nil) return;
    __weak UIViewController *weakController = controller;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *strongController = weakController;
        if (strongController == nil || !strongController.isViewLoaded) return;

        IQT13TranslateController(strongController);
        [strongController.view setNeedsLayout];
        [strongController.view layoutIfNeeded];

        UINavigationController *navigation = strongController.navigationController;
        if (navigation != nil && navigation.isViewLoaded) {
            IQT13TranslateViewTree(navigation.navigationBar);
            [navigation.navigationBar setNeedsLayout];
            [navigation.navigationBar layoutIfNeeded];
        }
    });
}

static void IQT13ScheduleFinalPasses(UIViewController *controller) {
    if (controller == nil) return;
    const NSTimeInterval delays[] = {0.03, 0.12, 0.35, 0.75};
    __weak UIViewController *weakController = controller;
    for (NSUInteger index = 0; index < sizeof(delays) / sizeof(delays[0]); index++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(delays[index] * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIViewController *strongController = weakController;
            if (strongController == nil || !strongController.isViewLoaded ||
                strongController.view.window == nil) return;
            IQT13TranslateController(strongController);
            [strongController.view setNeedsLayout];
            [strongController.view layoutIfNeeded];

            UINavigationController *navigation = strongController.navigationController;
            if (navigation != nil && navigation.isViewLoaded) {
                IQT13TranslateViewTree(navigation.navigationBar);
                [navigation.navigationBar setNeedsLayout];
                [navigation.navigationBar layoutIfNeeded];
            }
        });
    }
}

static void IQT13ViewDidLayoutSubviews(id self, SEL command) {
    IMP original = IQT13OriginalForObject(self, IQT13LayoutOriginals());
    if (original != NULL) {
        ((void (*)(id, SEL))original)(self, command);
    }

    if (![self isKindOfClass:UIViewController.class]) return;
    UIViewController *controller = (UIViewController *)self;
    IQT13TranslateController(controller);
    IQT13RelayoutControllerSoon(controller);
}

static void IQT13ViewDidAppear(id self, SEL command, BOOL animated) {
    IMP original = IQT13OriginalForObject(self, IQT13AppearOriginals());
    if (original != NULL) {
        ((void (*)(id, SEL, BOOL))original)(self, command, animated);
    }

    if (![self isKindOfClass:UIViewController.class]) return;
    UIViewController *controller = (UIViewController *)self;
    IQT13TranslateController(controller);
    IQT13ScheduleFinalPasses(controller);
}

static BOOL IQT13IsViewControllerClass(Class cls) {
    if (cls == Nil) return NO;
    Class current = cls;
    Class base = UIViewController.class;
    while (current != Nil) {
        if (current == base) return YES;
        current = class_getSuperclass(current);
    }
    return NO;
}

static BOOL IQT13ShouldHookClass(Class cls) {
    if (!IQT13IsViewControllerClass(cls)) return NO;
    NSString *name = NSStringFromClass(cls);
    if (![name hasPrefix:@"IQT"]) return NO;

    static NSSet<NSString *> *allowed;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        allowed = [NSSet setWithArray:@[
            @"IQTSettingsViewController",
            @"IQTTranslateLanguagePicker",
            @"IQTCallRecordingsViewController",
            @"IQTDeletionLogViewController",
            @"IQTDeletedArchiveViewController",
            @"IQTDeletedPeopleViewController",
            @"IQTEditHistoryViewController",
            @"IQTVoiceTrimViewController",
            @"IQTYTSearchViewController"
        ]];
    });
    return [allowed containsObject:name];
}

static BOOL IQT13HasHookTargetSuperclass(Class cls) {
    Class parent = class_getSuperclass(cls);
    while (parent != Nil && parent != UIViewController.class) {
        if (IQT13ShouldHookClass(parent)) return YES;
        parent = class_getSuperclass(parent);
    }
    return NO;
}

static BOOL IQT13InstallHooks(void) {
    if (IQT13HooksInstalled) return YES;

    IQT13MSHookMessageExFunction hook =
        (IQT13MSHookMessageExFunction)IQT13FindSymbol("MSHookMessageEx");
    if (hook == NULL) return NO;

    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return NO;

    Class *classes = (__unsafe_unretained Class *)calloc((size_t)count, sizeof(Class));
    if (classes == NULL) return NO;
    count = objc_getClassList(classes, count);

    NSUInteger hookedCount = 0;
    for (int index = 0; index < count; index++) {
        Class cls = classes[index];
        if (!IQT13ShouldHookClass(cls)) continue;
        if (IQT13HasHookTargetSuperclass(cls)) continue;

        NSString *className = NSStringFromClass(cls);

        Method layoutMethod = class_getInstanceMethod(cls, @selector(viewDidLayoutSubviews));
        if (layoutMethod != NULL && IQT13LayoutOriginals()[className] == nil) {
            IMP original = NULL;
            hook(cls,
                 @selector(viewDidLayoutSubviews),
                 (IMP)&IQT13ViewDidLayoutSubviews,
                 &original);
            if (original != NULL) {
                IQT13LayoutOriginals()[className] = [NSValue valueWithPointer:original];
                hookedCount += 1;
            }
        }

        Method appearMethod = class_getInstanceMethod(cls, @selector(viewDidAppear:));
        if (appearMethod != NULL && IQT13AppearOriginals()[className] == nil) {
            IMP original = NULL;
            hook(cls,
                 @selector(viewDidAppear:),
                 (IMP)&IQT13ViewDidAppear,
                 &original);
            if (original != NULL) {
                IQT13AppearOriginals()[className] = [NSValue valueWithPointer:original];
                hookedCount += 1;
            }
        }
    }

    free(classes);

    IQT13HooksInstalled =
        IQT13LayoutOriginals()[@"IQTSettingsViewController"] != nil &&
        IQT13AppearOriginals()[@"IQTSettingsViewController"] != nil;
    return IQT13HooksInstalled || hookedCount > 0;
}

static void IQT13RetryInstall(NSUInteger attempt) {
    if (IQT13InstallHooks() || attempt >= 60) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.20 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        IQT13RetryInstall(attempt + 1);
    });
}

__attribute__((constructor))
static void IQT13TranslationInit(void) {
    @autoreleasepool {
        NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier ?: @"";
        NSString *executable = NSBundle.mainBundle.executablePath.lastPathComponent ?: @"";
        if (![bundleIdentifier isEqualToString:@"ph.telegra.Telegraph"] &&
            ![executable isEqualToString:@"Telegram"]) {
            return;
        }
        if (!IQTShouldUsePortuguese()) return;

        dispatch_async(dispatch_get_main_queue(), ^{
            IQT13RetryInstall(0);
        });
    }
}
