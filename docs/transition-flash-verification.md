# Transition residual fixes

Baseline: `8371829` (remote main). Linux has no Xcode; Swift build, XCTest and UI results must come from GitHub Actions. Device checks below remain pending until performed on hardware.

## Causes and changes

1. **Detail appearance:** baseline `CollectionPage.swift:62` emitted `preferredColorScheme(.dark)` from the album/playlist List. `LibraryView.swift:577` embeds that destination in a NavigationStack inside `DetailZoomCard`, an overlay rather than a sheet. The overlay does not introduce a presentation boundary: the preference reaches the shared window. Remove the preference entirely. `CollectionArtworkColor` resolves the sampled hue into a light tint under light appearance and preserves the dark palette under dark appearance; text and playlist controls use semantic foreground colors. Detail slot geometry and radius are unchanged.
2. **Collapse background:** baseline `PlayerCard.swift:86–88` proposed the shrinking card dimensions to `NowPlayingBackground`, while expanded controls retained full-screen dimensions at line 94. The background's bottom dark gradient therefore moved upward as its height compressed, over a second regular-material backing at line 77. The card now crops one full-screen backdrop into its moving bounds; its texture and gradient retain the same coordinates as expanded content. The extra material layer is removed. No edits to `NowPlayingView.swift`, its scrolling morph, or playback logic.
3. **Bottom chrome:** baseline `LibraryView.swift:156–162` measured an invisible native accessory, then moved an independently glassed mini in the root overlay. Asynchronous frame updates and inline/expanded placement changes could disagree with the native animation. The search-role tab at baseline line 189 also requested a detached search button. The visible resting mini now lives inside the native accessory and responds there to placement. Only player presentation uses the measured-frame overlay; animation completion transfers ownership back to the native mini in one state update. Search remains a regular fourth tab with its existing search page and reselection behavior. Both iOS 26 paths retain `.tabBarMinimizeBehavior(.onScrollDown)`.

These are source-level causes and corrections, not a claim that the original video has been reproduced on this Linux machine. The final grouped appearance and absence of transient chrome overlap require the hardware check below.

## Apple alignment

- [preferredColorScheme](https://developer.apple.com/documentation/swiftui/view/preferredcolorscheme(_:)): a preference targets the enclosing presentation, not just the modified view. Detail tint should be local paint under inherited appearance.
- [tabViewBottomAccessory](https://developer.apple.com/documentation/swiftui/view/tabviewbottomaccessory(content:)): the system places an accessory above the expanded bar and inline with the minimized bar. Hosting visible content there keeps it in the system animation.
- [Build a UIKit app with the new design](https://developer.apple.com/videos/play/wwdc2025/284/): native accessory views animate alongside the tab bar; the app does not need an independently positioned resting mini.

## Automated coverage and thresholds

`PlayerCardRenderingTests` covers both appearances, drag/spring samples, and serial handover. New collapse samples test four vertical positions through the card, including the lower region: RGB tolerance is 3/255. A proportional lower dark band must stay at its full-screen y=540 rather than compress upward. Existing textured artwork/clip tests remain in place.

Detail zoom pixel samples run forward and backward at progress 0, .15, .35, .65 and .85. Outside the growing card, each light RGB channel must exceed 220/255 (allowing only the intentional 12% dim); each dark channel must remain below 8/255. A separate hosted-window test uses the actual `CollectionPage` in a navigation overlay at 0, .2, .5, .8 and 1 in both directions, allowing 100 ms for preference propagation and requiring the window and hosting controller to stay light. Tint brightness must be at least .93 in light appearance.

`GlassScreenshots.testNativeBottomAccessoryHasOneMiniAcrossScrollAndReturn` asserts exactly one accessible mini and one tab bar after repeated scroll-down/return gestures and one mini after player landing; it saves inline and expanded screenshots. These settled-state assertions do not prove every intermediate animation frame. Continuous native animation and physical glass appearance need visual verification.

## Device checklist (not yet performed)

Record slow-motion opening/closing of albums and playlists in light appearance: underlying library stays light throughout, with no black/white flash; detail uses light artwork tint. Repeat in dark appearance.

Slowly pull the player closed, pause/reverse the drag, release and interrupt a close by reopening. The card must show continuous blurred artwork through its lower region until the mini takes over, without a rectangular dark patch.

Scroll down and back to the top repeatedly in library, playlists, favorites and search. The minimized chrome must read as one coherent native bottom group, without a separate search orb or displaced mini. Check intermediate frames for duplicate bars, flashes or overlap. Confirm search typing and tapping the selected search tab still work.

Repeat all three checks with accessibility text sizes and Reduce Motion, including a missing-artwork track and both inline/expanded starting slots. Check iOS 26.0 and 26.1+ accessory paths, and the iOS 17–25 material fallback where available.
