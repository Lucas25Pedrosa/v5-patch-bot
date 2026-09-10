from pathlib import Path

path = Path("Tweak.m")
source = path.read_text(encoding="utf-8")

replacements = [
    (
        """// iQFaceCache 0.2.0-beta1
// Native add-on for the iQFace settings UI.
// Adds native rows to the Tools section of IQFSettingsViewController.
// Cleaning remains restricted to the two validated Facebook cache directories.
//
// Beta behavior:
//   - automatic options remain Nunca / Diariamente / Semanalmente / Mensalmente
//   - every enabled option uses a 1-hour interval for easier testing
//   - automatic cleaning shows a confirmation alert after it runs
//
// Production behavior will restore 24 h / 7 d / 30 d and remove the automatic alert.
""",
        """// iQFaceCache 0.2.0
// Native add-on for the iQFace settings UI.
// Adds native rows to the Tools section of IQFSettingsViewController.
// Cleaning remains restricted to the two validated Facebook cache directories.
// Automatic cleaning uses the production intervals: 24 h / 7 d / 30 d.
// Automatic runs are silent; manual cleaning keeps its result confirmation.
""",
    ),
    (
        """static NSTimeInterval IQFCCacheAutomaticInterval(void) {
    // Beta: every enabled option is intentionally shortened to one hour.
    return IQFCCacheAutomaticMode() == IQFCCacheAutoModeNever ? 0.0 : 3600.0;
}
""",
        """static NSTimeInterval IQFCCacheAutomaticInterval(void) {
    switch (IQFCCacheAutomaticMode()) {
        case IQFCCacheAutoModeDaily:
            return 86400.0;
        case IQFCCacheAutoModeWeekly:
            return 604800.0;
        case IQFCCacheAutoModeMonthly:
            return 2592000.0;
        case IQFCCacheAutoModeNever:
        default:
            return 0.0;
    }
}
""",
    ),
    (
        """static void IQFCCachePresentAutomaticBetaResult(unsigned long long freed,
                                                NSUInteger errorCount) {
    UIViewController *controller = IQFCCacheTopViewController();
    if (controller == nil || controller.view.window == nil ||
        [controller isKindOfClass:UIAlertController.class] ||
        controller.presentedViewController != nil) {
        return;
    }

    NSString *title = IQFCCacheText(@"Limpeza automática — Beta", @"Automatic cleaning — Beta");
    NSString *message = [NSString stringWithFormat:
                         IQFCCacheText(@"A limpeza automática foi realizada.\\n\\n%@ liberados",
                                       @"Automatic cleaning completed.\\n\\n%@ freed"),
                         IQFCCacheHumanBytes(freed)];
    if (errorCount > 0) {
        message = [message stringByAppendingString:
                   IQFCCacheText(@"\\n\\nAlguns arquivos estavam em uso.",
                                 @"\\n\\nSome files were in use.")];
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [controller presentViewController:alert animated:YES completion:nil];
}

""",
        "",
    ),
    (
        """            if (automatic) {
                IQFCCacheMarkAutomaticCleaningNow();
                IQFCCachePresentAutomaticBetaResult(freed, errors.count);
            } else {
""",
        """            if (automatic) {
                IQFCCacheMarkAutomaticCleaningNow();
            } else {
""",
    ),
    (
        """        // Start the one-hour beta countdown when the user selects a mode.
        [defaults setDouble:NSDate.date.timeIntervalSince1970 forKey:IQFCCacheLastAutomaticCleaningKey];
""",
        """        // Any frequency change starts a fresh countdown from this moment.
        [defaults setDouble:NSDate.date.timeIntervalSince1970 forKey:IQFCCacheLastAutomaticCleaningKey];
""",
    ),
    (
        """    NSString *message = IQFCCacheText(
        @"Para facilitar o teste, qualquer opção automática ativa executa a limpeza a cada 1 hora neste beta.",
        @"For easier testing, any enabled automatic option runs every 1 hour in this beta."
    );
""",
        """    NSString *message = nil;
""",
    ),
]

for old, new in replacements:
    count = source.count(old)
    if count != 1:
        raise SystemExit(f"Expected exactly one match, found {count}: {old.splitlines()[0]}")
    source = source.replace(old, new, 1)

for forbidden in (
    "0.2.0-beta1",
    "3600.0",
    "Limpeza automática — Beta",
    "Automatic cleaning — Beta",
    "A limpeza automática foi realizada.",
    "Automatic cleaning completed.",
    "one-hour beta countdown",
    "Para facilitar o teste",
    "For easier testing",
):
    if forbidden in source:
        raise SystemExit(f"Beta behavior still present: {forbidden}")

for required in (
    "iQFaceCache 0.2.0",
    "86400.0",
    "604800.0",
    "2592000.0",
    "Limpar cache automaticamente",
    "IQFCCacheMarkAutomaticCleaningNow();",
):
    if required not in source:
        raise SystemExit(f"Missing final marker: {required}")

path.write_text(source, encoding="utf-8")
print("Prepared iQFaceCache 0.2.0 final with real intervals and silent automatic cleaning.")
