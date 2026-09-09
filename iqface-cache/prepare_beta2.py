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
        """// iQFaceCache 0.2.0-beta2
// Native add-on for the iQFace settings UI.
// Adds native rows to the Tools section of IQFSettingsViewController.
// Cleaning remains restricted to the two validated Facebook cache directories.
//
// Beta 2 behavior:
//   - automatic options remain Nunca / Diariamente / Semanalmente / Mensalmente
//   - real intervals are active: 24 h / 7 d / 30 d
//   - automatic cleaning still shows a confirmation alert for validation
//
// Final production behavior keeps these intervals and removes only the automatic alert.
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
        """    NSString *message = IQFCCacheText(
        @"Intervalos reais deste beta: Diariamente = 24 horas, Semanalmente = 7 dias e Mensalmente = 30 dias. O aviso de cache limpo permanece ativo para validação.",
        @"Real intervals in this beta: Daily = 24 hours, Weekly = 7 days, and Monthly = 30 days. The cache-cleaned alert remains enabled for validation."
    );
""",
    ),
    (
        """    NSString *title = IQFCCacheText(@"Limpeza automática — Beta", @"Automatic cleaning — Beta");
""",
        """    NSString *title = IQFCCacheText(@"Limpeza automática — Beta 2", @"Automatic cleaning — Beta 2");
""",
    ),
]

for old, new in replacements:
    count = source.count(old)
    if count != 1:
        raise SystemExit(f"Expected exactly one match, found {count}: {old.splitlines()[0]}")
    source = source.replace(old, new, 1)

for forbidden in ("return IQFCCacheAutomaticMode() == IQFCCacheAutoModeNever ? 0.0 : 3600.0;", "every enabled option uses a 1-hour interval"):
    if forbidden in source:
        raise SystemExit(f"Beta 1 behavior still present: {forbidden}")

for required in ("0.2.0-beta2", "86400.0", "604800.0", "2592000.0", "Limpeza automática — Beta 2"):
    if required not in source:
        raise SystemExit(f"Missing beta 2 marker: {required}")

path.write_text(source, encoding="utf-8")
print("Prepared iQFaceCache 0.2.0-beta2 with real automatic intervals.")
