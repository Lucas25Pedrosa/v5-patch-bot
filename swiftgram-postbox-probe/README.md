# SwiftgramPostboxProbe 0.1

Passive diagnostic dylib for the Swiftgram 13.0 (319) crash seen on iOS 27.2 beta.

Known crash signature:

- `EXC_BREAKPOINT / SIGTRAP`
- queue: `org.telegram.postbox.Postbox`
- `TelegramCoreFramework` UUID: `D8A0C19B-0918-336A-A542-9E30416542EC`
- fault PC: `TelegramCoreFramework + 0x908638`

The on-disk Swiftgram 13.0 binary does **not** contain a `BRK` at that address. The probe therefore monitors the first 32 bytes of that exact function in memory and compares them with the pristine binary.

If a runtime hook changes the function entry, the probe logs the mutation and attempts to decode common ARM64 hook trampolines (`B`, `BL`, `LDR x16 / BR x16`) and resolve the destination image with `dladdr`. This can identify whether the crash entry was redirected into iQTele, iQTeleLocation, iQSwiftEnhancer, iqKeepDeleted, or another injected image.

The probe also records:

- Swiftgram version/build
- iOS version/build and device model
- UUID/base/path of TelegramCore, Postbox, SwiftSignalKit and relevant injected dylibs
- app lifecycle events
- Objective-C uncaught exceptions
- a heartbeat every ~2 seconds showing whether the target is still pristine

Log file inside the app sandbox:

`Documents/SwiftgramPostboxProbe.log`

Crash recovery: if the previous probe session did not terminate normally, the next Swiftgram launch copies the previous probe log to the clipboard and shows a short recovery alert.

This probe does not hook TelegramCore/Postbox functions and does not attempt to fix the crash. It only observes runtime code integrity and state.
