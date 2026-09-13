from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text(encoding="utf-8")

s = s.replace('@"paperplane.fill"', '@"hammer.fill"', 1)

old_about = '''static id NexusCreateAboutVersion(void) {
    return NexusCreateStaticSetting(@"Nexus v1.0", nil, @"point.3.connected.trianglepath.dotted");
}'''
new_about = '''static id NexusCreateAboutVersion(void) {
    id setting = NexusCreateStaticSetting(@"Nexus", nil, @"point.3.connected.trianglepath.dotted");
    if (setting == nil) return nil;
    @try { [setting setValue:@"v1.0" forKey:@"valueText"]; }
    @catch (__unused NSException *exception) {}
    return setting;
}'''
if old_about not in s:
    raise SystemExit("about factory marker not found")
s = s.replace(old_about, new_about, 1)

s = s.replace('[NexusTitleForSetting(row) isEqualToString:@"Nexus v1.0"]',
              '[NexusTitleForSetting(row) isEqualToString:@"Nexus"]', 1)

old_order = '''        NSUInteger insertionIndex = rows.count;

        for (NSUInteger rowIndex = 0; rowIndex < rows.count; rowIndex++) {
            NSString *title = NexusTitleForSetting(rows[rowIndex]);
            NSString *normalized = title.lowercaseString;
            if ([normalized hasPrefix:@"iqface v1.1"]) {
                insertionIndex = rowIndex + 1;
                break;
            }
        }

        [rows insertObject:version atIndex:MIN(insertionIndex, rows.count)];'''
new_order = '''        NSUInteger insertionIndex = NSNotFound;
        NSUInteger facebookIndex = NSNotFound;

        for (NSUInteger rowIndex = 0; rowIndex < rows.count; rowIndex++) {
            NSString *title = NexusTitleForSetting(rows[rowIndex]);
            NSString *normalized = title.lowercaseString;
            if ([normalized isEqualToString:@"iqface"] || [normalized hasPrefix:@"iqface "]) {
                insertionIndex = rowIndex + 1;
                break;
            }
            if (facebookIndex == NSNotFound && [normalized isEqualToString:@"facebook"]) {
                facebookIndex = rowIndex;
            }
        }

        if (insertionIndex == NSNotFound) {
            insertionIndex = facebookIndex != NSNotFound ? facebookIndex : rows.count;
        }

        [rows insertObject:version atIndex:MIN(insertionIndex, rows.count)];'''
if old_order not in s:
    raise SystemExit("about ordering marker not found")
s = s.replace(old_order, new_order, 1)

assert '@"hammer.fill"' in s
assert 'setValue:@"v1.0" forKey:@"valueText"' in s
assert '[normalized isEqualToString:@"iqface"]' in s
p.write_text(s, encoding="utf-8")
print("Applied Nexus presentation v2 fixes")
