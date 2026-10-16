# XLiquidGlassNative

Clean native Liquid Glass activation variant for X.

## Goal

Expose the native Liquid Glass redesign already present inside X without adding compatibility, navigation, badge or visual fixes of our own.

The only non-activation feature included is a NeoFreeBird settings entry with a single toggle to enable or disable Liquid Glass.

## NeoFreeBird toggle

The tweak adds a `Liquid Glass` entry to `ModernSettingsViewController`.

Inside it there is only one option:

- `Ativar Liquid Glass`

The default state is ON. After changing the switch, restart X so the full interface is rebuilt with the selected state.

## What it activates when enabled

- `T1LiquidGlassDebugSettings +useTabBarControllerEnabled` -> `YES`
- `TFSUtilitiesSwift.LiquidGlass +isEnabled` -> `YES`
- `T1TwitterSwift.LiquidGlassRedesignFeatures -isRedesignEnabled` -> `YES`
- `T1LiquidGlassGateInstaller +installGateWithRedesignEnabled:` -> native installer forced ON
- `T1LiquidGlassGateInstaller +installGateForAccount:` -> original account install, then native redesign gate ON
- `TFNTwitterAccount -isDummyTest1FeatureEnabled` -> native account gate forced ON while enabled
- `T1LiquidGlassRedesignPersistedGate` -> `YES`
- `LiquidGlassCompatibilityOverride +applyOverrideIfNeeded` when available

When disabled, the persisted Liquid Glass gate is removed and the activation hooks stop forcing the redesign. The original account-gate behavior is preserved where an original implementation exists.

## Intentionally not included

No sidebar fix, edge-swipe fix, badge bridge/fix, multi-account badge logic, navigation routing/host fix, tab-label behavior, selection chrome changes, avatar styling changes, blur changes, root-tab routing, legacy navigation compatibility or any other visual/runtime patch.

The retry schedule exists only because X loads some of the native gate and NeoFreeBird settings classes after tweak construction; it does not alter UI behavior.

## Usage

Inject **XLiquidGlassNative.dylib** into X. Do not inject it together with another XLiquidGlass build that hooks the same activation gates.
