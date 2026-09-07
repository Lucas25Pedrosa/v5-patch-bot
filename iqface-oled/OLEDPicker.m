#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

extern BOOL IQFOLEDGetEnabled(void);
extern void IQFOLEDSetEnabledFromPicker(BOOL enabled);

@interface IQFOLEDModeCell : UICollectionViewCell
@property(nonatomic, strong) UIImageView *symbolView;
@property(nonatomic, strong) UILabel *titleLabel;
@property(nonatomic, strong) UIImageView *checkView;
- (void)applyTitle:(NSString *)title symbol:(NSString *)symbol selected:(BOOL)selected;
@end

@implementation IQFOLEDModeCell

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.contentView.layer.cornerRadius = 18.0;
        self.contentView.layer.masksToBounds = YES;
        self.contentView.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;

        _symbolView = [UIImageView new];
        _symbolView.translatesAutoresizingMaskIntoConstraints = NO;
        _symbolView.contentMode = UIViewContentModeScaleAspectFit;
        _symbolView.tintColor = UIColor.systemBlueColor;
        [self.contentView addSubview:_symbolView];

        _titleLabel = [UILabel new];
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _titleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
        _titleLabel.textAlignment = NSTextAlignmentCenter;
        _titleLabel.adjustsFontSizeToFitWidth = YES;
        _titleLabel.minimumScaleFactor = 0.8;
        [self.contentView addSubview:_titleLabel];

        _checkView = [UIImageView new];
        _checkView.translatesAutoresizingMaskIntoConstraints = NO;
        _checkView.image = [UIImage systemImageNamed:@"checkmark.circle.fill"];
        _checkView.tintColor = UIColor.systemBlueColor;
        [self.contentView addSubview:_checkView];

        [NSLayoutConstraint activateConstraints:@[
            [_symbolView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:18.0],
            [_symbolView.centerXAnchor constraintEqualToAnchor:self.contentView.centerXAnchor],
            [_symbolView.widthAnchor constraintEqualToConstant:58.0],
            [_symbolView.heightAnchor constraintEqualToConstant:58.0],
            [_titleLabel.topAnchor constraintEqualToAnchor:_symbolView.bottomAnchor constant:12.0],
            [_titleLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:8.0],
            [_titleLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-8.0],
            [_checkView.widthAnchor constraintEqualToConstant:24.0],
            [_checkView.heightAnchor constraintEqualToConstant:24.0],
            [_checkView.trailingAnchor constraintEqualToAnchor:_symbolView.trailingAnchor constant:8.0],
            [_checkView.bottomAnchor constraintEqualToAnchor:_symbolView.bottomAnchor constant:8.0]
        ]];
    }
    return self;
}

- (void)applyTitle:(NSString *)title symbol:(NSString *)symbol selected:(BOOL)selected {
    self.symbolView.image = [UIImage systemImageNamed:symbol];
    self.titleLabel.text = title;
    self.checkView.hidden = !selected;
    self.contentView.layer.borderWidth = selected ? 2.0 : 0.0;
    self.contentView.layer.borderColor = UIColor.systemBlueColor.CGColor;
}

@end

@interface IQFOLEDModePickerController : UIViewController <UICollectionViewDataSource, UICollectionViewDelegateFlowLayout>
@property(nonatomic, strong) UICollectionView *collectionView;
@property(nonatomic, copy) NSArray<NSDictionary *> *entries;
@end

@implementation IQFOLEDModePickerController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"Modo OLED";
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.entries = @[
        @{ @"enabled": @YES, @"title": @"Ativado", @"symbol": @"circle.lefthalf.filled" },
        @{ @"enabled": @NO, @"title": @"Desativado", @"symbol": @"circle" }
    ];

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:@"Fechar"
                style:UIBarButtonItemStyleDone
               target:self
               action:@selector(iqfoled_close)];

    UICollectionViewFlowLayout *layout = [UICollectionViewFlowLayout new];
    layout.minimumInteritemSpacing = 12.0;
    layout.minimumLineSpacing = 14.0;
    layout.sectionInset = UIEdgeInsetsMake(18.0, 16.0, 26.0, 16.0);

    self.collectionView = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:layout];
    self.collectionView.translatesAutoresizingMaskIntoConstraints = NO;
    self.collectionView.backgroundColor = UIColor.clearColor;
    self.collectionView.dataSource = self;
    self.collectionView.delegate = self;
    [self.collectionView registerClass:IQFOLEDModeCell.class forCellWithReuseIdentifier:@"IQFOLEDModeCell"];
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
    [self.collectionView reloadData];
}

- (void)iqfoled_close {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    (void)collectionView;
    (void)section;
    return (NSInteger)self.entries.count;
}

- (__kindof UICollectionViewCell *)collectionView:(UICollectionView *)collectionView
                            cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    IQFOLEDModeCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"IQFOLEDModeCell"
                                                                       forIndexPath:indexPath];
    NSDictionary *entry = self.entries[(NSUInteger)indexPath.item];
    BOOL enabled = [entry[@"enabled"] boolValue];
    BOOL selected = enabled == IQFOLEDGetEnabled();
    [cell applyTitle:entry[@"title"] symbol:entry[@"symbol"] selected:selected];
    return cell;
}

- (CGSize)collectionView:(UICollectionView *)collectionView
                  layout:(UICollectionViewLayout *)layout
  sizeForItemAtIndexPath:(NSIndexPath *)indexPath {
    (void)layout;
    (void)indexPath;
    CGFloat available = CGRectGetWidth(collectionView.bounds) - 44.0;
    CGFloat width = floor(available / 2.0);
    return CGSizeMake(MAX(130.0, width), 128.0);
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    [collectionView deselectItemAtIndexPath:indexPath animated:YES];

    NSDictionary *entry = self.entries[(NSUInteger)indexPath.item];
    BOOL enabled = [entry[@"enabled"] boolValue];
    IQFOLEDSetEnabledFromPicker(enabled);
    [self.collectionView reloadData];
}

@end

void IQFOLEDPresentModePickerFromViewController(UIViewController *presenter) {
    if (presenter == nil || presenter.presentedViewController != nil) {
        return;
    }

    IQFOLEDModePickerController *picker = [IQFOLEDModePickerController new];
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:picker];
    navigation.modalPresentationStyle = UIModalPresentationPageSheet;
    [presenter presentViewController:navigation animated:YES completion:nil];
}
