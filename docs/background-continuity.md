# Background continuity verification

## Layer audit

Source diagnosis against main `23b0adb`:

- `App/PlayerCard.swift:77–80` draws `.regularMaterial` at full opacity even at progress zero. This is the app-owned pale backing behind the entire mini, over the native accessory's glass. `App/LibraryView.swift:839–871` supplies mini content without its own background. Removing only a color from that content cannot fix the backing.
- `App/LibraryView.swift:165–180` uses the same clear measurement slot for iOS 26/26.1 accessories and the older `safeAreaInset`. `App/PlayerCard.swift:151–177` measures with `Color.clear`; it supplies no white fill. Inline placement changes only the measured height. The visible mini already lives in the common player overlay.
- `App/LibraryView.swift:183–201` leaves tab bar rendering to the system, without an app-supplied toolbar background. Native accessory/tab glass must also be inspected on device; source inspection cannot prove the host's runtime material.
- `App/CollectionPage.swift:59` uses the multi-color `ArtworkBackdrop` only for playlists. Its gradient and dark overlays (`App/NowPlayingView.swift:824–853`) do not produce a single color. Albums retain the system list background at `App/CollectionPage.swift:144`, omit a clear header row at lines 172–174, and never sample album artwork at lines 198–203.

The fix wraps the full sized collapsed content in `PlayerMiniGlass` (`App/PlayerCard.swift:126`): `GlassEffectContainer` plus `.glassEffect(.regular)` on iOS 26, and a shaped `.ultraThinMaterial` backdrop on older iOS. No translucent color substitutes for glass. The regular expanded backing hands over with the existing mini opacity, leaving the expanded artwork, clipping and geometry intact. Every tab and placement uses this one container. This follows Apple's [glassEffect API](https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:)).

Album and playlist pages share one opaque, brightness-limited cover color beneath transparent list/header/track/empty-state rows. Missing artwork uses the same fallback across the entire page. Both pages use dark text appearance on that dark sampled color, regardless of system appearance. Row layouts, artwork dimensions, controls and detail-card geometry are unchanged.

If device inspection still shows an opaque native accessory behind this surface, stop and report the OS/placement and the accessory call at `App/LibraryView.swift:167` or `:171`. Do not hide private UIKit backgrounds or relocate the slot without user agreement. A possible follow-up is to reserve geometry outside the native accessory and retain the visible glass mini in the shared overlay; that structural change is not included here.

## Validation

Linux has no Xcode: no local iOS build or runtime test is claimed. Existing player rendering and interaction tests run in GitHub Actions. The screenshot suite additionally captures scrolled songs, album and playlist details, plus mini presence on favorites/search. Screenshots are review evidence, not automated assertions of blur quality.

Physical-device checklist (pending):

- [ ] Library/songs scroll beneath the mini with frosted content visible, no opaque white/gray board. Match the brief's photo-5 glass state; photo-3 is the defect.
- [ ] Repeat on library, playlists, favorites and search, including accessory expanded/inline and pre-iOS 26 safeAreaInset fallback. Inspect the mini and tab bar together.
- [ ] Album and playlist details keep exactly one page color from header through all rows and bottom overscroll, before/after scrolling.
- [ ] Light/dark system appearance, large Dynamic Type, empty playlist, missing artwork and custom playlist artwork: readable text, one background.
- [ ] Expand/collapse, slow/reversed pull, spring landing and Reduce Motion retain player behavior and expanded artwork/corners.
- [ ] Album/playlist artwork card opens/closes to the same grid slot, including repeated opens.

The requested branch name was already present locally and remotely with an older material-only fix. `codex/bg-continuity-glass` was created directly from current `origin/main`, preserving that branch without force pushes.
