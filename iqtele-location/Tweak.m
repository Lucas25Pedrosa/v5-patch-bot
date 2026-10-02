#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreLocation/CoreLocation.h>
#import <MapKit/MapKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSString * const IQTLVersion = @"1.0 Beta 1";
static NSString * const IQTLEnabledKey = @"LucasIQTFakeLocationEnabled";
static NSString * const IQTLLatitudeKey = @"LucasIQTFakeLatitude";
static NSString * const IQTLLongitudeKey = @"LucasIQTFakeLongitude";
static NSString * const IQTLDidChangeNotification = @"LucasIQTFakeLocationDidChange";

static char IQTLRootSettingsKey;

#pragma mark - Preferences

static NSUserDefaults *IQTLDefaults(void) {
    return NSUserDefaults.standardUserDefaults;
}

static BOOL IQTLHasCoordinate(void) {
    NSUserDefaults *d = IQTLDefaults();
    return [d objectForKey:IQTLLatitudeKey] != nil &&
           [d objectForKey:IQTLLongitudeKey] != nil;
}

static CLLocationCoordinate2D IQTLSavedCoordinate(void) {
    NSUserDefaults *d = IQTLDefaults();
    return CLLocationCoordinate2DMake([d doubleForKey:IQTLLatitudeKey],
                                      [d doubleForKey:IQTLLongitudeKey]);
}

static BOOL IQTLCoordinateIsUsable(CLLocationCoordinate2D c) {
    return CLLocationCoordinate2DIsValid(c) &&
           c.latitude >= -90.0 && c.latitude <= 90.0 &&
           c.longitude >= -180.0 && c.longitude <= 180.0;
}

static BOOL IQTLFakeEnabled(void) {
    return [IQTLDefaults() boolForKey:IQTLEnabledKey] &&
           IQTLHasCoordinate() &&
           IQTLCoordinateIsUsable(IQTLSavedCoordinate());
}

static void IQTLSaveCoordinate(CLLocationCoordinate2D c) {
    if (!IQTLCoordinateIsUsable(c)) return;
    NSUserDefaults *d = IQTLDefaults();
    [d setDouble:c.latitude forKey:IQTLLatitudeKey];
    [d setDouble:c.longitude forKey:IQTLLongitudeKey];
    [d synchronize];
    [NSNotificationCenter.defaultCenter postNotificationName:IQTLDidChangeNotification object:nil];
}

static CLLocation *IQTLFakeLocationFrom(CLLocation *original) {
    if (!IQTLFakeEnabled()) return original;

    CLLocationCoordinate2D c = IQTLSavedCoordinate();
    CLLocationDistance altitude = original ? original.altitude : 0.0;
    CLLocationAccuracy hAcc = original ? MAX(original.horizontalAccuracy, 1.0) : 5.0;
    CLLocationAccuracy vAcc = original ? MAX(original.verticalAccuracy, 1.0) : 5.0;
    CLLocationDirection course = original ? original.course : -1.0;
    CLLocationSpeed speed = original ? original.speed : -1.0;

    return [[CLLocation alloc] initWithCoordinate:c
                                        altitude:altitude
                              horizontalAccuracy:hAcc
                                verticalAccuracy:vAcc
                                          course:course
                                           speed:speed
                                       timestamp:[NSDate date]];
}

static NSArray<CLLocation *> *IQTLFakeLocations(NSArray<CLLocation *> *locations) {
    if (!IQTLFakeEnabled()) return locations;
    CLLocation *source = locations.lastObject;
    CLLocation *fake = IQTLFakeLocationFrom(source);
    return fake ? @[fake] : locations;
}

#pragma mark - Fake location engine

@interface IQTLocationEngine : NSObject
@property (nonatomic, strong) NSHashTable<CLLocationManager *> *locationManagers;
@property (nonatomic, strong) NSTimer *lieTimer;
+ (instancetype)shared;
- (void)trackManager:(CLLocationManager *)manager;
- (void)setupTimer;
- (void)lieToDelegates;
@end

@implementation IQTLocationEngine

+ (instancetype)shared {
    static IQTLocationEngine *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [IQTLocationEngine new];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _locationManagers = [NSHashTable weakObjectsHashTable];
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(appDidBecomeActive)
                                                   name:UIApplicationDidBecomeActiveNotification
                                                 object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(appDidEnterBackground)
                                                   name:UIApplicationDidEnterBackgroundNotification
                                                 object:nil];
    }
    return self;
}

- (void)trackManager:(CLLocationManager *)manager {
    if (manager == nil) return;
    @synchronized (self) {
        [self.locationManagers addObject:manager];
    }
    [self setupTimer];
}

- (void)setupTimer {
    if (self.lieTimer != nil) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.lieTimer != nil) return;
        self.lieTimer = [NSTimer timerWithTimeInterval:1.0
                                                target:self
                                              selector:@selector(lieToDelegates)
                                              userInfo:nil
                                               repeats:YES];
        [NSRunLoop.mainRunLoop addTimer:self.lieTimer forMode:NSRunLoopCommonModes];
    });
}

- (void)lieToDelegates {
    if (!IQTLFakeEnabled()) return;

    NSArray<CLLocationManager *> *managers;
    @synchronized (self) {
        managers = self.locationManagers.allObjects;
    }

    for (CLLocationManager *manager in managers) {
        id delegate = manager.delegate;
        SEL callback = @selector(locationManager:didUpdateLocations:);
        if (delegate == nil || ![delegate respondsToSelector:callback]) continue;

        CLLocation *source = manager.location;
        CLLocation *fake = IQTLFakeLocationFrom(source);
        if (fake == nil) continue;

        void (*send)(id, SEL, CLLocationManager *, NSArray<CLLocation *> *) = (void *)objc_msgSend;
        send(delegate, callback, manager, @[fake]);
    }
}

- (void)appDidBecomeActive {
    [self setupTimer];
}

- (void)appDidEnterBackground {
    [self.lieTimer invalidate];
    self.lieTimer = nil;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

@end

#pragma mark - Runtime hooks

static BOOL IQTLHookMethod(Class cls, SEL selector, IMP replacement, IMP *originalOut) {
    if (cls == Nil) return NO;
    Method method = class_getInstanceMethod(cls, selector);
    if (method == NULL) return NO;

    const char *types = method_getTypeEncoding(method);
    IMP original = method_getImplementation(method);

    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    BOOL owns = NO;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == selector) {
            owns = YES;
            break;
        }
    }
    free(methods);

    if (owns) {
        original = method_setImplementation(method, replacement);
    } else {
        class_addMethod(cls, selector, replacement, types);
    }

    if (originalOut != NULL) *originalOut = original;
    return YES;
}

static id (*IQTLOrigCLInit)(id, SEL) = NULL;
static void (*IQTLOrigCLSetDelegate)(id, SEL, id) = NULL;
static CLLocation *(*IQTLOrigCLLocation)(id, SEL) = NULL;

static id IQTLCLInit(id self, SEL _cmd) {
    id result = IQTLOrigCLInit ? IQTLOrigCLInit(self, _cmd) : self;
    if ([result isKindOfClass:CLLocationManager.class]) {
        [[IQTLocationEngine shared] trackManager:result];
    }
    return result;
}

static void IQTLCLSetDelegate(id self, SEL _cmd, id delegate) {
    if (IQTLOrigCLSetDelegate) IQTLOrigCLSetDelegate(self, _cmd, delegate);
    if ([self isKindOfClass:CLLocationManager.class]) {
        [[IQTLocationEngine shared] trackManager:self];
    }
}

static CLLocation *IQTLCLLocation(id self, SEL _cmd) {
    CLLocation *real = IQTLOrigCLLocation ? IQTLOrigCLLocation(self, _cmd) : nil;
    return IQTLFakeLocationFrom(real);
}

static void (*IQTLOrigDeviceUpdate)(id, SEL, id, NSArray *) = NULL;
static void IQTLDeviceUpdate(id self, SEL _cmd, id manager, NSArray *locations) {
    NSArray *replacement = IQTLFakeLocations(locations);
    if (IQTLOrigDeviceUpdate) IQTLOrigDeviceUpdate(self, _cmd, manager, replacement);
}

static void (*IQTLOrigMKUpdate)(id, SEL, id, NSArray *) = NULL;
static void IQTLMKUpdate(id self, SEL _cmd, id manager, NSArray *locations) {
    NSArray *replacement = IQTLFakeLocations(locations);
    if (IQTLOrigMKUpdate) IQTLOrigMKUpdate(self, _cmd, manager, replacement);
}

#pragma mark - UI

@interface IQTLocationMapController : UIViewController <MKMapViewDelegate>
@property (nonatomic, strong) MKMapView *mapView;
@property (nonatomic, strong) MKPointAnnotation *pin;
@property (nonatomic, assign) BOOL hasSelection;
@end

@implementation IQTLocationMapController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Selecionar localização";
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemSave
                                                     target:self
                                                     action:@selector(saveLocation)];

    MKMapView *map = [[MKMapView alloc] initWithFrame:CGRectZero];
    map.translatesAutoresizingMaskIntoConstraints = NO;
    map.delegate = self;
    map.showsUserLocation = YES;
    [self.view addSubview:map];
    self.mapView = map;

    [NSLayoutConstraint activateConstraints:@[
        [map.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [map.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [map.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [map.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor]
    ]];

    UITapGestureRecognizer *tap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(mapTapped:)];
    tap.cancelsTouchesInView = NO;
    [map addGestureRecognizer:tap];

    if (IQTLHasCoordinate()) {
        CLLocationCoordinate2D c = IQTLSavedCoordinate();
        [self selectCoordinate:c animated:NO];
        MKCoordinateRegion region = MKCoordinateRegionMakeWithDistance(c, 2500.0, 2500.0);
        [map setRegion:region animated:NO];
    }
}

- (void)mapTapped:(UITapGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateEnded) return;
    CGPoint point = [gesture locationInView:self.mapView];
    CLLocationCoordinate2D c = [self.mapView convertPoint:point toCoordinateFromView:self.mapView];
    [self selectCoordinate:c animated:YES];
}

- (void)selectCoordinate:(CLLocationCoordinate2D)c animated:(BOOL)animated {
    if (!IQTLCoordinateIsUsable(c)) return;

    if (self.pin == nil) {
        self.pin = [MKPointAnnotation new];
        self.pin.title = @"Localização selecionada";
        [self.mapView addAnnotation:self.pin];
    }

    self.pin.coordinate = c;
    self.hasSelection = YES;

    if (animated) {
        [self.mapView setCenterCoordinate:c animated:YES];
    }
}

- (void)mapView:(MKMapView *)mapView didUpdateUserLocation:(MKUserLocation *)userLocation {
    if (self.hasSelection || IQTLHasCoordinate()) return;
    CLLocation *location = userLocation.location;
    if (location == nil) return;

    MKCoordinateRegion region =
        MKCoordinateRegionMakeWithDistance(location.coordinate, 5000.0, 5000.0);
    [mapView setRegion:region animated:YES];
}

- (void)saveLocation {
    if (!self.hasSelection || self.pin == nil) {
        UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:@"Selecione um ponto"
                                                message:@"Toque no mapa para escolher a localização falsa."
                                         preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                                  style:UIAlertActionStyleDefault
                                                handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    IQTLSaveCoordinate(self.pin.coordinate);
    [self.navigationController popViewControllerAnimated:YES];
}

@end

@interface IQTLocationSettingsController : UITableViewController
@end

@implementation IQTLocationSettingsController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Localização falsa";
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(locationChanged)
                                               name:IQTLDidChangeNotification
                                             object:nil];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)locationChanged {
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return 3;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    return section == 1 ? 2 : 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    if (section == 0) return @"FAKE LOCATION";
    if (section == 1) return @"LOCALIZAÇÃO";
    return nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    if (section == 0) {
        return @"O spoof é aplicado apenas dentro do Telegram. Outros apps continuam usando a localização real do iPhone.";
    }
    if (section == 2) {
        return [NSString stringWithFormat:@"iQTeleLocation %@", IQTLVersion];
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSString *identifier = [NSString stringWithFormat:@"iqtl-%ld-%ld",
                            (long)indexPath.section, (long)indexPath.row];
    UITableViewCell *cell =
        [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                               reuseIdentifier:identifier];

    if (indexPath.section == 0) {
        cell.textLabel.text = @"Ativar localização falsa";
        cell.detailTextLabel.text = @"Substitui a localização recebida pelo Telegram.";
        UISwitch *toggle = [UISwitch new];
        toggle.on = IQTLFakeEnabled();
        [toggle addTarget:self action:@selector(toggleChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (indexPath.section == 1 && indexPath.row == 0) {
        cell.textLabel.text = @"Selecionar localização";
        cell.detailTextLabel.text = @"Escolha um ponto no mapa.";
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (indexPath.section == 1) {
        cell.textLabel.text = @"Coordenadas";
        if (IQTLHasCoordinate()) {
            CLLocationCoordinate2D c = IQTLSavedCoordinate();
            cell.detailTextLabel.text =
                [NSString stringWithFormat:@"%.6f, %.6f", c.latitude, c.longitude];
        } else {
            cell.detailTextLabel.text = @"Nenhuma localização selecionada";
        }
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else {
        cell.textLabel.text = @"Usar localização real";
        cell.textLabel.textColor = UIColor.systemRedColor;
        cell.detailTextLabel.text = @"Desativa o spoof imediatamente.";
    }

    return cell;
}

- (void)toggleChanged:(UISwitch *)sender {
    if (sender.on && !IQTLHasCoordinate()) {
        sender.on = NO;
        IQTLocationMapController *picker = [IQTLocationMapController new];
        [self.navigationController pushViewController:picker animated:YES];
        return;
    }

    [IQTLDefaults() setBool:sender.on forKey:IQTLEnabledKey];
    [IQTLDefaults() synchronize];
    [NSNotificationCenter.defaultCenter postNotificationName:IQTLDidChangeNotification object:nil];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.section == 1 && indexPath.row == 0) {
        IQTLocationMapController *picker = [IQTLocationMapController new];
        [self.navigationController pushViewController:picker animated:YES];
    } else if (indexPath.section == 2) {
        [IQTLDefaults() setBool:NO forKey:IQTLEnabledKey];
        [IQTLDefaults() synchronize];
        [NSNotificationCenter.defaultCenter postNotificationName:IQTLDidChangeNotification object:nil];
        [self.tableView reloadData];
    }
}

@end

#pragma mark - iQTele settings integration

static id (*IQTLOrigSettingsInit)(id, SEL) = NULL;
static NSInteger (*IQTLOrigNumberOfSections)(id, SEL, UITableView *) = NULL;
static NSInteger (*IQTLOrigRowsInSection)(id, SEL, UITableView *, NSInteger) = NULL;
static NSString *(*IQTLOrigHeaderTitle)(id, SEL, UITableView *, NSInteger) = NULL;
static UITableViewCell *(*IQTLOrigCellForRow)(id, SEL, UITableView *, NSIndexPath *) = NULL;
static void (*IQTLOrigDidSelect)(id, SEL, UITableView *, NSIndexPath *) = NULL;

static BOOL IQTLIsRootSettings(id controller) {
    return [objc_getAssociatedObject(controller, &IQTLRootSettingsKey) boolValue];
}

static id IQTLSettingsInit(id self, SEL _cmd) {
    id result = IQTLOrigSettingsInit ? IQTLOrigSettingsInit(self, _cmd) : self;
    if (result != nil) {
        objc_setAssociatedObject(result, &IQTLRootSettingsKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return result;
}

static NSInteger IQTLSettingsNumberOfSections(id self, SEL _cmd, UITableView *tableView) {
    NSInteger original = IQTLOrigNumberOfSections ?
        IQTLOrigNumberOfSections(self, _cmd, tableView) : 0;
    return IQTLIsRootSettings(self) ? original + 1 : original;
}

static NSInteger IQTLSettingsRowsInSection(id self, SEL _cmd, UITableView *tableView, NSInteger section) {
    NSInteger originalSections = IQTLOrigNumberOfSections ?
        IQTLOrigNumberOfSections(self, @selector(numberOfSectionsInTableView:), tableView) : 0;

    if (IQTLIsRootSettings(self) && section == originalSections) return 1;
    return IQTLOrigRowsInSection ?
        IQTLOrigRowsInSection(self, _cmd, tableView, section) : 0;
}

static NSString *IQTLSettingsHeaderTitle(id self, SEL _cmd, UITableView *tableView, NSInteger section) {
    NSInteger originalSections = IQTLOrigNumberOfSections ?
        IQTLOrigNumberOfSections(self, @selector(numberOfSectionsInTableView:), tableView) : 0;

    if (IQTLIsRootSettings(self) && section == originalSections) {
        return @"LOCALIZAÇÃO";
    }

    return IQTLOrigHeaderTitle ?
        IQTLOrigHeaderTitle(self, _cmd, tableView, section) : nil;
}

static UITableViewCell *IQTLSettingsCellForRow(id self, SEL _cmd,
                                               UITableView *tableView,
                                               NSIndexPath *indexPath) {
    NSInteger originalSections = IQTLOrigNumberOfSections ?
        IQTLOrigNumberOfSections(self, @selector(numberOfSectionsInTableView:), tableView) : 0;

    if (IQTLIsRootSettings(self) && indexPath.section == originalSections) {
        UITableViewCell *cell =
            [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                   reuseIdentifier:@"iQTeleLocationRootCell"];
        cell.textLabel.text = @"Localização falsa";
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

        if (IQTLFakeEnabled()) {
            CLLocationCoordinate2D c = IQTLSavedCoordinate();
            cell.detailTextLabel.text =
                [NSString stringWithFormat:@"Ativada • %.5f, %.5f", c.latitude, c.longitude];
        } else {
            cell.detailTextLabel.text = @"Desativada";
        }
        return cell;
    }

    return IQTLOrigCellForRow ?
        IQTLOrigCellForRow(self, _cmd, tableView, indexPath) : [UITableViewCell new];
}

static void IQTLSettingsDidSelect(id self, SEL _cmd,
                                  UITableView *tableView,
                                  NSIndexPath *indexPath) {
    NSInteger originalSections = IQTLOrigNumberOfSections ?
        IQTLOrigNumberOfSections(self, @selector(numberOfSectionsInTableView:), tableView) : 0;

    if (IQTLIsRootSettings(self) && indexPath.section == originalSections) {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        IQTLocationSettingsController *controller = [IQTLocationSettingsController new];

        UIViewController *vc = [self isKindOfClass:UIViewController.class] ? self : nil;
        if (vc.navigationController != nil) {
            [vc.navigationController pushViewController:controller animated:YES];
        } else if (vc != nil) {
            UINavigationController *nav =
                [[UINavigationController alloc] initWithRootViewController:controller];
            [vc presentViewController:nav animated:YES completion:nil];
        }
        return;
    }

    if (IQTLOrigDidSelect) {
        IQTLOrigDidSelect(self, _cmd, tableView, indexPath);
    }
}

static BOOL IQTLCoreHooksInstalled = NO;
static BOOL IQTLDeviceHookInstalled = NO;
static BOOL IQTLMKHookInstalled = NO;
static BOOL IQTLSettingsHooksInstalled = NO;

static void IQTLInstallCoreHooks(void) {
    if (IQTLCoreHooksInstalled) return;

    Class cls = CLLocationManager.class;
    BOOL a = IQTLHookMethod(cls, @selector(init), (IMP)&IQTLCLInit, (IMP *)&IQTLOrigCLInit);
    BOOL b = IQTLHookMethod(cls, @selector(setDelegate:), (IMP)&IQTLCLSetDelegate,
                            (IMP *)&IQTLOrigCLSetDelegate);
    BOOL c = IQTLHookMethod(cls, @selector(location), (IMP)&IQTLCLLocation,
                            (IMP *)&IQTLOrigCLLocation);
    IQTLCoreHooksInstalled = a && b && c;
}

static void IQTLInstallTelegramLocationHooksIfReady(void) {
    if (!IQTLDeviceHookInstalled) {
        Class device = NSClassFromString(@"DeviceLocationManager.DeviceLocationManager");
        if (device != Nil) {
            IQTLDeviceHookInstalled =
                IQTLHookMethod(device,
                               @selector(locationManager:didUpdateLocations:),
                               (IMP)&IQTLDeviceUpdate,
                               (IMP *)&IQTLOrigDeviceUpdate);
        }
    }

    if (!IQTLMKHookInstalled) {
        Class mk = NSClassFromString(@"MKCoreLocationProvider");
        if (mk != Nil) {
            IQTLMKHookInstalled =
                IQTLHookMethod(mk,
                               @selector(locationManager:didUpdateLocations:),
                               (IMP)&IQTLMKUpdate,
                               (IMP *)&IQTLOrigMKUpdate);
        }
    }
}

static void IQTLInstallSettingsHooksIfReady(void) {
    if (IQTLSettingsHooksInstalled) return;

    Class cls = NSClassFromString(@"IQTSettingsViewController");
    if (cls == Nil) return;

    BOOL a = IQTLHookMethod(cls, @selector(init),
                            (IMP)&IQTLSettingsInit, (IMP *)&IQTLOrigSettingsInit);
    BOOL b = IQTLHookMethod(cls, @selector(numberOfSectionsInTableView:),
                            (IMP)&IQTLSettingsNumberOfSections,
                            (IMP *)&IQTLOrigNumberOfSections);
    BOOL c = IQTLHookMethod(cls, @selector(tableView:numberOfRowsInSection:),
                            (IMP)&IQTLSettingsRowsInSection,
                            (IMP *)&IQTLOrigRowsInSection);
    BOOL d = IQTLHookMethod(cls, @selector(tableView:titleForHeaderInSection:),
                            (IMP)&IQTLSettingsHeaderTitle,
                            (IMP *)&IQTLOrigHeaderTitle);
    BOOL e = IQTLHookMethod(cls, @selector(tableView:cellForRowAtIndexPath:),
                            (IMP)&IQTLSettingsCellForRow,
                            (IMP *)&IQTLOrigCellForRow);
    BOOL f = IQTLHookMethod(cls, @selector(tableView:didSelectRowAtIndexPath:),
                            (IMP)&IQTLSettingsDidSelect,
                            (IMP *)&IQTLOrigDidSelect);

    IQTLSettingsHooksInstalled = a && b && c && d && e && f;
}

static BOOL IQTLIsTelegramProcess(void) {
    NSString *bid = NSBundle.mainBundle.bundleIdentifier ?: @"";
    NSString *exe = NSBundle.mainBundle.executablePath.lastPathComponent ?: @"";
    NSString *proc = NSProcessInfo.processInfo.processName ?: @"";
    return [bid isEqualToString:@"ph.telegra.Telegraph"] ||
           [exe isEqualToString:@"Telegram"] ||
           [proc isEqualToString:@"Telegram"];
}

__attribute__((constructor)) static void IQTLocationInit(void) {
    @autoreleasepool {
        if (!IQTLIsTelegramProcess()) return;

        dispatch_async(dispatch_get_main_queue(), ^{
            IQTLInstallCoreHooks();
            [[IQTLocationEngine shared] setupTimer];

            __block NSTimer *installer = nil;
            installer = [NSTimer timerWithTimeInterval:0.35
                                               repeats:YES
                                                 block:^(__unused NSTimer *timer) {
                IQTLInstallTelegramLocationHooksIfReady();
                IQTLInstallSettingsHooksIfReady();

                if (IQTLDeviceHookInstalled &&
                    IQTLMKHookInstalled &&
                    IQTLSettingsHooksInstalled) {
                    [installer invalidate];
                    installer = nil;
                }
            }];
            [NSRunLoop.mainRunLoop addTimer:installer forMode:NSRunLoopCommonModes];

            IQTLInstallTelegramLocationHooksIfReady();
            IQTLInstallSettingsHooksIfReady();
        });
    }
}
