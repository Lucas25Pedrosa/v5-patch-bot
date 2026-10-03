from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text(encoding="utf-8")

marker = '#import <QuartzCore/QuartzCore.h>\n'
if marker not in s:
    raise SystemExit("import marker missing")
s = s.replace(marker, marker + '\nextern NSString *Nexus2Localized(NSString *key);\n', 1)

replacements = {
    'return @"Padrão";': 'return Nexus2Localized(@"Default");',
    '@"title": @"Padrão",': '@"title": Nexus2Localized(@"Default"),',
    'self.title = @"Alterar ícone";': 'self.title = Nexus2Localized(@"Change Icon");',
    'initWithTitle:@"Fechar"': 'initWithTitle:Nexus2Localized(@"Close")',
    '[self iqficons_error:@"O iOS não permite alterar o ícone deste aplicativo."];':
        '[self iqficons_error:Nexus2Localized(@"iOS does not allow changing this app icon.")];',
    'error.localizedDescription ?: @"Não foi possível alterar o ícone."':
        'error.localizedDescription ?: Nexus2Localized(@"Could not change icon")',
}
for old, new in replacements.items():
    if old not in s:
        raise SystemExit(f"icon picker marker missing: {old}")
    s = s.replace(old, new, 1)

p.write_text(s, encoding="utf-8")
print("Localized Nexus 2.0 icon picker")
