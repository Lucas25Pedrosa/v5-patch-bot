#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreLocation/CoreLocation.h>
#import <MapKit/MapKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSString * const IQTLVersion = @"1.0";
static NSString * const IQTLEnabledKey = @"LucasIQTFakeLocationEnabled";
static NSString * const IQTLLatitudeKey = @"LucasIQTFakeLatitude";
static NSString * const IQTLLongitudeKey = @"LucasIQTFakeLongitude";
static NSString * const IQTLDidChangeNotification = @"LucasIQTFakeLocationDidChange";
static NSString * const IQTLSavedLocationsKey = @"LucasIQTFakeSavedLocations";

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


static NSArray<NSDictionary *> *IQTLSavedLocations(void) {
    id stored = [IQTLDefaults() objectForKey:IQTLSavedLocationsKey];
    if (![stored isKindOfClass:NSArray.class]) return @[];

    NSMutableArray<NSDictionary *> *valid = [NSMutableArray array];
    for (id item in (NSArray *)stored) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSNumber *lat = item[@"latitude"];
        NSNumber *lon = item[@"longitude"];
        NSString *name = item[@"name"];
        if (![lat isKindOfClass:NSNumber.class] ||
            ![lon isKindOfClass:NSNumber.class] ||
            ![name isKindOfClass:NSString.class]) {
            continue;
        }

        CLLocationCoordinate2D c =
            CLLocationCoordinate2DMake(lat.doubleValue, lon.doubleValue);
        if (!IQTLCoordinateIsUsable(c)) continue;
        [valid addObject:item];
    }
    return valid.copy;
}

static void IQTLStoreSavedLocations(NSArray<NSDictionary *> *locations) {
    [IQTLDefaults() setObject:locations ?: @[] forKey:IQTLSavedLocationsKey];
    [IQTLDefaults() synchronize];
    [NSNotificationCenter.defaultCenter postNotificationName:IQTLDidChangeNotification object:nil];
}

static NSString *IQTLTrimmedString(NSString *value) {
    if (![value isKindOfClass:NSString.class]) return @"";
    return [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static NSString *IQTLDefaultSavedName(void) {
    return [NSString stringWithFormat:@"Localização %lu",
            (unsigned long)(IQTLSavedLocations().count + 1)];
}

static void IQTLAddSavedLocation(NSString *name, CLLocationCoordinate2D c) {
    if (!IQTLCoordinateIsUsable(c)) return;

    NSString *cleanName = IQTLTrimmedString(name);
    if (cleanName.length == 0) cleanName = IQTLDefaultSavedName();

    NSMutableArray<NSDictionary *> *locations =
        [IQTLSavedLocations() mutableCopy] ?: [NSMutableArray array];

    NSDictionary *record = @{
        @"name": cleanName,
        @"latitude": @(c.latitude),
        @"longitude": @(c.longitude)
    };
    [locations addObject:record];
    IQTLStoreSavedLocations(locations);
}

static BOOL IQTLCoordinateMatchesRecord(CLLocationCoordinate2D c, NSDictionary *record) {
    if (!IQTLCoordinateIsUsable(c) || ![record isKindOfClass:NSDictionary.class]) return NO;
    NSNumber *lat = record[@"latitude"];
    NSNumber *lon = record[@"longitude"];
    if (![lat isKindOfClass:NSNumber.class] || ![lon isKindOfClass:NSNumber.class]) return NO;

    return fabs(c.latitude - lat.doubleValue) < 0.000001 &&
           fabs(c.longitude - lon.doubleValue) < 0.000001;
}

static BOOL IQTLParseCoordinateText(NSString *text, double *valueOut) {
    NSString *clean = IQTLTrimmedString(text);
    if (clean.length == 0) return NO;
    clean = [clean stringByReplacingOccurrencesOfString:@"," withString:@"."];

    NSScanner *scanner = [NSScanner scannerWithString:clean];
    double value = 0.0;
    if (![scanner scanDouble:&value] || !scanner.isAtEnd) return NO;

    if (valueOut != NULL) *valueOut = value;
    return YES;
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


@interface IQTManualCoordinateController : UITableViewController
@property (nonatomic, strong) UITextField *latitudeField;
@property (nonatomic, strong) UITextField *longitudeField;
@property (nonatomic, strong) UITextField *nameField;
@end

@implementation IQTManualCoordinateController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Inserir coordenadas";
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"Usar"
                                        style:UIBarButtonItemStyleDone
                                       target:self
                                       action:@selector(useCoordinates)];

    if (IQTLHasCoordinate()) {
        CLLocationCoordinate2D c = IQTLSavedCoordinate();
        self.latitudeField.text = [NSString stringWithFormat:@"%.6f", c.latitude];
        self.longitudeField.text = [NSString stringWithFormat:@"%.6f", c.longitude];
    }
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    return section == 0 ? 2 : 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    return section == 0 ? @"Coordenadas" : @"Salvar localização";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    if (section == 0) {
        return @"Aceita ponto ou vírgula como separador decimal.";
    }
    return @"O nome é opcional. Se preenchido, a coordenada também será adicionada a Localizações salvas.";
}

- (UITextField *)coordinateFieldWithPlaceholder:(NSString *)placeholder {
    UITextField *field = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 185, 34)];
    field.placeholder = placeholder;
    field.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    field.textAlignment = NSTextAlignmentRight;
    field.clearButtonMode = UITextFieldViewModeWhileEditing;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    return field;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    UITableViewCell *cell =
        [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    if (indexPath.section == 0 && indexPath.row == 0) {
        cell.textLabel.text = @"Latitude";
        if (self.latitudeField == nil) {
            self.latitudeField = [self coordinateFieldWithPlaceholder:@"-90 a 90"];
            if (IQTLHasCoordinate()) {
                self.latitudeField.text =
                    [NSString stringWithFormat:@"%.6f", IQTLSavedCoordinate().latitude];
            }
        }
        cell.accessoryView = self.latitudeField;
    } else if (indexPath.section == 0) {
        cell.textLabel.text = @"Longitude";
        if (self.longitudeField == nil) {
            self.longitudeField = [self coordinateFieldWithPlaceholder:@"-180 a 180"];
            if (IQTLHasCoordinate()) {
                self.longitudeField.text =
                    [NSString stringWithFormat:@"%.6f", IQTLSavedCoordinate().longitude];
            }
        }
        cell.accessoryView = self.longitudeField;
    } else {
        cell.textLabel.text = @"Nome";
        if (self.nameField == nil) {
            self.nameField = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 185, 34)];
            self.nameField.placeholder = @"Opcional";
            self.nameField.textAlignment = NSTextAlignmentRight;
            self.nameField.clearButtonMode = UITextFieldViewModeWhileEditing;
            self.nameField.autocorrectionType = UITextAutocorrectionTypeDefault;
            self.nameField.autocapitalizationType = UITextAutocapitalizationTypeWords;
        }
        cell.accessoryView = self.nameField;
    }
    return cell;
}

- (void)showInvalidCoordinateAlert {
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"Coordenadas inválidas"
                                            message:@"Latitude deve ficar entre -90 e 90 e longitude entre -180 e 180."
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)useCoordinates {
    double lat = 0.0;
    double lon = 0.0;
    if (!IQTLParseCoordinateText(self.latitudeField.text, &lat) ||
        !IQTLParseCoordinateText(self.longitudeField.text, &lon)) {
        [self showInvalidCoordinateAlert];
        return;
    }

    CLLocationCoordinate2D c = CLLocationCoordinate2DMake(lat, lon);
    if (!IQTLCoordinateIsUsable(c)) {
        [self showInvalidCoordinateAlert];
        return;
    }

    IQTLSaveCoordinate(c);

    NSString *name = IQTLTrimmedString(self.nameField.text);
    if (name.length > 0) {
        IQTLAddSavedLocation(name, c);
    }

    [self.navigationController popViewControllerAnimated:YES];
}

@end


@interface IQTSavedLocationsController : UITableViewController
@property (nonatomic, copy) NSArray<NSDictionary *> *locations;
@end

@implementation IQTSavedLocationsController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Localizações salvas";
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                     target:self
                                                     action:@selector(addCurrentLocation)];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(reloadLocations)
                                               name:IQTLDidChangeNotification
                                             object:nil];
    [self reloadLocations];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)reloadLocations {
    self.locations = IQTLSavedLocations();
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return MAX((NSInteger)self.locations.count, 1);
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return @"Localizações salvas";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    if (self.locations.count == 0) {
        return @"Use o botão + para salvar a coordenada selecionada atualmente.";
    }
    return @"Toque em uma localização para usá-la. Deslize para a esquerda para apagar.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;

    if (self.locations.count == 0) {
        UITableViewCell *empty =
            [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        empty.textLabel.text = @"Nenhuma localização salva";
        empty.detailTextLabel.text = @"Selecione uma localização e toque em +.";
        empty.selectionStyle = UITableViewCellSelectionStyleNone;
        return empty;
    }

    NSDictionary *record = self.locations[(NSUInteger)indexPath.row];
    UITableViewCell *cell =
        [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];

    cell.textLabel.text = record[@"name"];
    cell.detailTextLabel.text =
        [NSString stringWithFormat:@"%.6f, %.6f",
         [record[@"latitude"] doubleValue],
         [record[@"longitude"] doubleValue]];

    UIImage *pin = [UIImage systemImageNamed:@"mappin.and.ellipse"];
    cell.imageView.image = pin;
    cell.accessoryType =
        (IQTLHasCoordinate() && IQTLCoordinateMatchesRecord(IQTLSavedCoordinate(), record))
        ? UITableViewCellAccessoryCheckmark
        : UITableViewCellAccessoryNone;

    return cell;
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    (void)indexPath;
    return self.locations.count > 0;
}

- (void)tableView:(UITableView *)tableView
commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
forRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    if (editingStyle != UITableViewCellEditingStyleDelete ||
        indexPath.row >= (NSInteger)self.locations.count) {
        return;
    }

    NSMutableArray<NSDictionary *> *locations = [self.locations mutableCopy];
    [locations removeObjectAtIndex:(NSUInteger)indexPath.row];
    IQTLStoreSavedLocations(locations);
    [self reloadLocations];
}

- (NSString *)tableView:(UITableView *)tableView
titleForDeleteConfirmationButtonForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    (void)indexPath;
    return @"Apagar";
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.locations.count == 0 ||
        indexPath.row >= (NSInteger)self.locations.count) {
        return;
    }

    NSDictionary *record = self.locations[(NSUInteger)indexPath.row];
    CLLocationCoordinate2D c =
        CLLocationCoordinate2DMake([record[@"latitude"] doubleValue],
                                   [record[@"longitude"] doubleValue]);
    if (!IQTLCoordinateIsUsable(c)) return;

    IQTLSaveCoordinate(c);
    [self.navigationController popViewControllerAnimated:YES];
}

- (void)addCurrentLocation {
    if (!IQTLHasCoordinate()) {
        UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:@"Nenhuma localização selecionada"
                                                message:@"Escolha uma localização no mapa ou insira coordenadas antes de salvá-la."
                                         preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                                  style:UIAlertActionStyleDefault
                                                handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"Salvar localização"
                                            message:@"Digite um nome para identificar esta localização."
                                     preferredStyle:UIAlertControllerStyleAlert];

    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = IQTLDefaultSavedName();
        field.autocapitalizationType = UITextAutocapitalizationTypeWords;
    }];

    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancelar"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Salvar"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        __strong typeof(weakSelf) self = weakSelf;
        if (self == nil) return;
        NSString *name = alert.textFields.firstObject.text;
        IQTLAddSavedLocation(name, IQTLSavedCoordinate());
        [self reloadLocations];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
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
    return section == 1 ? 4 : 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    if (section == 0) return @"Localização falsa";
    if (section == 1) return @"Localização";
    return nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    if (section == 0) {
        return @"O spoof é aplicado apenas dentro deste app. Outros apps continuam usando a localização real do iPhone.";
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
        cell.detailTextLabel.text = @"Substitui a localização recebida pelo app.";
        UISwitch *toggle = [UISwitch new];
        toggle.on = IQTLFakeEnabled();
        [toggle addTarget:self action:@selector(toggleChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (indexPath.section == 1 && indexPath.row == 0) {
        cell.textLabel.text = @"Selecionar localização";
        cell.detailTextLabel.text = @"Escolha um ponto no mapa.";
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (indexPath.section == 1 && indexPath.row == 1) {
        cell.textLabel.text = @"Inserir coordenadas";
        cell.detailTextLabel.text = @"Digite latitude e longitude manualmente.";
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (indexPath.section == 1 && indexPath.row == 2) {
        cell.textLabel.text = @"Localizações salvas";
        NSUInteger count = IQTLSavedLocations().count;
        cell.detailTextLabel.text =
            count == 0
            ? @"Nenhuma localização salva"
            : [NSString stringWithFormat:@"%lu %@", (unsigned long)count,
               count == 1 ? @"localização" : @"localizações"];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (indexPath.section == 1) {
        cell.textLabel.text = @"Coordenadas atuais";
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
    } else if (indexPath.section == 1 && indexPath.row == 1) {
        IQTManualCoordinateController *manual = [IQTManualCoordinateController new];
        [self.navigationController pushViewController:manual animated:YES];
    } else if (indexPath.section == 1 && indexPath.row == 2) {
        IQTSavedLocationsController *saved = [IQTSavedLocationsController new];
        [self.navigationController pushViewController:saved animated:YES];
    } else if (indexPath.section == 2) {
        [IQTLDefaults() setBool:NO forKey:IQTLEnabledKey];
        [IQTLDefaults() synchronize];
        [NSNotificationCenter.defaultCenter postNotificationName:IQTLDidChangeNotification object:nil];
        [self.tableView reloadData];
    }
}

@end


#pragma mark - Root settings presentation

static UIImage *IQTLRootIcon(void) {
    static UIImage *icon = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        CGSize size = CGSizeMake(30.0, 30.0);
        UIGraphicsImageRenderer *renderer =
            [[UIGraphicsImageRenderer alloc] initWithSize:size];

        icon = [renderer imageWithActions:^(__unused UIGraphicsImageRendererContext * _Nonnull context) {
            CGRect bounds = CGRectMake(0.0, 0.0, size.width, size.height);
            UIBezierPath *background =
                [UIBezierPath bezierPathWithRoundedRect:bounds cornerRadius:7.5];
            [UIColor.systemIndigoColor setFill];
            [background fill];

            UIImage *symbol = [UIImage systemImageNamed:@"location.fill"];
            if (symbol != nil) {
                UIImage *white =
                    [symbol imageWithTintColor:UIColor.whiteColor
                                 renderingMode:UIImageRenderingModeAlwaysOriginal];

                CGRect glyphRect = CGRectMake(7.0, 6.5, 16.0, 17.0);
                [white drawInRect:glyphRect];
            }
        }];
    });
    return icon;
}

static NSString *IQTLNormalizeHeader(NSString *value) {
    if (value.length == 0) return @"";
    return [[value stringByFoldingWithOptions:(NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch)
                                       locale:NSLocale.currentLocale] lowercaseString];
}

static BOOL IQTLHeaderLooksLikeAppearance(NSString *title) {
    NSString *value = IQTLNormalizeHeader(title);
    if (value.length == 0) return NO;

    NSArray<NSString *> *matches = @[
        @"aparencia",
        @"appearance",
        @"apariencia",
        @"apparence",
        @"aspetto",
        @"görünüm",
        @"gorunum",
        @"внешний вид"
    ];

    for (NSString *candidate in matches) {
        if ([value isEqualToString:IQTLNormalizeHeader(candidate)] ||
            [value containsString:IQTLNormalizeHeader(candidate)]) {
            return YES;
        }
    }
    return NO;
}

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

static NSInteger IQTLSettingsOriginalSectionCount(id self, UITableView *tableView) {
    return IQTLOrigNumberOfSections ?
        IQTLOrigNumberOfSections(self, @selector(numberOfSectionsInTableView:), tableView) : 0;
}

static NSInteger IQTLSettingsInsertionSection(id self, UITableView *tableView) {
    NSInteger originalSections = IQTLSettingsOriginalSectionCount(self, tableView);

    if (IQTLOrigHeaderTitle != NULL) {
        for (NSInteger section = 0; section < originalSections; section++) {
            NSString *title =
                IQTLOrigHeaderTitle(self,
                                    @selector(tableView:titleForHeaderInSection:),
                                    tableView,
                                    section);
            if (IQTLHeaderLooksLikeAppearance(title)) {
                return section;
            }
        }
    }

    // Fallback: if Appearance cannot be identified, preserve the Beta 2 behavior.
    return originalSections;
}

static NSInteger IQTLOriginalSectionForDisplayedSection(id self,
                                                         UITableView *tableView,
                                                         NSInteger displayedSection) {
    NSInteger insertion = IQTLSettingsInsertionSection(self, tableView);
    return displayedSection > insertion ? displayedSection - 1 : displayedSection;
}

static NSInteger IQTLSettingsNumberOfSections(id self, SEL _cmd, UITableView *tableView) {
    NSInteger original = IQTLOrigNumberOfSections ?
        IQTLOrigNumberOfSections(self, _cmd, tableView) : 0;
    return IQTLIsRootSettings(self) ? original + 1 : original;
}

static NSInteger IQTLSettingsRowsInSection(id self, SEL _cmd, UITableView *tableView, NSInteger section) {
    if (!IQTLIsRootSettings(self)) {
        return IQTLOrigRowsInSection ?
            IQTLOrigRowsInSection(self, _cmd, tableView, section) : 0;
    }

    NSInteger insertion = IQTLSettingsInsertionSection(self, tableView);
    if (section == insertion) return 1;

    NSInteger originalSection =
        IQTLOriginalSectionForDisplayedSection(self, tableView, section);
    return IQTLOrigRowsInSection ?
        IQTLOrigRowsInSection(self, _cmd, tableView, originalSection) : 0;
}

static NSString *IQTLSettingsHeaderTitle(id self, SEL _cmd, UITableView *tableView, NSInteger section) {
    if (!IQTLIsRootSettings(self)) {
        return IQTLOrigHeaderTitle ?
            IQTLOrigHeaderTitle(self, _cmd, tableView, section) : nil;
    }

    NSInteger insertion = IQTLSettingsInsertionSection(self, tableView);
    if (section == insertion) {
        return @"Localização";
    }

    NSInteger originalSection =
        IQTLOriginalSectionForDisplayedSection(self, tableView, section);
    return IQTLOrigHeaderTitle ?
        IQTLOrigHeaderTitle(self, _cmd, tableView, originalSection) : nil;
}

static UITableViewCell *IQTLSettingsCellForRow(id self, SEL _cmd,
                                               UITableView *tableView,
                                               NSIndexPath *indexPath) {
    if (!IQTLIsRootSettings(self)) {
        return IQTLOrigCellForRow ?
            IQTLOrigCellForRow(self, _cmd, tableView, indexPath) : [UITableViewCell new];
    }

    NSInteger insertion = IQTLSettingsInsertionSection(self, tableView);
    if (indexPath.section == insertion) {
        UITableViewCell *cell =
            [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                   reuseIdentifier:@"iQTeleLocationRootCell"];
        cell.textLabel.text = @"Localização falsa";
        cell.imageView.image = IQTLRootIcon();
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

    NSInteger originalSection =
        IQTLOriginalSectionForDisplayedSection(self, tableView, indexPath.section);
    NSIndexPath *originalIndexPath =
        [NSIndexPath indexPathForRow:indexPath.row inSection:originalSection];

    return IQTLOrigCellForRow ?
        IQTLOrigCellForRow(self, _cmd, tableView, originalIndexPath) : [UITableViewCell new];
}

static void IQTLSettingsDidSelect(id self, SEL _cmd,
                                  UITableView *tableView,
                                  NSIndexPath *indexPath) {
    if (!IQTLIsRootSettings(self)) {
        if (IQTLOrigDidSelect) {
            IQTLOrigDidSelect(self, _cmd, tableView, indexPath);
        }
        return;
    }

    NSInteger insertion = IQTLSettingsInsertionSection(self, tableView);
    if (indexPath.section == insertion) {
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

    NSInteger originalSection =
        IQTLOriginalSectionForDisplayedSection(self, tableView, indexPath.section);
    NSIndexPath *originalIndexPath =
        [NSIndexPath indexPathForRow:indexPath.row inSection:originalSection];

    if (IQTLOrigDidSelect) {
        IQTLOrigDidSelect(self, _cmd, tableView, originalIndexPath);
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
           [proc isEqualToString:@"Telegram"] ||
           [bid isEqualToString:@"app.swiftgram.ios"] ||
           [exe isEqualToString:@"Swiftgram"] ||
           [proc isEqualToString:@"Swiftgram"];
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
