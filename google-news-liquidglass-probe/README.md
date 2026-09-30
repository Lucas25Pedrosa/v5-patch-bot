# GoogleNewsLiquidGlassProbe 0.1

Read-only Liquid Glass probe for Google News 5.122 (5.122.1300).

Target bundle: `com.google.GoogleDigitalEditions`

The dylib observes and logs the original return values of:
- `+[M3CLiquidGlass isLiquidGlassAvailable]`
- `+[M3CLiquidGlass computeIsLiquidGlassAvailable]`
- `-[ASWPhenotypeFlagsImpl AppSwitching__enable_app_switching_liquid_glass]`
- `-[ASWPhenotypeFlagsImpl AppSwitching__enable_switcher_ui_liquid_glass]`
- `-[ASWPhenotypeFlagsImpl ExperienceKit__enable_experiencekit_liquid_glass]`

No value is forced or modified.

Runtime log:
`Documents/GoogleNewsLiquidGlassProbe.log`
