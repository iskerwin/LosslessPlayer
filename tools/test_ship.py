"""Local version command checks; no App builds or Swift tests."""
from contextlib import redirect_stdout, redirect_stderr
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import ship
from versioning import version_tuple


class VersionTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.project = self.root / 'project.yml'
        self.original = "settings:\n  base:\n    MARKETING_VERSION: '1.9.9' # keep\n    CURRENT_PROJECT_VERSION: '42'\n"
        self.project.write_text(self.original)
        patcher = patch.object(ship, 'ROOT', self.root)
        patcher.start()
        self.addCleanup(patcher.stop)

    def invoke(self, value):
        with redirect_stdout(io.StringIO()) as output, redirect_stderr(io.StringIO()):
            code = ship.main(['version', value])
        return code, output.getvalue()

    def test_numeric_comparison_and_bumps(self):
        self.assertGreater(version_tuple('1.10.0'), version_tuple('1.9.9'))
        for value, expected in [('patch', '1.9.10'), ('minor', '1.10.0'),
                                ('major', '2.0.0'), ('1.10.1', '1.10.1')]:
            with self.subTest(value=value):
                self.project.write_text(self.original)
                code, output = self.invoke(value)
                self.assertEqual(code, 0)
                self.assertIn('CHANGELOG.md 不存在', output)
                self.assertEqual(self.project.read_text(), self.original.replace('1.9.9', expected))
                self.assertFalse((self.root / 'CHANGELOG.md').exists())

    def test_invalid_or_non_increasing_versions_leave_files_untouched(self):
        changelog = self.root / 'CHANGELOG.md'
        changelog.write_text('# 更新记录\n\n## 1.9.9（开发中）\n\n- 旧条目\n')
        original = changelog.read_text()
        for value in ('1.9.9', '1.9.8', '0.99.99', '1.2', 'v2.0.0', '2.0.0-beta',
                      '01.10.0', '-1.0.0', 'bad'):
            with self.subTest(value=value):
                # Pass negative malformed input through to version validation.
                with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
                    code = ship.main(['version', '--', value])
                self.assertEqual(code, 1)
                self.assertEqual(self.project.read_text(), self.original)
                self.assertEqual(changelog.read_text(), original)

    def test_new_section_preserves_title_and_all_old_entries(self):
        changelog = self.root / 'CHANGELOG.md'
        old = '## 1.9.9（开发中）\n\n### 修复\n- 旧条目\n\n## 1.0.0（已发布）\n- 更旧条目\n'
        changelog.write_text('# 更新记录\n\n' + old)
        self.assertEqual(self.invoke('minor')[0], 0)
        self.assertEqual(changelog.read_text(), '# 更新记录\n\n## 1.10.0（开发中）\n\n' + old)

    def test_invalid_project_version_fails_without_writing(self):
        for text in ('MARKETING_VERSION: bad\n', "MARKETING_VERSION: '1.2.3'\n" * 2):
            self.project.write_text(text)
            self.assertEqual(self.invoke('patch')[0], 1)
            self.assertEqual(self.project.read_text(), text)


if __name__ == '__main__':
    unittest.main()
