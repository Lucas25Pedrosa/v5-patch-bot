from pathlib import Path
import sys
src=Path(sys.argv[1]).read_text(encoding='utf-8')
lines=src.splitlines()
out=[]
for line in lines:
    if line.startswith('iQFace_FILES ='):
        out.append('Nexus_FILES = IconsTweak.m IconsPicker.m CacheTweak.m AdaptiveBackground.m Nexus2.m NexusAvatarFix.m')
    elif line.startswith('iQFace_'):
        out.append(line.replace('iQFace_','Nexus_',1))
    elif line.strip().startswith('TWEAK_NAME'):
        out.append('TWEAK_NAME = Nexus')
    else:
        out.append(line.replace('iQFace','Nexus'))
s='\n'.join(out)+'\n'
s=s.replace('@rpath/iQFace.dylib','@rpath/Nexus.dylib')
s=s.replace('OLEDTweak.m','').replace('EnhancerTweak.m','')
if '-Wno-unused-function' not in s:
    s += '\nNexus_CFLAGS += -Wno-unused-function -Wno-deprecated-declarations\n'
Path(sys.argv[2]).write_text(s,encoding='utf-8')
assert 'AdaptiveBackground.m' in s
assert 'OLEDTweak.m' not in s
assert 'FacebookPlusOLED.m' not in s
assert '@rpath/Nexus.dylib' in s or 'Nexus' in s
