"""Python-only checks of the cloud flow; these do not build or run the iOS app."""

import json
from pathlib import Path
import plistlib
import re
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import ci

ROOT = Path(__file__).resolve().parents[1]
SOURCE = {'apps': [{'versions': [
    {'buildVersion': '155', 'downloadURL': 'old'},
    {'buildVersion': '144'},
]}]}


def plan(**changes):
    value = dict(schema=1, head='h', tree='t', base='b', base_tag='dev-155-2', changed=[],
                 full=False, reason='r', only_testing=['-only-testing:LosslessPlayerTests/X'],
                 ui=True, ui_testing=['-only-testing:LosslessPlayerUITests'])
    value.update(changes)
    return value


class BuildNumberTests(unittest.TestCase):
    def test_old_and_new_tag_shapes(self):
        self.assertEqual(ci.tag_build('dev-155-2'), 155)
        self.assertEqual(ci.tag_build('dev-156'), 156)
        self.assertIsNone(ci.tag_build('preview-155.1'))
        self.assertIsNone(ci.tag_build('v1.0'))

    def test_next_build_never_goes_backwards(self):
        # A new workflow restarts run numbers at 1; builds must still exceed every known one.
        self.assertEqual(ci.next_build(['dev-99-1', 'dev-155-2'], SOURCE), 156)
        self.assertEqual(ci.next_build(['dev-160'], SOURCE), 161)
        with self.assertRaises(ci.Failure):
            ci.next_build([], {'apps': [{'versions': []}]})

    def test_preview_counts_within_current_dev(self):
        self.assertEqual(ci.preview_build(['dev-155-2'], SOURCE), '155.1')
        self.assertEqual(ci.preview_build(['dev-155-2', 'preview-155.1', 'preview-154.3'], SOURCE), '155.2')


class IPAPackagingTests(unittest.TestCase):
    def test_phone_package_builds_and_copies_the_optimized_product(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            product = root / 'build/device/Build/Products/Release-iphoneos/LosslessPlayer.app'
            product.mkdir(parents=True)
            info = dict(CFBundleIdentifier=ci.BUNDLE_ID, CFBundleSupportedPlatforms=['iPhoneOS'],
                        UIBackgroundModes=['audio'],
                        CFBundleIcons={'CFBundlePrimaryIcon': {'CFBundleIconName': 'AppIcon'}},
                        DTSDKName='iphoneos26.6', DTXcode='2660', MinimumOSVersion='17.0',
                        CFBundleVersion='180.1', CFBundleExecutable='LosslessPlayer',
                        CADisableMinimumFrameDurationOnPhone=True)
            (product / 'Info.plist').write_bytes(plistlib.dumps(info))
            (product / 'LosslessPlayer').write_bytes(b'fixture executable')
            commands = []

            def fake_run(command, **kwargs):
                commands.append(command)
                if command[0] == 'xcodebuild':
                    self.assertEqual(command[command.index('-configuration') + 1], 'Release')
                elif command[0] == 'ditto':
                    with zipfile.ZipFile(command[-1], 'w') as archive:
                        archive.writestr('Payload/LosslessPlayer.app/Info.plist', plistlib.dumps(info))

            with patch.object(ci, 'ROOT', root), patch.object(ci, 'run', side_effect=fake_run):
                ipa, packaged = ci.build_ipa('180.1')
            self.assertEqual(packaged, info)
            self.assertTrue(ipa.exists())
            self.assertEqual((root / 'build/ipa/Payload/LosslessPlayer.app/LosslessPlayer').read_bytes(),
                             b'fixture executable')
            self.assertTrue(any(command[0] == 'lipo' for command in commands))
            self.assertIn(ci.IPA_NAME, (root / 'dist/SHA256SUMS.txt').read_text())


class SourceTests(unittest.TestCase):
    def source(self, *builds):
        return {'apps': [{'versions': [{'buildVersion': b} for b in builds]}]}

    def builds(self, source):
        return [v['buildVersion'] for v in source['apps'][0]['versions']]

    def test_dev_drops_superseded_previews(self):
        result = ci.updated_source(self.source('155.2', '155', '144'), {'buildVersion': '156'})
        self.assertEqual(self.builds(result), ['156', '155', '144'])

    def test_only_newest_preview_is_listed(self):
        result = ci.updated_source(self.source('155.1', '155'), {'buildVersion': '155.2'})
        self.assertEqual(self.builds(result), ['155.2', '155'])

    def test_keeps_ten_and_replaces_same_build(self):
        result = ci.updated_source(self.source(*map(str, range(20, 8, -1))), {'buildVersion': '20'})
        self.assertEqual(self.builds(result), [str(n) for n in range(20, 10, -1)])

    def test_source_icons_point_at_the_app_icon_in_this_repo(self):
        source = json.loads((ROOT / 'apps.json').read_text())
        prefix = f'https://raw.githubusercontent.com/{ci.REPO}/main/'
        for icon in (source['iconURL'], source['apps'][0]['iconURL']):
            self.assertTrue(icon.startswith(prefix), icon)
            self.assertTrue((ROOT / icon[len(prefix):]).is_file(), icon)

    def test_publishing_keeps_the_app_icon(self):
        source = self.source('155')
        source['apps'][0]['iconURL'] = 'icon'
        self.assertEqual(ci.updated_source(source, {'buildVersion': '156'})['apps'][0]['iconURL'], 'icon')

    def test_entry_points_at_release_asset(self):
        info = {'CFBundleShortVersionString': '0.2.0', 'CFBundleVersion': '156'}
        entry = ci.source_entry({'name': 'kept'}, info, 'dev-156', 10, 'd')
        self.assertEqual(entry['name'], 'kept')
        self.assertTrue(entry['downloadURL'].endswith('/releases/download/dev-156/' + ci.IPA_NAME))


class ProofTests(unittest.TestCase):
    def proof(self, value):
        return dict(schema=1, tree='t', plan_key=ci.plan_key(value), unit_passed=3, ui_passed=0)

    def test_same_tree_and_plan_is_reusable(self):
        self.assertTrue(ci.proof_matches(self.proof(plan()), plan()))

    def test_any_difference_is_not_reusable(self):
        proof = self.proof(plan())
        for change in (dict(tree='other'), dict(base='newer-dev'), dict(ui=False),
                       dict(only_testing=['-only-testing:LosslessPlayerTests'])):
            with self.subTest(change=change):
                self.assertFalse(ci.proof_matches(proof, plan(**change)))

    def test_zero_passes_never_count(self):
        proof = dict(self.proof(plan()), unit_passed=0, ui_passed=0)
        self.assertFalse(ci.proof_matches(proof, plan()))

    def test_check_only_proof_is_never_reusable_even_for_empty_plan(self):
        empty = plan(only_testing=[], ui=False)
        with patch.object(ci, 'prepare') as prepare:
            proof = ci.execute(empty)
        prepare.assert_not_called()
        self.assertTrue(proof['check_only'])
        self.assertEqual(proof['unit_passed'] + proof['ui_passed'], 0)
        self.assertFalse(ci.proof_matches(proof, empty))
        self.assertFalse(ci.proof_matches(dict(proof, unit_passed=3), empty))
        self.assertFalse(ci.proof_matches(dict(self.proof(plan()), check_only=True), plan()))
        self.assertFalse(ci.proof_matches(proof, plan()))

    def test_selected_tests_with_zero_passes_still_fail(self):
        with patch.object(ci, 'prepare'), patch.object(ci, 'xcodebuild_test', return_value=0):
            with self.assertRaises(ci.Failure):
                ci.execute(plan(ui=False))

    def test_head_and_reason_do_not_block_reuse(self):
        # The PR merge commit differs from main's merge commit; the tree is what was tested.
        self.assertTrue(ci.proof_matches(self.proof(plan()), plan(head='merge', reason='other words')))


class NotesTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        (self.root / 'project.yml').write_text("MARKETING_VERSION: '0.2.0'\n")
        patcher = patch.object(ci, 'ROOT', self.root)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_notes_include_only_current_version_list_entries(self):
        (self.root / 'CHANGELOG.md').write_text(
            '# 更新记录\n\n## 0.3.0（开发中）\n- 将来条目\n\n'
            '## 0.2.0（开发中）\n### 新增\n- 新增条目\n  补充说明\n'
            '### 修复\n- 修复条目\n\n## 0.1.0（已发布）\n- 历史条目\n')
        for kind, value, proof in [('dev', plan(), {'unit_passed': 3, 'ui_passed': 0}),
                                   ('preview', None, None)]:
            text = ci.notes(kind, value, proof, 'abc')
            self.assertIn('### 新增\n- 新增条目\n  补充说明', text)
            self.assertIn('- 修复条目', text)
            self.assertNotIn('历史条目', text)
            self.assertNotIn('将来条目', text)
            if kind == 'dev':
                self.assertIn('测试范围：r', text)

    def test_empty_or_missing_current_section_keeps_template(self):
        fallback = ci.notes('dev', plan(), {'unit_passed': 3, 'ui_passed': 0}, 'abc')
        for body in ('## 0.2.0（开发中）\n### 新增\n### 修复\n',
                     '## 0.1.0（已发布）\n- 历史条目\n', ''):
            (self.root / 'CHANGELOG.md').write_text(body)
            self.assertEqual(ci.notes('dev', plan(), {'unit_passed': 3, 'ui_passed': 0}, 'abc'), fallback)

    def test_published_source_description_includes_changes_or_original_template(self):
        (self.root / 'dist').mkdir()
        (self.root / 'apps.json').write_text('{"apps": [{"versions": [{}]}]}')
        ipa = self.root / 'dist/test.ipa'
        ipa.write_bytes(b'ipa')
        info = {'CFBundleShortVersionString': '0.2.0', 'CFBundleVersion': '156'}
        for kind, description in [('dev', 'dev-156：最新开发版。'),
                                  ('preview', 'preview-156：预览包（合并前确认用）。')]:
            for exists in (False, True):
                with self.subTest(kind=kind, exists=exists):
                    changelog = self.root / 'CHANGELOG.md'
                    if exists:
                        changelog.write_text('## 0.2.0（开发中）\n### 修复\n- 修复条目\n')
                    else:
                        changelog.unlink(missing_ok=True)
                    text = ci.notes(kind, plan(), {'unit_passed': 3, 'ui_passed': 0}, 'abc')
                    with patch.object(ci, 'run') as run, patch.object(ci, 'push_source') as push:
                        ci.publish(kind, f'{kind}-156', ipa, info, text, 'abc')
                    expected = description + ('\n\n### 修复\n- 修复条目' if exists else '')
                    self.assertEqual(push.call_args.args[0]['localizedDescription'], expected)
                    self.assertEqual((self.root / 'dist/release-notes.md').read_text(), text + '\n')
                    self.assertIn('--notes-file', run.call_args.args[0])

    def test_preview_without_proof(self):
        text = ci.notes('preview', None, None, 'abc')
        self.assertIn('源码：abc。预览包只编译', text)
        self.assertNotIn('测试范围', text)

    def test_dev_reused_or_own_run(self):
        reused = ci.notes('dev', plan(), {'url': 'https://x/1'}, 'abc')
        self.assertIn('测试由 PR 检查完成并复用：https://x/1', reused)
        self.assertIn('测试范围：r；基线 dev-155-2', reused)
        own = ci.notes('dev', plan(), {'unit_passed': 3, 'ui_passed': 2}, 'abc')
        self.assertIn('单元测试通过 3 项，界面测试通过 2 项', own)


class SelectorTests(unittest.TestCase):
    def test_manual_selectors(self):
        for good in ('LosslessPlayerTests', 'LosslessPlayerTests/PlaybackTests',
                     'LosslessPlayerUITests/GlassScreenshots/testPlayerPullDownThreshold'):
            self.assertTrue(ci.SELECTOR.fullmatch(good), good)
        for bad in ('Other/Class', 'LosslessPlayerTests/', 'LosslessPlayerTests/a/b/c', '-only-testing:X', ''):
            self.assertFalse(ci.SELECTOR.fullmatch(bad), bad)

    def test_manual_plan_splits_targets(self):
        value = ci.make_plan(only=['LosslessPlayerTests/PlaybackTests', 'LosslessPlayerUITests/GlassScreenshots'])
        self.assertEqual(value['only_testing'], ['-only-testing:LosslessPlayerTests/PlaybackTests'])
        self.assertEqual(value['ui_testing'], ['-only-testing:LosslessPlayerUITests/GlassScreenshots'])
        self.assertTrue(value['ui'])
        with self.assertRaises(ci.Failure):
            ci.make_plan(only=['rm -rf'])


class IPadStageTests(unittest.TestCase):
    def test_whole_ui_target_runs_ipad_class_on_ipad_only(self):
        phone, ipad = ci.split_ui(['-only-testing:LosslessPlayerUITests'])
        self.assertEqual(phone, ['-only-testing:LosslessPlayerUITests',
                                 '-skip-testing:LosslessPlayerUITests/IPadSidebarTests'])
        self.assertEqual(ipad, ['-only-testing:LosslessPlayerUITests/IPadSidebarTests'])

    def test_manual_ipad_selector_skips_iphone_stage(self):
        phone, ipad = ci.split_ui(['-only-testing:LosslessPlayerUITests/IPadSidebarTests/testMiniOpensPlayerBesideSidebar'])
        self.assertEqual(phone, [])
        self.assertEqual(ipad, ['-only-testing:LosslessPlayerUITests/IPadSidebarTests/testMiniOpensPlayerBesideSidebar'])

    def test_other_ui_classes_stay_on_iphone(self):
        phone, ipad = ci.split_ui(['-only-testing:LosslessPlayerUITests/GlassScreenshots'])
        self.assertEqual(phone, ['-only-testing:LosslessPlayerUITests/GlassScreenshots'])
        self.assertEqual(ipad, [])

    def test_ipad_results_are_uploaded(self):
        for name in ('ci.yml', 'dev.yml'):
            text = (ROOT / '.github/workflows' / name).read_text()
            if 'build/UIResults.xcresult' in text:
                self.assertIn('build/IPadResults.xcresult', text, name)


class WorkflowTests(unittest.TestCase):
    def test_workflows_call_the_shared_executor(self):
        for name, command in (('ci.yml', 'tools/ci.py gate'), ('dev.yml', 'tools/ci.py dev'),
                              ('preview.yml', 'tools/ci.py preview')):
            with self.subTest(name=name):
                self.assertIn(command, (ROOT / '.github/workflows' / name).read_text())

    def test_only_publishing_workflows_can_write(self):
        for path in (ROOT / '.github/workflows').glob('*.yml'):
            writes = re.search(r'contents:\s*write', path.read_text())
            self.assertEqual(bool(writes), path.name in ('dev.yml', 'preview.yml'), path.name)

    def test_gate_skips_drafts_and_runs_when_ready(self):
        workflow = (ROOT / '.github/workflows/ci.yml').read_text()
        self.assertRegex(workflow, r'pull_request:\n    types: \[opened, synchronize, reopened, ready_for_review\]')
        self.assertIn("if: github.event_name == 'pull_request' && !github.event.pull_request.draft", workflow)

    def test_gate_job_name_is_stable_for_branch_protection(self):
        self.assertRegex((ROOT / '.github/workflows/ci.yml').read_text(), r'\n  gate:\n')


if __name__ == '__main__':
    unittest.main()
