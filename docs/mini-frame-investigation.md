# PR #37: product-side mini frame investigation, 2026-10-29

## Status

Product repair is **not complete**. This round records evidence, without a
speculative production change. Initial working tree was clean on
`codex/transition-flash-fix`, HEAD
`a9287238a7bfd03d4f22ef23f03eac8baf883f93`. The preceding `readyMini`, `tapMini`
and fresh-read changes remain intact. No test, timeout, workflow, visual
surface, layout, player animation or playback behavior is changed.

## Observed failure windows

Source: [run 40971086756](https://github.com/iskerwin/LosslessPlayer/actions/runs/40971086756),
job `123787705469`, Capture iOS 26 screenshots. Build and test passed;
UI results were 7 passing and 3 failing. All three failures report an invalid
activation point and no suggested hit points based on the mini element frame.

| Case | Last relevant action and failure, relative to test start | What this establishes |
| --- | --- | --- |
| `testMiniGlassAcrossRemainingTabs` | Initial mini ready at 14.87 s; tap Favorites at 15.39 s; next mini lookup at 19.58 s; AX failure at approximately 21 s | Failure occurs without opening the player or a detail. PlayerCard mounting and collapse ownership transfer are not necessary conditions. |
| `testDarkMinimizedNativeBottomAccessory` | Second inline capture at 47.12 s; swipe down at 47.12 s; mini lookup at 52.77 s; AX failure at approximately 55 s | Failure follows native inline-to-wide return, before the test ever taps mini to expand the player. Here “expanded” means the tab accessory's wide placement, not PlayerCard presentation. |
| `testNativeBottomAccessoryHasOneMiniAcrossScrollAndReturn` | Four placement captures finish at 47.91 s; mini tap at 49.16 s; close-player tap at 53.59 s; mini lookup at 55.36 s; AX failure at approximately 60 s | Failure follows player collapse, but the log does not identify whether the observed node is the travelling mini or the returned native mini. |

These are action-to-failure windows, not measurements of the exact invalid
layout frame. The job log does not include synchronized native geometry,
ownership state, and accessibility frame samples. The previously reported
`{{inf,inf},{0,0}}` is an accessibility observation; it is not a recorded
`GeometryReader` measurement from this run.

## Code trace and repair boundary

- `App/LibraryView.swift:175`: native tab accessory hosts `miniPlayer` on
  iOS 26/26.1+. `tabBarMinimizeBehavior(.onScrollDown)` remains enabled.
- `App/PlayerCard.swift:169`: native placement selects compact content.
  `PlayerMiniSlotMeasure` sets the slot height to 36 or at least 56 points,
  measures its global frame at line 188, and asynchronously reports it at
  line 199. This callback is a travel-target measurement; it does not assign
  the resting native mini's frame or its accessibility frame.
- `App/LibraryView.swift:168`: `receiveMiniSlot` already rejects zero width
  or height and leaves the previous stored slot intact. Thus a zero-size
  `{{inf,inf},{0,0}}` measurement, **if** delivered through this callback,
  would already be rejected. Missing finite-origin validation for positive
  sizes is a possible defensive gap, but there is no observed positive-size
  nonfinite measurement establishing that it causes these failures.
- `App/LibraryView.swift:55`: stored `miniSlot` is converted to root-local
  coordinates only for PlayerCard travel. The card is absent until
  `playerMounted` is true (line 59). The Favorites failure and dark native
  return failure both occur before any call to open this card.
- `App/LibraryView.swift:159`: the native mini content is hidden while
  `playerMounted`; `setPlayer` mounts the overlay on open and releases it in
  the guarded close-animation completion (lines 566–580). This transfer
  remains a candidate for the light return failure, not a sufficient common
  cause for all three failures.
- `App/LibraryView.swift:882`: `mini-player` identifies a SwiftUI accessibility
  container using `.contain`. Apple's [contain documentation](https://developer.apple.com/documentation/swiftui/accessibilitychildbehavior/contain)
  describes child grouping. It does not guarantee that an invalid exported
  container frame means the underlying native host geometry is invalid.
  The present evidence cannot distinguish a host layout failure from an
  accessibility export failure.

Consequently no finite-value guard is presented as a fix for the reported
AX frame, and no container, capsule, glass or ownership rewrite is attempted.
There is no demonstrated cause-to-repair correspondence yet.

## Detail latency

`CollectionPage` supplies the collection artwork URL to `ArtworkBackground`.
The loader in `App/NowPlayingView.swift:847–868` uses a cached analysis or a
detached image decode/analysis task, followed by a guarded state update.
`LibraryView` does not await that task when measuring mini or transferring
player ownership. Detail opening separately waits for its measured header
before advancing detail progress. The failing Favorites and dark scroll
sequences do not open details at all.

No source-level dependency establishes that the reported 10–14 second detail
delay causes the common mini failure. A shared runtime stall is still
possible; timing/profiling evidence is missing. Treat latency as an unresolved
performance report rather than bundle an artwork rewrite into this round.
`App/NowPlayingView.swift` has not been edited.

## Evidence needed to choose one repair

On iOS, correlate timestamps and native accessory placement with (1) the raw
slot global frame before its asynchronous report, (2) the stored target and
root origin, (3) `playerMounted`/`showPlayer`/progress at mounting and guarded
completion, and (4) the corresponding native view and AX container frames.
Reproduce Favorites switching, the second inline-to-wide return, and player
collapse in light/dark. This separates a native layout gap from invalid AX
export and identifies where retaining a previous valid frame would apply.
Do not infer native layout corruption from the AX value alone.

Required physical-device checks remain:

- Cold launch: does tapping mini within the first second lose the first tap?
- View Debugger: capture host and accessibility geometry during transition,
  including which mini owns the frame when it becomes invalid.

## Local validation and limits

This environment is Linux with neither Xcode nor Swift installed. It cannot
execute the iOS layout/AX path or profile detail rendering. Source tracing and
the existing run log support the exclusions above, not a verified root cause
or a successful repair. `git diff --check` is the applicable local check for
this documentation-only change. No CI rerun, CI wait or merge is requested.
