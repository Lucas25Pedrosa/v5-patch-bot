#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

__attribute__((used, visibility("default"))) NSString * const NexusVersion = @"2.0 Beta 2";

static NSString * const NXKeyThreads = @"NexusHideThreadsPromotions";
static NSString * const NXKeyPages = @"NexusHideSuggestedPages";
static NSString * const NXKeyStoryPeople = @"NexusHideStoryPeopleSuggestions";
static NSString * const NXKeyActivation = @"NexusActivationMode";
static NSString * const NXKeyBackgroundMode = @"NexusBackgroundMode";
static NSString * const NXKeyBackgroundColor = @"NexusCustomBackgroundColor";
static NSString * const NXSettingsChangedNotification = @"NexusSettingsDidChange";

typedef NSString *(*NXResolvedLanguageFunction)(void);
typedef void (*NXPresentSettingsFunction)(void);

extern BOOL Nexus2BackgroundHookInstalled(void);
extern NSInteger Nexus2BackgroundCurrentMode(void);
extern BOOL Nexus2AvatarHooksInstalled(void);

#pragma mark - Shared helpers

static void *NXFindSymbol(const char *name) {
    void *value = dlsym(RTLD_DEFAULT, name);
    if (value) return value;
    char underscored[160] = {0};
    underscored[0] = '_';
    strlcpy(underscored + 1, name, sizeof(underscored) - 1);
    return dlsym(RTLD_DEFAULT, underscored);
}

static NSString *NXLanguageCode(void) {
    NXResolvedLanguageFunction resolved =
        (NXResolvedLanguageFunction)NXFindSymbol("IQFResolvedLanguage");
    NSString *language = resolved ? resolved() : nil;
    if (![language isKindOfClass:NSString.class] || language.length == 0) {
        language = NSLocale.preferredLanguages.firstObject ?: @"en";
    }
    NSString *code = language.lowercaseString;
    if ([code hasPrefix:@"pt"]) return @"pt";
    if ([code hasPrefix:@"ar"]) return @"ar";
    if ([code hasPrefix:@"ckb"] || [code hasPrefix:@"ku"]) return @"ckb";
    if ([code hasPrefix:@"fr"]) return @"fr";
    if ([code hasPrefix:@"ru"]) return @"ru";
    if ([code hasPrefix:@"fa"]) return @"fa";
    if ([code hasPrefix:@"zh"]) return @"zh";
    if ([code hasPrefix:@"vi"]) return @"vi";
    return @"en";
}

static NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *NXTranslations(void) {
    static NSDictionary *all;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        all = @{
            @"pt": @{
                @"Appearance": @"Aparência",
                @"Background appearance": @"Aparência do fundo",
                @"Standard": @"Padrão",
                @"OLED": @"OLED",
                @"Custom color": @"Cor personalizada",
                @"Background color": @"Cor do fundo",
                @"Dark mode required": @"Requer o Modo Escuro do Facebook ativado.",
                @"Light color warning": @"Esta cor pode reduzir o contraste de textos e ícones no Modo Escuro.",
                @"Feed filters": @"Filtros do feed",
                @"Hide Threads promotion": @"Ocultar promoção do Threads",
                @"Hide suggested pages": @"Ocultar páginas sugeridas",
                @"Hide people suggestions in Stories": @"Ocultar sugestões de pessoas nos Stories",
                @"Activation": @"Ativação",
                @"iQFace icon": @"Ícone do iQFace",
                @"Facebook logo": @"Logo do Facebook",
                @"Activation icon subtitle": @"Exibe o ícone do iQFace e usa-o para abrir as configurações.",
                @"Activation logo subtitle": @"Oculta o ícone do iQFace e abre as configurações ao tocar no logo do Facebook.",
                @"Unavailable on this Facebook version": @"Indisponível nesta versão do Facebook",
                @"Available": @"Disponível",
                @"Settings manager": @"Gerenciador de configurações",
                @"Export settings": @"Exportar configurações",
                @"Import settings": @"Importar configurações",
                @"Reset settings": @"Redefinir configurações",
                @"Reset all settings?": @"Redefinir todas as configurações do Nexus e iQFace?",
                @"Reset warning": @"Esta ação remove as preferências do Nexus e iQFace. O aplicativo pode precisar ser reaberto.",
                @"Reset": @"Redefinir",
                @"Cancel": @"Cancelar",
                @"Import completed": @"Importação concluída",
                @"Invalid backup": @"Backup inválido",
                @"Diagnostics": @"Diagnóstico",
                @"Copy diagnostics": @"Copiar diagnóstico",
                @"Refresh": @"Atualizar",
                @"Capture UI": @"Capturar interface",
                @"Copied": @"Copiado",
                @"Change Icon": @"Alterar ícone",
                @"Feed separators": @"Separadores no feed",
                @"Clear cache": @"Limpar cache",
                @"Automatic cache clearing": @"Limpar cache automaticamente",
                @"Disabled": @"Desativado",
                @"Daily": @"Diariamente",
                @"Weekly": @"Semanalmente",
                @"Monthly": @"Mensalmente",
                @"Close": @"Fechar",
                @"Default": @"Padrão",
                @"Could not change icon": @"Não foi possível alterar o ícone.",
                @"iOS does not allow changing this app icon.": @"O iOS não permite alterar o ícone deste aplicativo.",
                @"Cache cleared": @"Cache limpo",
                @"freed": @"liberados",
                @"Some files were in use.": @"Alguns arquivos estavam em uso.",
                @"Approximately %@ of temporary files will be removed.": @"Serão removidos aproximadamente %@ de arquivos temporários.",
                @"Clear": @"Limpar",
                @"Nexus developer": @"Desenvolvedor do Nexus"
            },
            @"fr": @{
                @"Appearance": @"Apparence", @"Background appearance": @"Arrière-plan",
                @"Standard": @"Standard", @"OLED": @"OLED", @"Custom color": @"Couleur personnalisée",
                @"Background color": @"Couleur d’arrière-plan",
                @"Dark mode required": @"Nécessite le mode sombre de Facebook.",
                @"Light color warning": @"Cette couleur peut réduire le contraste du texte et des icônes en mode sombre.",
                @"Feed filters": @"Filtres du fil", @"Hide Threads promotion": @"Masquer la promotion Threads",
                @"Hide suggested pages": @"Masquer les pages suggérées",
                @"Hide people suggestions in Stories": @"Masquer les suggestions de personnes dans les Stories",
                @"Activation": @"Activation", @"iQFace icon": @"Icône iQFace", @"Facebook logo": @"Logo Facebook",
                @"Activation icon subtitle": @"Affiche l’icône iQFace pour ouvrir les réglages.",
                @"Activation logo subtitle": @"Masque l’icône iQFace et ouvre les réglages en touchant le logo Facebook.",
                @"Unavailable on this Facebook version": @"Indisponible avec cette version de Facebook",
                @"Available": @"Disponible", @"Settings manager": @"Gestionnaire des réglages",
                @"Export settings": @"Exporter les réglages", @"Import settings": @"Importer les réglages",
                @"Reset settings": @"Réinitialiser les réglages",
                @"Reset all settings?": @"Réinitialiser tous les réglages Nexus et iQFace ?",
                @"Reset warning": @"Cette action supprime les préférences de Nexus et iQFace.",
                @"Reset": @"Réinitialiser", @"Cancel": @"Annuler", @"Import completed": @"Importation terminée",
                @"Invalid backup": @"Sauvegarde invalide", @"Diagnostics": @"Diagnostic",
                @"Copy diagnostics": @"Copier le diagnostic", @"Refresh": @"Actualiser",
                @"Capture UI": @"Capturer l’interface", @"Copied": @"Copié",
                @"Change Icon": @"Changer l’icône", @"Feed separators": @"Séparateurs du fil",
                @"Clear cache": @"Vider le cache", @"Automatic cache clearing": @"Nettoyage automatique du cache",
                @"Disabled": @"Désactivé", @"Daily": @"Tous les jours", @"Weekly": @"Chaque semaine",
                @"Monthly": @"Chaque mois", @"Close": @"Fermer", @"Default": @"Par défaut",
                @"Could not change icon": @"Impossible de changer l’icône.",
                @"iOS does not allow changing this app icon.": @"iOS n’autorise pas le changement de cette icône.",
                @"Cache cleared": @"Cache vidé", @"freed": @"libérés",
                @"Some files were in use.": @"Certains fichiers étaient utilisés.",
                @"Approximately %@ of temporary files will be removed.": @"Environ %@ de fichiers temporaires seront supprimés.",
                @"Clear": @"Vider",
                @"Nexus developer": @"Développeur de Nexus"
            },
            @"ru": @{
                @"Appearance": @"Оформление", @"Background appearance": @"Фон",
                @"Standard": @"Стандартный", @"OLED": @"OLED", @"Custom color": @"Свой цвет",
                @"Background color": @"Цвет фона", @"Dark mode required": @"Требуется тёмный режим Facebook.",
                @"Light color warning": @"Светлый цвет может снизить контраст текста и значков.",
                @"Feed filters": @"Фильтры ленты", @"Hide Threads promotion": @"Скрывать рекламу Threads",
                @"Hide suggested pages": @"Скрывать рекомендуемые страницы",
                @"Hide people suggestions in Stories": @"Скрывать рекомендации людей в Stories",
                @"Activation": @"Активация", @"iQFace icon": @"Значок iQFace", @"Facebook logo": @"Логотип Facebook",
                @"Activation icon subtitle": @"Показывает значок iQFace для открытия настроек.",
                @"Activation logo subtitle": @"Скрывает значок iQFace и открывает настройки нажатием на логотип Facebook.",
                @"Unavailable on this Facebook version": @"Недоступно в этой версии Facebook",
                @"Available": @"Доступно", @"Settings manager": @"Управление настройками",
                @"Export settings": @"Экспорт настроек", @"Import settings": @"Импорт настроек",
                @"Reset settings": @"Сбросить настройки", @"Reset all settings?": @"Сбросить все настройки Nexus и iQFace?",
                @"Reset warning": @"Будут удалены настройки Nexus и iQFace.", @"Reset": @"Сбросить",
                @"Cancel": @"Отмена", @"Import completed": @"Импорт завершён", @"Invalid backup": @"Неверная резервная копия",
                @"Diagnostics": @"Диагностика", @"Copy diagnostics": @"Копировать диагностику",
                @"Refresh": @"Обновить", @"Capture UI": @"Снять структуру интерфейса", @"Copied": @"Скопировано",
                @"Change Icon": @"Изменить значок", @"Feed separators": @"Разделители в ленте",
                @"Clear cache": @"Очистить кэш", @"Automatic cache clearing": @"Автоочистка кэша",
                @"Disabled": @"Выключено", @"Daily": @"Ежедневно", @"Weekly": @"Еженедельно",
                @"Monthly": @"Ежемесячно", @"Close": @"Закрыть", @"Default": @"По умолчанию",
                @"Could not change icon": @"Не удалось изменить значок.",
                @"iOS does not allow changing this app icon.": @"iOS не позволяет изменить значок этого приложения.",
                @"Cache cleared": @"Кэш очищен", @"freed": @"освобождено",
                @"Some files were in use.": @"Некоторые файлы использовались.",
                @"Approximately %@ of temporary files will be removed.": @"Будет удалено примерно %@ временных файлов.",
                @"Clear": @"Очистить",
                @"Nexus developer": @"Разработчик Nexus"
            },
            @"zh": @{
                @"Appearance": @"外观", @"Background appearance": @"背景外观",
                @"Standard": @"标准", @"OLED": @"OLED", @"Custom color": @"自定义颜色",
                @"Background color": @"背景颜色", @"Dark mode required": @"需要启用 Facebook 深色模式。",
                @"Light color warning": @"此颜色可能会降低深色模式下文字和图标的对比度。",
                @"Feed filters": @"动态筛选", @"Hide Threads promotion": @"隐藏 Threads 推广",
                @"Hide suggested pages": @"隐藏推荐主页", @"Hide people suggestions in Stories": @"隐藏 Stories 中的好友推荐",
                @"Activation": @"启动方式", @"iQFace icon": @"iQFace 图标", @"Facebook logo": @"Facebook 标志",
                @"Activation icon subtitle": @"显示 iQFace 图标并用它打开设置。",
                @"Activation logo subtitle": @"隐藏 iQFace 图标，点击 Facebook 标志打开设置。",
                @"Unavailable on this Facebook version": @"此 Facebook 版本不可用", @"Available": @"可用",
                @"Settings manager": @"设置管理", @"Export settings": @"导出设置", @"Import settings": @"导入设置",
                @"Reset settings": @"重置设置", @"Reset all settings?": @"重置 Nexus 和 iQFace 的全部设置？",
                @"Reset warning": @"此操作会移除 Nexus 和 iQFace 偏好设置。", @"Reset": @"重置", @"Cancel": @"取消",
                @"Import completed": @"导入完成", @"Invalid backup": @"无效备份", @"Diagnostics": @"诊断",
                @"Copy diagnostics": @"复制诊断", @"Refresh": @"刷新", @"Capture UI": @"捕获界面", @"Copied": @"已复制",
                @"Change Icon": @"更改图标", @"Feed separators": @"动态分隔线", @"Clear cache": @"清除缓存",
                @"Automatic cache clearing": @"自动清除缓存", @"Disabled": @"关闭", @"Daily": @"每天",
                @"Weekly": @"每周", @"Monthly": @"每月", @"Close": @"关闭", @"Default": @"默认",
                @"Could not change icon": @"无法更改图标。",
                @"iOS does not allow changing this app icon.": @"iOS 不允许更改此应用图标。",
                @"Cache cleared": @"缓存已清除", @"freed": @"已释放",
                @"Some files were in use.": @"部分文件正在使用。",
                @"Approximately %@ of temporary files will be removed.": @"将删除约 %@ 的临时文件。",
                @"Clear": @"清除",
                @"Nexus developer": @"Nexus 开发者"
            },
            @"vi": @{
                @"Appearance": @"Giao diện", @"Background appearance": @"Giao diện nền",
                @"Standard": @"Mặc định", @"OLED": @"OLED", @"Custom color": @"Màu tùy chỉnh",
                @"Background color": @"Màu nền", @"Dark mode required": @"Yêu cầu bật Chế độ tối của Facebook.",
                @"Light color warning": @"Màu này có thể làm giảm độ tương phản của chữ và biểu tượng.",
                @"Feed filters": @"Bộ lọc bảng tin", @"Hide Threads promotion": @"Ẩn quảng bá Threads",
                @"Hide suggested pages": @"Ẩn Trang được đề xuất",
                @"Hide people suggestions in Stories": @"Ẩn gợi ý người trong Stories",
                @"Activation": @"Kích hoạt", @"iQFace icon": @"Biểu tượng iQFace", @"Facebook logo": @"Logo Facebook",
                @"Activation icon subtitle": @"Hiển thị biểu tượng iQFace để mở cài đặt.",
                @"Activation logo subtitle": @"Ẩn biểu tượng iQFace và chạm logo Facebook để mở cài đặt.",
                @"Unavailable on this Facebook version": @"Không khả dụng trên phiên bản Facebook này",
                @"Available": @"Khả dụng", @"Settings manager": @"Quản lý cài đặt",
                @"Export settings": @"Xuất cài đặt", @"Import settings": @"Nhập cài đặt",
                @"Reset settings": @"Đặt lại cài đặt", @"Reset all settings?": @"Đặt lại toàn bộ cài đặt Nexus và iQFace?",
                @"Reset warning": @"Thao tác này sẽ xóa tùy chọn Nexus và iQFace.", @"Reset": @"Đặt lại",
                @"Cancel": @"Hủy", @"Import completed": @"Nhập hoàn tất", @"Invalid backup": @"Bản sao lưu không hợp lệ",
                @"Diagnostics": @"Chẩn đoán", @"Copy diagnostics": @"Sao chép chẩn đoán", @"Refresh": @"Làm mới",
                @"Capture UI": @"Chụp cấu trúc giao diện", @"Copied": @"Đã sao chép",
                @"Change Icon": @"Đổi biểu tượng", @"Feed separators": @"Dấu phân cách bảng tin",
                @"Clear cache": @"Xóa bộ nhớ đệm", @"Automatic cache clearing": @"Tự động xóa bộ nhớ đệm",
                @"Disabled": @"Tắt", @"Daily": @"Hàng ngày", @"Weekly": @"Hàng tuần", @"Monthly": @"Hàng tháng",
                @"Close": @"Đóng", @"Default": @"Mặc định", @"Could not change icon": @"Không thể đổi biểu tượng.",
                @"iOS does not allow changing this app icon.": @"iOS không cho phép đổi biểu tượng ứng dụng này.",
                @"Cache cleared": @"Đã xóa bộ nhớ đệm", @"freed": @"đã giải phóng",
                @"Some files were in use.": @"Một số tệp đang được sử dụng.",
                @"Approximately %@ of temporary files will be removed.": @"Khoảng %@ tệp tạm thời sẽ bị xóa.",
                @"Clear": @"Xóa",
                @"Nexus developer": @"Nhà phát triển Nexus"
            },
            @"ar": @{
                @"Appearance": @"المظهر", @"Background appearance": @"مظهر الخلفية",
                @"Standard": @"افتراضي", @"OLED": @"OLED", @"Custom color": @"لون مخصص",
                @"Background color": @"لون الخلفية", @"Dark mode required": @"يتطلب تفعيل الوضع الداكن في Facebook.",
                @"Light color warning": @"قد يقلل هذا اللون من تباين النصوص والأيقونات في الوضع الداكن.",
                @"Feed filters": @"مرشحات الموجز", @"Hide Threads promotion": @"إخفاء ترويج Threads",
                @"Hide suggested pages": @"إخفاء الصفحات المقترحة",
                @"Hide people suggestions in Stories": @"إخفاء اقتراحات الأشخاص في القصص",
                @"Activation": @"طريقة الفتح", @"iQFace icon": @"أيقونة iQFace", @"Facebook logo": @"شعار Facebook",
                @"Activation icon subtitle": @"إظهار أيقونة iQFace واستخدامها لفتح الإعدادات.",
                @"Activation logo subtitle": @"إخفاء أيقونة iQFace وفتح الإعدادات بالنقر على شعار Facebook.",
                @"Unavailable on this Facebook version": @"غير متاح في إصدار Facebook هذا", @"Available": @"متاح",
                @"Settings manager": @"إدارة الإعدادات", @"Export settings": @"تصدير الإعدادات",
                @"Import settings": @"استيراد الإعدادات", @"Reset settings": @"إعادة تعيين الإعدادات",
                @"Reset all settings?": @"إعادة تعيين جميع إعدادات Nexus وiQFace؟",
                @"Reset warning": @"سيؤدي ذلك إلى إزالة تفضيلات Nexus وiQFace.", @"Reset": @"إعادة تعيين",
                @"Cancel": @"إلغاء", @"Import completed": @"اكتمل الاستيراد", @"Invalid backup": @"نسخة احتياطية غير صالحة",
                @"Diagnostics": @"التشخيص", @"Copy diagnostics": @"نسخ التشخيص", @"Refresh": @"تحديث",
                @"Capture UI": @"التقاط الواجهة", @"Copied": @"تم النسخ", @"Change Icon": @"تغيير الأيقونة",
                @"Feed separators": @"فواصل الموجز", @"Clear cache": @"مسح ذاكرة التخزين المؤقت",
                @"Automatic cache clearing": @"المسح التلقائي للذاكرة المؤقتة", @"Disabled": @"معطل",
                @"Daily": @"يوميًا", @"Weekly": @"أسبوعيًا", @"Monthly": @"شهريًا", @"Close": @"إغلاق",
                @"Default": @"افتراضي", @"Could not change icon": @"تعذر تغيير الأيقونة.",
                @"iOS does not allow changing this app icon.": @"لا يسمح iOS بتغيير أيقونة هذا التطبيق.",
                @"Cache cleared": @"تم مسح ذاكرة التخزين المؤقت", @"freed": @"تم تحريرها",
                @"Some files were in use.": @"كانت بعض الملفات قيد الاستخدام.",
                @"Approximately %@ of temporary files will be removed.": @"ستتم إزالة نحو %@ من الملفات المؤقتة.",
                @"Clear": @"مسح",
                @"Nexus developer": @"مطوّر Nexus"
            },
            @"fa": @{
                @"Appearance": @"ظاهر", @"Background appearance": @"ظاهر پس‌زمینه",
                @"Standard": @"استاندارد", @"OLED": @"OLED", @"Custom color": @"رنگ دلخواه",
                @"Background color": @"رنگ پس‌زمینه", @"Dark mode required": @"نیازمند فعال بودن حالت تاریک Facebook است.",
                @"Light color warning": @"این رنگ ممکن است کنتراست متن و نمادها را کاهش دهد.",
                @"Feed filters": @"فیلترهای فید", @"Hide Threads promotion": @"مخفی کردن تبلیغ Threads",
                @"Hide suggested pages": @"مخفی کردن صفحات پیشنهادی",
                @"Hide people suggestions in Stories": @"مخفی کردن پیشنهاد افراد در Stories",
                @"Activation": @"فعال‌سازی", @"iQFace icon": @"آیکن iQFace", @"Facebook logo": @"لوگوی Facebook",
                @"Activation icon subtitle": @"آیکن iQFace را برای باز کردن تنظیمات نمایش می‌دهد.",
                @"Activation logo subtitle": @"آیکن iQFace را مخفی می‌کند و با لمس لوگوی Facebook تنظیمات را باز می‌کند.",
                @"Unavailable on this Facebook version": @"در این نسخه Facebook در دسترس نیست", @"Available": @"در دسترس",
                @"Settings manager": @"مدیریت تنظیمات", @"Export settings": @"خروجی تنظیمات",
                @"Import settings": @"ورود تنظیمات", @"Reset settings": @"بازنشانی تنظیمات",
                @"Reset all settings?": @"همه تنظیمات Nexus و iQFace بازنشانی شوند؟",
                @"Reset warning": @"این کار تنظیمات Nexus و iQFace را حذف می‌کند.", @"Reset": @"بازنشانی",
                @"Cancel": @"لغو", @"Import completed": @"ورود انجام شد", @"Invalid backup": @"نسخه پشتیبان نامعتبر",
                @"Diagnostics": @"عیب‌یابی", @"Copy diagnostics": @"کپی عیب‌یابی", @"Refresh": @"تازه‌سازی",
                @"Capture UI": @"ثبت رابط", @"Copied": @"کپی شد", @"Change Icon": @"تغییر آیکن",
                @"Feed separators": @"جداکننده‌های فید", @"Clear cache": @"پاک کردن کش",
                @"Automatic cache clearing": @"پاک‌سازی خودکار کش", @"Disabled": @"غیرفعال",
                @"Daily": @"روزانه", @"Weekly": @"هفتگی", @"Monthly": @"ماهانه", @"Close": @"بستن",
                @"Default": @"پیش‌فرض", @"Could not change icon": @"تغییر آیکن ممکن نشد.",
                @"iOS does not allow changing this app icon.": @"iOS اجازه تغییر آیکن این برنامه را نمی‌دهد.",
                @"Cache cleared": @"کش پاک شد", @"freed": @"آزاد شد",
                @"Some files were in use.": @"برخی فایل‌ها در حال استفاده بودند.",
                @"Approximately %@ of temporary files will be removed.": @"حدود %@ فایل موقت حذف خواهد شد.",
                @"Clear": @"پاک کردن",
                @"Nexus developer": @"توسعه‌دهنده Nexus"
            },
            @"ckb": @{
                @"Appearance": @"ڕووکار", @"Background appearance": @"ڕووکاری پاشبنەما",
                @"Standard": @"بنەڕەتی", @"OLED": @"OLED", @"Custom color": @"ڕەنگی تایبەت",
                @"Background color": @"ڕەنگی پاشبنەما", @"Dark mode required": @"پێویستی بە چالاکبوونی دۆخی تاریکی Facebook هەیە.",
                @"Light color warning": @"ئەم ڕەنگە لەوانەیە کۆنتراستی دەق و ئایکۆن کەم بکات.",
                @"Feed filters": @"پاڵێوەرەکانی فید", @"Hide Threads promotion": @"شاردنەوەی بانگەشەی Threads",
                @"Hide suggested pages": @"شاردنەوەی پەڕە پێشنیارکراوەکان",
                @"Hide people suggestions in Stories": @"شاردنەوەی پێشنیاری کەسان لە چیرۆکەکان",
                @"Activation": @"چالاککردن", @"iQFace icon": @"ئایکۆنی iQFace", @"Facebook logo": @"لۆگۆی Facebook",
                @"Activation icon subtitle": @"ئایکۆنی iQFace پیشان دەدات بۆ کردنەوەی ڕێکخستنەکان.",
                @"Activation logo subtitle": @"ئایکۆنی iQFace دەشارێتەوە و بە کرتە لە لۆگۆی Facebook ڕێکخستنەکان دەکاتەوە.",
                @"Unavailable on this Facebook version": @"لە ئەم وەشانی Facebook بەردەست نییە", @"Available": @"بەردەستە",
                @"Settings manager": @"بەڕێوەبەری ڕێکخستنەکان", @"Export settings": @"هەناردەکردنی ڕێکخستنەکان",
                @"Import settings": @"هاوردەکردنی ڕێکخستنەکان", @"Reset settings": @"ڕێکخستنەوەی ڕێکخستنەکان",
                @"Reset all settings?": @"هەموو ڕێکخستنەکانی Nexus و iQFace ڕێکبخرێنەوە؟",
                @"Reset warning": @"ئەم کردارە هەڵبژاردەکانی Nexus و iQFace دەسڕێتەوە.", @"Reset": @"ڕێکخستنەوە",
                @"Cancel": @"هەڵوەشاندنەوە", @"Import completed": @"هاوردەکردن تەواو بوو",
                @"Invalid backup": @"پاڵپشتی نادروست", @"Diagnostics": @"پشکنین",
                @"Copy diagnostics": @"کۆپیکردنی پشکنین", @"Refresh": @"نوێکردنەوە",
                @"Capture UI": @"تۆمارکردنی ڕووکار", @"Copied": @"کۆپی کرا", @"Change Icon": @"گۆڕینی ئایکۆن",
                @"Feed separators": @"جیاکەرەوەکانی فید", @"Clear cache": @"پاککردنەوەی کاش",
                @"Automatic cache clearing": @"پاککردنەوەی خۆکارانەی کاش", @"Disabled": @"ناچالاک",
                @"Daily": @"ڕۆژانە", @"Weekly": @"هەفتانە", @"Monthly": @"مانگانە", @"Close": @"داخستن",
                @"Default": @"بنەڕەتی", @"Could not change icon": @"نەتوانرا ئایکۆن بگۆڕدرێت.",
                @"iOS does not allow changing this app icon.": @"iOS ڕێگە بە گۆڕینی ئایکۆنی ئەم ئەپە نادات.",
                @"Cache cleared": @"کاش پاککرایەوە", @"freed": @"ئازاد کرا",
                @"Some files were in use.": @"هەندێک فایل لە بەکارهێناندا بوون.",
                @"Approximately %@ of temporary files will be removed.": @"نزیکەی %@ فایلە کاتییەکان دەسڕدرێنەوە.",
                @"Clear": @"پاککردنەوە",
                @"Nexus developer": @"گەشەپێدەری Nexus"
            }
        };
    });
    return all;
}

static NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *NXExtraTranslations(void) {
    static NSDictionary *all;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        all = @{
            @"pt": @{@"Summary":@"Resumo", @"Technical log":@"Log técnico", @"Working":@"Funcionando",
                     @"Loaded":@"Carregado", @"Ready":@"Pronto", @"Waiting for feed detection":@"Aguardando detecção do feed",
                     @"Integration with iQFace":@"Integração com iQFace", @"Icons":@"Ícones", @"Cache":@"Cache",
                     @"Utilities":@"Utilitários", @"Tools":@"Ferramentas", @"Activation method":@"Método de ativação",
                     @"Backup and restore":@"Backup e restauração",
                     @"Hide suggestions in Stories":@"Ocultar sugestões nos Stories",
                     @"Feed detection pending":@"Os filtros serão aplicados assim que o Facebook carregar um modelo de feed compatível."},
            @"fr": @{@"Summary":@"Résumé", @"Technical log":@"Journal technique", @"Working":@"Fonctionne",
                     @"Waiting for feed detection":@"En attente de détection du fil", @"Integration with iQFace":@"Intégration avec iQFace",
                     @"Icons":@"Icônes", @"Cache":@"Cache", @"Utilities":@"Utilitaires",
                     @"Hide suggestions in Stories":@"Masquer les suggestions dans Stories",
                     @"Feed detection pending":@"Les filtres seront appliqués dès que Facebook chargera un modèle de fil compatible."},
            @"ru": @{@"Summary":@"Сводка", @"Technical log":@"Технический журнал", @"Working":@"Работает",
                     @"Waiting for feed detection":@"Ожидание обнаружения ленты", @"Integration with iQFace":@"Интеграция с iQFace",
                     @"Icons":@"Значки", @"Cache":@"Кэш", @"Utilities":@"Инструменты",
                     @"Hide suggestions in Stories":@"Скрывать рекомендации в Stories",
                     @"Feed detection pending":@"Фильтры применятся, когда Facebook загрузит совместимую модель ленты."},
            @"zh": @{@"Summary":@"摘要", @"Technical log":@"技术日志", @"Working":@"正常",
                     @"Waiting for feed detection":@"等待检测动态", @"Integration with iQFace":@"与 iQFace 集成",
                     @"Icons":@"图标", @"Cache":@"缓存", @"Utilities":@"工具",
                     @"Hide suggestions in Stories":@"隐藏 Stories 中的推荐",
                     @"Feed detection pending":@"Facebook 加载兼容的动态模型后将自动应用筛选。"},
            @"vi": @{@"Summary":@"Tóm tắt", @"Technical log":@"Nhật ký kỹ thuật", @"Working":@"Hoạt động",
                     @"Waiting for feed detection":@"Đang chờ phát hiện bảng tin", @"Integration with iQFace":@"Tích hợp iQFace",
                     @"Icons":@"Biểu tượng", @"Cache":@"Bộ nhớ đệm", @"Utilities":@"Tiện ích",
                     @"Hide suggestions in Stories":@"Ẩn gợi ý trong Stories",
                     @"Feed detection pending":@"Bộ lọc sẽ được áp dụng khi Facebook tải mô hình bảng tin tương thích."},
            @"ar": @{@"Summary":@"الملخص", @"Technical log":@"السجل التقني", @"Working":@"يعمل",
                     @"Waiting for feed detection":@"بانتظار اكتشاف الموجز", @"Integration with iQFace":@"التكامل مع iQFace",
                     @"Icons":@"الأيقونات", @"Cache":@"ذاكرة التخزين المؤقت", @"Utilities":@"أدوات",
                     @"Hide suggestions in Stories":@"إخفاء الاقتراحات في القصص",
                     @"Feed detection pending":@"سيتم تطبيق المرشحات عندما يحمّل Facebook نموذج موجز متوافقًا."},
            @"fa": @{@"Summary":@"خلاصه", @"Technical log":@"گزارش فنی", @"Working":@"فعال",
                     @"Waiting for feed detection":@"در انتظار شناسایی فید", @"Integration with iQFace":@"یکپارچگی با iQFace",
                     @"Icons":@"آیکون‌ها", @"Cache":@"کش", @"Utilities":@"ابزارها",
                     @"Hide suggestions in Stories":@"پنهان کردن پیشنهادها در Stories",
                     @"Feed detection pending":@"فیلترها پس از بارگذاری مدل فید سازگار توسط Facebook اعمال می‌شوند."},
            @"ckb": @{@"Summary":@"پوختە", @"Technical log":@"تۆماری تەکنیکی", @"Working":@"کاردەکات",
                      @"Waiting for feed detection":@"چاوەڕوانی دۆزینەوەی فید", @"Integration with iQFace":@"یەکگرتن لەگەڵ iQFace",
                      @"Icons":@"ئایکۆنەکان", @"Cache":@"کاش", @"Utilities":@"ئامرازەکان",
                      @"Hide suggestions in Stories":@"شاردنەوەی پێشنیارەکان لە Stories",
                      @"Feed detection pending":@"فلتەرەکان کاتێک جێبەجێ دەکرێن کە Facebook مۆدێلی فیدی گونجاو باربکات."}
        };
    });
    return all;
}

__attribute__((used, visibility("default")))
NSString *Nexus2Localized(NSString *key) {
    if (![key isKindOfClass:NSString.class]) return @"";
    NSString *code = NXLanguageCode();
    NSString *value = NXExtraTranslations()[code][key] ?: NXTranslations()[code][key];
    return value ?: key;
}

static BOOL NXBool(NSString *key, BOOL fallback) {
    id value = [NSUserDefaults.standardUserDefaults objectForKey:key];
    return value == nil ? fallback : [value boolValue];
}

static void NXSetBool(NSString *key, BOOL value) {
    [NSUserDefaults.standardUserDefaults setBool:value forKey:key];
    [NSNotificationCenter.defaultCenter postNotificationName:NXSettingsChangedNotification object:nil];
}

static NSInteger NXInteger(NSString *key, NSInteger fallback) {
    id value = [NSUserDefaults.standardUserDefaults objectForKey:key];
    return value == nil ? fallback : [value integerValue];
}

static void NXSetInteger(NSString *key, NSInteger value) {
    [NSUserDefaults.standardUserDefaults setInteger:value forKey:key];
    [NSNotificationCenter.defaultCenter postNotificationName:NXSettingsChangedNotification object:nil];
}

#pragma mark - Diagnostics

static NSMutableArray<NSString *> *NXEvents;
static BOOL NXWordmarkClassFound = NO;
static BOOL NXWordmarkSelectorFound = NO;
static BOOL NXWordmarkHookInstalled = NO;
static BOOL NXWordmarkTargetFound = NO;
static BOOL NXWordmarkRecognizerAttached = NO;
static BOOL NXLauncherButtonSeen = NO;
static BOOL NXLauncherBarItemSeen = NO;
static BOOL NXLauncherCurrentlyHidden = NO;
static BOOL NXSettingsSectionsHook = NO;
static BOOL NXFeedClassFound = NO;
static BOOL NXFeedTreeABICompatible = NO;
static BOOL NXFeedPandoABICompatible = NO;
static BOOL NXFeedTreeHookInstalled = NO;
static BOOL NXFeedPandoHookInstalled = NO;
static NSInteger NXWordmarkAttempts = 0;
static NSInteger NXFeedHookAttempts = 0;
static NSTimer *NXFeedDetectionTimer = nil;

static void NXEvent(NSString *event) {
    if (!event.length) return;
    if (!NXEvents) NXEvents = [NSMutableArray array];
    NSString *line = [NSString stringWithFormat:@"%.3f %@", NSDate.timeIntervalSinceReferenceDate, event];
    [NXEvents addObject:line];
    if (NXEvents.count > 120) [NXEvents removeObjectAtIndex:0];
}

static NSString *NXStatus(BOOL value) { return value ? @"OK" : @"NO"; }

static void NXAppendViewTree(UIView *view, NSUInteger depth, NSMutableString *out, NSUInteger *count) {
    if (!view || depth > 16 || *count >= 240) return;
    (*count)++;
    [out appendFormat:@"%*s%@ %.0fx%.0f hidden=%d alpha=%.2f\n",
     (int)(depth * 2), "", NSStringFromClass(view.class),
     fabs(view.bounds.size.width), fabs(view.bounds.size.height), view.hidden, view.alpha];
    for (UIView *child in view.subviews) NXAppendViewTree(child, depth + 1, out, count);
}

static NSString *NXCapturedUI = nil;

__attribute__((used, visibility("default")))
void Nexus2CaptureUI(void) {
    NSMutableString *out = [NSMutableString stringWithString:@"\n--- UI TREE ---\n"];
    NSUInteger count = 0;
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        NXAppendViewTree(window, 0, out, &count);
        if (count >= 240) break;
    }
    NXCapturedUI = [out copy];
    NXEvent([NSString stringWithFormat:@"UI captured (%lu views)", (unsigned long)count]);
}

static BOOL NXSettingsSymbolAvailable(void) {
    return NXFindSymbol("IQFPresentSettings") != NULL;
}

__attribute__((used, visibility("default")))
BOOL Nexus2LogoActivationAvailable(void) {
    return NXWordmarkClassFound && NXWordmarkSelectorFound &&
           NXWordmarkHookInstalled && NXWordmarkTargetFound &&
           NXWordmarkRecognizerAttached && NXSettingsSymbolAvailable();
}

__attribute__((used, visibility("default")))
NSString *Nexus2DiagnosticsText(void) {
    NSString *fbVersion = NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"?";
    NSString *fbBuild = NSBundle.mainBundle.infoDictionary[@"CFBundleVersion"] ?: @"?";
    BOOL languageBridge = NXFindSymbol("IQFResolvedLanguage") != NULL;
    BOOL iconPicker = NSClassFromString(@"IQFIconsPickerController") != Nil;
    NSMutableString *report = [NSMutableString string];
    [report appendFormat:@"Nexus 2.0 Beta 2\nFacebook %@ (%@)\niOS %@\niQFace language: %@\nIQFResolvedLanguage: %@\n\n",
     fbVersion, fbBuild, UIDevice.currentDevice.systemVersion ?: @"?", NXLanguageCode(),
     NXStatus(languageBridge)];
    [report appendFormat:@"[Activation / Facebook Logo]\nFBNavigationBar: %@\nlayoutSubviews: %@\nhook installed: %@\nwordmark target found: %@\nrecognizer attached: %@\nIQFPresentSettings: %@\niQFace button seen: %@\niQFace bar item seen: %@\nlauncher hidden: %@\nmode: %@\n\n",
     NXStatus(NXWordmarkClassFound), NXStatus(NXWordmarkSelectorFound),
     NXStatus(NXWordmarkHookInstalled), NXStatus(NXWordmarkTargetFound),
     NXStatus(NXWordmarkRecognizerAttached), NXStatus(NXSettingsSymbolAvailable()),
     NXStatus(NXLauncherButtonSeen), NXStatus(NXLauncherBarItemSeen),
     NXStatus(NXLauncherCurrentlyHidden),
     [NSUserDefaults.standardUserDefaults stringForKey:NXKeyActivation] ?: @"iqface"];
    [report appendFormat:@"[Settings integration]\nIQFTweakSettings: %@\nsections hook: %@\nicon picker: %@\n\n",
     NXStatus(NSClassFromString(@"IQFTweakSettings") != Nil),
     NXStatus(NXSettingsSectionsHook), NXStatus(iconPicker)];
    [report appendFormat:@"[Feed filters]\nmodule loaded: %@\nFBMemModelObject: %@\ninitWithFBTree ABI: %@ hook: %@\ninitWithFBPandoTree ABI: %@ hook: %@\nThreads=%d Pages=%d StoryPYMK=%d\nkeys: feedUnitType/feed_unit_type/inlineUnitType/unitType\n\n",
     NXStatus(NXSettingsSectionsHook), NXStatus(NXFeedClassFound), NXStatus(NXFeedTreeABICompatible), NXStatus(NXFeedTreeHookInstalled),
     NXStatus(NXFeedPandoABICompatible), NXStatus(NXFeedPandoHookInstalled),
     NXBool(NXKeyThreads, NO), NXBool(NXKeyPages, NO), NXBool(NXKeyStoryPeople, NO)];
    [report appendFormat:@"[Appearance]\nbackground hook: %@\nmode=%ld color=%@\navatar hooks: %@\n\n",
     NXStatus(Nexus2BackgroundHookInstalled()), (long)Nexus2BackgroundCurrentMode(),
     [NSUserDefaults.standardUserDefaults stringForKey:NXKeyBackgroundColor] ?: @"#000000FF",
     NXStatus(Nexus2AvatarHooksInstalled())];
    [report appendString:@"[Events]\n"];
    for (NSString *event in NXEvents ?: @[]) [report appendFormat:@"%@\n", event];
    if (NXCapturedUI.length) [report appendString:NXCapturedUI];
    return report;
}

#pragma mark - Facebook logo activation

static const void *NXWordmarkRecognizerKey = &NXWordmarkRecognizerKey;
static IMP NXWordmarkOriginalLayoutSubviews = NULL;
static NSTimer *NXActivationTimer = nil;
static void NXAttachWordmark(UIView *navigationBar);
static void NXRefreshActivationMode(void);

static BOOL NXLogoModeSelected(void) {
    return [[NSUserDefaults.standardUserDefaults stringForKey:NXKeyActivation] isEqualToString:@"facebookLogo"];
}

static void NXOpenSettings(void) {
    NXPresentSettingsFunction present =
        (NXPresentSettingsFunction)NXFindSymbol("IQFPresentSettings");
    if (present) present();
}

@interface Nexus2WordmarkTarget : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)shared;
- (void)tap:(UITapGestureRecognizer *)recognizer;
@end

@implementation Nexus2WordmarkTarget
+ (instancetype)shared {
    static id value;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ value = [self new]; });
    return value;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)a shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)b {
    (void)a; (void)b; return YES;
}
- (void)tap:(UITapGestureRecognizer *)recognizer {
    if (recognizer.state == UIGestureRecognizerStateEnded &&
        NXLogoModeSelected() && Nexus2LogoActivationAvailable()) {
        NXOpenSettings();
    }
}
@end

static BOOL NXLooksLikeWordmarkContainer(UIView *view, UIView *navigationBar) {
    if (!view || !navigationBar || view == navigationBar) return NO;
    if (![NSStringFromClass(view.class) isEqualToString:@"UIView"]) return NO;
    if (view.hidden || view.alpha < 0.01 || !view.userInteractionEnabled) return NO;
    CGRect rect = [view convertRect:view.bounds toView:navigationBar];
    CGFloat h = CGRectGetHeight(navigationBar.bounds);
    return rect.origin.x >= 28.0 && rect.origin.x <= 64.0 &&
           fabs(rect.origin.y) <= 3.0 &&
           rect.size.width >= 95.0 && rect.size.width <= 180.0 &&
           rect.size.height >= h * 0.82 && rect.size.height <= h * 1.18;
}

static UIView *NXFindWordmark(UIView *root, UIView *navigationBar) {
    UIView *best = nil;
    for (UIView *child in root.subviews) {
        UIView *nested = NXFindWordmark(child, navigationBar);
        if (nested) best = nested;
        if (NXLooksLikeWordmarkContainer(child, navigationBar)) best = child;
    }
    return best;
}

static void NXProbeWordmarkInView(UIView *view) {
    if (!view) return;
    if ([NSStringFromClass(view.class) isEqualToString:@"FBNavigationBar"]) {
        NXAttachWordmark(view);
    }
    for (UIView *child in view.subviews.copy) NXProbeWordmarkInView(child);
}

static void NXProbeVisibleWordmarks(void) {
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        NXProbeWordmarkInView(window);
    }
}

static void NXEnsureActivationTimer(void) {
    if (NXActivationTimer || !NXLogoModeSelected()) return;
    NXActivationTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(__unused NSTimer *timer) {
        NXRefreshActivationMode();
    }];
}

static const void *NXLauncherViewStateKey = &NXLauncherViewStateKey;
static const void *NXLauncherBarItemsKey = &NXLauncherBarItemsKey;

static void NXAttachWordmark(UIView *navigationBar) {
    UIView *target = NXFindWordmark(navigationBar, navigationBar);
    if (!target) return;
    NXWordmarkTargetFound = YES;
    UITapGestureRecognizer *existing = objc_getAssociatedObject(target, NXWordmarkRecognizerKey);
    if (existing != nil) {
        NXWordmarkRecognizerAttached = [target.gestureRecognizers containsObject:existing];
        return;
    }
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
        initWithTarget:Nexus2WordmarkTarget.shared action:@selector(tap:)];
    tap.cancelsTouchesInView = NO;
    tap.delaysTouchesBegan = NO;
    tap.delaysTouchesEnded = NO;
    tap.delegate = Nexus2WordmarkTarget.shared;
    [target addGestureRecognizer:tap];
    objc_setAssociatedObject(target, NXWordmarkRecognizerKey, tap, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NXWordmarkRecognizerAttached = [target.gestureRecognizers containsObject:tap];
    if (NXWordmarkRecognizerAttached) NXEvent(@"Facebook logo recognizer attached");
}

static void NXNavigationLayoutSubviews(id self, SEL command) {
    if (NXWordmarkOriginalLayoutSubviews)
        ((void (*)(id, SEL))NXWordmarkOriginalLayoutSubviews)(self, command);
    if ([self isKindOfClass:UIView.class]) NXAttachWordmark((UIView *)self);
}

static BOOL NXIsIQFaceButton(UIView *view) {
    if (![view isKindOfClass:UIButton.class]) return NO;
    UIButton *button = (UIButton *)view;
    if (![button.accessibilityLabel isEqualToString:@"iQFace"]) return NO;
    for (id target in button.allTargets) {
        NSArray *actions = [button actionsForTarget:target forControlEvent:UIControlEventTouchUpInside];
        if ([actions containsObject:@"iqf_tapped"]) return YES;
    }
    return NO;
}

static BOOL NXIsIQFaceBarButtonItem(UIBarButtonItem *item) {
    if (![item isKindOfClass:UIBarButtonItem.class]) return NO;
    SEL action = item.action;
    return action != NULL && [NSStringFromSelector(action) isEqualToString:@"iqf_tapped"];
}

static void NXApplyLauncherVisibility(UIView *view, BOOL hide) {
    if (!view) return;
    if (NXIsIQFaceButton(view)) {
        NXLauncherButtonSeen = YES;
        NSDictionary *state = objc_getAssociatedObject(view, NXLauncherViewStateKey);
        if (hide) {
            if (!state) {
                state = @{@"hidden": @(view.hidden), @"alpha": @(view.alpha),
                          @"interaction": @(view.userInteractionEnabled)};
                objc_setAssociatedObject(view, NXLauncherViewStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            view.hidden = YES;
            view.alpha = 0.0;
            view.userInteractionEnabled = NO;
        } else if (state) {
            view.hidden = [state[@"hidden"] boolValue];
            view.alpha = [state[@"alpha"] doubleValue];
            view.userInteractionEnabled = [state[@"interaction"] boolValue];
            objc_setAssociatedObject(view, NXLauncherViewStateKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    for (UIView *child in view.subviews.copy) NXApplyLauncherVisibility(child, hide);
}

static void NXApplyNavigationItemVisibility(UINavigationItem *item, BOOL hide) {
    if (!item) return;
    NSArray<UIBarButtonItem *> *stored = objc_getAssociatedObject(item, NXLauncherBarItemsKey);
    if (!hide) {
        if (stored) {
            item.leftBarButtonItems = stored;
            objc_setAssociatedObject(item, NXLauncherBarItemsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return;
    }

    NSArray<UIBarButtonItem *> *items = item.leftBarButtonItems ?: @[];
    NSMutableArray<UIBarButtonItem *> *filtered = [NSMutableArray arrayWithCapacity:items.count];
    BOOL found = NO;
    for (UIBarButtonItem *candidate in items) {
        if (NXIsIQFaceBarButtonItem(candidate)) {
            found = YES;
            NXLauncherBarItemSeen = YES;
        } else {
            [filtered addObject:candidate];
        }
    }
    if (!found && NXIsIQFaceBarButtonItem(item.leftBarButtonItem)) {
        found = YES;
        NXLauncherBarItemSeen = YES;
        items = @[item.leftBarButtonItem];
        [filtered removeAllObjects];
    }
    if (found) {
        if (!stored) objc_setAssociatedObject(item, NXLauncherBarItemsKey, [items copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        item.leftBarButtonItems = [filtered copy];
    }
}

static void NXApplyControllerLauncherVisibility(UIViewController *controller, BOOL hide) {
    if (!controller) return;
    NXApplyNavigationItemVisibility(controller.navigationItem, hide);
    for (UIViewController *child in controller.childViewControllers.copy)
        NXApplyControllerLauncherVisibility(child, hide);
    if (controller.presentedViewController)
        NXApplyControllerLauncherVisibility(controller.presentedViewController, hide);
}

static void NXRefreshActivationMode(void) {
    if (!NXLogoModeSelected() && NXActivationTimer) {
        [NXActivationTimer invalidate];
        NXActivationTimer = nil;
    }
    BOOL hardUnavailable = NXWordmarkAttempts >= 40 &&
        (!NXWordmarkClassFound || !NXWordmarkSelectorFound ||
         !NXWordmarkHookInstalled || !NXSettingsSymbolAvailable());
    if (NXLogoModeSelected() && hardUnavailable) {
        [NSUserDefaults.standardUserDefaults setObject:@"iqface" forKey:NXKeyActivation];
        NXEvent(@"Logo activation unavailable; fell back to iQFace icon");
    }
    BOOL hide = NXLogoModeSelected() && Nexus2LogoActivationAvailable();
    NXLauncherCurrentlyHidden = hide;
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        NXApplyLauncherVisibility(window, hide);
        NXApplyControllerLauncherVisibility(window.rootViewController, hide);
    }
}

static BOOL NXVoidNoArgMethodCompatible(Method method) {
    if (!method || method_getNumberOfArguments(method) != 2) return NO;
    char ret[8] = {0};
    method_getReturnType(method, ret, sizeof(ret));
    return ret[0] == 'v';
}

static void NXTryInstallWordmarkHook(void) {
    NXWordmarkAttempts++;
    Class cls = NSClassFromString(@"FBNavigationBar");
    NXWordmarkClassFound = cls != Nil;
    Method method = cls ? class_getInstanceMethod(cls, @selector(layoutSubviews)) : NULL;
    NXWordmarkSelectorFound = NXVoidNoArgMethodCompatible(method);
    if (NXWordmarkSelectorFound && !NXWordmarkHookInstalled) {
        IMP current = method_getImplementation(method);
        if (current == (IMP)&NXNavigationLayoutSubviews) {
            NXWordmarkHookInstalled = YES;
        } else {
            NXWordmarkOriginalLayoutSubviews =
                method_setImplementation(method, (IMP)&NXNavigationLayoutSubviews);
            NXWordmarkHookInstalled = NXWordmarkOriginalLayoutSubviews != NULL;
        }
        if (NXWordmarkHookInstalled) NXEvent(@"Facebook logo activation hook installed");
    }
    if (!NXWordmarkHookInstalled && NXWordmarkAttempts < 40) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ NXTryInstallWordmarkHook(); });
    }
    if (NXWordmarkHookInstalled) NXProbeVisibleWordmarks();
    NXRefreshActivationMode();
    NXEnsureActivationTimer();
}

#pragma mark - Feed filters

static id (*NXOrigTree)(id, SEL, id) = NULL;
static id (*NXOrigPando)(id, SEL, id) = NULL;

static NSString *NXModelTokens(id object) {
    if (!object) return @"";
    NSMutableArray<NSString *> *values = [NSMutableArray array];
    [values addObject:NSStringFromClass([object class]) ?: @""];
    NSArray *keys = @[@"category", @"storyBucketType", @"identifier", @"trackingName",
                      @"name", @"type", @"feedStoryCategory", @"renderType",
                      @"feedUnitType", @"feed_unit_type", @"inlineUnitType", @"unitType"];
    for (NSString *key in keys) {
        @try {
            id value = [object valueForKey:key];
            if ([value isKindOfClass:NSString.class]) [values addObject:value];
            else if ([value isKindOfClass:NSNumber.class]) [values addObject:[value stringValue]];
        } @catch (__unused NSException *e) {}
    }
    return [[values componentsJoinedByString:@"|"] lowercaseString];
}

static BOOL NXShouldDropModel(id object) {
    NSString *tokens = NXModelTokens(object);
    if (NXBool(NXKeyThreads, NO) &&
        ([tokens containsString:@"threads_in_feed_unit"] ||
         [tokens containsString:@"threads_in_story_unit_mid_card"])) return YES;
    if (NXBool(NXKeyPages, NO) &&
        ([tokens containsString:@"pagesyoumaylike"] ||
         [tokens containsString:@"fbmempagesyoumaylikefeedunit"])) return YES;
    if (NXBool(NXKeyStoryPeople, NO) && [tokens containsString:@"pymk_story"]) return YES;
    return NO;
}

static id NXInitTree(id self, SEL command, id tree) {
    id value = NXOrigTree ? NXOrigTree(self, command, tree) : nil;
    if (NXShouldDropModel(value)) return nil;
    return value;
}

static id NXInitPando(id self, SEL command, id tree) {
    id value = NXOrigPando ? NXOrigPando(self, command, tree) : nil;
    if (NXShouldDropModel(value)) return nil;
    return value;
}

static BOOL NXObjectUnaryMethodCompatible(Method method) {
    if (!method || method_getNumberOfArguments(method) != 3) return NO;
    char ret[16] = {0};
    char arg[16] = {0};
    method_getReturnType(method, ret, sizeof(ret));
    method_getArgumentType(method, 2, arg, sizeof(arg));
    return ret[0] == '@' && arg[0] == '@';
}

static void NXRefreshFeedCapability(void) {
    Class cls = NSClassFromString(@"FBMemModelObject");
    NXFeedClassFound = cls != Nil;
    Method tree = cls ? class_getInstanceMethod(cls, NSSelectorFromString(@"initWithFBTree:")) : NULL;
    Method pando = cls ? class_getInstanceMethod(cls, NSSelectorFromString(@"initWithFBPandoTree:")) : NULL;
    NXFeedTreeABICompatible = NXObjectUnaryMethodCompatible(tree);
    NXFeedPandoABICompatible = NXObjectUnaryMethodCompatible(pando);
}

static void NXTryInstallFeedHooks(void) {
    NXFeedHookAttempts++;
    NXRefreshFeedCapability();
    Class cls = NSClassFromString(@"FBMemModelObject");
    if (cls) {
        Method tree = class_getInstanceMethod(cls, NSSelectorFromString(@"initWithFBTree:"));
        if (NXFeedTreeABICompatible && !NXFeedTreeHookInstalled) {
            IMP current = method_getImplementation(tree);
            if (current == (IMP)&NXInitTree) NXFeedTreeHookInstalled = YES;
            else {
                NXOrigTree = (id (*)(id, SEL, id))method_setImplementation(tree, (IMP)&NXInitTree);
                NXFeedTreeHookInstalled = NXOrigTree != NULL;
            }
            if (NXFeedTreeHookInstalled) NXEvent(@"Feed FBTree hook installed");
        }
        Method pando = class_getInstanceMethod(cls, NSSelectorFromString(@"initWithFBPandoTree:"));
        if (NXFeedPandoABICompatible && !NXFeedPandoHookInstalled) {
            IMP current = method_getImplementation(pando);
            if (current == (IMP)&NXInitPando) NXFeedPandoHookInstalled = YES;
            else {
                NXOrigPando = (id (*)(id, SEL, id))method_setImplementation(pando, (IMP)&NXInitPando);
                NXFeedPandoHookInstalled = NXOrigPando != NULL;
            }
            if (NXFeedPandoHookInstalled) NXEvent(@"Feed FBPandoTree hook installed");
        }
    }
    BOOL needsTree = NXFeedTreeABICompatible && !NXFeedTreeHookInstalled;
    BOOL needsPando = NXFeedPandoABICompatible && !NXFeedPandoHookInstalled;
    if ((needsTree || needsPando) && NXFeedHookAttempts < 40) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ NXTryInstallFeedHooks(); });
    }
}

static BOOL NXAnyFeedFilterEnabled(void) {
    return NXBool(NXKeyThreads, NO) || NXBool(NXKeyPages, NO) || NXBool(NXKeyStoryPeople, NO);
}

static void NXStopFeedDetectionTimer(void) {
    if (!NXFeedDetectionTimer) return;
    [NXFeedDetectionTimer invalidate];
    NXFeedDetectionTimer = nil;
}

static void NXFeedDetectionPass(void) {
    if (!NXAnyFeedFilterEnabled()) {
        NXStopFeedDetectionTimer();
        return;
    }
    NXRefreshFeedCapability();
    if (NXFeedTreeABICompatible || NXFeedPandoABICompatible) NXTryInstallFeedHooks();
    if (NXFeedTreeHookInstalled || NXFeedPandoHookInstalled) NXStopFeedDetectionTimer();
}

static void NXEnsureFeedDetectionTimer(void) {
    if (!NXAnyFeedFilterEnabled()) {
        NXStopFeedDetectionTimer();
        return;
    }
    NXFeedDetectionPass();
    if (NXFeedTreeHookInstalled || NXFeedPandoHookInstalled || NXFeedDetectionTimer) return;
    NXFeedDetectionTimer = [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(__unused NSTimer *timer) {
        NXFeedDetectionPass();
    }];
    NXFeedDetectionTimer.tolerance = 0.25;
}

#pragma mark - UI helpers

static id NXNavigationSetting(NSString *title, NSString *subtitle, NSString *icon, UIViewController *controller) {
    Class cls = NSClassFromString(@"IQFSetting");
    SEL sel = NSSelectorFromString(@"navigationCellWithTitle:subtitle:icon:viewController:");
    if (!cls || ![cls respondsToSelector:sel] || !controller) return nil;
    typedef id (*Factory)(id, SEL, id, id, id, id);
    return ((Factory)(void *)objc_msgSend)(cls, sel, title, subtitle, icon, controller);
}

static id NXStaticSetting(NSString *title, NSString *subtitle, NSString *icon) {
    Class cls = NSClassFromString(@"IQFSetting");
    SEL sel = NSSelectorFromString(@"staticCellWithTitle:subtitle:icon:");
    if (!cls || ![cls respondsToSelector:sel]) return nil;
    typedef id (*Factory)(id, SEL, id, id, id);
    return ((Factory)(void *)objc_msgSend)(cls, sel, title, subtitle, icon);
}

static void NXShowMessage(UIViewController *controller, NSString *title, NSString *message) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [controller presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Appearance controller

@interface Nexus2AppearanceController : UITableViewController <UIColorPickerViewControllerDelegate>
@end

@implementation Nexus2AppearanceController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = Nexus2Localized(@"Background appearance");
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { (void)tableView; return 3; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    return section == 0 ? 3 : 1;
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    return section == 0 ? Nexus2Localized(@"Dark mode required") : nil;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"NXAppearance"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"NXAppearance"];
    NSInteger mode = NXInteger(NXKeyBackgroundMode, 1);
    if (indexPath.section == 0) {
        NSArray *titles = @[Nexus2Localized(@"Standard"), Nexus2Localized(@"OLED"), Nexus2Localized(@"Custom color")];
        cell.textLabel.text = titles[(NSUInteger)indexPath.row];
        cell.accessoryType = mode == indexPath.row ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        cell.imageView.image = [UIImage systemImageNamed:indexPath.row == 0 ? @"circle" : (indexPath.row == 1 ? @"circle.fill" : @"paintpalette")];
    } else if (indexPath.section == 1) {
        cell.textLabel.text = Nexus2Localized(@"Background color");
        cell.detailTextLabel.text = [NSUserDefaults.standardUserDefaults stringForKey:NXKeyBackgroundColor] ?: @"#000000FF";
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = mode == 2 ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
        cell.textLabel.enabled = mode == 2;
    } else {
        cell.textLabel.text = Nexus2Localized(@"Feed separators");
        cell.detailTextLabel.text = nil;
        UISwitch *toggle = [UISwitch new];
        toggle.on = NXBool(@"iQFaceOLEDFeedSeparatorsEnabled", NO);
        [toggle addTarget:self action:@selector(nx_separatorsChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    return cell;
}
- (void)nx_separatorsChanged:(UISwitch *)sender {
    NXSetBool(@"iQFaceOLEDFeedSeparatorsEnabled", sender.isOn);
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0) {
        NXSetInteger(NXKeyBackgroundMode, indexPath.row);
        [tableView reloadData];
        return;
    }
    if (indexPath.section == 2) return;
    if (NXInteger(NXKeyBackgroundMode, 1) != 2) return;
    UIColorPickerViewController *picker = [UIColorPickerViewController new];
    picker.delegate = self;
    picker.supportsAlpha = NO;
    picker.selectedColor = [self nx_colorFromStored];
    [self presentViewController:picker animated:YES completion:nil];
}
- (UIColor *)nx_colorFromStored {
    NSString *hex = [NSUserDefaults.standardUserDefaults stringForKey:NXKeyBackgroundColor] ?: @"#000000FF";
    unsigned value = 0;
    NSScanner *scanner = [NSScanner scannerWithString:[hex stringByReplacingOccurrencesOfString:@"#" withString:@""]];
    [scanner scanHexInt:&value];
    if (hex.length <= 7) value = (value << 8) | 0xFF;
    return [UIColor colorWithRed:((value >> 24)&0xFF)/255.0 green:((value >> 16)&0xFF)/255.0 blue:((value >> 8)&0xFF)/255.0 alpha:1.0];
}
- (void)colorPickerViewControllerDidFinish:(UIColorPickerViewController *)viewController {
    UIColor *color = viewController.selectedColor;
    CGFloat r=0,g=0,b=0,a=1;
    [color getRed:&r green:&g blue:&b alpha:&a];
    NSString *hex = [NSString stringWithFormat:@"#%02X%02X%02XFF",
                     (int)llround(r*255), (int)llround(g*255), (int)llround(b*255)];
    [NSUserDefaults.standardUserDefaults setObject:hex forKey:NXKeyBackgroundColor];
    [NSNotificationCenter.defaultCenter postNotificationName:NXSettingsChangedNotification object:nil];
    CGFloat luminance = 0.2126*r + 0.7152*g + 0.0722*b;
    [self.tableView reloadData];
    if (luminance > 0.68) NXShowMessage(self, Nexus2Localized(@"Custom color"), Nexus2Localized(@"Light color warning"));
}
@end

#pragma mark - Feed controller

@interface Nexus2FeedController : UITableViewController
@end
@implementation Nexus2FeedController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = Nexus2Localized(@"Feed filters");
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    NXRefreshFeedCapability();
    if (NXAnyFeedFilterEnabled()) NXEnsureFeedDetectionTimer();
    [self.tableView reloadData];
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; (void)section; return 3;
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView; (void)section;
    if ((NXFeedTreeHookInstalled || NXFeedPandoHookInstalled) || !NXAnyFeedFilterEnabled()) return nil;
    return Nexus2Localized(@"Feed detection pending");
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"NXFeed"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"NXFeed"];
    NSArray *titles = @[Nexus2Localized(@"Hide Threads promotion"),
                        Nexus2Localized(@"Hide suggested pages"),
                        Nexus2Localized(@"Hide suggestions in Stories")];
    NSArray *keys = @[NXKeyThreads, NXKeyPages, NXKeyStoryPeople];
    cell.textLabel.text = titles[(NSUInteger)indexPath.row];
    cell.textLabel.adjustsFontSizeToFitWidth = YES;
    cell.textLabel.minimumScaleFactor = 0.82;
    UISwitch *sw = [UISwitch new];
    sw.tag = indexPath.row;
    sw.on = NXBool(keys[(NSUInteger)indexPath.row], NO);
    [sw addTarget:self action:@selector(nx_switch:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = sw;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}
- (void)nx_switch:(UISwitch *)sender {
    NSArray *keys = @[NXKeyThreads, NXKeyPages, NXKeyStoryPeople];
    if (sender.tag < 0 || sender.tag >= (NSInteger)keys.count) return;
    NXSetBool(keys[(NSUInteger)sender.tag], sender.isOn);
    if (sender.isOn) {
        NXEnsureFeedDetectionTimer();
    } else if (!NXAnyFeedFilterEnabled()) {
        NXStopFeedDetectionTimer();
    }
    [self.tableView reloadData];
}
@end

#pragma mark - Activation controller

@interface Nexus2ActivationController : UITableViewController
@end
@implementation Nexus2ActivationController
- (void)viewDidLoad { [super viewDidLoad]; self.title = Nexus2Localized(@"Activation"); self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped]; }
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    NXTryInstallWordmarkHook();
    [self.tableView reloadData];
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { (void)tableView;(void)section; return 2; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"NXActivation"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"NXActivation"];
    BOOL logo = NXLogoModeSelected();
    if (indexPath.row == 0) {
        cell.textLabel.text = Nexus2Localized(@"iQFace icon");
        cell.detailTextLabel.text = Nexus2Localized(@"Activation icon subtitle");
        cell.accessoryType = !logo ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        cell.textLabel.enabled = YES;
    } else {
        BOOL available = Nexus2LogoActivationAvailable();
        cell.textLabel.text = Nexus2Localized(@"Facebook logo");
        cell.detailTextLabel.text = available ? Nexus2Localized(@"Activation logo subtitle") : Nexus2Localized(@"Unavailable on this Facebook version");
        cell.accessoryType = logo ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        cell.textLabel.enabled = available; cell.detailTextLabel.enabled = available;
    }
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row == 1) {
        NXTryInstallWordmarkHook();
        NXProbeVisibleWordmarks();
        if (!Nexus2LogoActivationAvailable()) return;
    }
    [NSUserDefaults.standardUserDefaults setObject:(indexPath.row == 1 ? @"facebookLogo" : @"iqface") forKey:NXKeyActivation];
    NXEvent(indexPath.row == 1 ? @"Activation mode changed to Facebook logo" : @"Activation mode changed to iQFace icon");
    NXRefreshActivationMode();
    if (indexPath.row == 1) NXEnsureActivationTimer();
    [tableView reloadData];
}
@end

#pragma mark - Settings manager

static BOOL NXAllowedPreferenceKey(NSString *key) {
    return [key hasPrefix:@"_IQFKey"] || [key hasPrefix:@"IQF"] ||
           [key hasPrefix:@"iQFace"] || [key hasPrefix:@"Nexus"] ||
           [key hasPrefix:@"com.lucas.iqface"];
}

@interface Nexus2SettingsManagerController : UITableViewController <UIDocumentPickerDelegate>
@end
@implementation Nexus2SettingsManagerController
- (void)viewDidLoad { [super viewDidLoad]; self.title = Nexus2Localized(@"Backup and restore"); self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped]; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { (void)tableView;(void)section; return 3; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"NXManager"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"NXManager"];
    NSArray *titles = @[Nexus2Localized(@"Export settings"), Nexus2Localized(@"Import settings"), Nexus2Localized(@"Reset settings")];
    NSArray *icons = @[@"square.and.arrow.up", @"square.and.arrow.down", @"arrow.counterclockwise"];
    cell.textLabel.text = titles[(NSUInteger)indexPath.row]; cell.imageView.image = [UIImage systemImageNamed:icons[(NSUInteger)indexPath.row]];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}
- (NSDictionary *)nx_exportedSettings {
    NSDictionary *all = NSUserDefaults.standardUserDefaults.dictionaryRepresentation;
    NSMutableDictionary *settings = [NSMutableDictionary dictionary];
    [all enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
        (void)stop;
        if (!NXAllowedPreferenceKey(key)) return;
        if ([NSJSONSerialization isValidJSONObject:@[value]]) settings[key] = value;
    }];
    return @{@"format": @"nexus-settings",
             @"schemaVersion": @1,
             @"nexusVersion": @"2.0 Beta 2",
             @"facebookVersion": NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"?",
             @"createdAt": @([[NSDate date] timeIntervalSince1970]),
             @"settings": settings};
}
- (void)nx_export {
    NSDictionary *payload = [self nx_exportedSettings];
    NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:NSJSONWritingPrettyPrinted error:nil];
    if (!data) return;
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"Nexus-Settings.json"];
    [data writeToFile:path atomically:YES];
    UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:path]] applicationActivities:nil];
    [self presentViewController:activity animated:YES completion:nil];
}
- (void)nx_import {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.json"] inMode:UIDocumentPickerModeImport];
#pragma clang diagnostic pop
    picker.delegate = self; [self presentViewController:picker animated:YES completion:nil];
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    (void)controller;
    NSURL *url = urls.firstObject; if (!url) return;
    NSData *data = [NSData dataWithContentsOfURL:url];
    NSDictionary *root = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSString *format = [root isKindOfClass:NSDictionary.class] && [root[@"format"] isKindOfClass:NSString.class] ? root[@"format"] : nil;
    NSNumber *schema = [root isKindOfClass:NSDictionary.class] && [root[@"schemaVersion"] isKindOfClass:NSNumber.class] ? root[@"schemaVersion"] : nil;
    NSDictionary *settings = [root isKindOfClass:NSDictionary.class] ? root[@"settings"] : nil;
    BOOL validFormat = format == nil || [format isEqualToString:@"nexus-settings"];
    BOOL validSchema = schema != nil && schema.integerValue == 1;
    if (!validFormat || !validSchema || ![settings isKindOfClass:NSDictionary.class]) {
        NXShowMessage(self, Nexus2Localized(@"Settings manager"), Nexus2Localized(@"Invalid backup"));
        return;
    }
    [settings enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
        (void)stop; if (NXAllowedPreferenceKey(key)) [NSUserDefaults.standardUserDefaults setObject:value forKey:key];
    }];
    [NSUserDefaults.standardUserDefaults synchronize];
    [NSNotificationCenter.defaultCenter postNotificationName:NXSettingsChangedNotification object:nil];
    NXEvent(@"Settings imported");
    NXShowMessage(self, Nexus2Localized(@"Settings manager"), Nexus2Localized(@"Import completed"));
}
- (void)nx_reset {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:Nexus2Localized(@"Reset all settings?") message:Nexus2Localized(@"Reset warning") preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:Nexus2Localized(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:Nexus2Localized(@"Reset") style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *a) {
        NSArray *keys = NSUserDefaults.standardUserDefaults.dictionaryRepresentation.allKeys.copy;
        for (NSString *key in keys) if (NXAllowedPreferenceKey(key)) [NSUserDefaults.standardUserDefaults removeObjectForKey:key];
        [NSUserDefaults.standardUserDefaults synchronize];
        NXEvent(@"Nexus/iQFace settings reset");
        [NSNotificationCenter.defaultCenter postNotificationName:NXSettingsChangedNotification object:nil];
        NXRefreshActivationMode();
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row == 0) [self nx_export];
    else if (indexPath.row == 1) [self nx_import];
    else [self nx_reset];
}
@end

#pragma mark - Diagnostics controller

@interface Nexus2DiagnosticsController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property(nonatomic,strong) UISegmentedControl *segment;
@property(nonatomic,strong) UITableView *summaryTable;
@property(nonatomic,strong) UITextView *textView;
@end

@implementation Nexus2DiagnosticsController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = Nexus2Localized(@"Diagnostics");
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    self.segment = [[UISegmentedControl alloc] initWithItems:@[Nexus2Localized(@"Summary"), Nexus2Localized(@"Technical log")]];
    self.segment.selectedSegmentIndex = 0;
    [self.segment addTarget:self action:@selector(nx_segmentChanged:) forControlEvents:UIControlEventValueChanged];
    self.segment.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.segment];

    self.summaryTable = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.summaryTable.translatesAutoresizingMaskIntoConstraints = NO;
    self.summaryTable.dataSource = self;
    self.summaryTable.delegate = self;
    [self.view addSubview:self.summaryTable];

    self.textView = [UITextView new];
    self.textView.translatesAutoresizingMaskIntoConstraints = NO;
    self.textView.editable = NO;
    self.textView.hidden = YES;
    self.textView.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    [self.view addSubview:self.textView];

    [NSLayoutConstraint activateConstraints:@[
        [self.segment.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:10],
        [self.segment.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [self.segment.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
        [self.summaryTable.topAnchor constraintEqualToAnchor:self.segment.bottomAnchor constant:8],
        [self.summaryTable.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.summaryTable.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.summaryTable.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.textView.topAnchor constraintEqualToAnchor:self.segment.bottomAnchor constant:8],
        [self.textView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [self.textView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [self.textView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-8]
    ]];

    [self nx_updateButtons];
    [self nx_refresh];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    NXTryInstallWordmarkHook();
    NXRefreshFeedCapability();
    [self nx_refresh];
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; (void)section; return 6;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"NXDiagSummary"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"NXDiagSummary"];

    BOOL languageOK = NXFindSymbol("IQFResolvedLanguage") != NULL;
    BOOL activationOK = NXSettingsSymbolAvailable();
    BOOL integrationOK = NXSettingsSectionsHook && languageOK;
    BOOL appearanceOK = Nexus2BackgroundHookInstalled() && Nexus2AvatarHooksInstalled();
    BOOL feedModuleLoaded = NXSettingsSectionsHook && NSClassFromString(@"Nexus2FeedController") != Nil;
    BOOL feedOK = feedModuleLoaded;
    BOOL iconOK = NSClassFromString(@"IQFIconsPickerController") != Nil;

    NSArray *titles = @[
        Nexus2Localized(@"Activation"),
        Nexus2Localized(@"Integration with iQFace"),
        [NSString stringWithFormat:@"%@ / OLED", Nexus2Localized(@"Appearance")],
        Nexus2Localized(@"Feed filters"),
        Nexus2Localized(@"Icons"),
        Nexus2Localized(@"Cache")
    ];
    NSArray *oks = @[@(activationOK), @(integrationOK), @(appearanceOK), @(feedOK), @(iconOK), @YES];

    BOOL ok = [oks[(NSUInteger)indexPath.row] boolValue];
    NSString *emoji = ok ? @"🟢" : @"🔴";
    cell.textLabel.text = [NSString stringWithFormat:@"%@ %@", emoji, titles[(NSUInteger)indexPath.row]];
    if (indexPath.row == 3) {
        cell.detailTextLabel.text = ok ? Nexus2Localized(@"Loaded") : Nexus2Localized(@"Unavailable on this Facebook version");
    } else {
        cell.detailTextLabel.text = ok ? Nexus2Localized(@"Working") : Nexus2Localized(@"Unavailable on this Facebook version");
    }
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.accessoryType = UITableViewCellAccessoryNone;
    return cell;
}
- (void)nx_segmentChanged:(UISegmentedControl *)sender {
    BOOL technical = sender.selectedSegmentIndex == 1;
    self.summaryTable.hidden = technical;
    self.textView.hidden = !technical;
    [self nx_updateButtons];
    [self nx_refresh];
}
- (void)nx_updateButtons {
    BOOL technical = self.segment.selectedSegmentIndex == 1;
    UIBarButtonItem *refresh = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(nx_refresh)];
    if (technical) {
        UIBarButtonItem *copy = [[UIBarButtonItem alloc] initWithTitle:Nexus2Localized(@"Copy diagnostics") style:UIBarButtonItemStylePlain target:self action:@selector(nx_copy)];
        self.navigationItem.rightBarButtonItems = @[refresh, copy];
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:Nexus2Localized(@"Capture UI") style:UIBarButtonItemStylePlain target:self action:@selector(nx_capture)];
    } else {
        self.navigationItem.rightBarButtonItems = @[refresh];
        self.navigationItem.leftBarButtonItem = nil;
    }
}
- (void)nx_refresh {
    NXRefreshFeedCapability();
    self.textView.text = Nexus2DiagnosticsText();
    [self.summaryTable reloadData];
}
- (void)nx_capture { Nexus2CaptureUI(); [self nx_refresh]; }
- (void)nx_copy {
    UIPasteboard.generalPasteboard.string = Nexus2DiagnosticsText();
    NXShowMessage(self, Nexus2Localized(@"Diagnostics"), Nexus2Localized(@"Copied"));
}
@end

#pragma mark - Nexus utilities / tools

extern id NexusCacheCreateManualSetting(void);
extern id NexusCacheCreateAutomaticSetting(void);

static NSString *const NXCacheAutoFrequencyKey = @"iQFaceCacheAutoFrequency";

static NSInteger NXCacheAutomaticFrequency(void) {
    Class prefs = NSClassFromString(@"IQFPrefs");
    SEL selector = NSSelectorFromString(@"integerForKey:defaultValue:");
    if (prefs && [prefs respondsToSelector:selector]) {
        typedef NSInteger (*Getter)(id, SEL, id, NSInteger);
        NSInteger value = ((Getter)(void *)objc_msgSend)(prefs, selector, NXCacheAutoFrequencyKey, 0);
        return MAX(0, MIN(3, value));
    }
    NSInteger value = [NSUserDefaults.standardUserDefaults integerForKey:NXCacheAutoFrequencyKey];
    return MAX(0, MIN(3, value));
}

static void NXSetCacheAutomaticFrequency(NSInteger value) {
    value = MAX(0, MIN(3, value));
    Class prefs = NSClassFromString(@"IQFPrefs");
    SEL selector = NSSelectorFromString(@"setInteger:forKey:");
    if (prefs && [prefs respondsToSelector:selector]) {
        typedef void (*Setter)(id, SEL, NSInteger, id);
        ((Setter)(void *)objc_msgSend)(prefs, selector, value, NXCacheAutoFrequencyKey);
    } else {
        [NSUserDefaults.standardUserDefaults setInteger:value forKey:NXCacheAutoFrequencyKey];
        [NSUserDefaults.standardUserDefaults synchronize];
    }
    NXEvent([NSString stringWithFormat:@"Automatic cache frequency changed to %ld", (long)value]);
}

static NSArray<NSString *> *NXCacheFrequencyLabels(void) {
    return @[
        Nexus2Localized(@"Disabled"),
        Nexus2Localized(@"Daily"),
        Nexus2Localized(@"Weekly"),
        Nexus2Localized(@"Monthly")
    ];
}

@interface Nexus2UtilitiesController : UITableViewController
@end

@implementation Nexus2UtilitiesController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = Nexus2Localized(@"Utilities");
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 58.0;
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; (void)section; return 3;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"NXUtilitiesBeta2"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"NXUtilitiesBeta2"];

    cell.imageView.image = nil;
    cell.accessoryView = nil;
    cell.detailTextLabel.text = nil;
    cell.textLabel.numberOfLines = 2;
    cell.textLabel.lineBreakMode = NSLineBreakByWordWrapping;
    cell.detailTextLabel.numberOfLines = 1;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

    if (indexPath.row == 0) {
        cell.textLabel.text = Nexus2Localized(@"Change Icon");
    } else if (indexPath.row == 1) {
        cell.textLabel.text = Nexus2Localized(@"Clear cache");
    } else {
        cell.textLabel.text = Nexus2Localized(@"Automatic cache clearing");
        NSInteger value = NXCacheAutomaticFrequency();
        NSArray<NSString *> *labels = NXCacheFrequencyLabels();
        cell.detailTextLabel.text = labels[(NSUInteger)value];
    }
    return cell;
}
- (void)nx_runCacheSetting:(id)setting {
    if (!setting) return;
    id action = nil;
    @try { action = [setting valueForKey:@"action"]; } @catch (__unused NSException *e) {}
    if (action) {
        void (^block)(void) = action;
        block();
    }
}
- (void)nx_chooseCacheFrequency {
    NSInteger current = NXCacheAutomaticFrequency();
    NSArray<NSString *> *labels = NXCacheFrequencyLabels();

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:Nexus2Localized(@"Automatic cache clearing")
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSInteger i = 0; i < (NSInteger)labels.count; i++) {
        NSString *title = labels[(NSUInteger)i];
        if (i == current) title = [NSString stringWithFormat:@"✓ %@", title];
        NSInteger selectedValue = i;
        [alert addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
            NXSetCacheAutomaticFrequency(selectedValue);
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:2 inSection:0]]
                                      withRowAnimation:UITableViewRowAnimationNone];
            });
        }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:Nexus2Localized(@"Cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    if (alert.popoverPresentationController) {
        alert.popoverPresentationController.sourceView = self.view;
        alert.popoverPresentationController.sourceRect = self.view.bounds;
    }
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row == 0) {
        Class pickerClass = NSClassFromString(@"IQFIconsPickerController");
        UIViewController *picker = pickerClass ? [pickerClass new] : nil;
        if (picker) [self.navigationController pushViewController:picker animated:YES];
    } else if (indexPath.row == 1) {
        [self nx_runCacheSetting:NexusCacheCreateManualSetting()];
    } else {
        [self nx_chooseCacheFrequency];
    }
}
@end

@interface Nexus2ToolsController : UITableViewController
@end

@implementation Nexus2ToolsController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = Nexus2Localized(@"Tools");
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; (void)section; return 2;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"NXTools"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"NXTools"];
    cell.imageView.image = nil;
    cell.textLabel.text = indexPath.row == 0 ? Nexus2Localized(@"Backup and restore") : Nexus2Localized(@"Diagnostics");
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    UIViewController *controller = indexPath.row == 0 ? [Nexus2SettingsManagerController new] : [Nexus2DiagnosticsController new];
    [self.navigationController pushViewController:controller animated:YES];
}
@end

#pragma mark - Settings integration

extern id NexusIconsCreateSetting(void);
extern id NexusCacheCreateManualSetting(void);
extern id NexusCacheCreateAutomaticSetting(void);

static NSString *NXSettingTitle(id setting) {
    if (!setting) return nil;
    @try {
        id value = [setting valueForKey:@"title"];
        return [value isKindOfClass:NSString.class] ? value : nil;
    } @catch (__unused NSException *e) {
        return nil;
    }
}

static id NXCreateLocalizedIconSetting(void) {
    Class settingClass = NSClassFromString(@"IQFSetting");
    Class pickerClass = NSClassFromString(@"IQFIconsPickerController");
    SEL selector = NSSelectorFromString(@"navigationCellWithTitle:subtitle:icon:viewController:");
    if (!settingClass || !pickerClass || ![settingClass respondsToSelector:selector]) return nil;
    typedef id (*Factory)(id, SEL, id, id, id, id);
    return ((Factory)(void *)objc_msgSend)(settingClass, selector, Nexus2Localized(@"Change Icon"), nil, @"app", [pickerClass new]);
}

static id NXCreateSeparatorSetting(void) {
    Class settingClass = NSClassFromString(@"IQFSetting");
    SEL selector = NSSelectorFromString(@"switchCellWithTitle:subtitle:defaultsKey:defaultOn:");
    if (!settingClass || ![settingClass respondsToSelector:selector]) return nil;
    typedef id (*Factory)(id, SEL, id, id, id, BOOL);
    return ((Factory)(void *)objc_msgSend)(settingClass, selector, Nexus2Localized(@"Feed separators"), nil, @"iQFaceOLEDFeedSeparatorsEnabled", NO);
}

static id NXCreateDeveloperCredit(void) {
    Class settingClass = NSClassFromString(@"IQFSetting");
    SEL selector = NSSelectorFromString(@"buttonCellWithTitle:subtitle:icon:action:");
    if (!settingClass || ![settingClass respondsToSelector:selector]) return nil;
    void (^action)(void) = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            NSURL *url = [NSURL URLWithString:@"https://t.me/lucaspedrosa"];
            if (url) [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
        });
    };
    typedef id (*Factory)(id, SEL, id, id, id, id);
    return ((Factory)(void *)objc_msgSend)(settingClass, selector,
        @"Lucas", Nexus2Localized(@"Nexus developer"), @"paperplane.fill", [action copy]);
}

static id NXCreateVersionSetting(void) {
    return NXStaticSetting(@"Nexus", @"2.0 Beta 2", @"point.3.connected.trianglepath.dotted");
}

static BOOL NXHeaderContainsAny(NSString *header, NSArray<NSString *> *tokens) {
    if (![header isKindOfClass:NSString.class]) return NO;
    NSString *value = header.lowercaseString;
    for (NSString *token in tokens) if ([value containsString:token]) return YES;
    return NO;
}

static BOOL NXIsDevHeader(NSString *header) {
    return NXHeaderContainsAny(header, @[@"developer", @"dev", @"desenvolvedor", @"développeur", @"разработ",
                                         @"开发", @"nhà phát triển", @"المطور", @"مطو", @"توسعه", @"گەشەپێدەر"]);
}

static BOOL NXIsAboutHeader(NSString *header) {
    return NXHeaderContainsAny(header, @[@"about", @"sobre", @"à propos", @"о программе", @"关于",
                                         @"giới thiệu", @"حول", @"درباره", @"دەربارە"]);
}

static NSArray *NXCoreRows(void) {
    NSMutableArray *rows = [NSMutableArray array];
    NSArray *controllers = @[
        @[Nexus2Localized(@"Appearance"), @"paintpalette", [Nexus2AppearanceController new]],
        @[Nexus2Localized(@"Feed filters"), @"line.3.horizontal.decrease.circle", [Nexus2FeedController new]],
        @[Nexus2Localized(@"Activation method"), @"hand.tap", [Nexus2ActivationController new]],
        @[Nexus2Localized(@"Utilities"), @"wrench.and.screwdriver", [Nexus2UtilitiesController new]],
        @[Nexus2Localized(@"Tools"), @"hammer", [Nexus2ToolsController new]]
    ];
    for (NSArray *entry in controllers) {
        id row = NXNavigationSetting(entry[0], nil, entry[1], entry[2]);
        if (row) [rows addObject:row];
    }
    return [rows copy];
}

static NSArray *NXUtilityRows(void) { return @[]; }

static UIColor *NXIconColorForTitle(NSString *title, NSString **symbolOut) {
    if (!title.length) return nil;
    if ([title isEqualToString:Nexus2Localized(@"Appearance")]) { if(symbolOut)*symbolOut=@"paintpalette.fill"; return UIColor.systemPurpleColor; }
    if ([title isEqualToString:Nexus2Localized(@"Feed filters")]) { if(symbolOut)*symbolOut=@"line.3.horizontal.decrease.circle.fill"; return UIColor.systemCyanColor; }
    if ([title isEqualToString:Nexus2Localized(@"Activation method")]) { if(symbolOut)*symbolOut=@"hand.tap.fill"; return UIColor.systemOrangeColor; }
    if ([title isEqualToString:Nexus2Localized(@"Utilities")]) { if(symbolOut)*symbolOut=@"wrench.and.screwdriver.fill"; return UIColor.systemBlueColor; }
    if ([title isEqualToString:Nexus2Localized(@"Tools")]) { if(symbolOut)*symbolOut=@"hammer.fill"; return UIColor.systemGreenColor; }
    if ([title isEqualToString:@"Lucas"]) { if(symbolOut)*symbolOut=@"paperplane.fill"; return UIColor.systemBlueColor; }
    if ([title isEqualToString:@"Nexus"]) { if(symbolOut)*symbolOut=@"point.3.connected.trianglepath.dotted"; return UIColor.systemIndigoColor; }
    return nil;
}

static UIImage *NXColoredIcon(NSString *symbolName, UIColor *background) {
    if (!symbolName.length || !background) return nil;
    CGSize size = CGSizeMake(34.0, 34.0);
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGRect bounds = (CGRect){CGPointZero, size};
        [background setFill];
        [[UIBezierPath bezierPathWithRoundedRect:bounds cornerRadius:8.0] fill];

        UIImageSymbolConfiguration *configuration =
            [UIImageSymbolConfiguration configurationWithPointSize:16.0 weight:UIImageSymbolWeightSemibold];
        UIImage *symbol = [UIImage systemImageNamed:symbolName withConfiguration:configuration];
        symbol = [symbol imageWithTintColor:UIColor.whiteColor renderingMode:UIImageRenderingModeAlwaysOriginal];
        CGSize symbolSize = symbol.size;
        CGFloat scale = MIN(20.0 / MAX(symbolSize.width, 1.0), 20.0 / MAX(symbolSize.height, 1.0));
        CGSize drawSize = CGSizeMake(symbolSize.width * scale, symbolSize.height * scale);
        CGRect drawRect = CGRectMake((size.width-drawSize.width)/2.0, (size.height-drawSize.height)/2.0,
                                     drawSize.width, drawSize.height);
        [symbol drawInRect:drawRect];
        (void)context;
    }];
}

static UITableViewCell *(*NXOrigSettingsCell)(id, SEL, UITableView *, NSIndexPath *) = NULL;
static BOOL NXSettingsCellStyleHookInstalled = NO;

static UIImageView *NXFindLeadingIconView(UIView *root, UITableViewCell *cell) {
    if (!root) return nil;
    UIImageView *best = nil;
    for (UIView *child in root.subviews) {
        if ([child isKindOfClass:UIImageView.class]) {
            CGRect rect = [child convertRect:child.bounds toView:cell.contentView];
            CGFloat w = CGRectGetWidth(rect), h = CGRectGetHeight(rect);
            if (rect.origin.x < 90.0 && w >= 24.0 && w <= 55.0 && h >= 24.0 && h <= 55.0) {
                best = (UIImageView *)child;
                break;
            }
        }
        UIImageView *nested = NXFindLeadingIconView(child, cell);
        if (nested) { best = nested; break; }
    }
    return best;
}

static void NXApplyColoredIconToCell(UITableViewCell *cell, NSString *title) {
    NSString *symbol = nil;
    UIColor *color = NXIconColorForTitle(title, &symbol);
    if (!color || !symbol.length) return;
    UIImage *image = NXColoredIcon(symbol, color);
    if (!image) return;

    [cell layoutIfNeeded];
    UIImageView *target = NXFindLeadingIconView(cell.contentView, cell);
    if (!target) target = cell.imageView;
    target.image = image;
    target.tintColor = UIColor.clearColor;
    target.contentMode = UIViewContentModeScaleAspectFit;
}

static UITableViewCell *NXStyledSettingsCell(id self, SEL command, UITableView *tableView, NSIndexPath *indexPath) {
    UITableViewCell *cell = NXOrigSettingsCell ? NXOrigSettingsCell(self, command, tableView, indexPath) : nil;
    if (!cell) return cell;

    NSString *title = cell.textLabel.text;
    SEL settingSelector = NSSelectorFromString(@"settingForIndexPath:");
    if ([self respondsToSelector:settingSelector]) {
        typedef id (*Getter)(id, SEL, id);
        id setting = ((Getter)(void *)objc_msgSend)(self, settingSelector, indexPath);
        NSString *settingTitle = NXSettingTitle(setting);
        if (settingTitle.length) title = settingTitle;
    }

    NXApplyColoredIconToCell(cell, title);
    dispatch_async(dispatch_get_main_queue(), ^{
        NXApplyColoredIconToCell(cell, title);
    });
    return cell;
}

static void NXTryInstallSettingsCellStyleHook(void) {
    if (NXSettingsCellStyleHookInstalled) return;
    Class cls = NSClassFromString(@"IQFSettingsViewController");
    SEL selector = NSSelectorFromString(@"tableView:cellForRowAtIndexPath:");
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    if (!method) return;
    IMP current = method_getImplementation(method);
    if (current == (IMP)&NXStyledSettingsCell) {
        NXSettingsCellStyleHookInstalled = YES;
        return;
    }
    NXOrigSettingsCell = (UITableViewCell *(*)(id, SEL, UITableView *, NSIndexPath *))
        method_setImplementation(method, (IMP)&NXStyledSettingsCell);
    NXSettingsCellStyleHookInstalled = NXOrigSettingsCell != NULL;
}

static void NXRemoveOwnedRowsFromSection(NSMutableDictionary *section) {
    NSArray *rows = [section[@"rows"] isKindOfClass:NSArray.class] ? section[@"rows"] : @[];
    NSMutableArray *filtered = [NSMutableArray array];
    for (id row in rows) {
        NSString *title = NXSettingTitle(row);
        if ([title isEqualToString:@"Lucas"] || [title isEqualToString:@"Nexus"] ||
            [title hasPrefix:@"Nexus 2.0 Beta 1"]) continue;
        [filtered addObject:row];
    }
    section[@"rows"] = [filtered copy];
}

static NSArray *(*NXOrigTweakSections)(id, SEL) = NULL;
static NSInteger NXSettingsHookAttempts = 0;

static NSArray *NXTweakSections(id self, SEL command) {
    NSArray *sections = NXOrigTweakSections ? NXOrigTweakSections(self, command) : nil;
    if (![sections isKindOfClass:NSArray.class]) return sections;

    NSMutableArray *result = [NSMutableArray array];
    for (id raw in sections) {
        if (![raw isKindOfClass:NSDictionary.class]) { [result addObject:raw]; continue; }
        NSMutableDictionary *section = [raw mutableCopy];
        NSString *header = [section[@"header"] isKindOfClass:NSString.class] ? section[@"header"] : nil;
        NSString *lower = header.lowercaseString ?: @"";
        if ([lower containsString:@"nexus"]) continue;
        NXRemoveOwnedRowsFromSection(section);
        [result addObject:[section copy]];
    }

    NSInteger devIndex = NSNotFound;
    NSInteger aboutIndex = NSNotFound;
    for (NSUInteger i=0;i<result.count;i++) {
        id raw = result[i];
        if (![raw isKindOfClass:NSDictionary.class]) continue;
        NSString *header = [raw[@"header"] isKindOfClass:NSString.class] ? raw[@"header"] : nil;
        if (devIndex == NSNotFound && NXIsDevHeader(header)) devIndex = (NSInteger)i;
        if (aboutIndex == NSNotFound && NXIsAboutHeader(header)) aboutIndex = (NSInteger)i;
    }

    NSUInteger insertIndex = devIndex != NSNotFound ? (NSUInteger)devIndex :
        (aboutIndex != NSNotFound ? (NSUInteger)aboutIndex : result.count);
    NSDictionary *nexusSection = @{@"header": @"Nexus", @"rows": NXCoreRows()};
    [result insertObject:nexusSection atIndex:MIN(insertIndex, result.count)];

    // Re-find Dev/About after inserting the two Nexus sections.
    devIndex = NSNotFound; aboutIndex = NSNotFound;
    for (NSUInteger i=0;i<result.count;i++) {
        id raw = result[i];
        if (![raw isKindOfClass:NSDictionary.class]) continue;
        NSString *header = [raw[@"header"] isKindOfClass:NSString.class] ? raw[@"header"] : nil;
        if (devIndex == NSNotFound && NXIsDevHeader(header)) devIndex = (NSInteger)i;
        if (aboutIndex == NSNotFound && NXIsAboutHeader(header)) aboutIndex = (NSInteger)i;
    }

    if (devIndex != NSNotFound) {
        NSMutableDictionary *dev = [result[(NSUInteger)devIndex] mutableCopy];
        NSMutableArray *rows = [[dev[@"rows"] isKindOfClass:NSArray.class] ? dev[@"rows"] : @[] mutableCopy];
        id credit = NXCreateDeveloperCredit();
        if (credit) {
            NSUInteger idx = rows.count;
            for (NSUInteger i=0;i<rows.count;i++) {
                if ([[NXSettingTitle(rows[i]) lowercaseString] isEqualToString:@"7md"]) { idx = i + 1; break; }
            }
            [rows insertObject:credit atIndex:MIN(idx, rows.count)];
        }
        dev[@"rows"] = [rows copy];
        result[(NSUInteger)devIndex] = [dev copy];
    }

    if (aboutIndex != NSNotFound) {
        NSMutableDictionary *about = [result[(NSUInteger)aboutIndex] mutableCopy];
        NSMutableArray *rows = [[about[@"rows"] isKindOfClass:NSArray.class] ? about[@"rows"] : @[] mutableCopy];
        id version = NXCreateVersionSetting();
        if (version) {
            NSUInteger idx = rows.count;
            for (NSUInteger i=0;i<rows.count;i++) {
                if ([[NXSettingTitle(rows[i]) lowercaseString] isEqualToString:@"iqface"]) { idx = i + 1; break; }
            }
            [rows insertObject:version atIndex:MIN(idx, rows.count)];
        }
        about[@"rows"] = [rows copy];
        result[(NSUInteger)aboutIndex] = [about copy];
    }

    NXTryInstallSettingsCellStyleHook();
    return [result copy];
}

static void NXTryInstallSettingsHooks(void) {
    if (NXSettingsSectionsHook) return;
    NXSettingsHookAttempts++;

    Class target = NSClassFromString(@"IQFTweakSettings");
    SEL selector = NSSelectorFromString(@"sections");
    Method method = target != Nil ? class_getClassMethod(target, selector) : NULL;

    if (method != NULL) {
        IMP current = method_getImplementation(method);
        if (current == (IMP)&NXTweakSections) {
            NXSettingsSectionsHook = YES;
        } else {
            NXOrigTweakSections = (NSArray *(*)(id, SEL))method_setImplementation(method, (IMP)&NXTweakSections);
            NXSettingsSectionsHook = NXOrigTweakSections != NULL;
        }
        if (NXSettingsSectionsHook) NXEvent(@"IQFTweakSettings sections hook installed");
    }

    if (!NXSettingsSectionsHook && NXSettingsHookAttempts < 120) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ NXTryInstallSettingsHooks(); });
    }
}

__attribute__((constructor))
static void Nexus2Initialize(void) {
    @autoreleasepool {
        if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.facebook.Facebook"] ||
            [NSBundle.mainBundle.bundlePath hasSuffix:@".appex"]) return;

        NXEvents=[NSMutableArray array];
        NXEvent(@"Nexus 2.0 Beta 2 loaded");

        dispatch_async(dispatch_get_main_queue(), ^{
            NXTryInstallSettingsHooks();

            if (NXLogoModeSelected()) {
                NXEvent(@"Restoring saved Facebook logo activation immediately");
                NXTryInstallWordmarkHook();
                NXEnsureActivationTimer();
            }

            if (NXAnyFeedFilterEnabled()) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{ NXEnsureFeedDetectionTimer(); });
            }
        });
    }
}
