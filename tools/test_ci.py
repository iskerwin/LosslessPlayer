"""Python-only checks of the cloud flow; these do not build or run the iOS app."""

from pathlib import Path
import re
import unittest

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

    def test_head_and_reason_do_not_block_reuse(self):
        # The PR merge commit differs from main's merge commit; the tree is what was tested.
        self.assertTrue(ci.proof_matches(self.proof(plan()), plan(head='merge', reason='other words')))


class NotesTests(unittest.TestCase):
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

    def test_gate_job_name_is_stable_for_branch_protection(self):
        self.assertRegex((ROOT / '.github/workflows/ci.yml').read_text(), r'\n  gate:\n')


if __name__ == '__main__':
    unittest.main()
