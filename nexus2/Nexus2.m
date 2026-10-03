#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

__attribute__((used, visibility("default"))) NSString * const NexusVersion = @"2.0 Beta 1";

static NSString * const NXKeyThreads = @"NexusHideThreadsPromotions";
static NSString * const NXKeyPages = @"NexusHideSuggestedPages";
static NSString * const NXKeyStoryPeople = @"NexusHideStoryPeopleSuggestions";
static NSString * const NXKeyActivation = @"NexusActivationMode";
static NSString * const NXKeyBackgroundMode = @"NexusBackgroundMode";
static NSString * const NXKeyBackgroundColor = @"NexusCustomBackgroundColor";
static NSString * const NXSettingsChangedNotification = @"NexusSettingsDidChange";

typedef NSString *(*NXResolvedLanguageFunction)(void);
typedef void (*NXPresentSettingsFunction)(void);

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
                @"Clear": @"Limpar"
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
                @"Clear": @"Vider"
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
                @"Clear": @"Очистить"
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
                @"Clear": @"清除"
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
                @"Clear": @"Xóa"
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
                @"Clear": @"مسح"
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
                @"Clear": @"پاک کردن"
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
                @"Clear": @"پاککردنەوە"
            }
        };
    });
    return all;
}

__attribute__((used, visibility("default")))
NSString *Nexus2Localized(NSString *key) {
    if (![key isKindOfClass:NSString.class]) return @"";
    NSString *code = NXLanguageCode();
    NSString *value = NXTranslations()[code][key];
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
static BOOL NXFeedClassFound = NO;
static BOOL NXFeedTreeHookInstalled = NO;
static BOOL NXFeedPandoHookInstalled = NO;
static NSInteger NXWordmarkAttempts = 0;
static NSInteger NXFeedHookAttempts = 0;

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
           NXWordmarkHookInstalled && NXSettingsSymbolAvailable();
}

__attribute__((used, visibility("default")))
NSString *Nexus2DiagnosticsText(void) {
    NSString *fbVersion = NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"?";
    NSString *fbBuild = NSBundle.mainBundle.infoDictionary[@"CFBundleVersion"] ?: @"?";
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"Nexus 2.0 Beta 1\nFacebook %@ (%@)\niOS %@\niQFace language: %@\n\n",
     fbVersion, fbBuild, UIDevice.currentDevice.systemVersion ?: @"?", NXLanguageCode()];
    [s appendFormat:@"[Activation / Facebook Logo]\nFBNavigationBar: %@\nlayoutSubviews: %@\nhook installed: %@\nIQFPresentSettings: %@\nmode: %@\n\n",
     NXStatus(NXWordmarkClassFound), NXStatus(NXWordmarkSelectorFound),
     NXStatus(NXWordmarkHookInstalled), NXStatus(NXSettingsSymbolAvailable()),
     [NSUserDefaults.standardUserDefaults stringForKey:NXKeyActivation] ?: @"iqface"];
    [s appendFormat:@"[Feed filters]\nFBMemModelObject: %@\ninitWithFBTree hook: %@\ninitWithFBPandoTree hook: %@\nThreads=%d Pages=%d StoryPYMK=%d\n\n",
     NXStatus(NXFeedClassFound), NXStatus(NXFeedTreeHookInstalled),
     NXStatus(NXFeedPandoHookInstalled), NXBool(NXKeyThreads, NO), NXBool(NXKeyPages, NO),
     NXBool(NXKeyStoryPeople, NO)];
    [s appendFormat:@"[Background]\nmode=%ld color=%@\n\n",
     (long)NXInteger(NXKeyBackgroundMode, 1),
     [NSUserDefaults.standardUserDefaults stringForKey:NXKeyBackgroundColor] ?: @"#000000FF"];
    [s appendString:@"[Events]\n"];
    for (NSString *event in NXEvents ?: @[]) [s appendFormat:@"%@\n", event];
    if (NXCapturedUI.length) [s appendString:NXCapturedUI];
    return s;
}

#pragma mark - Facebook logo activation

static const void *NXWordmarkRecognizerKey = &NXWordmarkRecognizerKey;
static IMP NXWordmarkOriginalLayoutSubviews = NULL;
static NSTimer *NXActivationTimer = nil;

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

static void NXAttachWordmark(UIView *navigationBar) {
    UIView *target = NXFindWordmark(navigationBar, navigationBar);
    if (!target || objc_getAssociatedObject(target, NXWordmarkRecognizerKey)) return;
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
        initWithTarget:Nexus2WordmarkTarget.shared action:@selector(tap:)];
    tap.cancelsTouchesInView = NO;
    tap.delegate = Nexus2WordmarkTarget.shared;
    [target addGestureRecognizer:tap];
    objc_setAssociatedObject(target, NXWordmarkRecognizerKey, tap, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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

static void NXApplyLauncherVisibility(UIView *view, BOOL hide) {
    if (!view) return;
    if (NXIsIQFaceButton(view)) {
        view.hidden = hide;
        view.alpha = hide ? 0.0 : 1.0;
        view.userInteractionEnabled = !hide;
    }
    for (UIView *child in view.subviews.copy) NXApplyLauncherVisibility(child, hide);
}

static void NXRefreshActivationMode(void) {
    BOOL available = Nexus2LogoActivationAvailable();
    if (NXLogoModeSelected() && !available && NXWordmarkAttempts >= 120) {
        [NSUserDefaults.standardUserDefaults setObject:@"iqface" forKey:NXKeyActivation];
        NXEvent(@"Logo activation unavailable; fell back to iQFace icon");
    }
    BOOL hide = NXLogoModeSelected() && available;
    for (UIWindow *window in UIApplication.sharedApplication.windows) NXApplyLauncherVisibility(window, hide);
}

static void NXTryInstallWordmarkHook(void) {
    NXWordmarkAttempts++;
    Class cls = NSClassFromString(@"FBNavigationBar");
    NXWordmarkClassFound = cls != Nil;
    Method method = cls ? class_getInstanceMethod(cls, @selector(layoutSubviews)) : NULL;
    NXWordmarkSelectorFound = method != NULL;
    if (method && !NXWordmarkHookInstalled) {
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
    if (!NXWordmarkHookInstalled && NXWordmarkAttempts < 120) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ NXTryInstallWordmarkHook(); });
    }
    NXRefreshActivationMode();
}

#pragma mark - Feed filters

static id (*NXOrigTree)(id, SEL, id) = NULL;
static id (*NXOrigPando)(id, SEL, id) = NULL;

static NSString *NXModelTokens(id object) {
    if (!object) return @"";
    NSMutableArray<NSString *> *values = [NSMutableArray array];
    [values addObject:NSStringFromClass([object class]) ?: @""];
    NSArray *keys = @[@"category", @"storyBucketType", @"identifier", @"trackingName",
                      @"name", @"type", @"feedStoryCategory", @"renderType", @"unitType"];
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

static void NXTryInstallFeedHooks(void) {
    NXFeedHookAttempts++;
    Class cls = NSClassFromString(@"FBMemModelObject");
    NXFeedClassFound = cls != Nil;
    if (cls) {
        Method tree = class_getInstanceMethod(cls, NSSelectorFromString(@"initWithFBTree:"));
        if (tree && !NXFeedTreeHookInstalled) {
            IMP current = method_getImplementation(tree);
            if (current == (IMP)&NXInitTree) NXFeedTreeHookInstalled = YES;
            else {
                NXOrigTree = (id (*)(id, SEL, id))method_setImplementation(tree, (IMP)&NXInitTree);
                NXFeedTreeHookInstalled = NXOrigTree != NULL;
            }
            if (NXFeedTreeHookInstalled) NXEvent(@"Feed FBTree hook installed");
        }
        Method pando = class_getInstanceMethod(cls, NSSelectorFromString(@"initWithFBPandoTree:"));
        if (pando && !NXFeedPandoHookInstalled) {
            IMP current = method_getImplementation(pando);
            if (current == (IMP)&NXInitPando) NXFeedPandoHookInstalled = YES;
            else {
                NXOrigPando = (id (*)(id, SEL, id))method_setImplementation(pando, (IMP)&NXInitPando);
                NXFeedPandoHookInstalled = NXOrigPando != NULL;
            }
            if (NXFeedPandoHookInstalled) NXEvent(@"Feed FBPandoTree hook installed");
        }
    }
    if ((!NXFeedTreeHookInstalled || !NXFeedPandoHookInstalled) && NXFeedHookAttempts < 120) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ NXTryInstallFeedHooks(); });
    }
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
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { (void)tableView; return 2; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { (void)tableView; return section == 0 ? 3 : 1; }
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
    } else {
        cell.textLabel.text = Nexus2Localized(@"Background color");
        cell.detailTextLabel.text = [NSUserDefaults.standardUserDefaults stringForKey:NXKeyBackgroundColor] ?: @"#000000FF";
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = mode == 2 ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
        cell.textLabel.enabled = mode == 2;
    }
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0) {
        NXSetInteger(NXKeyBackgroundMode, indexPath.row);
        [tableView reloadData];
        return;
    }
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
- (void)viewDidLoad { [super viewDidLoad]; self.title = Nexus2Localized(@"Feed filters"); self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped]; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { (void)tableView;(void)section; return 3; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"NXFeed"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"NXFeed"];
    NSArray *titles = @[Nexus2Localized(@"Hide Threads promotion"), Nexus2Localized(@"Hide suggested pages"), Nexus2Localized(@"Hide people suggestions in Stories")];
    NSArray *keys = @[NXKeyThreads, NXKeyPages, NXKeyStoryPeople];
    cell.textLabel.text = titles[(NSUInteger)indexPath.row];
    UISwitch *sw = [UISwitch new]; sw.tag = indexPath.row; sw.on = NXBool(keys[(NSUInteger)indexPath.row], NO);
    [sw addTarget:self action:@selector(nx_switch:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = sw; cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}
- (void)nx_switch:(UISwitch *)sender {
    NSArray *keys = @[NXKeyThreads, NXKeyPages, NXKeyStoryPeople];
    if (sender.tag >= 0 && sender.tag < (NSInteger)keys.count) NXSetBool(keys[(NSUInteger)sender.tag], sender.isOn);
}
@end

#pragma mark - Activation controller

@interface Nexus2ActivationController : UITableViewController
@end
@implementation Nexus2ActivationController
- (void)viewDidLoad { [super viewDidLoad]; self.title = Nexus2Localized(@"Activation"); self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped]; }
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self.tableView reloadData]; }
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
    if (indexPath.row == 1 && !Nexus2LogoActivationAvailable()) return;
    [NSUserDefaults.standardUserDefaults setObject:(indexPath.row == 1 ? @"facebookLogo" : @"iqface") forKey:NXKeyActivation];
    NXEvent(indexPath.row == 1 ? @"Activation mode changed to Facebook logo" : @"Activation mode changed to iQFace icon");
    NXRefreshActivationMode();
    [tableView reloadData];
}
@end

#pragma mark - Settings manager

static BOOL NXAllowedPreferenceKey(NSString *key) {
    return [key hasPrefix:@"IQF"] || [key hasPrefix:@"iQFace"] || [key hasPrefix:@"Nexus"] ||
           [key hasPrefix:@"com.lucas.iqface"];
}

@interface Nexus2SettingsManagerController : UITableViewController <UIDocumentPickerDelegate>
@end
@implementation Nexus2SettingsManagerController
- (void)viewDidLoad { [super viewDidLoad]; self.title = Nexus2Localized(@"Settings manager"); self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped]; }
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
    return @{@"schemaVersion": @1, @"nexusVersion": @"2.0 Beta 1",
             @"facebookVersion": NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"?",
             @"createdAt": @([[NSDate date] timeIntervalSince1970]), @"settings": settings};
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
    NSDictionary *settings = [root isKindOfClass:NSDictionary.class] ? root[@"settings"] : nil;
    if (![settings isKindOfClass:NSDictionary.class]) { NXShowMessage(self, Nexus2Localized(@"Settings manager"), Nexus2Localized(@"Invalid backup")); return; }
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

@interface Nexus2DiagnosticsController : UIViewController
@property(nonatomic,strong) UITextView *textView;
@end
@implementation Nexus2DiagnosticsController
- (void)viewDidLoad {
    [super viewDidLoad]; self.title = Nexus2Localized(@"Diagnostics"); self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.textView = [UITextView new]; self.textView.translatesAutoresizingMaskIntoConstraints = NO; self.textView.editable = NO;
    self.textView.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular]; [self.view addSubview:self.textView];
    [NSLayoutConstraint activateConstraints:@[
        [self.textView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
        [self.textView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [self.textView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [self.textView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-8]
    ]];
    UIBarButtonItem *copy = [[UIBarButtonItem alloc] initWithTitle:Nexus2Localized(@"Copy diagnostics") style:UIBarButtonItemStylePlain target:self action:@selector(nx_copy)];
    UIBarButtonItem *refresh = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(nx_refresh)];
    self.navigationItem.rightBarButtonItems = @[refresh, copy];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:Nexus2Localized(@"Capture UI") style:UIBarButtonItemStylePlain target:self action:@selector(nx_capture)];
    [self nx_refresh];
}
- (void)nx_refresh { self.textView.text = Nexus2DiagnosticsText(); }
- (void)nx_capture { Nexus2CaptureUI(); [self nx_refresh]; }
- (void)nx_copy { UIPasteboard.generalPasteboard.string = Nexus2DiagnosticsText(); NXShowMessage(self, Nexus2Localized(@"Diagnostics"), Nexus2Localized(@"Copied")); }
@end

#pragma mark - Settings integration

extern id NexusIconsCreateSetting(void);
extern id NexusCacheCreateManualSetting(void);
extern id NexusCacheCreateAutomaticSetting(void);

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

static NSArray *NXOwnedRows(void) {
    NSMutableArray *rows = [NSMutableArray array];
    NSArray *controllers = @[
        @[Nexus2Localized(@"Appearance"), @"paintpalette", [Nexus2AppearanceController new]],
        @[Nexus2Localized(@"Feed filters"), @"line.3.horizontal.decrease.circle", [Nexus2FeedController new]],
        @[Nexus2Localized(@"Activation"), @"hand.tap", [Nexus2ActivationController new]],
        @[Nexus2Localized(@"Settings manager"), @"arrow.up.arrow.down.square", [Nexus2SettingsManagerController new]],
        @[Nexus2Localized(@"Diagnostics"), @"stethoscope", [Nexus2DiagnosticsController new]]
    ];
    for (NSArray *entry in controllers) {
        id row = NXNavigationSetting(entry[0], nil, entry[1], entry[2]); if (row) [rows addObject:row];
    }
    id icon = NXCreateLocalizedIconSetting(); if (icon) [rows addObject:icon];
    id separators = NXCreateSeparatorSetting(); if (separators) [rows addObject:separators];
    id cache = NexusCacheCreateManualSetting(); if (cache) [rows addObject:cache];
    id autoCache = NexusCacheCreateAutomaticSetting(); if (autoCache) [rows addObject:autoCache];
    id version = NXStaticSetting(@"Nexus 2.0 Beta 1", nil, @"point.3.connected.trianglepath.dotted"); if (version) [rows addObject:version];
    return rows.copy;
}

static id (*NXOrigInitBuilder)(id, SEL, id, id) = NULL;
static id (*NXOrigInitSections)(id, SEL, id, id) = NULL;
typedef NSArray * _Nullable (^NXSectionsBuilder)(void);
static BOOL NXSettingsBuilderHook = NO;
static BOOL NXSettingsSectionsHook = NO;
static NSInteger NXSettingsHookAttempts = 0;

static BOOL NXLooksLikeIQFaceTitle(id title) {
    return [title isKindOfClass:NSString.class] && [[(NSString *)title lowercaseString] containsString:@"iqface"];
}

static NSArray *NXSectionsAddingNexus(NSArray *sections) {
    if (![sections isKindOfClass:NSArray.class]) return sections;
    NSMutableArray *result = sections.mutableCopy;
    for (NSInteger i=(NSInteger)result.count-1;i>=0;i--) {
        id raw=result[(NSUInteger)i]; if (![raw isKindOfClass:NSDictionary.class]) continue;
        NSString *header=[raw[@"header"] isKindOfClass:NSString.class] ? raw[@"header"] : nil;
        if ([[header lowercaseString] containsString:@"nexus"]) [result removeObjectAtIndex:(NSUInteger)i];
    }
    NSDictionary *section = @{@"header": @"NEXUS 2.0", @"rows": NXOwnedRows()};
    NSUInteger index=result.count;
    for(NSUInteger i=0;i<result.count;i++){
        NSString *h=[result[i][@"header"] isKindOfClass:NSString.class]?result[i][@"header"]:nil;
        NSString *l=h.lowercaseString;
        if([l containsString:@"developer"]||[l isEqualToString:@"dev"]||[l containsString:@"about"]||[l containsString:@"sobre"]){ index=i; break; }
    }
    [result insertObject:section atIndex:MIN(index,result.count)];
    return result.copy;
}

static id NXInitSections(id self, SEL cmd, id title, id sections) {
    if (!NXOrigInitSections) return nil;
    id adjusted = NXLooksLikeIQFaceTitle(title) && [sections isKindOfClass:NSArray.class] ? NXSectionsAddingNexus(sections) : sections;
    return NXOrigInitSections(self, cmd, title, adjusted);
}

static id NXInitBuilder(id self, SEL cmd, id title, id builder) {
    if (!NXOrigInitBuilder) return nil;
    if (!NXLooksLikeIQFaceTitle(title) || !builder) return NXOrigInitBuilder(self,cmd,title,builder);
    NXSectionsBuilder original=[builder copy];
    NXSectionsBuilder wrapped=[^NSArray *{ return NXSectionsAddingNexus(original ? original() : nil); } copy];
    return NXOrigInitBuilder(self,cmd,title,wrapped);
}

static void NXTryInstallSettingsHooks(void) {
    NXSettingsHookAttempts++;
    Class cls=NSClassFromString(@"IQFSettingsViewController");
    if(cls){
        Method m=class_getInstanceMethod(cls,NSSelectorFromString(@"initWithTitle:sectionsBuilder:"));
        if(m&&!NXSettingsBuilderHook){
            NXOrigInitBuilder=(id(*)(id,SEL,id,id))method_setImplementation(m,(IMP)&NXInitBuilder);
            NXSettingsBuilderHook=NXOrigInitBuilder!=NULL;
        }
        m=class_getInstanceMethod(cls,NSSelectorFromString(@"initWithTitle:sections:"));
        if(m&&!NXSettingsSectionsHook){
            NXOrigInitSections=(id(*)(id,SEL,id,id))method_setImplementation(m,(IMP)&NXInitSections);
            NXSettingsSectionsHook=NXOrigInitSections!=NULL;
        }
    }
    if(!NXSettingsBuilderHook&&!NXSettingsSectionsHook&&NXSettingsHookAttempts<120)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.25*NSEC_PER_SEC)),dispatch_get_main_queue(),^{NXTryInstallSettingsHooks();});
}

__attribute__((constructor))
static void Nexus2Initialize(void) {
    @autoreleasepool {
        if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.facebook.Facebook"] ||
            [NSBundle.mainBundle.bundlePath hasSuffix:@".appex"]) return;
        NXEvents=[NSMutableArray array];
        NXEvent(@"Nexus 2.0 Beta 1 loaded");
        dispatch_async(dispatch_get_main_queue(), ^{
            NXTryInstallSettingsHooks();
            NXTryInstallWordmarkHook();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(2.5*NSEC_PER_SEC)),dispatch_get_main_queue(),^{NXTryInstallFeedHooks();});
            NXActivationTimer=[NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(__unused NSTimer *timer){ NXRefreshActivationMode(); }];
        });
    }
}
