#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// iQTeleEnhancer / iQTele 1.3 localization overlay.
// Reuses the proven translation table from Translation.m but disables its
// private IQTSettingsViewController hooks. Translation is applied by a
// scanner restricted to visible iQTele controllers, following the iQFace 1.1 model.

// Neutralize the legacy constructor and rename its text resolver while including
// the existing file. The legacy translation table remains available in this TU.
#define constructor unused
#define IQTTranslatedText IQTLegacyTranslatedText
#include "Translation.m"
#undef IQTTranslatedText
#undef constructor

__attribute__((used, visibility("default"))) NSString * const IQTEnhancerLocalizationVersion13 = @"1.3-scanner-only";
static dispatch_source_t IQT13LocalizationScanner = nil;

static NSDictionary<NSString *, NSString *> *IQT13ExtraTranslations(void) {
    static NSDictionary<NSString *, NSString *> *translations;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        translations = @{
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
            @"Eye button in chats": @"Botão de olho nas conversas",
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

static void IQT13TranslateLabel(UILabel *label) {
    if (label == nil) return;
    NSString *source = label.text;
    NSString *translated = IQT13TranslatedText(source);
    if (translated == nil || [translated isEqualToString:source]) return;
    NSAttributedString *attributed = label.attributedText;
    if (attributed.length == source.length && attributed.length > 0) {
        NSMutableAttributedString *replacement = [attributed mutableCopy];
        [replacement replaceCharactersInRange:NSMakeRange(0, replacement.length) withString:translated];
        label.attributedText = replacement;
    } else {
        label.text = translated;
    }
}

static void IQT13TranslateButton(UIButton *button) {
    if (button == nil) return;
    UIControlState states[] = { UIControlStateNormal, UIControlStateHighlighted, UIControlStateSelected, UIControlStateDisabled };
    for (NSUInteger index = 0; index < sizeof(states) / sizeof(states[0]); index++) {
        UIControlState state = states[index];
        NSString *source = [button titleForState:state];
        NSString *translated = IQT13TranslatedText(source);
        if (translated != nil && ![translated isEqualToString:source]) [button setTitle:translated forState:state];
    }
    if (@available(iOS 15.0, *)) {
        UIButtonConfiguration *configuration = button.configuration;
        NSString *source = configuration.title;
        NSString *translated = IQT13TranslatedText(source);
        if (translated != nil && ![translated isEqualToString:source]) {
            UIButtonConfiguration *copy = [configuration copy];
            copy.title = translated;
            button.configuration = copy;
        }
    }
}

static void IQT13TranslateViewTree(UIView *view) {
    if (view == nil) return;
    if ([view isKindOfClass:UILabel.class]) {
        IQT13TranslateLabel((UILabel *)view);
    } else if ([view isKindOfClass:UIButton.class]) {
        IQT13TranslateButton((UIButton *)view);
    } else if ([view isKindOfClass:UITextField.class]) {
        UITextField *field = (UITextField *)view;
        NSString *translated = IQT13TranslatedText(field.text);
        if (translated != nil) field.text = translated;
        translated = IQT13TranslatedText(field.placeholder);
        if (translated != nil) field.placeholder = translated;
    } else if ([view isKindOfClass:UITextView.class]) {
        UITextView *textView = (UITextView *)view;
        NSString *translated = IQT13TranslatedText(textView.text);
        if (translated != nil) textView.text = translated;
    } else if ([view isKindOfClass:UISegmentedControl.class]) {
        UISegmentedControl *segmented = (UISegmentedControl *)view;
        for (NSInteger index = 0; index < segmented.numberOfSegments; index++) {
            NSString *source = [segmented titleForSegmentAtIndex:index];
            NSString *translated = IQT13TranslatedText(source);
            if (translated != nil) [segmented setTitle:translated forSegmentAtIndex:index];
        }
    } else if ([view isKindOfClass:UISearchBar.class]) {
        UISearchBar *searchBar = (UISearchBar *)view;
        NSString *translated = IQT13TranslatedText(searchBar.placeholder);
        if (translated != nil) searchBar.placeholder = translated;
        translated = IQT13TranslatedText(searchBar.prompt);
        if (translated != nil) searchBar.prompt = translated;
    }
    for (UIView *subview in view.subviews.copy) IQT13TranslateViewTree(subview);
}

static BOOL IQT13ClassBelongsToIQTele(Class cls) {
    NSString *name = cls != Nil ? NSStringFromClass(cls) : @"";
    return [name hasPrefix:@"IQT"];
}

static BOOL IQT13NavigationContainsIQTele(UINavigationController *navigation) {
    for (UIViewController *controller in navigation.viewControllers.copy) {
        if (IQT13ClassBelongsToIQTele(controller.class)) return YES;
    }
    return NO;
}

static BOOL IQT13BeginsContext(UIViewController *controller) {
    if (controller == nil) return NO;
    if (IQT13ClassBelongsToIQTele(controller.class)) return YES;
    if ([controller isKindOfClass:UINavigationController.class]) return IQT13NavigationContainsIQTele((UINavigationController *)controller);
    return NO;
}

static void IQT13TranslateControllerTree(UIViewController *controller, BOOL inheritedContext) {
    if (controller == nil) return;
    BOOL context = inheritedContext || IQT13BeginsContext(controller);
    if (context) {
        NSString *translated = IQT13TranslatedText(controller.title);
        if (translated != nil) controller.title = translated;
        IQT13TranslateNavigationItem(controller.navigationItem);
        for (UIBarButtonItem *item in controller.toolbarItems) IQT13TranslateBarButtonItem(item);
        if (controller.isViewLoaded) IQT13TranslateViewTree(controller.view);
        if ([controller isKindOfClass:UINavigationController.class]) {
            UINavigationController *navigation = (UINavigationController *)controller;
            IQT13TranslateNavigationItem(navigation.visibleViewController.navigationItem);
            if (navigation.isViewLoaded && navigation.navigationBar != nil) IQT13TranslateViewTree(navigation.navigationBar);
            if (navigation.isViewLoaded && navigation.toolbar != nil) IQT13TranslateViewTree(navigation.toolbar);
        }
    }
    for (UIViewController *child in controller.childViewControllers.copy) IQT13TranslateControllerTree(child, context);
    if (controller.presentedViewController != nil) IQT13TranslateControllerTree(controller.presentedViewController, context);
}

static void IQT13ScanVisibleUI(void) {
    if (!IQTShouldUsePortuguese() || UIApplication.sharedApplication.applicationState == UIApplicationStateBackground) return;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows.copy) {
                if (!window.hidden && window.alpha > 0.01) IQT13TranslateControllerTree(window.rootViewController, NO);
            }
        }
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        for (UIWindow *window in UIApplication.sharedApplication.windows.copy) {
            if (!window.hidden && window.alpha > 0.01) IQT13TranslateControllerTree(window.rootViewController, NO);
        }
#pragma clang diagnostic pop
    }
}

static void IQT13StartScanner(void) {
    if (IQT13LocalizationScanner != nil) return;
    IQT13LocalizationScanner = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(IQT13LocalizationScanner, dispatch_time(DISPATCH_TIME_NOW, 0),
                              (uint64_t)(0.20 * NSEC_PER_SEC), (uint64_t)(0.04 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(IQT13LocalizationScanner, ^{ IQT13ScanVisibleUI(); });
    dispatch_resume(IQT13LocalizationScanner);
}

__attribute__((constructor))
static void IQT13TranslationInit(void) {
    @autoreleasepool {
        NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier ?: @"";
        NSString *executable = NSBundle.mainBundle.executablePath.lastPathComponent ?: @"";
        if (![bundleIdentifier isEqualToString:@"ph.telegra.Telegraph"] && ![executable isEqualToString:@"Telegram"]) return;
        if (!IQTShouldUsePortuguese()) return;
        dispatch_async(dispatch_get_main_queue(), ^{ IQT13StartScanner(); });
    }
}
