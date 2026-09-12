#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <string.h>

// iQFaceEnhancer localization module for iQFace 1.1.
// Kept separate from the gesture/launcher code so the proven launcher behavior
// does not need to change just to extend the Portuguese translation catalog.

__attribute__((visibility("default"))) NSString * const IQFEnhancerLocalizationVersion = @"1.1";

typedef NSString *(*IQFLocFunction)(NSString *key);
typedef void (*MSHookFunctionType)(void *symbol, void *replacement, void **original);

static IQFLocFunction IQFOriginalLoc11 = NULL;
static BOOL IQFLocalization11Installed = NO;
static NSInteger IQFLocalization11Attempts = 0;

static void *IQF11FindSymbol(const char *name) {
    void *symbol = dlsym(RTLD_DEFAULT, name);
    if (symbol != NULL) return symbol;

    char underscored[128] = {0};
    if (strlen(name) + 2 >= sizeof(underscored)) return NULL;
    underscored[0] = '_';
    strlcpy(underscored + 1, name, sizeof(underscored) - 1);
    return dlsym(RTLD_DEFAULT, underscored);
}

static BOOL IQF11ShouldUsePortuguese(void) {
    id forcedValue = [[NSUserDefaults standardUserDefaults] objectForKey:@"IQFEnhancerForcePortuguese"];
    if (forcedValue != nil) return [forcedValue boolValue];

    NSString *language = NSLocale.preferredLanguages.firstObject.lowercaseString;
    return [language hasPrefix:@"pt"];
}

static NSDictionary<NSString *, NSString *> *IQF11PortugueseTranslations(void) {
    static NSDictionary<NSString *, NSString *> *translations;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        translations = @{
            // Core / navigation
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

            // iQFace 1.1 - General
            @"Open links in Safari": @"Abrir links no Safari",
            @"Block ads": @"Bloquear anúncios",
            @"Download videos": @"Baixar vídeos",
            @"Block in-stream video ads": @"Bloquear anúncios em vídeos",

            // iQFace 1.1 - Feed
            @"Hide suggested Reels": @"Ocultar Reels sugeridos",
            @"Hide group suggestions": @"Ocultar sugestões de grupos",
            @"Hide \"People You May Know\"": @"Ocultar \"Pessoas que você talvez conheça\"",
            @"Hide suggested posts": @"Ocultar publicações sugeridas",

            // iQFace 1.1 - Stories
            @"Anonymous stories": @"Stories anônimos",
            @"Hide stories": @"Ocultar stories",
            @"Ghost mode in stories": @"Modo fantasma nos stories",
            @"Watch stories locally (grey ring)": @"Assistir stories localmente (anel cinza)",

            // iQFace 1.1 - Reels
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

            // Save / download actions
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

            // Story state / feedback
            @"Marked as seen": @"Marcado como visto",
            @"Already marked as seen": @"Já estava marcado como visto",
            @"They can already see you": @"Essa pessoa já pode ver que você assistiu",
            @"Nothing to send for this story": @"Não há nada para enviar neste story",

            // Confirmations
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

            // Descriptions
            @"Asks before an action that is easy to tap by accident. Everything here is off until you turn it on.": @"Pede confirmação antes de ações que podem ser tocadas por engano. Todas ficam desativadas até você ativá-las.",
            @"Blocks sponsored posts in the feed, and ads inside stories and Reels.": @"Bloqueia publicações patrocinadas no feed e anúncios dentro de stories e Reels.",
            @"Removes these cards from the feed entirely — nothing is left in their place. Each is off until you turn it on.": @"Remove completamente esses cartões do feed, sem deixar espaços no lugar. Cada opção fica desativada até você ativá-las.",

            @"OK": @"OK"
        };
    });
    return translations;
}

static NSString *IQF11LocalizedPortuguese(NSString *key) {
    if (key.length == 0 || !IQF11ShouldUsePortuguese()) return nil;
    return IQF11PortugueseTranslations()[key];
}

static NSString *IQF11LocReplacement(NSString *key) {
    NSString *translation = IQF11LocalizedPortuguese(key);
    if (translation != nil) return translation;
    return IQFOriginalLoc11 != NULL ? IQFOriginalLoc11(key) : key;
}

static BOOL IQF11InstallLocalizationHook(void) {
    if (IQFLocalization11Installed) return YES;

    void *locSymbol = IQF11FindSymbol("IQFLoc");
    MSHookFunctionType hookFunction = (MSHookFunctionType)IQF11FindSymbol("MSHookFunction");
    if (locSymbol == NULL || hookFunction == NULL) return NO;

    hookFunction(locSymbol, (void *)&IQF11LocReplacement, (void **)&IQFOriginalLoc11);
    IQFLocalization11Installed = IQFOriginalLoc11 != NULL;
    return IQFLocalization11Installed;
}

static void IQF11TryInstallLocalization(void) {
    IQFLocalization11Attempts += 1;
    if (IQF11InstallLocalizationHook() || IQFLocalization11Attempts >= 80) return;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        IQF11TryInstallLocalization();
    });
}

__attribute__((constructor))
static void IQFEnhancerLocalization11Initialize(void) {
    @autoreleasepool {
        NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier;
        if (![bundleIdentifier isEqualToString:@"com.facebook.Facebook"] ||
            [NSBundle.mainBundle.bundlePath hasSuffix:@".appex"]) return;

        dispatch_async(dispatch_get_main_queue(), ^{
            IQF11TryInstallLocalization();
        });
    }
}
