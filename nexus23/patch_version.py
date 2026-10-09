from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text(encoding='utf-8')
s=s.replace('NexusVersion = @"2.1"','NexusVersion = @"2.3 Beta 1"')
s=s.replace('@"Nexus 2.1\\nFacebook %@ (%@)', '@"Nexus 2.3 Beta 1\\nFacebook %@ (%@)')
s=s.replace('engine: run52 legacy OLED', 'engine: adaptive custom background (2.3 Beta 1)')
s=s.replace('[setting setValue:@"v2.1" forKey:@"valueText"]', '[setting setValue:@"v2.3 Beta 1" forKey:@"valueText"]')
s=s.replace('@"nexusVersion": @"2.1"', '@"nexusVersion": @"2.3 Beta 1"')
s=s.replace('Nexus 2.1 loaded', 'Nexus 2.3 Beta 1 loaded')

# 2.3 preference keys
needle='static NSString * const NXKeyOLED = @"iQFaceOLEDEnabled";'
s=s.replace(needle, needle+'\nstatic NSString * const NXKeyCustomBackground = @"NexusCustomBackgroundEnabled";\nstatic NSString * const NXKeyCustomBackgroundColor = @"NexusCustomBackgroundColor";')

# Helpers shared by Appearance UI and adaptive engine.
needle='static void NXSetOLEDEnabled(BOOL enabled) {\n    NXSetIQFBool(NXKeyOLED, enabled);\n}\n'
helpers=r'''static void NXSetOLEDEnabled(BOOL enabled) {
    NXSetIQFBool(NXKeyOLED, enabled);
}

static NSString *NXCustomBackgroundHex(void) {
    id value=[NSUserDefaults.standardUserDefaults objectForKey:NXKeyCustomBackgroundColor];
    return [value isKindOfClass:NSString.class] && [value length]==7 ? value : @"#1C1C1E";
}
static void NXSetCustomBackground(BOOL enabled, NSString *hex) {
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:NXKeyCustomBackground];
    if (hex.length) [NSUserDefaults.standardUserDefaults setObject:hex forKey:NXKeyCustomBackgroundColor];
    [NSUserDefaults.standardUserDefaults synchronize];
    [NSNotificationCenter.defaultCenter postNotificationName:NXSettingsChangedNotification object:nil];
}
static UIColor *NXColorFromHex(NSString *hex) {
    NSString *v=[[hex ?: @"" stringByReplacingOccurrencesOfString:@"#" withString:@""] uppercaseString];
    if (v.length!=6) return [UIColor colorWithRed:28/255.0 green:28/255.0 blue:30/255.0 alpha:1];
    unsigned x=0; [[NSScanner scannerWithString:v] scanHexInt:&x];
    return [UIColor colorWithRed:((x>>16)&255)/255.0 green:((x>>8)&255)/255.0 blue:(x&255)/255.0 alpha:1];
}
static NSString *NXHexFromColor(UIColor *color) {
    CGFloat r=0,g=0,b=0,a=0; UIColor *c=color;
    if (![c getRed:&r green:&g blue:&b alpha:&a]) return NXCustomBackgroundHex();
    return [NSString stringWithFormat:@"#%02lX%02lX%02lX",(long)lround(r*255),(long)lround(g*255),(long)lround(b*255)];
}
'''
assert needle in s
s=s.replace(needle,helpers)

# Add 2.3 diagnostics state.
s=s.replace('feed separators: %@\\nengine: adaptive custom background (2.3 Beta 1)\\n\\n",',
'''feed separators: %@\\ncustom background: %@\\ncustom color: %@\\nengine: adaptive custom background (2.3 Beta 1)\\n\\n",''')
s=s.replace('NXStatus(NXIQFBool(@"iQFaceOLEDFeedSeparatorsEnabled", NO))];',
'''NXStatus(NXIQFBool(@"iQFaceOLEDFeedSeparatorsEnabled", NO)),
     NXStatus(NXBool(NXKeyCustomBackground, NO)), NXCustomBackgroundHex()];''')

# Native UIColorPicker controller and 3-state background mode UI.
start=s.index('@interface Nexus2AppearanceController : UITableViewController')
end=s.index('#pragma mark - Feed controller', start)
appearance=r'''@interface Nexus2AppearanceController : UITableViewController <UIColorPickerViewControllerDelegate>
@end

@implementation Nexus2AppearanceController
- (void)viewDidLoad {
    [super viewDidLoad]; self.title=Nexus2Localized(@"Appearance");
    self.tableView=[[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
}
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self.tableView reloadData]; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { (void)tableView; return 2; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { (void)tableView; return section==0 ? 4 : 1; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { (void)tableView; return section==0 ? Nexus2Localized(@"Background appearance") : nil; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section { (void)tableView; return section==0 ? Nexus2Localized(@"Dark mode required") : nil; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell=[tableView dequeueReusableCellWithIdentifier:@"NXAppearance23"];
    if (!cell) cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"NXAppearance23"];
    cell.accessoryView=nil; cell.accessoryType=UITableViewCellAccessoryNone; cell.selectionStyle=UITableViewCellSelectionStyleDefault;
    cell.detailTextLabel.text=nil; cell.imageView.image=nil;
    BOOL oled=NXOLEDEnabled(), custom=NXBool(NXKeyCustomBackground,NO);
    if (indexPath.section==0) {
        if (indexPath.row==0) { cell.textLabel.text=Nexus2Localized(@"Default"); cell.accessoryType=!oled ? UITableViewCellAccessoryCheckmark:UITableViewCellAccessoryNone; }
        else if (indexPath.row==1) { cell.textLabel.text=Nexus2Localized(@"OLED Mode"); cell.accessoryType=(oled&&!custom)?UITableViewCellAccessoryCheckmark:UITableViewCellAccessoryNone; }
        else if (indexPath.row==2) { cell.textLabel.text=Nexus2Localized(@"Custom color"); cell.accessoryType=(oled&&custom)?UITableViewCellAccessoryCheckmark:UITableViewCellAccessoryNone; }
        else { cell.textLabel.text=Nexus2Localized(@"Choose color"); cell.detailTextLabel.text=NXCustomBackgroundHex(); cell.imageView.image=[UIImage systemImageNamed:@"paintpalette.fill"]; cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator; }
    } else {
        cell.textLabel.text=Nexus2Localized(@"Feed separators"); cell.imageView.image=[UIImage systemImageNamed:@"line.3.horizontal"];
        UISwitch *toggle=[UISwitch new]; toggle.on=NXIQFBool(@"iQFaceOLEDFeedSeparatorsEnabled",NO);
        [toggle addTarget:self action:@selector(nx_separatorsChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView=toggle; cell.selectionStyle=UITableViewCellSelectionStyleNone;
    }
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES]; if (indexPath.section!=0) return;
    if (indexPath.row==0) { NXSetCustomBackground(NO,nil); NXSetOLEDEnabled(NO); }
    else if (indexPath.row==1) { NXSetCustomBackground(NO,nil); NXSetOLEDEnabled(YES); }
    else if (indexPath.row==2) { NXSetOLEDEnabled(YES); NXSetCustomBackground(YES,nil); }
    else {
        UIColorPickerViewController *picker=[UIColorPickerViewController new]; picker.delegate=self;
        picker.selectedColor=NXColorFromHex(NXCustomBackgroundHex()); picker.supportsAlpha=NO;
        [self presentViewController:picker animated:YES completion:nil];
    }
    [self.tableView reloadData];
}
- (void)colorPickerViewControllerDidSelectColor:(UIColorPickerViewController *)viewController {
    NXSetOLEDEnabled(YES); NXSetCustomBackground(YES,NXHexFromColor(viewController.selectedColor)); [self.tableView reloadData];
}
- (void)colorPickerViewControllerDidFinish:(UIColorPickerViewController *)viewController {
    NXSetOLEDEnabled(YES); NXSetCustomBackground(YES,NXHexFromColor(viewController.selectedColor)); [self.tableView reloadData];
}
- (void)nx_separatorsChanged:(UISwitch *)sender { NXSetIQFBool(@"iQFaceOLEDFeedSeparatorsEnabled",sender.isOn); }
@end

'''
s=s[:start]+appearance+s[end:]

p.write_text(s,encoding='utf-8')
for marker in ['NexusVersion = @"2.3 Beta 1"','v2.3 Beta 1','adaptive custom background (2.3 Beta 1)',
               'UIColorPickerViewController','NexusCustomBackgroundEnabled','NexusCustomBackgroundColor','Custom color','Choose color']:
    assert marker in s
