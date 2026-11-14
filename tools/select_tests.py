#!/usr/bin/env python3
"""Select audited XCTest classes; emit JSON, never shell code.

Paths are repository-relative positional arguments, or a NUL-delimited file
from `git diff --name-only --no-renames -z` via --files-from. Renames must
include BOTH paths so moving a mapped file cannot hide an unknown dependency.
Selections are unions, never intersections. Only exact, reviewed source paths
may narrow the suite. Unmapped App paths select all units without adding UI.
Docs (docs/** and *.md) add no tests. Tools, workflows, Tests/, UITests/,
project.yml, other unknown paths, empty input and errors select all units
and UI. --full does the same explicitly; mixed paths union their requirements.
The workflow also guards invocation/JSON failures, including syntax errors here.

This saves little unit execution time: simulator startup/build still dominate.
The useful saving is skipping screenshots for audited non-UI-only changes.
Re-audit this table when dependencies or XCTest class boundaries change.
"""

import argparse
import json
from pathlib import Path
import sys


TARGET = "LosslessPlayerTests"
PLAYBACK = {"PlaybackQueueTests", "AudioPathTests", "GaplessPlaybackTests",
            "AudioSessionRatePolicyTests", "EngineSwitchContinuityTests", "TransportFaderTests"}
# These integration classes instantiate PlayerStore -> EnginePlayer, not just
# LibraryStore (testToggleStartsFirstAvailableTrack / upcoming queue mutations).
PLAYER_INTEGRATION = {"FolderScanTests", "FolderPlaylistTests", "LyricPlaybackTests"}
LIBRARY = {
    "LibraryTests", "FolderScanTests", "LibraryCatalogTests",
    "PlaylistManagementTests", "FolderPlaylistTests",
    "LibraryIndexAndPersistenceTests", "PlaylistSearchCacheTests",
}
# AudioTags/Track -> album identity, search, derived groups, queue/menu models.
CATALOG = LIBRARY | {
    "ArtistTagTests", "MigrationAndLyricsTests", "SearchResultsTests",
    "BrowseAndArtworkPerformanceTests", "PlaybackQueueTests", "AudioPathTests",
}

# Explicit transitive dependencies checked against both Tests/*.swift files.
# A value is (XCTest classes, affects screenshots). No wildcard source mapping.
MAPPING = {
    "App/EnginePlayer.swift": (PLAYBACK | PLAYER_INTEGRATION, False),
    "App/TransportFader.swift": (PLAYBACK | PLAYER_INTEGRATION, False),
    "App/TransportEnvelopeDriver.swift": (PLAYBACK | PLAYER_INTEGRATION, False),
    "App/GaplessPlayback.swift": (PLAYBACK | PLAYER_INTEGRATION, False),
    "App/AudioPath.swift": (PLAYBACK | PLAYER_INTEGRATION, False),
    "App/PlayerStore.swift": (PLAYBACK | PLAYER_INTEGRATION, False),
    "App/LibraryStore.swift": (LIBRARY, False),
    # AudioScanner also owns relativePath (PlaybackQueueTests), tags and covers.
    "App/AudioScanner.swift": (LIBRARY | {"PlaybackQueueTests", "ArtistTagTests"}, False),
    "App/FLACComments.swift": (LIBRARY | {"ArtistTagTests"}, False),
    "App/LibraryCatalog.swift": (CATALOG, False),
    # Track.swift also defines PlaybackQueue, RepeatMode and playback migration.
    "App/Track.swift": (CATALOG | {"GaplessPlaybackTests"}, False),
    # AlbumGroup and SearchResults live in LibraryView, used by LibraryStore.
    "App/LibraryView.swift": (CATALOG, True),
    # Player spring and native detail navigation wiring.
    "App/PlayerCard.swift": ({"BrowseAndArtworkPerformanceTests", "PlayerCardRenderingTests"}, True),
    "App/DetailZoom.swift": ({"SearchResultsTests", "PlayerCardRenderingTests"}, True),
    # LyricsLine.parse is here, alongside scrubber, swipe and palette helpers.
    "App/NowPlayingView.swift": ({
        "MigrationAndLyricsTests", "PlaybackQueueTests", "ArtworkSwipeTests",
        "ArtworkAnalysisTests", "BrowseAndArtworkPerformanceTests", "LyricPlaybackTests",
    }, True),
    "App/MusicChrome.swift": ({"PlaybackQueueTests"}, True),
    # LibraryStore invalidates this cache during removal, rescans and cover edits.
    "App/ArtworkCache.swift": (LIBRARY | {"BrowseAndArtworkPerformanceTests", "ArtworkAnalysisTests"}, True),
    "App/PlaylistBrowser.swift": ({"LibraryCatalogTests", "SearchResultsTests"}, True),
    # These views delegate model behavior; retain the relevant model coverage.
    "App/CollectionPage.swift": (LIBRARY | {"PlaybackQueueTests", "SearchResultsTests"}, True),
    "App/PlaylistArtworkEditor.swift": ({"PlaylistManagementTests", "FolderPlaylistTests"}, True),
    "App/SourcesView.swift": ({"FolderScanTests", "FolderPlaylistTests"}, True),
    "App/SearchTabReselect.swift": ({"SearchResultsTests"}, True),
    "App/ScreenshotFixture.swift": (LIBRARY | PLAYBACK, True),
    "App/LosslessPlayerApp.swift": (LIBRARY | PLAYBACK, True),
}


def full_selection(reason):
    return {"only_testing": [f"-only-testing:{TARGET}"],
            "screenshots": True, "full": True, "reason": reason}


def select_tests(paths, full=False):
    if full:
        return full_selection("forced full suite")
    if not paths:
        return full_selection("no changed paths available")
    sensitive = sorted(p for p in set(paths) if p == "project.yml" or
                       p.startswith(("tools/", ".github/workflows/", "Tests/", "UITests/")))
    if sensitive:
        return full_selection("selection-sensitive paths: " + ", ".join(sensitive))
    paths = sorted({p for p in paths if not (p.startswith("docs/") or p.endswith(".md"))})
    unknown = sorted(set(paths) - MAPPING.keys())
    unsafe = [p for p in unknown if not p.startswith("App/")]
    if unsafe:
        return full_selection("unmapped paths: " + ", ".join(unsafe))
    classes = set()
    screenshots = False
    for path in paths:
        if path not in MAPPING:
            continue
        tests, ui = MAPPING[path]
        classes.update(tests)
        screenshots |= ui
    if unknown:
        return {"only_testing": [f"-only-testing:{TARGET}"], "screenshots": screenshots,
                "full": False, "reason": "unmapped App paths (all units): " + ", ".join(unknown)}
    if not classes:
        return {"only_testing": [], "screenshots": False, "full": False,
                "reason": "documentation only; static checks and tool tests"}
    return {"only_testing": [f"-only-testing:{TARGET}/{name}" for name in sorted(classes)],
            "screenshots": screenshots, "full": False,
            "reason": "union of audited source dependencies"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="*")
    parser.add_argument("--files-from", type=Path, help="NUL-delimited changed paths")
    parser.add_argument("--full", action="store_true", help="force unit target and screenshots")
    args = parser.parse_args()
    try:
        paths = args.paths
        if args.files_from is not None:
            data = args.files_from.read_bytes()
            if data and not data.endswith(b"\0"):
                raise ValueError("changed-path file must be NUL terminated")
            paths += data.decode("utf-8").split("\0")[:-1] if data else []
        selection = select_tests(paths, full=args.full)
    except Exception as error:
        print(f"Selection failed: {error}", file=sys.stderr)
        selection = full_selection("selector input error")
    print(json.dumps(selection, ensure_ascii=True))


if __name__ == "__main__":
    main()
