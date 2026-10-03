from pathlib import Path
import re
import sys

p = Path(sys.argv[1])
s = p.read_text(encoding="utf-8")

s = s.replace(
    "// Nexus 1.0.2 avatar fix, carried over from the validated FBOLED 0.2.4 test.",
    "// Nexus 2.0 avatar fix, carried over from the validated FBOLED 0.2.4 test.",
    1,
)

old_pref = '''static BOOL NexusAvatarOLEDEnabled(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults objectForKey:@"iQFaceOLEDEnabled"] == nil) return YES;
    return [defaults boolForKey:@"iQFaceOLEDEnabled"];
}'''
new_pref = '''extern BOOL Nexus2BackgroundEffectActive(void);

static BOOL NexusAvatarOLEDEnabled(void) {
    return Nexus2BackgroundEffectActive();
}'''
if old_pref not in s:
    raise SystemExit("avatar preference function not found")
s = s.replace(old_pref, new_pref, 1)

timer = "static NSTimer *gNexusAvatarTimer;"
if timer not in s:
    raise SystemExit("avatar timer marker not found")
s = s.replace(
    timer,
    timer + '''
static BOOL gNexus2AvatarHooksInstalled = NO;

__attribute__((used, visibility("default")))
BOOL Nexus2AvatarHooksInstalled(void) {
    return gNexus2AvatarHooksInstalled;
}''',
    1,
)

pattern = re.compile(
    r'static void NexusAvatarInstallImmediateHooks\(void\) \{.*?\n\}',
    re.S,
)
replacement = '''static void NexusAvatarInstallImmediateHooks(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method addSubviewOriginal = class_getInstanceMethod(UIView.class, @selector(addSubview:));
        Method addSubviewReplacement = class_getInstanceMethod(UIView.class, @selector(nexus_avatar_addSubview:));
        Method setImageOriginal = class_getInstanceMethod(UIImageView.class, @selector(setImage:));
        Method setImageReplacement = class_getInstanceMethod(UIImageView.class, @selector(nexus_avatar_setImage:));

        BOOL addSubviewReady = addSubviewOriginal != NULL && addSubviewReplacement != NULL;
        BOOL setImageReady = setImageOriginal != NULL && setImageReplacement != NULL;

        if (addSubviewReady) {
            method_exchangeImplementations(addSubviewOriginal, addSubviewReplacement);
        }
        if (setImageReady) {
            method_exchangeImplementations(setImageOriginal, setImageReplacement);
        }
        gNexus2AvatarHooksInstalled = addSubviewReady && setImageReady;
    });
}'''
s, n = pattern.subn(replacement, s, count=1)
if n != 1:
    raise SystemExit(f"avatar hook function replacement count={n}")

for marker in [
    "Nexus2BackgroundEffectActive",
    "Nexus2AvatarHooksInstalled",
    "gNexus2AvatarHooksInstalled = addSubviewReady && setImageReady",
]:
    if marker not in s:
        raise SystemExit(f"missing avatar v2 marker: {marker}")

p.write_text(s, encoding="utf-8")
print("Prepared Nexus 2.0 avatar fix")
