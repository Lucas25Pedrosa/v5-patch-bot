from pathlib import Path
import re
import sys

p = Path(sys.argv[1])
s = p.read_text(encoding="utf-8")

# Keep the PT-BR Nexus presentation, but target iQFace 1.2's settings controller
# construction path instead of the iQFace 1.1-only +[IQFTweakSettings sections] hook.
s = s.replace('NexusVersion = @"1.0.1"', 'NexusVersion = @"1.0.2"', 1)
s = s.replace('setValue:@"v1.0.1" forKey:@"valueText"', 'setValue:@"v1.0.2" forKey:@"valueText"', 1)

old_decl = '''static NSArray *(*NexusOriginalSections)(id, SEL) = NULL;
static BOOL NexusHookInstalled = NO;
static NSInteger NexusHookAttempts = 0;'''
new_decl = '''static id (*NexusOriginalInitWithBuilder)(id, SEL, id, id) = NULL;
static id (*NexusOriginalInitWithSections)(id, SEL, id, id) = NULL;
static BOOL NexusBuilderHookInstalled = NO;
static BOOL NexusSectionsHookInstalled = NO;
static NSInteger NexusHookAttempts = 0;'''
if old_decl not in s:
    raise SystemExit("legacy Nexus settings hook declarations not found")
s = s.replace(old_decl, new_decl, 1)

start = s.find("static NSArray *NexusTweakSections")
if start < 0:
    raise SystemExit("legacy NexusTweakSections block not found")

replacement = r'''typedef NSArray * _Nullable (^NexusSectionsBuilder)(void);

static BOOL NexusLooksLikeIQFaceSettingsTitle(id title) {
    if (![title isKindOfClass:NSString.class]) return NO;
    NSString *normalized = [(NSString *)title lowercaseString];
    return [normalized containsString:@"iqface"];
}

static id NexusInitWithTitleSections(id self, SEL command, id title, id sections) {
    if (NexusOriginalInitWithSections == NULL) return nil;

    id adjusted = sections;
    if (NexusLooksLikeIQFaceSettingsTitle(title) && [sections isKindOfClass:NSArray.class]) {
        adjusted = NexusSectionsWithAdditions((NSArray *)sections);
    }

    return NexusOriginalInitWithSections(self, command, title, adjusted);
}

static id NexusInitWithTitleSectionsBuilder(id self, SEL command, id title, id builder) {
    if (NexusOriginalInitWithBuilder == NULL) return nil;

    if (!NexusLooksLikeIQFaceSettingsTitle(title) || builder == nil) {
        return NexusOriginalInitWithBuilder(self, command, title, builder);
    }

    NexusSectionsBuilder originalBuilder = [builder copy];
    NexusSectionsBuilder wrappedBuilder = [^NSArray *{
        NSArray *nativeSections = originalBuilder != nil ? originalBuilder() : nil;
        return NexusSectionsWithAdditions(nativeSections);
    } copy];

    return NexusOriginalInitWithBuilder(self, command, title, wrappedBuilder);
}

static void NexusTryInstallHooks(void) {
    NexusHookAttempts += 1;

    Class target = NSClassFromString(@"IQFSettingsViewController");
    if (target != Nil) {
        SEL builderSelector = NSSelectorFromString(@"initWithTitle:sectionsBuilder:");
        Method builderMethod = class_getInstanceMethod(target, builderSelector);
        if (!NexusBuilderHookInstalled && builderMethod != NULL) {
            NexusOriginalInitWithBuilder =
                (id (*)(id, SEL, id, id))method_getImplementation(builderMethod);
            method_setImplementation(builderMethod, (IMP)&NexusInitWithTitleSectionsBuilder);
            NexusBuilderHookInstalled = YES;
        }

        SEL sectionsSelector = NSSelectorFromString(@"initWithTitle:sections:");
        Method sectionsMethod = class_getInstanceMethod(target, sectionsSelector);
        if (!NexusSectionsHookInstalled && sectionsMethod != NULL) {
            NexusOriginalInitWithSections =
                (id (*)(id, SEL, id, id))method_getImplementation(sectionsMethod);
            method_setImplementation(sectionsMethod, (IMP)&NexusInitWithTitleSections);
            NexusSectionsHookInstalled = YES;
        }
    }

    if (!NexusBuilderHookInstalled && !NexusSectionsHookInstalled && NexusHookAttempts < 120) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ NexusTryInstallHooks(); });
    }
}

__attribute__((constructor))
static void NexusInitialize(void) {
    @autoreleasepool {
        if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.facebook.Facebook"] ||
            [NSBundle.mainBundle.bundlePath hasSuffix:@".appex"]) {
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{ NexusTryInstallHooks(); });
    }
}
'''

s = s[:start] + replacement

required = [
    'NexusVersion = @"1.0.2"',
    'setValue:@"v1.0.2" forKey:@"valueText"',
    'NSClassFromString(@"IQFSettingsViewController")',
    'initWithTitle:sectionsBuilder:',
    'initWithTitle:sections:',
    'NexusSectionsWithAdditions(nativeSections)',
]
for marker in required:
    if marker not in s:
        raise SystemExit(f"missing iQFace 1.2 marker: {marker}")

forbidden = [
    'NSClassFromString(@"IQFTweakSettings")',
    'NexusOriginalSections',
    'NexusTweakSections',
]
for marker in forbidden:
    if marker in s:
        raise SystemExit(f"legacy iQFace 1.1 settings integration remains: {marker}")

p.write_text(s, encoding="utf-8")
print("Prepared Nexus 1.0.2 settings integration for iQFace 1.2")
