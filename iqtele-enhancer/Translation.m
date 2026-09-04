#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static __weak UIViewController *IQTTranslationSettingsController = nil;
static NSTimer *IQTTranslationTimer = nil;
static BOOL IQTTranslationHooksInstalled = NO;

static BOOL IQTShouldUsePortuguese(void) {
    id forced = [NSUserDefaults.standardUserDefaults objectForKey:@"IQTEnhancerForcePortuguese"];
    if (forced != nil) {
        return [forced boolValue];
    }

    NSString *language = NSLocale.preferredLanguages.firstObject.lowercaseString ?: @"";
    return [language hasPrefix:@"pt"];
}

static NSDictionary<NSString *, NSString *> *IQTPortugueseTranslations(void) {
    static NSDictionary<NSString *, NSString *> *translations;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        translations = @{
            @"Features": @"Recursos",
            @"Messages": @"Mensagens",
            @"Stories": @"Stories",
            @"Call recorder": @"Gravador de chamadas",
            @"Appearance": @"Aparência",
            @"Language": @"Idioma",
            @"Login": @"Login",
            @"Log in by QR code": @"Entrar por código QR",
            @"Developer": @"Desenvolvedor",
            @"Join Telegram channel": @"Entrar no canal do Telegram",
            @"About": @"Sobre",
            @"Diagnostics": @"Diagnóstico",
            @"Diagnostics shown": @"Diagnóstico exibido",
            @"Diagnostics hidden": @"Diagnóstico oculto",
            @"Record diagnostics": @"Registrar diagnóstico",
            @"Off by default. Turning it off also clears what was recorded.": @"Desativado por padrão. Desativar esta opção também apaga o que foi registrado.",
            @"Follow system": @"Seguir o sistema",
            @"Ghost mode": @"Modo fantasma",
            @"Temporary media": @"Mídia temporária",
            @"Activity indicators": @"Indicadores de atividade",
            @"Other": @"Outros",
            @"Send as round video": @"Enviar como vídeo circular",
            @"Restricted content": @"Conteúdo restrito",
            @"Save, screenshot, copy and forward restricted content.": @"Salvar, capturar a tela, copiar e encaminhar conteúdo restrito.",
            @"Hide ads in channels": @"Ocultar anúncios nos canais",
            @"Experimental feature": @"Recurso experimental",
            @"Translate messages": @"Traduzir mensagens",
            @"Edit history": @"Histórico de edições",
            @"Edit History": @"Histórico de edições",
            @"Highlight edited words": @"Destacar palavras editadas",
            @"In the edit-history screen, colours what changed between versions.": @"Na tela do histórico de edições, destaca o que mudou entre as versões.",
            @"Clear edit history": @"Limpar histórico de edições",
            @"Nothing saved yet": @"Nada salvo ainda",
            @"Clear edit history?": @"Limpar histórico de edições?",
            @"This removes every version saved here. It cannot be undone.": @"Isso remove todas as versões salvas aqui. Esta ação não pode ser desfeita.",
            @"Enable call recorder": @"Ativar gravador de chamadas",
            @"Auto record calls": @"Gravar chamadas automaticamente",
            @"Record video call": @"Gravar videochamada",
            @"Recordings": @"Gravações",
            @"Online status": @"Status online",
            @"Hide online status": @"Ocultar status online",
            @"Hide typing": @"Ocultar digitação",
            @"Hide recording voice": @"Ocultar gravação de voz",
            @"Hide sending photo": @"Ocultar envio de foto",
            @"Hide sending video": @"Ocultar envio de vídeo",
            @"Hide sending file": @"Ocultar envio de arquivo",
            @"Hide choosing sticker": @"Ocultar escolha de sticker",
            @"Hide location and contact": @"Ocultar localização e contato",
            @"Ghost mode in messages": @"Modo fantasma nas mensagens",
            @"Ghost mode and deleted messages": @"Modo fantasma e mensagens excluídas",
            @"On your side": @"Do seu lado",
            @"Read messages locally": @"Ler mensagens localmente",
            @"Mark as read": @"Marcar como lida",
            @"Read button in the chat": @"Botão de leitura no chat",
            @"Mark as read on reaction": @"Marcar como lida ao reagir",
            @"Mark as read on typing": @"Marcar como lida ao digitar",
            @"Where the read button appears": @"Onde o botão de leitura aparece",
            @"Private chats": @"Conversas privadas",
            @"Channels and groups": @"Canais e grupos",
            @"Do not send read receipts automatically.": @"Não enviar confirmações de leitura automaticamente.",
            @"Read receipts are held back": @"As confirmações de leitura ficam retidas",
            @"Reading a message no longer tells the sender you read it. The receipt is held back rather than thrown away, so you can still send it whenever you choose.": @"Ler uma mensagem deixa de informar ao remetente que você a leu. A confirmação fica retida em vez de ser descartada, para que você ainda possa enviá-la quando quiser.",
            @"Reacting to a message sends the receipt for that chat.": @"Reagir a uma mensagem envia a confirmação de leitura desse chat.",
            @"Typing in a chat sends the receipt for it.": @"Digitar em um chat envia a confirmação de leitura dele.",
            @"Typing, recording, sending a file": @"Digitando, gravando, enviando um arquivo",
            @"Nobody sees that you are online.": @"Ninguém vê que você está online.",
            @"Ghost mode in stories": @"Modo fantasma nos stories",
            @"Watch stories locally": @"Ver stories localmente",
            @"Mark as watched": @"Marcar como visto",
            @"Eye button in stories": @"Botão de olho nos stories",
            @"Saving": @"Salvamento",
            @"Download button in stories": @"Botão de download nos stories",
            @"View without expiring": @"Visualizar sem expirar",
            @"No screenshot notification": @"Sem notificação de captura de tela",
            @"Save button in the viewer": @"Botão de salvar no visualizador",
            @"Watching without being seen": @"Assistir sem ser visto",
            @"Ghost mode, the eye button, and downloads": @"Modo fantasma, botão de olho e downloads",
            @"Do not tell people you watched.": @"Não informar às pessoas que você assistiu.",
            @"Watching a story no longer puts you in its viewer list. The receipt is held rather than discarded, so you can still send it deliberately.": @"Assistir a um story deixa de colocar você na lista de visualizações. A confirmação fica retida em vez de ser descartada, para que você ainda possa enviá-la manualmente.",
            @"Tap it while watching to let them see you did.": @"Toque enquanto estiver assistindo para permitir que vejam que você assistiu.",
            @"Save the story to your photos.": @"Salvar o story no app Fotos.",
            @"They can now see that you watched.": @"Agora eles podem ver que você assistiu.",
            @"Nothing is being held back for this story.": @"Não há nenhuma confirmação retida para este story.",
            @"Story saved.": @"Story salvo.",
            @"Could not save this story.": @"Não foi possível salvar este story.",
            @"Wait for the story to load, then try again.": @"Aguarde o story carregar e tente novamente.",
            @"Allow photo access to save stories.": @"Permita acesso ao app Fotos para salvar stories.",
            @"Let the video finish loading, then try again.": @"Aguarde o vídeo terminar de carregar e tente novamente.",
            @"One-time and self-destructing photos and videos": @"Fotos e vídeos de visualização única ou autodestrutivos",
            @"Do not start the self-destruct timer.": @"Não iniciar o temporizador de autodestruição.",
            @"Take screenshots without telling the other person.": @"Fazer capturas de tela sem avisar a outra pessoa.",
            @"Save temporary media to your photos.": @"Salvar mídias temporárias no app Fotos.",
            @"Keep deleted messages": @"Manter mensagens excluídas",
            @"Keep deleted": @"Manter excluídas",
            @"Keeping what other people delete": @"Manter o que outras pessoas excluem",
            @"Keep the ones I delete": @"Manter as que eu excluir",
            @"They stay in the chat with the trash badge. The other side still loses them.": @"Elas permanecem no chat com o ícone de lixeira. Para a outra pessoa, continuam excluídas.",
            @"Messages deleted by the other side remain visible to you.": @"Mensagens excluídas pela outra pessoa continuam visíveis para você.",
            @"Saved messages": @"Mensagens salvas",
            @"Deleted messages": @"Mensagens excluídas",
            @"Deleted message": @"Mensagem excluída",
            @"Nothing here yet. Messages the other side deletes will be saved here.": @"Ainda não há nada aqui. As mensagens que a outra pessoa excluir serão salvas aqui.",
            @"Tap a chat to see its deleted messages.": @"Toque em um chat para ver as mensagens excluídas.",
            @"Tap a message to copy it.": @"Toque em uma mensagem para copiá-la.",
            @"Today": @"Hoje",
            @"Last 7 days": @"Últimos 7 dias",
            @"Last 30 days": @"Últimos 30 dias",
            @"Any time": @"Qualquer período",
            @"Date": @"Data",
            @"Search messages": @"Pesquisar mensagens",
            @"Any direction": @"Qualquer direção",
            @"Received": @"Recebidas",
            @"Sent": @"Enviadas",
            @"Deleted by anyone": @"Excluídas por qualquer pessoa",
            @"Deleted by me": @"Excluídas por mim",
            @"Deleted by them": @"Excluídas pela outra pessoa",
            @"Direction": @"Direção",
            @"Deleted by": @"Excluída por",
            @"Them": @"A outra pessoa",
            @"You": @"Você",
            @"deleted by you": @"excluída por você",
            @"deleted by them": @"excluída pela outra pessoa",
            @"Nothing matches those filters.": @"Nada corresponde a esses filtros.",
            @"Clear all": @"Limpar tudo",
            @"This removes every message saved here. It cannot be undone.": @"Isso remove todas as mensagens salvas aqui. Esta ação não pode ser desfeita.",
            @"Clear saved messages?": @"Limpar mensagens salvas?",
            @"Search": @"Pesquisar",
            @"No results": @"Nenhum resultado",
            @"No results found": @"Nenhum resultado encontrado",
            @"Back": @"Voltar",
            @"Close": @"Fechar",
            @"Cancel": @"Cancelar",
            @"Clear": @"Limpar",
            @"Delete": @"Excluir",
            @"Done": @"Concluído",
            @"Open": @"Abrir",
            @"Select": @"Selecionar",
            @"Share": @"Compartilhar",
            @"Copy": @"Copiar",
            @"Filter": @"Filtrar",
            @"Sort": @"Ordenar",
            @"All": @"Todos",
            @"Audio": @"Áudio",
            @"Video": @"Vídeo",
            @"Audio + video": @"Áudio + vídeo",
            @"Audio only": @"Somente áudio",
            @"Video only": @"Somente vídeo",
            @"Choose call recording mode": @"Escolher modo de gravação de chamadas",
            @"Record voice and video calls": @"Gravar chamadas de voz e vídeo",
            @"Recorded calls": @"Chamadas gravadas",
            @"Search recordings": @"Pesquisar gravações",
            @"No call recordings found": @"Nenhuma gravação de chamada encontrada",
            @"Newest first": @"Mais recentes primeiro",
            @"Oldest first": @"Mais antigas primeiro",
            @"Largest first": @"Maiores primeiro",
            @"Name A-Z": @"Nome A-Z",
            @"Call recording saved successfully!": @"Gravação da chamada salva com sucesso!",
            @"Call recording started": @"Gravação da chamada iniciada",
            @"Call recording started automatically": @"Gravação automática da chamada iniciada",
            @"Translation": @"Tradução",
            @"Double-tap a message to translate it": @"Toque duas vezes em uma mensagem para traduzi-la",
            @"Could not translate": @"Não foi possível traduzir",
            @"Nothing to translate": @"Não há nada para traduzir",
            @"Version": @"Versão",
            @"Restart": @"Reiniciar",
            @"Restart required": @"Reinicialização necessária",
            @"Telegram has to restart for this to take effect.": @"O Telegram precisa ser reiniciado para que esta alteração entre em vigor.",
            @"Status": @"Status",
            @"Starting up": @"Inicializando",
            @"Not armed": @"Não ativado",
            @"NOT installed": @"NÃO instalado",
            @"installed": @"instalado",
            @"off": @"desativado",
            @"on": @"ativado",
            @"refused": @"recusado",
            @"No hooks reported yet.": @"Nenhum hook informado ainda.",
            @"Nothing logged yet.": @"Nada registrado ainda.",
            @"Nothing logged yet. Reproduce the problem, then come back.": @"Nada registrado ainda. Reproduza o problema e volte aqui.",
            @"If messages are still disappearing, this says which parts are working. Tap to copy.": @"Se as mensagens ainda estiverem desaparecendo, isto mostra quais partes estão funcionando. Toque para copiar.",
            @"Choose a file": @"Escolher um arquivo",
            @"Choose from library": @"Escolher da biblioteca",
            @"Send from a file": @"Enviar de um arquivo",
            @"Send as voice message": @"Enviar como mensagem de voz",
            @"Turn a file or video into a voice message": @"Transformar um arquivo ou vídeo em mensagem de voz",
            @"Voice message": @"Mensagem de voz",
            @"Voice message sent": @"Mensagem de voz enviada",
            @"Ready. Open a chat and hold the record button briefly.": @"Pronto. Abra um chat e mantenha o botão de gravação pressionado brevemente.",
            @"Open the chat first, then try again.": @"Abra o chat primeiro e tente novamente.",
            @"Telegram is not connected yet.": @"O Telegram ainda não está conectado.",
            @"Telegram did not answer.": @"O Telegram não respondeu.",
            @"Could not send that.": @"Não foi possível enviar.",
            @"Cancelled": @"Cancelado",
            @"Paste a link": @"Cole um link",
            @"Download audio": @"Baixar áudio",
            @"History": @"Histórico",
            @"YouTube link": @"Link do YouTube",
            @"Search YouTube": @"Pesquisar no YouTube",
            @"Search for a song or video": @"Pesquisar uma música ou vídeo",
            @"Search history": @"Histórico de pesquisa",
            @"Selected videos": @"Vídeos selecionados",
            @"Tap to search again": @"Toque para pesquisar novamente",
            @"Type to search YouTube": @"Digite para pesquisar no YouTube",
            @"No YouTube history yet": @"Ainda não há histórico do YouTube",
            @"No audio stream available": @"Nenhuma faixa de áudio disponível",
            @"Invalid YouTube link": @"Link do YouTube inválido",
            @"Could not download YouTube audio": @"Não foi possível baixar o áudio do YouTube",
            @"Video unavailable": @"Vídeo indisponível",
            @"This video can't be played": @"Este vídeo não pode ser reproduzido",
            @"This video is private or age-restricted": @"Este vídeo é privado ou possui restrição de idade",
            @"Unexpected response from YouTube": @"Resposta inesperada do YouTube",
            @"Live streams can't be sent as audio": @"Transmissões ao vivo não podem ser enviadas como áudio"
        };
    });
    return translations;
}

static NSString *IQTTranslatedText(NSString *text) {
    if (text.length == 0 || !IQTShouldUsePortuguese()) {
        return nil;
    }

    NSString *translated = IQTPortugueseTranslations()[text];
    if (translated.length > 0 && ![translated isEqualToString:text]) {
        return translated;
    }

    if ([text hasPrefix:@"Version "]) {
        return [@"Versão " stringByAppendingString:[text substringFromIndex:8]];
    }
    if ([text hasPrefix:@"Ready: "]) {
        return [@"Pronto: " stringByAppendingString:[text substringFromIndex:7]];
    }
    if ([text hasSuffix:@" results"]) {
        return [[text substringToIndex:text.length - 8] stringByAppendingString:@" resultados"];
    }
    if ([text hasSuffix:@" result"]) {
        return [[text substringToIndex:text.length - 7] stringByAppendingString:@" resultado"];
    }
    if ([text hasSuffix:@" chats"]) {
        return [[text substringToIndex:text.length - 6] stringByAppendingString:@" conversas"];
    }
    if ([text hasSuffix:@" chat"]) {
        return [[text substringToIndex:text.length - 5] stringByAppendingString:@" conversa"];
    }
    if ([text hasSuffix:@" messages"]) {
        return [[text substringToIndex:text.length - 9] stringByAppendingString:@" mensagens"];
    }
    if ([text hasSuffix:@" message"]) {
        return [[text substringToIndex:text.length - 8] stringByAppendingString:@" mensagem"];
    }

    return nil;
}

static void IQTTranslateBarButtonItem(UIBarButtonItem *item) {
    NSString *translated = IQTTranslatedText(item.title);
    if (translated != nil) {
        item.title = translated;
    }
}

static void IQTTranslateNavigationItem(UINavigationItem *item) {
    if (item == nil) return;

    NSString *translated = IQTTranslatedText(item.title);
    if (translated != nil) {
        item.title = translated;
    }

    IQTTranslateBarButtonItem(item.leftBarButtonItem);
    IQTTranslateBarButtonItem(item.rightBarButtonItem);
    for (UIBarButtonItem *barItem in item.leftBarButtonItems) {
        IQTTranslateBarButtonItem(barItem);
    }
    for (UIBarButtonItem *barItem in item.rightBarButtonItems) {
        IQTTranslateBarButtonItem(barItem);
    }
}

static void IQTTranslateLabel(UILabel *label) {
    NSString *source = label.text;
    NSString *translated = IQTTranslatedText(source);
    if (translated == nil) return;

    NSAttributedString *attributed = label.attributedText;
    if (attributed.length == source.length && attributed.length > 0) {
        NSDictionary<NSAttributedStringKey, id> *attributes = [attributed attributesAtIndex:0 effectiveRange:NULL];
        label.attributedText = [[NSAttributedString alloc] initWithString:translated attributes:attributes];
    } else {
        label.text = translated;
    }
}

static void IQTTranslateButton(UIButton *button) {
    UIControlState states[] = {
        UIControlStateNormal,
        UIControlStateHighlighted,
        UIControlStateSelected,
        UIControlStateDisabled
    };

    for (NSUInteger index = 0; index < sizeof(states) / sizeof(states[0]); index++) {
        UIControlState state = states[index];
        NSString *source = [button titleForState:state];
        NSString *translated = IQTTranslatedText(source);
        if (translated != nil) {
            [button setTitle:translated forState:state];
        }
    }
}

static void IQTTranslateViewTree(UIView *view) {
    if (view == nil) return;

    if ([view isKindOfClass:UILabel.class]) {
        IQTTranslateLabel((UILabel *)view);
    } else if ([view isKindOfClass:UIButton.class]) {
        IQTTranslateButton((UIButton *)view);
    } else if ([view isKindOfClass:UITextField.class]) {
        UITextField *field = (UITextField *)view;
        NSString *translated = IQTTranslatedText(field.placeholder);
        if (translated != nil) field.placeholder = translated;
    } else if ([view isKindOfClass:UITextView.class]) {
        UITextView *textView = (UITextView *)view;
        NSString *translated = IQTTranslatedText(textView.text);
        if (translated != nil) textView.text = translated;
    } else if ([view isKindOfClass:UISegmentedControl.class]) {
        UISegmentedControl *segmented = (UISegmentedControl *)view;
        for (NSInteger index = 0; index < segmented.numberOfSegments; index++) {
            NSString *source = [segmented titleForSegmentAtIndex:index];
            NSString *translated = IQTTranslatedText(source);
            if (translated != nil) {
                [segmented setTitle:translated forSegmentAtIndex:index];
            }
        }
    } else if ([view isKindOfClass:UISearchBar.class]) {
        UISearchBar *searchBar = (UISearchBar *)view;
        NSString *translated = IQTTranslatedText(searchBar.placeholder);
        if (translated != nil) searchBar.placeholder = translated;
    }

    for (UIView *subview in view.subviews.copy) {
        IQTTranslateViewTree(subview);
    }
}

static void IQTTranslateControllerTree(UIViewController *controller) {
    if (controller == nil) return;

    IQTTranslateNavigationItem(controller.navigationItem);
    for (UIBarButtonItem *item in controller.toolbarItems) {
        IQTTranslateBarButtonItem(item);
    }

    if (controller.isViewLoaded) {
        IQTTranslateViewTree(controller.view);
    }

    if ([controller isKindOfClass:UINavigationController.class]) {
        UINavigationController *navigation = (UINavigationController *)controller;
        IQTTranslateNavigationItem(navigation.visibleViewController.navigationItem);
        if (navigation.navigationBar != nil) {
            IQTTranslateViewTree(navigation.navigationBar);
        }
    }

    for (UIViewController *child in controller.childViewControllers.copy) {
        IQTTranslateControllerTree(child);
    }

    if (controller.presentedViewController != nil) {
        IQTTranslateControllerTree(controller.presentedViewController);
    }
}

static UIViewController *IQTTranslationRootController(UIViewController *settingsController) {
    if (settingsController.navigationController != nil) {
        return settingsController.navigationController;
    }
    return settingsController;
}

static void IQTApplyPortugueseTranslation(UIViewController *settingsController) {
    if (settingsController == nil || !IQTShouldUsePortuguese()) return;
    UIViewController *root = IQTTranslationRootController(settingsController);
    IQTTranslateControllerTree(root);
}

static void IQTStopTranslationTimer(void) {
    [IQTTranslationTimer invalidate];
    IQTTranslationTimer = nil;
}

static void IQTStartTranslationTimer(UIViewController *settingsController) {
    if (settingsController == nil || !IQTShouldUsePortuguese()) return;

    IQTTranslationSettingsController = settingsController;
    IQTApplyPortugueseTranslation(settingsController);

    if (IQTTranslationTimer != nil) return;

    IQTTranslationTimer = [NSTimer timerWithTimeInterval:0.25
                                                 repeats:YES
                                                   block:^(__unused NSTimer *timer) {
        UIViewController *controller = IQTTranslationSettingsController;
        if (controller == nil) {
            IQTStopTranslationTimer();
            return;
        }

        UIViewController *root = IQTTranslationRootController(controller);
        if (!root.isViewLoaded || root.view.window == nil) {
            IQTStopTranslationTimer();
            return;
        }

        IQTApplyPortugueseTranslation(controller);
    }];
    [NSRunLoop.mainRunLoop addTimer:IQTTranslationTimer forMode:NSRunLoopCommonModes];
}

static void IQTScheduleTranslationPasses(UIViewController *controller) {
    if (controller == nil || !IQTShouldUsePortuguese()) return;

    const NSTimeInterval delays[] = {0.0, 0.05, 0.15, 0.40, 0.80};
    __weak UIViewController *weakController = controller;
    for (NSUInteger index = 0; index < sizeof(delays) / sizeof(delays[0]); index++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delays[index] * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIViewController *strongController = weakController;
            if (strongController != nil) {
                IQTApplyPortugueseTranslation(strongController);
            }
        });
    }
}

static void (*IQTOriginalSettingsViewDidLoad)(id, SEL) = NULL;
static void (*IQTOriginalSettingsViewWillAppear)(id, SEL, BOOL) = NULL;
static void (*IQTOriginalSettingsViewDidAppear)(id, SEL, BOOL) = NULL;
static void (*IQTOriginalSettingsViewDidLayoutSubviews)(id, SEL) = NULL;

static void IQTSettingsViewDidLoad(id self, SEL _cmd) {
    if (IQTOriginalSettingsViewDidLoad != NULL) {
        IQTOriginalSettingsViewDidLoad(self, _cmd);
    }
    IQTScheduleTranslationPasses((UIViewController *)self);
}

static void IQTSettingsViewWillAppear(id self, SEL _cmd, BOOL animated) {
    if (IQTOriginalSettingsViewWillAppear != NULL) {
        IQTOriginalSettingsViewWillAppear(self, _cmd, animated);
    }
    IQTStartTranslationTimer((UIViewController *)self);
    IQTScheduleTranslationPasses((UIViewController *)self);
}

static void IQTSettingsViewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (IQTOriginalSettingsViewDidAppear != NULL) {
        IQTOriginalSettingsViewDidAppear(self, _cmd, animated);
    }
    IQTStartTranslationTimer((UIViewController *)self);
    IQTScheduleTranslationPasses((UIViewController *)self);
}

static void IQTSettingsViewDidLayoutSubviews(id self, SEL _cmd) {
    if (IQTOriginalSettingsViewDidLayoutSubviews != NULL) {
        IQTOriginalSettingsViewDidLayoutSubviews(self, _cmd);
    }
    IQTApplyPortugueseTranslation((UIViewController *)self);
}

static BOOL IQTClassOwnsMethod(Class cls, SEL selector) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    BOOL owns = NO;
    for (unsigned int index = 0; index < count; index++) {
        if (method_getName(methods[index]) == selector) {
            owns = YES;
            break;
        }
    }
    free(methods);
    return owns;
}

static BOOL IQTHookSettingsMethod(Class cls, SEL selector, IMP replacement, IMP *originalOut) {
    Method inherited = class_getInstanceMethod(cls, selector);
    if (inherited == NULL) return NO;

    IMP original = method_getImplementation(inherited);
    const char *types = method_getTypeEncoding(inherited);

    if (IQTClassOwnsMethod(cls, selector)) {
        Method own = class_getInstanceMethod(cls, selector);
        original = method_setImplementation(own, replacement);
    } else {
        if (!class_addMethod(cls, selector, replacement, types)) {
            return NO;
        }
    }

    if (originalOut != NULL) *originalOut = original;
    return YES;
}

static void IQTInstallTranslationHooksIfReady(void) {
    if (IQTTranslationHooksInstalled || !IQTShouldUsePortuguese()) return;

    Class settingsClass = NSClassFromString(@"IQTSettingsViewController");
    if (settingsClass == Nil) return;

    BOOL didLoad = IQTHookSettingsMethod(settingsClass,
                                         @selector(viewDidLoad),
                                         (IMP)&IQTSettingsViewDidLoad,
                                         (IMP *)&IQTOriginalSettingsViewDidLoad);
    BOOL willAppear = IQTHookSettingsMethod(settingsClass,
                                            @selector(viewWillAppear:),
                                            (IMP)&IQTSettingsViewWillAppear,
                                            (IMP *)&IQTOriginalSettingsViewWillAppear);
    BOOL didAppear = IQTHookSettingsMethod(settingsClass,
                                           @selector(viewDidAppear:),
                                           (IMP)&IQTSettingsViewDidAppear,
                                           (IMP *)&IQTOriginalSettingsViewDidAppear);
    BOOL didLayout = IQTHookSettingsMethod(settingsClass,
                                           @selector(viewDidLayoutSubviews),
                                           (IMP)&IQTSettingsViewDidLayoutSubviews,
                                           (IMP *)&IQTOriginalSettingsViewDidLayoutSubviews);

    IQTTranslationHooksInstalled = didLoad || willAppear || didAppear || didLayout;
}

static void IQTRetryTranslationHookInstall(NSUInteger attempt) {
    IQTInstallTranslationHooksIfReady();
    if (IQTTranslationHooksInstalled || attempt >= 40) return;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        IQTRetryTranslationHookInstall(attempt + 1);
    });
}

__attribute__((constructor)) static void IQTTranslationInit(void) {
    @autoreleasepool {
        NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier ?: @"";
        NSString *executable = NSBundle.mainBundle.executablePath.lastPathComponent ?: @"";
        if (![bundleIdentifier isEqualToString:@"ph.telegra.Telegraph"] &&
            ![executable isEqualToString:@"Telegram"]) {
            return;
        }

        if (!IQTShouldUsePortuguese()) return;

        dispatch_async(dispatch_get_main_queue(), ^{
            IQTRetryTranslationHookInstall(0);
        });
    }
}
