from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text(encoding='utf-8')
s=s.replace('NexusVersion = @"2.1"','NexusVersion = @"2.3 Beta 1"')
s=s.replace('@"Nexus 2.1\\nFacebook %@ (%@)', '@"Nexus 2.3 Beta 1\\nFacebook %@ (%@)')
s=s.replace('engine: run52 legacy OLED', 'engine: adaptive custom background (2.3 Beta 1)')
s=s.replace('[setting setValue:@"v2.1" forKey:@"valueText"]', '[setting setValue:@"v2.3 Beta 1" forKey:@"valueText"]')
s=s.replace('@"nexusVersion": @"2.1"', '@"nexusVersion": @"2.3 Beta 1"')
s=s.replace('Nexus 2.1 loaded', 'Nexus 2.3 Beta 1 loaded')
p.write_text(s,encoding='utf-8')
for marker in ['NexusVersion = @"2.3 Beta 1"','v2.3 Beta 1','adaptive custom background (2.3 Beta 1)']:
    assert marker in s
