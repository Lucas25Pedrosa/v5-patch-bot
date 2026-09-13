from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text(encoding="utf-8")

marker = '''static BOOL IQF11ContainsIQF(NSString *value) {
    if (value.length == 0) return NO;
    NSString *lower = value.lowercaseString;
    return [lower containsString:@"iqface"] || [lower containsString:@"iqf"];
}
'''
assert marker in s
replacement = marker + '''
static BOOL IQF11IsProtectedIQFaceAction(NSString *value) {
    if (value.length == 0) return NO;
    return [value isEqualToString:@"iqfDismiss"];
}
'''
s = s.replace(marker, replacement, 1)

old_control = '''        for (NSString *action in actions) {
            if (IQF11ContainsIQF(action)) return YES;
        }
'''
new_control = '''        for (NSString *action in actions) {
            if (IQF11IsProtectedIQFaceAction(action)) continue;
            if (IQF11ContainsIQF(action)) return YES;
        }
'''
assert old_control in s
s = s.replace(old_control, new_control, 1)

old_item = '''    if (item.action != NULL && IQF11ContainsIQF(NSStringFromSelector(item.action))) {
        return YES;
    }
'''
new_item = '''    if (item.action != NULL) {
        NSString *actionName = NSStringFromSelector(item.action);
        if (IQF11IsProtectedIQFaceAction(actionName)) return NO;
        if (IQF11ContainsIQF(actionName)) return YES;
    }
'''
assert old_item in s
s = s.replace(old_item, new_item, 1)

assert 'IQF11IsProtectedIQFaceAction' in s
assert '@"iqfDismiss"' in s
p.write_text(s, encoding="utf-8")
