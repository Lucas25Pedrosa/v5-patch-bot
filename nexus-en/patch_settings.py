from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text(encoding="utf-8")

s = s.replace('NexusVersion = @"1.0"', 'NexusVersion = @"1.0.1"', 1)
s = s.replace('@"Nexus v1.0"', '@"Nexus v1.0.1"')
s = s.replace('@"Desenvolvedor do Nexus"', '@"Nexus Developer"')

extern_marker = 'extern id NexusIconsCreateSetting(void);\n'
assert extern_marker in s
s = s.replace(extern_marker,
              extern_marker + 'extern id NexusIconsCreateIPAVaultSetting(void);\n',
              1)

marker = 'static void NexusAddAboutVersion(NSMutableArray *sections) {'
assert marker in s
helper = '''static void NexusAddIPAVaultCredit(NSMutableArray *sections) {
    for (NSUInteger i = 0; i < sections.count; i++) {
        id rawSection = sections[i];
        if (![rawSection isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *section = (NSDictionary *)rawSection;
        NSString *header = [section[@"header"] isKindOfClass:NSString.class] ? section[@"header"] : nil;
        if (!NexusIsDevHeader(header)) continue;

        NSArray *existingRows = [section[@"rows"] isKindOfClass:NSArray.class] ? section[@"rows"] : @[];
        for (id row in existingRows) {
            if ([NexusTitleForSetting(row) isEqualToString:@"IPA Vault"]) return;
        }

        id credit = NexusIconsCreateIPAVaultSetting();
        if (credit == nil) return;
        NSMutableArray *rows = [existingRows mutableCopy];
        NSUInteger insertionIndex = rows.count;
        for (NSUInteger rowIndex = 0; rowIndex < rows.count; rowIndex++) {
            if ([NexusTitleForSetting(rows[rowIndex]) isEqualToString:@"iQTweak"]) {
                insertionIndex = rowIndex + 1;
                break;
            }
        }
        [rows insertObject:credit atIndex:MIN(insertionIndex, rows.count)];
        NSMutableDictionary *updatedSection = [section mutableCopy];
        updatedSection[@"rows"] = [rows copy];
        sections[i] = [updatedSection copy];
        return;
    }
}

'''
s = s.replace(marker, helper + marker, 1)

call = '    NexusAddDeveloperCredit(updatedSections);\n    NexusAddAboutVersion(updatedSections);'
assert call in s
s = s.replace(call,
              '    NexusAddDeveloperCredit(updatedSections);\n    NexusAddIPAVaultCredit(updatedSections);\n    NexusAddAboutVersion(updatedSections);',
              1)

assert 'NexusVersion = @"1.0.1"' in s
assert '@"Nexus v1.0.1"' in s
assert '@"Nexus Developer"' in s
assert 'NexusIconsCreateIPAVaultSetting' in s
p.write_text(s, encoding="utf-8")
