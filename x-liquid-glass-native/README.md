# XLiquidGlassNative

Activation-only Liquid Glass variant for X.

## Goal

Expose the native Liquid Glass redesign already present inside X without adding compatibility or visual behavior of our own.

## What it activates

- `T1LiquidGlassDebugSettings +useTabBarControllerEnabled` -> `YES`
- `TFSUtilitiesSwift.LiquidGlass +isEnabled` -> `YES`
- `T1TwitterSwift.LiquidGlassRedesignFeatures -isRedesignEnabled` -> `YES`
- `T1LiquidGlassGateInstaller +installGateWithRedesignEnabled:` -> native installer forced ON
- `T1LiquidGlassGateInstaller +installGateForAccount:` -> original account install, then native redesign gate ON
- `TFNTwitterAccount -isDummyTest1FeatureEnabled` -> `YES` (native account gate observed in the activation path)
- `T1LiquidGlassRedesignPersistedGate` -> `YES`
- `LiquidGlassCompatibilityOverride +applyOverrideIfNeeded` when available

## Intentionally not included

No sidebar/swipe fix, badge bridge/fix, navigation host fix, tab-label behavior, blur changes, root-tab routing, legacy navigation compatibility, custom settings UI, or any other visual/runtime patch.

The retry schedule exists only because X loads some of the native gate classes after tweak construction; it does not alter UI behavior.

## Usage

Inject **XLiquidGlassNative.dylib** into X. Do not inject it together with another XLiquidGlass build that hooks the same activation gates.
