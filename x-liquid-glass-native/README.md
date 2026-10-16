# XLiquidGlassNative 3.0 - Distribution Edition

Clean native Liquid Glass activation variant for X, based directly on XLiquidGlassNative 3.0.

## Goal

Expose the native Liquid Glass redesign already present inside X without adding compatibility, navigation, badge, sidebar, blur or other visual/runtime fixes of our own.

The Distribution Edition keeps the 3.0 activation code and Appearance submenu unchanged. Its only additional behavior is the NeoFreeBird credits block used for distribution.

## NeoFreeBird integration

There is no standalone Liquid Glass entry on the NeoFreeBird root settings page.

Open:

`NeoFreeBird -> Appearance -> Liquid Glass`

The `Liquid Glass` button is inserted in the native NeoFreeBird Appearance page after the Theme, App Icon and Custom Tab Bar entries, matching the older XLiquidGlass placement.

Inside the submenu there is only one option: enable or disable Liquid Glass. The default state is ON. Restart X after changing the switch so the full interface is rebuilt with the selected state.

## Distribution credits

The NeoFreeBird root settings page receives the same two credit sections used by the previous distribution build, with polished public labels:

- `Liquid Glass` -> `Lucas` (`@Lucas25Pedrosa`), avatar from GitHub and tap action to `https://github.com/Lucas25Pedrosa`
- `IPA Source` -> `IPA Vault` (`@ipavault`), avatar from GitHub and tap action to `https://t.me/ipavault`

The public display name is `Lucas`, while the username and redirect remain `Lucas25Pedrosa`.

The credits are implemented in the separate `XLiquidGlassDistributionCredits.m` source file so they remain isolated from the Liquid Glass activation code and can be audited independently.

## Compact settings UI

The Liquid Glass row uses smaller title/detail typography, allows the description to use two lines, scales long titles when necessary and uses a smaller footer so translations do not overflow the cell.

## Languages

The settings page follows the NeoFreeBird language set and also preserves Portuguese compatibility:

- Arabic
- German
- English
- Spanish
- French
- Croatian
- Indonesian
- Japanese
- Korean
- Polish
- Portuguese
- Russian
- Swedish
- Turkish
- Ukrainian
- Traditional Chinese
- Simplified Chinese

Unsupported system languages fall back to English.

## What it activates when enabled

- `T1LiquidGlassDebugSettings +useTabBarControllerEnabled` -> enabled
- `TFSUtilitiesSwift.LiquidGlass +isEnabled` -> enabled
- `T1TwitterSwift.LiquidGlassRedesignFeatures -isRedesignEnabled` -> enabled
- `T1LiquidGlassGateInstaller +installGateWithRedesignEnabled:` -> native installer forced ON
- `T1LiquidGlassGateInstaller +installGateForAccount:` -> original account install, then native redesign gate ON
- `TFNTwitterAccount -isDummyTest1FeatureEnabled` -> native account gate forced ON while enabled
- `T1LiquidGlassRedesignPersistedGate` -> enabled
- `LiquidGlassCompatibilityOverride +applyOverrideIfNeeded` when available

When disabled, the persisted Liquid Glass gate is removed and the activation hooks stop forcing the redesign. The original account-gate behavior is preserved where an original implementation exists.

## Intentionally not included

No sidebar fix, edge-swipe fix, badge bridge/fix, multi-account badge logic, navigation routing/host fix, tab-label behavior, selection chrome changes, avatar styling changes, blur changes, root-tab routing, legacy navigation compatibility or any other visual/runtime patch.

The retry schedules exist only because X loads some native gate and NeoFreeBird settings classes after tweak construction; they do not alter X UI behavior outside the requested settings/credits integration.

## Usage

Inject **XLiquidGlassNative.dylib** into X. Do not inject it together with another XLiquidGlass build that hooks the same activation gates.
