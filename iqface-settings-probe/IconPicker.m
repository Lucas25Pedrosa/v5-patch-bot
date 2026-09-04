#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

static NSString * const IQFSPSelectionDefaultsKey = @"com.lucas.iqface.iconpicker.selected";
static NSString * const IQFSPDefaultSelectionSentinel = @"__IQFSP_DEFAULT__";

static void IQFSPSaveSelectedName(NSString *name) {
    NSString *value = name ?: IQFSPDefaultSelectionSentinel;
    [NSUserDefaults.standardUserDefaults setObject:value forKey:IQFSPSelectionDefaultsKey];
}

static NSString *IQFSPLoadStoredSelectedName(BOOL *hasStoredValue) {
    id value = [NSUserDefaults.standardUserDefaults objectForKey:IQFSPSelectionDefaultsKey];
    BOOL valid = [value isKindOfClass:NSString.class];
    if (hasStoredValue != NULL) {
        *hasStoredValue = valid;
    }
    if (!valid || [(NSString *)value isEqualToString:IQFSPDefaultSelectionSentinel]) {
        return nil;
    }
    return (NSString *)value;
}

static BOOL IQFSPUsesPortuguese(void) {
    return [NSLocale.preferredLanguages.firstObject.lowercaseString hasPrefix:@"pt"];
}

static NSString *IQFSPText(NSString *pt, NSString *en) {
    return IQFSPUsesPortuguese() ? pt : en;
}

static NSString *IQFSPDisplayName(NSString *logicalName) {
    if (logicalName.length == 0) {
        return IQFSPText(@"Padrão", @"Default");
    }
    NSString *name = logicalName;
    for (NSString *prefix in @[@"AltAppIcon", @"AlternateAppIcon"]) {
        if ([name hasPrefix:prefix]) {
            name = [name substringFromIndex:prefix.length];
            break;
        }
    }
    if ([name isEqualToString:@"WorldCup"]) {
        return @"World Cup";
    }
    return name.length ? name : logicalName;
}

static NSInteger IQFSPRank(NSString *name) {
    NSArray<NSString *> *order = @[
        @"AltAppIconChill",
        @"AltAppIconDreamy",
        @"AltAppIconFab",
        @"AltAppIconFierce",
        @"AltAppIconLovey",
        @"AltAppIconVaporwave",
        @"AltAppIconWorldCup"
    ];
    NSUInteger index = [order indexOfObject:name];
    return index == NSNotFound ? NSIntegerMax : (NSInteger)index;
}

static UIImage *IQFSPIconImage(NSDictionary *definition) {
    NSArray *files = [definition[@"CFBundleIconFiles"] isKindOfClass:NSArray.class] ? definition[@"CFBundleIconFiles"] : @[];
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
    }
    if (@available(iOS 13.0, *)) {
        return [UIImage systemImageNamed:@"app.fill"];
    }
    return nil;
}

static NSArray<NSDictionary *> *IQFSPEntries(void) {
    NSDictionary *icons = NSBundle.mainBundle.infoDictionary[@"CFBundleIcons"];
    if (![icons isKindOfClass:NSDictionary.class]) {
        icons = @{};
    }

    NSMutableArray<NSDictionary *> *result = [NSMutableArray array];
    NSDictionary *primary = [icons[@"CFBundlePrimaryIcon"] isKindOfClass:NSDictionary.class] ? icons[@"CFBundlePrimaryIcon"] : @{};
    [result addObject:@{
        @"name": NSNull.null,
        @"title": IQFSPText(@"Padrão", @"Default"),
        @"image": IQFSPIconImage(primary) ?: NSNull.null
    }];

    NSDictionary *alternates = [icons[@"CFBundleAlternateIcons"] isKindOfClass:NSDictionary.class] ? icons[@"CFBundleAlternateIcons"] : @{};
    NSArray<NSString *> *keys = [alternates.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *left, NSString *right) {
        NSInteger l = IQFSPRank(left);
        NSInteger r = IQFSPRank(right);
        if (l != r) {
            return l < r ? NSOrderedAscending : NSOrderedDescending;
        }
        return [IQFSPDisplayName(left) localizedCaseInsensitiveCompare:IQFSPDisplayName(right)];
    }];

    for (NSString *name in keys) {
        NSDictionary *definition = alternates[name];
        if (![definition isKindOfClass:NSDictionary.class]) {
            continue;
        }
        [result addObject:@{
            @"name": name,
            @"title": IQFSPDisplayName(name),
            @"image": IQFSPIconImage(definition) ?: NSNull.null
        }];
    }
    return result;
}

@interface IQFSPIconCell : UICollectionViewCell
@property(nonatomic, strong) UIImageView *iconView;
@property(nonatomic, strong) UILabel *titleLabel;
@property(nonatomic, strong) UIImageView *checkView;
- (void)applyEntry:(NSDictionary *)entry selected:(BOOL)selected;
@end

@implementation IQFSPIconCell

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.contentView.layer.cornerRadius = 18.0;
        self.contentView.layer.masksToBounds = YES;
        self.contentView.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;

        _iconView = [UIImageView new];
        _iconView.translatesAutoresizingMaskIntoConstraints = NO;
        _iconView.contentMode = UIViewContentModeScaleAspectFill;
        _iconView.layer.cornerRadius = 16.0;
        _iconView.layer.masksToBounds = YES;
        [self.contentView addSubview:_iconView];

        _titleLabel = [UILabel new];
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _titleLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
        _titleLabel.textAlignment = NSTextAlignmentCenter;
        _titleLabel.adjustsFontSizeToFitWidth = YES;
        _titleLabel.minimumScaleFactor = 0.75;
        [self.contentView addSubview:_titleLabel];

        _checkView = [UIImageView new];
        _checkView.translatesAutoresizingMaskIntoConstraints = NO;
        if (@available(iOS 13.0, *)) {
            _checkView.image = [UIImage systemImageNamed:@"checkmark.circle.fill"];
            _checkView.tintColor = UIColor.systemBlueColor;
        }
        [self.contentView addSubview:_checkView];

        [NSLayoutConstraint activateConstraints:@[
            [_iconView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:16.0],
            [_iconView.centerXAnchor constraintEqualToAnchor:self.contentView.centerXAnchor],
            [_iconView.widthAnchor constraintEqualToConstant:72.0],
            [_iconView.heightAnchor constraintEqualToConstant:72.0],
            [_titleLabel.topAnchor constraintEqualToAnchor:_iconView.bottomAnchor constant:10.0],
            [_titleLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:8.0],
            [_titleLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-8.0],
            [_checkView.widthAnchor constraintEqualToConstant:24.0],
            [_checkView.heightAnchor constraintEqualToConstant:24.0],
            [_checkView.trailingAnchor constraintEqualToAnchor:_iconView.trailingAnchor constant:6.0],
            [_checkView.bottomAnchor constraintEqualToAnchor:_iconView.bottomAnchor constant:6.0]
        ]];
    }
    return self;
}

- (void)applyEntry:(NSDictionary *)entry selected:(BOOL)selected {
    id image = entry[@"image"];
    self.iconView.image = [image isKindOfClass:UIImage.class] ? image : nil;
    self.titleLabel.text = entry[@"title"];
    self.checkView.hidden = !selected;
    self.contentView.layer.borderWidth = selected ? 2.0 : 0.0;
    self.contentView.layer.borderColor = UIColor.systemBlueColor.CGColor;
}

@end

@interface IQFSPIconPickerController : UIViewController <UICollectionViewDataSource, UICollectionViewDelegateFlowLayout>
@property(nonatomic, strong) UICollectionView *collectionView;
@property(nonatomic, copy) NSArray<NSDictionary *> *entries;
@property(nonatomic, copy) NSString *selectedName;
@end

@implementation IQFSPIconPickerController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = IQFSPText(@"Alterar ícone", @"Change Icon");
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.entries = IQFSPEntries();

    NSString *systemName = UIApplication.sharedApplication.alternateIconName;
    BOOL hasStoredValue = NO;
    NSString *storedName = IQFSPLoadStoredSelectedName(&hasStoredValue);
    if (systemName.length > 0) {
        self.selectedName = systemName;
        IQFSPSaveSelectedName(systemName);
    } else if (hasStoredValue) {
        self.selectedName = storedName;
    } else {
        self.selectedName = nil;
    }

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:IQFSPText(@"Fechar", @"Close")
                style:UIBarButtonItemStyleDone
               target:self
               action:@selector(iqfsp_close)];

    UICollectionViewFlowLayout *layout = [UICollectionViewFlowLayout new];
    layout.minimumInteritemSpacing = 12.0;
    layout.minimumLineSpacing = 14.0;
    layout.sectionInset = UIEdgeInsetsMake(18.0, 16.0, 26.0, 16.0);

    self.collectionView = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:layout];
    self.collectionView.translatesAutoresizingMaskIntoConstraints = NO;
    self.collectionView.backgroundColor = UIColor.clearColor;
    self.collectionView.dataSource = self;
    self.collectionView.delegate = self;
    [self.collectionView registerClass:IQFSPIconCell.class forCellWithReuseIdentifier:@"IQFSPIconCell"];
    [self.view addSubview:self.collectionView];

    [NSLayoutConstraint activateConstraints:@[
        [self.collectionView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.collectionView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.collectionView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.collectionView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    NSString *systemName = UIApplication.sharedApplication.alternateIconName;
    if (systemName.length == 0) {
        return;
    }
    if ([systemName isEqualToString:self.selectedName]) {
        return;
    }
    self.selectedName = systemName;
    IQFSPSaveSelectedName(systemName);
    [self.collectionView reloadData];
}

- (void)iqfsp_close {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    (void)collectionView;
    (void)section;
    return (NSInteger)self.entries.count;
}

- (__kindof UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    IQFSPIconCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"IQFSPIconCell" forIndexPath:indexPath];
    NSDictionary *entry = self.entries[(NSUInteger)indexPath.item];
    id value = entry[@"name"];
    NSString *name = [value isKindOfClass:NSString.class] ? value : nil;
    NSString *current = self.selectedName;
    BOOL selected = (name == nil && current == nil) || [name isEqualToString:current];
    [cell applyEntry:entry selected:selected];
    return cell;
}

- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)layout sizeForItemAtIndexPath:(NSIndexPath *)indexPath {
    (void)layout;
    (void)indexPath;
    CGFloat available = CGRectGetWidth(collectionView.bounds) - 44.0;
    CGFloat width = floor(available / 2.0);
    return CGSizeMake(MAX(130.0, width), 128.0);
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    [collectionView deselectItemAtIndexPath:indexPath animated:YES];
    UIApplication *application = UIApplication.sharedApplication;
    if (!application.supportsAlternateIcons) {
        [self iqfsp_error:IQFSPText(@"O iOS não permite alterar o ícone deste aplicativo.", @"iOS does not allow changing this app icon.")];
        return;
    }

    NSDictionary *entry = self.entries[(NSUInteger)indexPath.item];
    id value = entry[@"name"];
    NSString *name = [value isKindOfClass:NSString.class] ? value : nil;

    __weak typeof(self) weakSelf = self;
    [application setAlternateIconName:name completionHandler:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (self == nil) {
                return;
            }
            if (error != nil) {
                [self iqfsp_error:error.localizedDescription ?: IQFSPText(@"Não foi possível alterar o ícone.", @"The icon could not be changed.")];
                return;
            }

            self.selectedName = name;
            IQFSPSaveSelectedName(name);
            UISelectionFeedbackGenerator *feedback = [UISelectionFeedbackGenerator new];
            [feedback selectionChanged];
            [self.collectionView reloadData];

            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.75 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (strongSelf == nil) {
                    return;
                }
                NSString *systemName = UIApplication.sharedApplication.alternateIconName;
                BOOL systemMatchesRequested = (name == nil && systemName == nil) || [systemName isEqualToString:name];
                if (systemMatchesRequested) {
                    strongSelf.selectedName = systemName;
                    IQFSPSaveSelectedName(systemName);
                    [strongSelf.collectionView reloadData];
                }
            });
        });
    }];
}

- (void)iqfsp_error:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"iQFace"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

void IQFSPPresentIconPickerFromViewController(UIViewController *presenter) {
    if (presenter == nil || presenter.presentedViewController != nil) {
        return;
    }
    IQFSPIconPickerController *picker = [IQFSPIconPickerController new];
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:picker];
    navigation.modalPresentationStyle = UIModalPresentationPageSheet;
    [presenter presentViewController:navigation animated:YES completion:nil];
}
