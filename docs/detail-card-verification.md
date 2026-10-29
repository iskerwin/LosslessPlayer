# Detail card zoom verification

Grid album covers (including Recently Added) and playlist covers opt into a
measured transition. Row, search, and player links continue to use navigation
pushes. `DetailCardLink` records the tapped artwork's global frame with
`onGeometryChange`; the presenter retains that rectangle for the return trip.
The grid remains mounted and cannot scroll while covered.

`DetailZoomCard.animatableData` is the only transition progress. Each rendered
frame derives the card rectangle, exterior radius, cover rectangle, detail
opacity, and 12% maximum backdrop dim from that value. Reversing it returns to
the captured rectangle. The destination header is measured at its stationary
resting layout, independently of the moving clip, to avoid geometry feedback.
Only the traveling cover is visible in motion; the source stays hidden and the
header takes over at rest. Reduce Motion uses a stationary opacity transition.

Player top radius is now `18 + 14 * clamp(progress)`: 32 pt expanded, at least
18 pt throughout travel, and 18 pt at the mini slot. Bottom corners retain the
existing 18-to-zero curve. Drag recognition, 90 pt threshold, 1:1 travel,
cancellation spring, and the native accessory slot are unchanged.

## Validation status

This change is authored on Linux without Xcode. No local iOS build or test pass
is claimed. GitHub Actions must validate the build, unit tests and UI tests.
Geometry/radius tests cover the measured endpoints and two identical round
trips. The UI regression opens both album and playlist cards twice, checks the
returning cell frame and confirms tab bar / mini player availability.

## Physical device checklist (pending)

- [ ] Album grid and Recently Added: card expands from the tapped slot.
- [ ] Playlist grid: same expansion mechanism, including custom/mosaic covers.
- [ ] Back shrinks to **the same measured slot**, twice consecutively, without drift.
- [ ] No duplicate cover, ghost image, or square-corner flash in either direction.
- [ ] Grid stays still, dims slightly, then regains brightness; tabs and mini player stay visible.
- [ ] Search rows, playlist list layout, song menus and player links use ordinary pushes.
- [ ] Nested push/back from a card detail returns to that detail correctly.
- [ ] Light and dark appearances; large Dynamic Type; empty playlist.
- [ ] Reduce Motion: opacity transition without cover/frame travel.
- [ ] Player: slow downward drag keeps large top corners and the centered handle visible.
- [ ] Below 90 pt / horizontal drag cancels; over 90 pt closes; cancellation springs back.
- [ ] Mini landing retains rounded corners with no rectangular flash, including the native iOS 26 inline accessory.

The presenter clips its own player surface. Whether the native accessory's
background obscures the mini corner cutouts requires device inspection; this
change does not replace or reshape that system slot. If it masks the cutouts,
record the OS/device and report `App/PlayerCard.swift` (`PlayerMiniSlotView` /
`GlassPlayerMiniSlot`) and `App/LibraryView.swift` (`playerTabs`) as the boundary
before proposing a separate accessory-layout change. The existing expanded
cover upper-left crop is outside this change.
