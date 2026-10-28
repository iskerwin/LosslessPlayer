"""Python-only regression checks; these do not build or run the iOS app."""

import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

from select_tests import MAPPING, select_tests


ROOT = Path(__file__).resolve().parents[1]
FULL = ["-only-testing:LosslessPlayerTests"]


class SelectionTests(unittest.TestCase):
    def test_engine_keeps_playback_and_player_integration_without_screenshots(self):
        result = select_tests(["App/EnginePlayer.swift"])
        self.assertFalse(result["full"])
        self.assertFalse(result["screenshots"])
        for name in ("PlaybackQueueTests", "AudioPathTests", "GaplessPlaybackTests",
                     "FolderScanTests", "FolderPlaylistTests"):
            self.assertIn(f"-only-testing:LosslessPlayerTests/{name}", result["only_testing"])

    def test_now_playing_keeps_lyrics_coverage_and_screenshots(self):
        result = select_tests(["App/NowPlayingView.swift"])
        self.assertTrue(result["screenshots"])
        self.assertIn("-only-testing:LosslessPlayerTests/MigrationAndLyricsTests", result["only_testing"])

    def test_mixed_paths_union_and_deduplicate(self):
        engine = select_tests(["App/EnginePlayer.swift"])
        ui = select_tests(["App/NowPlayingView.swift"])
        mixed = select_tests(["App/EnginePlayer.swift", "App/NowPlayingView.swift", "App/EnginePlayer.swift"])
        self.assertEqual(mixed["only_testing"], sorted(set(engine["only_testing"] + ui["only_testing"])))
        self.assertTrue(mixed["screenshots"])

    def test_uncertain_inputs_never_narrow(self):
        for path in ("App/NewView.swift", "README.md", "project.yml",
                     "Tests/PlaybackTests.swift", "UITests/GlassScreenshots.swift",
                     "tools/select_tests.py", "tools/test_select_tests.py",
                     ".github/workflows/ios.yml", "App/Assets.xcassets/new.png",
                     "App/Odd\nName.swift", "App/EnginePlayer.swift "):
            with self.subTest(path=path):
                result = select_tests(["App/EnginePlayer.swift", path])
                self.assertEqual(result["only_testing"], FULL)
                self.assertTrue(result["full"])
                self.assertTrue(result["screenshots"])
        self.assertEqual(select_tests([])["only_testing"], FULL)
        self.assertEqual(select_tests(["App/EnginePlayer.swift"], full=True)["only_testing"], FULL)

    def test_audited_files_and_classes_exist(self):
        classes = set()
        for source in (ROOT / "Tests").glob("*.swift"):
            classes.update(re.findall(r"final class (\w+): XCTestCase", source.read_text()))
        for path, (selected, _) in MAPPING.items():
            with self.subTest(path=path):
                self.assertTrue((ROOT / path).is_file())
                self.assertTrue(selected)
                self.assertLessEqual(selected, classes)

    def test_cli_nul_paths_and_input_errors(self):
        script = str(ROOT / "tools/select_tests.py")
        with tempfile.TemporaryDirectory() as directory:
            paths = Path(directory) / "paths"
            paths.write_bytes(b"App/EnginePlayer.swift\0")
            def invoke():
                return json.loads(subprocess.check_output(
                    [sys.executable, script, "--files-from", str(paths)], text=True,
                    stderr=subprocess.DEVNULL,
                ))
            self.assertFalse(invoke()["full"])
            paths.write_bytes(b"App/EnginePlayer.swift")  # truncated diff output
            self.assertEqual(invoke()["only_testing"], FULL)
            paths.write_bytes(b"App/EnginePlayer.swift\0App/Unknown.swift\0")
            self.assertEqual(invoke()["only_testing"], FULL)
            paths.write_bytes(b"\xff\0")
            self.assertEqual(invoke()["only_testing"], FULL)
            paths.unlink()
            self.assertEqual(invoke()["only_testing"], FULL)


if __name__ == "__main__":
    unittest.main()
