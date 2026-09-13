from pathlib import Path
import sys

src = Path(sys.argv[1])
out = Path(sys.argv[2])
s = src.read_text(encoding="utf-8")
old = '''        dispatch_async(dispatch_get_main_queue(), ^{
            IQFIconsTryInstallHook();
        });'''
assert old in s
s = s.replace(old, '        // Nexus owns settings integration.', 1)
s += '\n\nid NexusIconsCreateSetting(void) { return IQFIconsCreateNavigationSetting(); }\nid NexusIconsCreateIPAVaultSetting(void) { return IQFIconsCreateLinkButton(@"IPA Vault", @"IPA Source • Nexus Distributor", @"shippingbox.circle", @"https://t.me/ipavault"); }\n'
out.write_text(s, encoding="utf-8")
