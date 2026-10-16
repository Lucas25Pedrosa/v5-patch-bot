# XLiquidGlassNative 3.1

Stable native Liquid Glass activation for X, based on the clean 3.0 activation path and validated on X 12.35.

## Goal

Expose the native Liquid Glass redesign already present inside X and add only the validated Tab Bar coloring control, without reintroducing badge, sidebar, blur, navigation, legacy-host or other visual/runtime fixes.

## NeoFreeBird integration

Open:

`NeoFreeBird -> Appearance -> Liquid Glass`

The Liquid Glass entry remains inside NeoFreeBird Appearance.

The settings include:

- enable/disable Liquid Glass;
- Tab Bar coloring with three modes: `Nativa`, `Aba ativa` and `Todas as abas`.

`Aba ativa` and `Todas as abas` apply without requiring a restart. When switching back to `Nativa`, XLiquidGlassNative shows a notice asking the user to restart X so the original Tab Bar coloring is fully restored.

## Tab Bar coloring

The stable 3.1 implementation keeps the icon resolver proven in 3.1 Beta 2 and uses the active-tab model validated in XLiquidGlass 2.0.2.

For `Aba ativa`, the visible primary Tab Bar items remain on X's native inactive tint while the unlabeled Portal/Carried copies keep the NeoFreeBird accent color. X's own Liquid Glass portal reveals the accented copy for the currently active tab.

For `Todas as abas`, all supported Tab Bar icons use the selected NeoFreeBird theme color.

The tweak does not poll selection state and does not hook `updateSelection` or `setSelected:`.

## Credit

Only one custom credit is added:

- `Liquid Glass` -> `Lucas` (`@Lucas25Pedrosa`), with GitHub avatar and tap action to `https://github.com/Lucas25Pedrosa`.

No IPA Vault credit or IPA Source section is included.

## Languages

The Liquid Glass settings follow the existing localized 3.0 integration, including Portuguese and the NeoFreeBird language set.

## Native Liquid Glass activation

When enabled, the tweak preserves the clean 3.0 activation path, including the native Liquid Glass gates already present inside X.

## Intentionally not included

No badge fix, sidebar fix, blur fix, tab-label patch, pill/platter patch, navigation routing fix, legacy-host fix, selection hook, polling loop or other compatibility workaround is included.

## Usage

Inject **XLiquidGlassNative.dylib** into X. Do not inject it together with another XLiquidGlass build that hooks the same activation gates.

## Stable release

Version: **3.1.0**

Validated base: **3.1 Beta 8**

Target used during validation: **X 12.35**
