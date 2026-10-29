# Transition residual fixes

Baseline: `8371829` (remote main). Linux has no Xcode; Swift build, XCTest and UI results must come from GitHub Actions. Device checks below remain pending until performed on hardware.

## Causes and changes

1. **Detail appearance:** baseline `CollectionPage.swift:62` emitted `preferredColorScheme(.dark)` from the album/playlist List. `LibraryView.swift:577` embeds that destination in a NavigationStack inside `DetailZoomCard`, an overlay rather than a sheet. The overlay does not introduce a presentation boundary: the preference reaches the shared window. Remove the preference entirely. `CollectionArtworkWash` paints a blurred cover under appearance-specific brightness veils; text and playlist controls use semantic foreground colors. Detail slot geometry and radius are unchanged.
2. **Collapse background:** baseline `PlayerCard.swift:86–88` proposed the shrinking card dimensions to `NowPlayingBackground`, while expanded controls retained full-screen dimensions at line 94. The background's bottom dark gradient therefore moved upward as its height compressed, over a second regular-material backing at line 77. The card now crops one full-screen backdrop into its moving bounds; its texture and gradient retain the same coordinates as expanded content. The extra material layer is removed. No edits to `NowPlayingView.swift`, its scrolling morph, or playback logic.
3. **Bottom chrome:** baseline `LibraryView.swift:156–162` measured an invisible native accessory, then moved an independently glassed mini in the root overlay. Asynchronous frame updates and inline/expanded placement changes could disagree with the native animation. The search-role tab at baseline line 189 also requested a detached search button. The visible resting mini now lives inside the native accessory and responds there to placement. Only player presentation uses the measured-frame overlay; animation completion transfers ownership back to the native mini in one state update. Search remains a regular fourth tab with its existing search page and reselection behavior. Both iOS 26 paths retain `.tabBarMinimizeBehavior(.onScrollDown)`.

These are source-level causes and corrections, not a claim that the original video has been reproduced on this Linux machine. The final grouped appearance and absence of transient chrome overlap require the hardware check below.

## Apple alignment

- [preferredColorScheme](https://developer.apple.com/documentation/swiftui/view/preferredcolorscheme(_:)): a preference targets the enclosing presentation, not just the modified view. Detail tint should be local paint under inherited appearance.
- [tabViewBottomAccessory](https://developer.apple.com/documentation/swiftui/view/tabviewbottomaccessory(content:)): the system places an accessory above the expanded bar and inline with the minimized bar. Hosting visible content there keeps it in the system animation.
- [Build a UIKit app with the new design](https://developer.apple.com/videos/play/wwdc2025/284/): native accessory views animate alongside the tab bar; the app does not need an independently positioned resting mini.

## Automated coverage and thresholds

`PlayerCardRenderingTests` covers both appearances, drag/spring samples, and serial handover. New collapse samples test four vertical positions through the card, including the lower region: RGB tolerance is 3/255. A proportional lower dark band must stay at its full-screen y=540 rather than compress upward. Existing textured artwork/clip tests remain in place.

Detail zoom pixel samples run forward and backward at progress 0, .15, .35, .65 and .85. Outside the growing card, each light RGB channel must exceed 220/255 (allowing only the intentional 12% dim); each dark channel must remain below 8/255. A separate hosted-window test uses the actual `CollectionPage` in a navigation overlay at 0, .2, .5, .8 and 1 in both directions, allowing 100 ms for preference propagation and requiring the window and hosting controller to stay light. Wash thresholds and hue coverage are described in C below.

`GlassScreenshots.testNativeBottomAccessoryHasOneMiniAcrossScrollAndReturn` asserts exactly one accessible mini and one tab bar after repeated scroll-down/return gestures and one mini after player landing; it saves inline and expanded screenshots. These settled-state assertions do not prove every intermediate animation frame. Continuous native animation and physical glass appearance need visual verification.

## Device checklist (not yet performed)

Record slow-motion opening/closing of albums and playlists in light appearance: underlying library stays light throughout, with no black/white flash; detail uses light artwork tint. Repeat in dark appearance.

Slowly pull the player closed, pause/reverse the drag, release and interrupt a close by reopening. The card must show continuous blurred artwork through its lower region until the mini takes over, without a rectangular dark patch.

Scroll down and back to the top repeatedly in library, playlists, favorites and search. The minimized chrome must read as one coherent native bottom group, without a separate search orb or displaced mini. Check intermediate frames for duplicate bars, flashes or overlap. Confirm search typing and tapping the selected search tab still work.

Repeat all three checks with accessibility text sizes and Reduce Motion, including a missing-artwork track and both inline/expanded starting slots. Check iOS 26.0 and 26.1+ accessory paths, and the iOS 17–25 material fallback where available.

## 2026-10-29 follow-up: dark inline mini and delayed light return

### A — visible layer audit and remaining blocker

Inspected `/tmp/mini_dark_minimized.jpg`: the crop shows a nearly uniform dark grey mini between the library and search circles. The crop has no varied content behind the bar, OS/build metadata, or frame sequence. It establishes the reported appearance, but cannot measure blur/transmission or establish which build produced it.

On this branch the resting iOS 26 path is `LibraryView.swift:154–181` → `PlayerMiniSlotView` → `GlassPlayerMiniSlot` (`PlayerCard.swift:145–170`). Its only app background is the clear geometry reader (`:184–191`); `AccessoryMiniPlayer` (`LibraryView.swift:830–881`) draws artwork, labels and buttons, with no backing fill/material. `PlayerMiniGlass` is now used only by the pre-iOS 26 fallback; the travelling overlay adds no mini backing (see D below). Thus the resting iOS 26 backing belongs to the native accessory, in both inline and expanded placement. At progress zero the travelling card background has opacity zero (`:84–86`); after completion `playerMounted` removes that entire overlay (`LibraryView.swift:563–582`). It cannot be a persistent expanded backing at rest under the current ownership rules.

**Unresolved:** a runtime layer inspection on the affected iOS build is still needed to establish whether the native inline accessory is opaque or merely adapting its glass to a uniform dark background. No claim that every iOS 26 release forces opacity. The brief does not identify the device OS patch, and Linux cannot inspect the native host. Adding `PlayerMiniGlass` over a potentially opaque native backing would not restore content transmission. No UIKit background hiding or slot migration is implemented.

If native inline opacity is confirmed, the structural workaround for user decision is to move the visible glass mini to a shared overlay, leave a transparent measurement/reservation slot, and drive visible geometry and native minimization from one coordinated presentation state. This requires addressing the detached-animation problem that the first pass fixed, and explicit approval of that expanded scope. Do not silently restore the old asynchronously positioned overlay.

`GlassScreenshots.testDarkMinimizedNativeBottomAccessory` now captures actual dark inline, expanded and post-player-return states. The existing ownership test explicitly runs light appearance. Both require one mini/one tab bar and assert compact accessibility height <45 pt (36 pt container with a 44 pt control) versus wide height >=55 pt before naming a snapshot. These are placement assertions, **not** blur assertions. A flat dark crop and simulator material snapshots do not support a defensible transmission threshold.

Required real-device check: record exact iOS version/build, app commit and Reduce Transparency setting. With Reduce Transparency off, scroll varied high-contrast artwork/text behind the dark compact mini, then repeat with light wide mini as control. The empty parts between artwork/title/play button must show a spatially changing, softened backdrop as content moves, without sharp readable content or a uniform solid plate. Save before/after frames with the same exposure; repeat on iOS 26.0 and 26.1+ where available. If dark compact stays uniform while light wide responds, capture the native layer ownership in Xcode View Debugger and retain A as blocked pending the overlay decision. The uniform provided crop alone cannot pass this check.

### B — retained appearance fix and timed regression coverage

The known detail source was the deleted presentation-wide `preferredColorScheme` at baseline `CollectionPage.swift:62`. The current detail route has no remaining dark preference: `CollectionPage.swift:55–65` paints a wash under inherited appearance, `DetailZoomCard` uses semantic system background, and `LibraryView.swift:628–655` embeds a NavigationStack without an appearance override. Keep that fix; no timer or delayed white reset is introduced.

The player's `LibraryView.swift:73` environment override flows down only into expanded `NowPlayingView`, not into the sibling tab/library subtree. The expanded dark content is deliberate. It stays mounted until the spring completion (`:572–582`), which is a possible lifetime to investigate on device, but **is not evidence of a window-wide appearance leak**. No other preferred scheme, window appearance override or delayed reset exists in app sources. Removing the local override would change the designed expanded player without establishing a cause for the library report, so it is retained.

New `PlayerCardRenderingTests.testDetailReturnHasNoDelayedAppearanceChange` (album and playlist) and `testPlayerReturnHasNoDelayedAppearanceChange` use one persistent window/controller/SwiftUI identity per appearance. They host actual CollectionPage/NavigationStack/DetailZoomCard or NowPlayingView/NowPlayingBackground/PlayerCard, sample opening progress 0/.5/1, closing .5/0 while mounted, then remove the overlay. Sample the first rendered return frame (~20 ms after removal), followed by .5, 1 and 1.5 seconds; require unchanged controller traits and base environment. A semantic UIKit system-background probe must have light RGB >245/255 or dark RGB <8/255. Detail's content environment must inherit the system; expanded player's must stay dark. The test waits are observation points, not production timing changes.

Limits: this harness isolates appearance propagation in real destination/card types; it does not execute LibraryView's private state machine, native tab hosting, interactive navigation or spring completion. Its discrete samples cannot exclude an intervening one-frame flash. CI success therefore cannot close the device report by itself. No new runtime cause has been reproduced here; this follow-up adds regression evidence and records the unresolved native-host investigation rather than inventing a production fix.

Required device sequence in **both light and dark**: from library open an album, return, repeat with playlist, then expand and close the player. Record opening, first fully returned frame, +0.5/+1/+1.5 seconds with slow-motion video and window/base traits in Xcode. In light mode, detail must use light tint throughout and library must already be light at return, with no jump during the next second; expanded player remains dark by design. Repeat while reversing/interruption of close and starting from dark compact mini. If delayed dark retention persists, inspect window/NavigationStack/native accessory traits separately before editing the implicated layer. These hardware checks remain pending.


### C — full-page artwork wash and top coverage

`CollectionPage.swift:202` resolves the playlist custom cover first, then the collection cover. `CollectionArtworkBackground` / `CollectionArtworkWash` (at the end of that file) replace single-color sampling with a cached 160-pixel cover enlarged to fill the page, extended by 15%, blurred by 36 points and clipped. A white veil at 82% in light appearance or black at 72% in dark appearance bounds brightness while preserving spatial hue. An opaque white/black base also handles transparent cover files. Missing, unreadable and loading covers use an intentional accent → pink → indigo gradient with the same veil, rather than a flat gray fill. The URL-keyed async load discards cancelled/stale results.

The wash ignores safe areas. `LibraryView.swift:657` also extends the detail overlay's reader into container safe areas: previously its outer card clip stopped at the safe-area top, so an inner background's ignoresSafeArea could not cover the exposed library/status-bar strip. Card interpolation/radius formulas and foreground layout code are unchanged. Native navigation still lays out the header; check its inset on device.

`testDetailArtworkWashPreservesTextureHueAndOpaqueEdgesInBothAppearances` renders warm, cool, grayscale and missing-cover textures. At y=0/180/540/719, alpha must be 255; light channels >=205, dark <=75; warm red-minus-blue and cool blue-minus-red >15; grayscale channels within 2; spatial range >5. Both old CollectionArtworkColor references were replaced with the wash; no remaining references are allowed. Linux cannot compile the iOS target; CI must establish compilation and rendering results.

Device checklist, each in light/dark: album and playlist with warm/cool/grayscale covers, missing covers and unreadable cover files. Confirm a continuous wash from the status bar through list bottom and beneath translucent mini/tab chrome, no library text at the top, no unrelated gray plate, readable semantic labels/buttons, and unchanged cover/header/row positions. Check portrait/landscape and scrolled headers. Loading fallback must not retain a previous collection's cover.

### D — double capsule re-audit (shared with A)

Inspected both `/tmp/mini_double_capsule_ours.jpg` and `/tmp/mini_single_capsule_apple.jpg`. The former clearly has two vertically offset rounded outlines; its matching full crop is inline (library circle + narrow mini + search circle). A still crop cannot establish whether it was captured at rest, during scroll, or at player landing, nor which commit it used. The earlier audit's resting-only conclusion did not exclude the travelling overlay and must not be used to dismiss this evidence.

Two surfaces CAN overlap in the previous branch code: the system accessory backing remains drawn when `LibraryView.swift:160` hides only MiniPlayer content, and `PlayerCard.swift:97` previously wrapped the travelling collapsed content in PlayerMiniGlass. During the last 3% of travel and while a completed spring waits for removal, that app glass overlaps the still-present native backing at the measured content frame. Host insets versus measured content bounds can produce unequal outlines. On iOS 17–25 the inset material likewise remains behind the hidden content. The travelling modifier is removed: the host owns the only mini backing, and travelling mini content fades over it at landing. No UIKit views are hidden and no slot is moved. At progress zero expanded paint is already fully transparent.

`testLandedPlayerAddsNoBackingOverAccessorySurface` covers light/dark, 36/56-point slots and Reduce Motion on/off: transparent collapsed content over a magenta host must preserve all RGBA channels within 2/255 at three interior samples. This checks absence of app paint, not the native glass's optical behavior. UI captures cover light/dark inline/wide and player return, but a single accessible mini does not prove a single visual outline.

Required device check: compare with the Apple single-capsule reference in all four appearance/width combinations, both settled and throughout scroll/player landing, including interrupted close and Reduce Motion. There must be exactly one capsule edge. Repeat A's varied-backdrop transmission check after removing this overlap. **Still unresolved:** a double outline in a fully settled current-build native host, or persistent dark inline opacity, requires Xcode View Debugger on the exact affected iOS version; the screenshot does not prove a forced opaque system layer. If that host owns the extra layer/opacity and public API cannot remove it, retain the blocker and shared-overlay workaround described in A for user decision. Hardware reproduction and optical acceptance remain pending; this patch does not claim A/D fully resolved.


## Round 2 — shared playback background and album metadata (2026-10-29)

This section supersedes the separate CollectionArtworkBackground/CollectionArtworkWash
implementation and its earlier visual description. All other first-round fixes and
hardware limitations above remain applicable.

Baseline: fetched origin; clean existing codex/transition-flash-fix at b00463c
already merged origin/main c7428db, including a6b02c8 (#39) and #38. Explicit
`git merge origin/main` reports already up to date. #39 uses QueueDragHandle,
QueueRowDrag and QueueDropMapping on this baseline (not draggable/dropDestination
as the brief anticipated); its entire implementation is preserved. #38's
flac.picture extraction, folder-cover priority, bounds and thumbnail storage are
preserved. No rebase, force push, engine, morph, threshold, queue, lyrics,
MusicBrainz, workflow or apps.json changes in this round.

### Red rendering test: fixture mismatch, not demonstrated production reflow

Run 40891528069 failed only
`testCollapseCropsFullSizeBackdropWithoutCompressingDarkLowerRegion`.
Its GeometryReader uses Color.green, an adaptive system color, but expects
RGB (0,255,0). The light failures report green=199, red=52, blue=89: exactly
system green, rather than a shifted black band. 138 assertions across samples
are consistent with that fixture mismatch. Use explicit Color(red:0,green:1,blue:0)
in that one band. Keep every progress (including .03), appearance, vertical
sample and RGB tolerance (3 / <4) unchanged. No PlayerCard production change:
its full expanded frame followed by top-leading crop remains in force.
GitHub Actions must still verify the unchanged geometry assertions; this Linux
host cannot establish an iOS rendering pass.

### One background component and explicit inputs

NowPlayingBackground is a small adapter into ArtworkBackground(url:).
CollectionPage uses that same component, passing backgroundArtworkURL derived
from its collection: playlist custom cover first, otherwise its selected cover
track; album uses its own sorted cover track. It never reads player.current to
choose detail art. URL-keyed ArtworkAnalysisCache entries also separate files
with the same basename under different roots. Cancelled loads cannot install a
stale result; displayed analysis is matched to the current URL.

ArtworkBackgroundSurface uses the existing ArtworkAnalysis palette + downsampled
blur-like texture and ArtworkBackdrop composition, with an opaque base and
bounded clipping. Missing/unreadable art uses the same colored fallback palette;
gray covers preserve neutral texture. Playback keeps its existing shading;
detail adds white .82 / black .72 legibility veils under inherited appearance.
No third wash renderer remains. CollectionPage's ignoresSafeArea and the outer
detail card's safe-area extension remain, as do removal of forced dark scheme,
native mini accessory ownership, no travelling PlayerMiniGlass, and normal
search-tab role. The warm/cool/neutral/missing pixel regression now exercises
this shared surface, retaining its hue, opacity and brightness requirements.

### Album audit: all three breakpoints checked

(a) Confirmed missing path: AudioTags.Role and the fullMetadata switch had no
album role. Format-specific id3/TALB, itsk/©alb, vorbis/ALBUM and riff/IPRD were
silently ignored if commonMetadata omitted the album. Add only the album role
and fallback assignment, preserving commonMetadata precedence and keeping
album artist separate. Identifier regression tests cover both roles.

(b) No demonstrated parser defect for the requested layouts. The reader checks
each block against file size, seeks to its declared end, traverses PICTURE
before COMMENT, and stops at last-block. Existing semantics intentionally keep
the first COMMENT only, cap it at 4 MiB and cap traversal at 128 blocks.
Tests cover ALBUM first/last among comment fields, pictures before/after,
5 MiB padding, multiple COMMENT blocks, oversized COMMENT and last-block audio
exclusion. These limits and VORBIS_COMMENT semantics are unchanged. Such bounded
or malformed files may still lack an album; do not claim universal recovery.

(c) The skip predicate is equal size + modifiedAt + catalogVersion, not
contentHash. Git history shows FLAC album fallback AND version 3 arrived in
0bcbf3c; catalogs predating that already qualify for a reread. There is no
evidence that a version-2 entry is permanently skipped. Version-3 entries
previously affected by (a), however, would otherwise retain unknown album;
bump to 4 so the next folder scan rereads them. The integration test constructs
a stale version-3 entry with unchanged hash/size/mtime, verifies album recovery,
stable ID/favorite and version, then verifies subsequent scans skip normally.

Valid synthetic FLACs (real STREAMINFO/audio, with ALBUM and with no ALBUM) go
through AudioScanner, not only the comment parser. Unknown albums in Morning/
Evening remain separate groups. Linux ffmpeg validates the synthetic audio;
AVAudioFile/scanner behavior must pass on CI. The affected user's original
file/catalog was not supplied, so (a) is a confirmed code defect and (c) its
persistence/migration path, not a proven forensic diagnosis of that file.

Rescan steps: after installing the build, open Sources and rescan the indexed
folder; version 4 forces metadata re-read even when the file is unchanged.
Copied imports are not folder-scanned: remove and re-import the affected copied
file (playlist membership may need restoring). No automatic reread of copied
imports or destructive library reset is introduced.

### Required physical-device acceptance (pending)

- While another song is playing, open album/playlist details: background follows
  the collection cover, including custom playlist art; switch collections and
  test missing, unreadable, warm, cool and neutral covers.
- Light/dark: text readable, inherited window appearance unchanged through open,
  reverse, interruption and close; background fills the top safe-area strip.
- Confirm search and repeated search-tab selection remain usable.
- Tagged files display their album; genuinely untagged files remain 未知专辑
  and group by folder. Rescan existing indexed files as described above.
- Collapse slowly at .03 in light appearance: no background reflow/compressed
  dark region; reverse and spring to landing, including Reduce Motion.
- First-round bottom-bar checklist remains: light/dark, inline/wide, scroll,
  return and interrupted landing have one capsule outline, correct native
  accessory ownership and softened backdrop. Check exact iOS build and Reduce
  Transparency; simulator node counts cannot settle the double-capsule report.

Validation: Linux has no Xcode/Swift SDK; no local iOS compile or XCTest claim.
`git diff --check` passes. Await GitHub Actions full unit suite and screenshots.
Only this existing branch/PR is pushed; do not merge. On CI failure inspect the
named failed step/test and correct one cause once; if that retry remains red,
stop and report step/test and commit. No duplicate watcher is created.
