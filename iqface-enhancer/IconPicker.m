#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>

#pragma mark - Shared helpers

static BOOL IQFIconPickerUsesPortuguese(void) {
    NSString *language = NSLocale.preferredLanguages.firstObject.lowercaseString;
    return [language hasPrefix:@"pt"];
}

static NSString *IQFIconPickerText(NSString *portuguese, NSString *english) {
    return IQFIconPickerUsesPortuguese() ? portuguese : english;
}

static UIViewController *IQFIconPickerTopViewController(void) {
    UIWindow *window = nil;
    for (UIWindow *candidate in UIApplication.sharedApplication.windows) {
        if (candidate.isKeyWindow) {
            window = candidate;
            break;
        }
    }
    if (window == nil) {
        for (UIWindow *candidate in UIApplication.sharedApplication.windows) {
            if (!candidate.hidden && candidate.alpha > 0.0 && candidate.windowLevel == UIWindowLevelNormal) {
                window = candidate;
                break;
            }
        }
    }

    UIViewController *controller = window.rootViewController;
    BOOL keepWalking = YES;
    while (controller != nil && keepWalking) {
        keepWalking = NO;
        if (controller.presentedViewController != nil && !controller.presentedViewController.isBeingDismissed) {
            controller = controller.presentedViewController;
            keepWalking = YES;
            continue;
        }
        if ([controller isKindOfClass:UINavigationController.class]) {
            UIViewController *visible = ((UINavigationController *)controller).visibleViewController;
            if (visible != nil && visible != controller) {
                controller = visible;
                keepWalking = YES;
                continue;
            }
        }
        if ([controller isKindOfClass:UITabBarController.class]) {
            UIViewController *selected = ((UITabBarController *)controller).selectedViewController;
            if (selected != nil && selected != controller) {
                controller = selected;
                keepWalking = YES;
            }
        }
    }
    return controller;
}

static UIImage *IQFLoadImageFromIconDictionary(NSDictionary *iconDictionary) {
    NSArray<NSString *> *files = iconDictionary[@"CFBundleIconFiles"];
    if (![files isKindOfClass:NSArray.class]) {
        files = @[];
    }

    for (NSString *file in files.reverseObjectEnumerator) {
        if (![file isKindOfClass:NSString.class] || file.length == 0) {
            continue;
        }

        UIImage *image = [UIImage imageNamed:file];
        if (image != nil) {
            return image;
        }

        NSString *path = [NSBundle.mainBundle pathForResource:file ofType:nil];
        if (path == nil && file.pathExtension.length == 0) {
            path = [NSBundle.mainBundle pathForResource:file ofType:@"png"];
        }
        if (path != nil) {
            image = [UIImage imageWithContentsOfFile:path];
            if (image != nil) {
                return image;
            }
        }

        NSString *base = [file stringByReplacingOccurrencesOfString:@"@3x" withString:@""];
        base = [base stringByReplacingOccurrencesOfString:@"@2x" withString:@""];
        image = [UIImage imageNamed:base];
        if (image != nil) {
            return image;
        }
    }

    NSString *iconName = iconDictionary[@"CFBundleIconName"];
    if ([iconName isKindOfClass:NSString.class] && iconName.length > 0) {
        UIImage *image = [UIImage imageNamed:iconName];
        if (image != nil) {
            return image;
        }
    }

    if (@available(iOS 13.0, *)) {
        return [UIImage systemImageNamed:@"app.fill"];
    }
    return nil;
}

static NSString *IQFDisplayNameForIcon(NSString *logicalName) {
    if (logicalName.length == 0) {
        return IQFIconPickerText(@"Padrão", @"Default");
    }

    NSString *name = logicalName;
    NSArray<NSString *> *prefixes = @[@"AlternateAppIcon", @"AltAppIcon"];
    for (NSString *prefix in prefixes) {
        if ([name hasPrefix:prefix]) {
            name = [name substringFromIndex:prefix.length];
            break;
        }
    }

    if ([name isEqualToString:@"WorldCup"]) {
        return @"World Cup";
    }
    return name.length > 0 ? name : logicalName;
}

static NSInteger IQFIconSortRank(NSString *logicalName) {
    NSArray<NSString *> *order = @[
        @"AltAppIconChill",
        @"AltAppIconDreamy",
        @"AltAppIconFab",
        @"AltAppIconFierce",
        @"AltAppIconLovey",
        @"AltAppIconVaporwave",
        @"AltAppIconWorldCup",
        @"AlternateAppIconChill",
        @"AlternateAppIconDreamy",
        @"AlternateAppIconFab",
        @"AlternateAppIconFierce",
        @"AlternateAppIconLovey",
        @"AlternateAppIconVaporwave"
    ];
    NSUInteger index = [order indexOfObject:logicalName];
    return index == NSNotFound ? NSIntegerMax : (NSInteger)index;
}

static NSArray<NSDictionary *> *IQFAvailableIconEntries(void) {
    NSDictionary *bundleInfo = NSBundle.mainBundle.infoDictionary;
    NSDictionary *icons = bundleInfo[@"CFBundleIcons"];
    if (![icons isKindOfClass:NSDictionary.class]) {
        icons = @{};
    }

    NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
    NSDictionary *primary = icons[@"CFBundlePrimaryIcon"];
    if (![primary isKindOfClass:NSDictionary.class]) {
        primary = @{};
    }
    UIImage *primaryImage = IQFLoadImageFromIconDictionary(primary);
    [entries addObject:@{
        @"name": NSNull.null,
        @"title": IQFIconPickerText(@"Padrão", @"Default"),
        @"image": primaryImage ?: NSNull.null
    }];

    NSDictionary *alternates = icons[@"CFBundleAlternateIcons"];
    if (![alternates isKindOfClass:NSDictionary.class]) {
        alternates = @{};
    }

    NSArray<NSString *> *keys = [alternates.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *left, NSString *right) {
        NSInteger leftRank = IQFIconSortRank(left);
        NSInteger rightRank = IQFIconSortRank(right);
        if (leftRank != rightRank) {
            return leftRank < rightRank ? NSOrderedAscending : NSOrderedDescending;
        }
        return [IQFDisplayNameForIcon(left) localizedCaseInsensitiveCompare:IQFDisplayNameForIcon(right)];
    }];

    for (NSString *logicalName in keys) {
        NSDictionary *icon = alternates[logicalName];
        if (![icon isKindOfClass:NSDictionary.class]) {
            continue;
        }
        UIImage *image = IQFLoadImageFromIconDictionary(icon);
        [entries addObject:@{
            @"name": logicalName,
            @"title": IQFDisplayNameForIcon(logicalName),
            @"image": image ?: NSNull.null
        }];
    }
    return entries;
}

#pragma mark - Icon cell

@interface IQFIconPickerCell : UICollectionViewCell
@property(nonatomic, strong) UIImageView *iconView;
@property(nonatomic, strong) UILabel *titleLabel;
@property(nonatomic, strong) UIImageView *checkView;
- (void)configureWithEntry:(NSDictionary *)entry selected:(BOOL)selected;
@end

@implementation IQFIconPickerCell

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.contentView.layer.cornerRadius = 16.0;
        self.contentView.layer.masksToBounds = YES;
        if (@available(iOS 13.0, *)) {
            self.contentView.backgroundColor = UIColor.secondarySystemBackgroundColor;
        } else {
            self.contentView.backgroundColor = [UIColor colorWithWhite:0.95 alpha:1.0];
        }

        _iconView = [UIImageView new];
        _iconView.translatesAutoresizingMaskIntoConstraints = NO;
        _iconView.contentMode = UIViewContentModeScaleAspectFill;
        _iconView.layer.cornerRadius = 14.0;
        _iconView.layer.masksToBounds = YES;
        [self.contentView addSubview:_iconView];

        _titleLabel = [UILabel new];
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _titleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightMedium];
        _titleLabel.textAlignment = NSTextAlignmentCenter;
        _titleLabel.numberOfLines = 1;
        _titleLabel.adjustsFontSizeToFitWidth = YES;
        _titleLabel.minimumScaleFactor = 0.72;
        [self.contentView addSubview:_titleLabel];

        _checkView = [UIImageView new];
        _checkView.translatesAutoresizingMaskIntoConstraints = NO;
        if (@available(iOS 13.0, *)) {
            _checkView.image = [UIImage systemImageNamed:@"checkmark.circle.fill"];
            _checkView.tintColor = UIColor.systemBlueColor;
        }
        [self.contentView addSubview:_checkView];

        [NSLayoutConstraint activateConstraints:@[
            [_iconView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:12.0],
            [_iconView.centerXAnchor constraintEqualToAnchor:self.contentView.centerXAnchor],
            [_iconView.widthAnchor constraintEqualToConstant:64.0],
            [_iconView.heightAnchor constraintEqualToConstant:64.0],

            [_titleLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:6.0],
            [_titleLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-6.0],
            [_titleLabel.topAnchor constraintEqualToAnchor:_iconView.bottomAnchor constant:8.0],

            [_checkView.widthAnchor constraintEqualToConstant:22.0],
            [_checkView.heightAnchor constraintEqualToConstant:22.0],
            [_checkView.trailingAnchor constraintEqualToAnchor:_iconView.trailingAnchor constant:5.0],
            [_checkView.bottomAnchor constraintEqualToAnchor:_iconView.bottomAnchor constant:5.0]
        ]];
    }
    return self;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.iconView.image = nil;
    self.titleLabel.text = nil;
    self.checkView.hidden = YES;
}

- (void)configureWithEntry:(NSDictionary *)entry selected:(BOOL)selected {
    id image = entry[@"image"];
    self.iconView.image = [image isKindOfClass:UIImage.class] ? image : nil;
    self.titleLabel.text = entry[@"title"];
    self.checkView.hidden = !selected;
    self.contentView.layer.borderWidth = selected ? 2.0 : 0.0;
    if (@available(iOS 13.0, *)) {
        self.contentView.layer.borderColor = UIColor.systemBlueColor.CGColor;
    }
}

@end

#pragma mark - Icon picker controller

@interface IQFIconPickerController : UIViewController <UICollectionViewDataSource, UICollectionViewDelegateFlowLayout>
@property(nonatomic, strong) UICollectionView *collectionView;
@property(nonatomic, copy) NSArray<NSDictionary *> *entries;
@end

@implementation IQFIconPickerController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = IQFIconPickerText(@"Alterar ícone", @"Change Icon");
    if (@available(iOS 13.0, *)) {
        self.view.backgroundColor = UIColor.systemBackgroundColor;
    } else {
        self.view.backgroundColor = UIColor.whiteColor;
    }

    self.entries = IQFAvailableIconEntries();
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:IQFIconPickerText(@"Fechar", @"Close")
                style:UIBarButtonItemStyleDone
               target:self
               action:@selector(iqf_closeIconPicker)];

    UICollectionViewFlowLayout *layout = [UICollectionViewFlowLayout new];
    layout.minimumInteritemSpacing = 10.0;
    layout.minimumLineSpacing = 12.0;
    layout.sectionInset = UIEdgeInsetsMake(18.0, 16.0, 24.0, 16.0);

    self.collectionView = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:layout];
    self.collectionView.translatesAutoresizingMaskIntoConstraints = NO;
    self.collectionView.backgroundColor = UIColor.clearColor;
    self.collectionView.dataSource = self;
    self.collectionView.delegate = self;
    self.collectionView.alwaysBounceVertical = YES;
    [self.collectionView registerClass:IQFIconPickerCell.class forCellWithReuseIdentifier:@"IQFIconPickerCell"];
    [self.view addSubview:self.collectionView];

    [NSLayoutConstraint activateConstraints:@[
        [self.collectionView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.collectionView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.collectionView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.collectionView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];
}

- (void)iqf_closeIconPicker {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    (void)collectionView;
    (void)section;
    return (NSInteger)self.entries.count;
}

- (__kindof UICollectionViewCell *)collectionView:(UICollectionView *)collectionView
                           cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    IQFIconPickerCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"IQFIconPickerCell"
                                                                        forIndexPath:indexPath];
    NSDictionary *entry = self.entries[(NSUInteger)indexPath.item];
    id value = entry[@"name"];
    NSString *logicalName = [value isKindOfClass:NSString.class] ? value : nil;
    NSString *current = UIApplication.sharedApplication.alternateIconName;
    BOOL selected = (logicalName == nil && current == nil) || [logicalName isEqualToString:current];
    [cell configureWithEntry:entry selected:selected];
    return cell;
}

- (CGSize)collectionView:(UICollectionView *)collectionView
                  layout:(UICollectionViewLayout *)collectionViewLayout
  sizeForItemAtIndexPath:(NSIndexPath *)indexPath {
    (void)collectionViewLayout;
    (void)indexPath;
    CGFloat available = CGRectGetWidth(collectionView.bounds) - 52.0;
    CGFloat width = floor(available / 3.0);
    width = MAX(92.0, MIN(width, 118.0));
    return CGSizeMake(width, 112.0);
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    [collectionView deselectItemAtIndexPath:indexPath animated:YES];

    UIApplication *application = UIApplication.sharedApplication;
    if (!application.supportsAlternateIcons) {
        [self iqf_showError:IQFIconPickerText(@"Este iPhone não permite alterar o ícone deste aplicativo.",
                                               @"This iPhone does not allow changing this app icon.")];
        return;
    }

    NSDictionary *entry = self.entries[(NSUInteger)indexPath.item];
    id value = entry[@"name"];
    NSString *logicalName = [value isKindOfClass:NSString.class] ? value : nil;

    __weak typeof(self) weakSelf = self;
    [application setAlternateIconName:logicalName completionHandler:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (strongSelf == nil) {
                return;
            }
            if (error != nil) {
                [strongSelf iqf_showError:error.localizedDescription ?: IQFIconPickerText(@"Não foi possível alterar o ícone.",
                                                                                           @"The icon could not be changed.")];
                return;
            }
            UISelectionFeedbackGenerator *feedback = [UISelectionFeedbackGenerator new];
            [feedback selectionChanged];
            [strongSelf.collectionView reloadData];
        });
    }];
}

- (void)iqf_showError:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"iQFace"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

#pragma mark - Launcher menu

static BOOL IQFLauncherMenuVisible = NO;

static void IQFPresentOriginalSettings(void) {
    typedef void (*IQFPresentSettingsFunction)(void);
    IQFPresentSettingsFunction present = (IQFPresentSettingsFunction)dlsym(RTLD_DEFAULT, "IQFPresentSettings");
    if (present == NULL) {
        present = (IQFPresentSettingsFunction)dlsym(RTLD_DEFAULT, "_IQFPresentSettings");
    }
    if (present != NULL) {
        present();
    }
}

static void IQFPresentIconPicker(void) {
    UIViewController *presenter = IQFIconPickerTopViewController();
    if (presenter == nil) {
        return;
    }

    IQFIconPickerController *picker = [IQFIconPickerController new];
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:picker];
    navigation.modalPresentationStyle = UIModalPresentationPageSheet;
    [presenter presentViewController:navigation animated:YES completion:nil];
}

static void IQFPresentLauncherMenu(void) {
    if (IQFLauncherMenuVisible) {
        return;
    }

    UIViewController *presenter = IQFIconPickerTopViewController();
    if (presenter == nil) {
        return;
    }

    IQFLauncherMenuVisible = YES;
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"iQFace"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    [menu addAction:[UIAlertAction actionWithTitle:IQFIconPickerText(@"Ajustes do iQFace", @"iQFace Settings")
                                             style:UIAlertActionStyleDefault
                                           handler:^(__unused UIAlertAction *action) {
        IQFLauncherMenuVisible = NO;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.16 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            IQFPresentOriginalSettings();
        });
    }]];

    [menu addAction:[UIAlertAction actionWithTitle:IQFIconPickerText(@"Alterar ícone", @"Change Icon")
                                             style:UIAlertActionStyleDefault
                                           handler:^(__unused UIAlertAction *action) {
        IQFLauncherMenuVisible = NO;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.16 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            IQFPresentIconPicker();
        });
    }]];

    UIPopoverPresentationController *popover = menu.popoverPresentationController;
    if (popover != nil) {
        popover.sourceView = presenter.view;
        popover.sourceRect = CGRectMake(CGRectGetMidX(presenter.view.bounds),
                                        CGRectGetMaxY(presenter.view.bounds) - 24.0,
                                        1.0,
                                        1.0);
        popover.permittedArrowDirections = 0;
        popover.delegate = nil;
    }

    [presenter presentViewController:menu animated:YES completion:nil];
}

#pragma mark - Replace enhancer long-press action

static BOOL IQFIconPickerHookInstalled = NO;

static void IQFIconPickerHandleLongPress(id self, SEL command, UILongPressGestureRecognizer *recognizer) {
    (void)self;
    (void)command;
    if (recognizer.state != UIGestureRecognizerStateBegan) {
        return;
    }

    UIView *view = recognizer.view;
    UIWindow *window = view.window;
    if (window == nil || CGRectGetWidth(window.bounds) <= 0.0 || CGRectGetHeight(window.bounds) <= 0.0) {
        return;
    }

    CGPoint point = [recognizer locationInView:window];
    BOOL isBottomZone = point.y >= CGRectGetHeight(window.bounds) * 0.68;
    UIUserInterfaceLayoutDirection direction = [UIView userInterfaceLayoutDirectionForSemanticContentAttribute:view.semanticContentAttribute];
    BOOL isHomeZone = direction == UIUserInterfaceLayoutDirectionRightToLeft
        ? point.x >= CGRectGetWidth(window.bounds) * (1.0 - 0.26)
        : point.x <= CGRectGetWidth(window.bounds) * 0.26;

    if (!isBottomZone || !isHomeZone) {
        return;
    }

    UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [feedback prepare];
    [feedback impactOccurred];
    IQFPresentLauncherMenu();
}

static void IQFTryInstallIconPickerHook(void) {
    if (IQFIconPickerHookInstalled) {
        return;
    }

    Class target = NSClassFromString(@"IQFEnhancerGestureTarget");
    Method method = class_getInstanceMethod(target, @selector(handleLongPress:));
    if (target == Nil || method == NULL) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            IQFTryInstallIconPickerHook();
        });
        return;
    }

    method_setImplementation(method, (IMP)&IQFIconPickerHandleLongPress);
    IQFIconPickerHookInstalled = YES;
}

__attribute__((constructor))
static void IQFIconPickerInitialize(void) {
    @autoreleasepool {
        NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier;
        if (![bundleIdentifier isEqualToString:@"com.facebook.Facebook"] ||
            [NSBundle.mainBundle.bundlePath hasSuffix:@".appex"]) {
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            IQFTryInstallIconPickerHook();
        });
    }
}
