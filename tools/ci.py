#!/usr/bin/env python3
"""Cloud side of the Lossless test and release flow. Runs only on GitHub macOS runners.

    python3 tools/ci.py check     static checks and tool tests (also run locally by ship.py)
    python3 tools/ci.py gate      PR gate: the Dev plan and executor on the PR merge result
    python3 tools/ci.py test      manual or weekly run: --full, or --only Target/Class[/method]
    python3 tools/ci.py dev       main only: reuse a matching PR proof or test, then publish
    python3 tools/ci.py preview   pushed branch: build and publish a preview, no simulator tests

PR gate and Dev share one plan: changes since the last dev release, selected by
tools/select_tests.py. A passing gate leaves .ship/proof.json; Dev reuses it when
main is that same tree with the same plan, and otherwise runs the same tests itself.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
import select_tests  # noqa: E402

SHIP = ROOT / '.ship'
PLAN = SHIP / 'plan.json'
PROOF = SHIP / 'proof.json'
REPO = os.environ.get('GITHUB_REPOSITORY', 'iskerwin/LosslessPlayer')
BUNDLE_ID = 'com.iskerwin.LosslessPlayer'
IPA_NAME = 'LosslessPlayer-dev-unsigned.ipa'
SCREENSHOTS = ('library.png', 'songs.png', 'playlist.png', 'now-playing.png')
SELECTOR = re.compile(r'LosslessPlayer(?:UI)?Tests(?:/[A-Za-z_]\w*){0,2}')
# Phase limits. A limit is a failure, never a pass.
UNIT_MINUTES = 15
UI_MINUTES = 20
IPA_MINUTES = 20


class Failure(Exception):
    pass


def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT, text=True).strip()


def run(command, log=None, timeout=None, env=None):
    print('▶', ' '.join(command), flush=True)
    handle = open(log, 'w') if log else None
    try:
        process = subprocess.Popen(command, cwd=ROOT, env=env, text=True,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        started = time.monotonic()
        for line in process.stdout:
            sys.stdout.write(line)
            if handle:
                handle.write(line)
            if timeout and time.monotonic() - started > timeout:
                process.kill()
                raise Failure(f'{command[0]} 超过 {timeout // 60} 分钟时限')
        if process.wait(timeout=60):
            raise Failure(f'{" ".join(command[:2])} 失败（退出码 {process.returncode}）')
    finally:
        if handle:
            handle.close()


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + '\n')


def summary(text):
    print(text, flush=True)
    if os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as target:
            target.write(text + '\n')


# ---- builds and tags ------------------------------------------------------

def tag_build(tag):
    """dev-155-2 and dev-156 both carry build 155/156; anything else is None."""
    match = re.fullmatch(r'dev-(\d+)(?:-\d+)?', tag)
    return int(match.group(1)) if match else None


def source_builds(source):
    builds = []
    for app in source.get('apps', []):
        for version in app.get('versions', []):
            match = re.fullmatch(r'(\d+)(?:\.\d+)?', str(version.get('buildVersion', '')))
            if match:
                builds.append(int(match.group(1)))
    return builds


def next_build(tags, source):
    """One more than every dev tag and every listed build, so AltStore always sees an update."""
    known = [b for b in map(tag_build, tags) if b is not None] + source_builds(source)
    if not known:
        raise Failure('找不到已有构建号，拒绝从头编号')
    return max(known) + 1


def preview_build(tags, source):
    """Previews are N.k after the newest dev build N; the next dev N+1 replaces them."""
    base = next_build(tags, source) - 1
    taken = [int(m.group(1)) for t in tags for m in [re.fullmatch(rf'preview-{base}\.(\d+)', t)] if m]
    return f'{base}.{max(taken, default=0) + 1}'


def last_dev_base(tags):
    """Commit of the newest dev tag that is an ancestor of HEAD, or None."""
    for tag in sorted((t for t in tags if tag_build(t) is not None), key=tag_build, reverse=True):
        commit = git('rev-list', '-n', '1', tag)
        if subprocess.run(['git', 'merge-base', '--is-ancestor', commit, 'HEAD'], cwd=ROOT).returncode == 0:
            return tag, commit
    return None, None


def all_tags():
    return git('tag', '-l').split()


# ---- plan and proof -------------------------------------------------------

def make_plan(full=False, only=()):
    head = git('rev-parse', 'HEAD')
    plan = dict(schema=1, head=head, tree=git('rev-parse', 'HEAD^{tree}'))
    if only:
        bad = [s for s in only if not SELECTOR.fullmatch(s)]
        if bad:
            raise Failure(f'测试选择器格式应为 Target/Class[/method]：{bad}')
        unit = [s for s in only if not s.startswith('LosslessPlayerUITests')]
        ui = [s for s in only if s.startswith('LosslessPlayerUITests')]
        plan.update(base=None, base_tag=None, changed=[], full=False, reason='手动指定',
                    only_testing=[f'-only-testing:{s}' for s in unit], ui=bool(ui),
                    ui_testing=[f'-only-testing:{s}' for s in ui])
        return plan
    tag, base = (None, None) if full else last_dev_base(all_tags())
    changed = []
    if base:
        changed = [p for p in subprocess.check_output(
            ['git', 'diff', '--name-only', '--no-renames', '-z', f'{base}...HEAD'], cwd=ROOT
        ).decode().split('\0') if p]
        selection = select_tests.select_tests(changed)
    else:
        selection = select_tests.full_selection('完整全量' if full else '找不到上一个开发版，按全量')
    plan.update(base=base, base_tag=tag, changed=changed, full=selection['full'],
                reason=selection['reason'], only_testing=selection['only_testing'],
                ui=selection['screenshots'], ui_testing=['-only-testing:LosslessPlayerUITests'])
    return plan


def plan_key(plan):
    """What a proof must match besides the tree: the same baseline and the same tests."""
    fields = {k: plan[k] for k in ('base', 'full', 'only_testing', 'ui', 'ui_testing')}
    return hashlib.sha256(json.dumps(fields, sort_keys=True).encode()).hexdigest()


def describe(plan, title):
    lines = [f'## {title}', '',
             f'- 基线：{plan["base_tag"] or "无"}（{(plan["base"] or "")[:7]}）',
             f'- 改动文件：{len(plan["changed"])} 个',
             f'- 原因：{plan["reason"]}',
             f'- 单元测试：{" ".join(plan["only_testing"]) or "无"}',
             f'- 界面测试：{" ".join(plan["ui_testing"]) if plan["ui"] else "不跑"}', '']
    return '\n'.join(lines)


def proof_matches(proof, plan):
    return (proof.get('schema') == 1 and proof.get('tree') == plan['tree']
            and proof.get('plan_key') == plan_key(plan)
            and proof.get('unit_passed', 0) + proof.get('ui_passed', 0) > 0)


def find_pr_proof(plan):
    """The newest passing PR gate whose tree and plan equal this run's, or None."""
    runs = json.loads(subprocess.check_output(
        ['gh', 'run', 'list', '-R', REPO, '--workflow', 'ci.yml', '--event', 'pull_request',
         '--status', 'success', '-L', '30', '--json', 'databaseId,url'], text=True))
    for item in runs:
        with tempfile.TemporaryDirectory() as folder:
            name = f'lossless-pr-proof-{item["databaseId"]}'
            got = subprocess.run(['gh', 'run', 'download', str(item['databaseId']), '-R', REPO,
                                  '-n', name, '-D', folder], capture_output=True)
            path = Path(folder) / 'proof.json'
            if got.returncode == 0 and path.is_file():
                proof = json.loads(path.read_text())
                if proof_matches(proof, plan):
                    return dict(proof, url=item['url'])
    return None


# ---- simulator tests ------------------------------------------------------

def prepare(simulator=True):
    """Pin the newest Xcode 26, generate the project and (for tests) boot one iPhone simulator."""
    apps = sorted(Path('/Applications').glob('Xcode_26*.app'), key=lambda p: [
        int(n) for n in re.findall(r'\d+', p.name)])
    if not apps:
        raise Failure('执行机上没有 Xcode 26')
    run(['sudo', 'xcode-select', '-s', str(apps[-1])])
    run(['xcodebuild', '-version'])
    if not shutil.which('xcodegen'):
        run(['brew', 'install', 'xcodegen'], env=dict(os.environ, HOMEBREW_NO_AUTO_UPDATE='1'))
    run(['xcodegen', 'generate'])
    if not simulator:
        return None
    data = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'available', '--json']))
    devices = [d for runtime, items in data['devices'].items() if 'iOS-26' in runtime
               for d in items if 'iPhone' in d['name']]
    if not devices:
        raise Failure('没有可用的 iOS 26 iPhone 模拟器')
    udid = sorted(devices, key=lambda d: d['name'])[0]['udid']
    subprocess.run(['xcrun', 'simctl', 'boot', udid], capture_output=True)
    run(['xcrun', 'simctl', 'bootstatus', udid, '-b'], timeout=8 * 60)
    return udid


def passed_count(result):
    """Passed tests in an xcresult; any failure, skip-only or unreadable result is an error."""
    data = json.loads(subprocess.check_output(
        ['xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', str(result)], text=True))
    passed, failed = data.get('passedTests', 0), data.get('failedTests', 0)
    if failed or not passed:
        raise Failure(f'{result.name}：通过 {passed}，失败 {failed}')
    return passed


def xcodebuild_test(udid, selectors, result, minutes, env=None):
    if result.exists():
        shutil.rmtree(result)
    run(['xcodebuild', 'test', '-project', 'LosslessPlayer.xcodeproj', '-scheme', 'LosslessPlayer',
         '-destination', f'platform=iOS Simulator,id={udid}', *selectors,
         '-parallel-testing-enabled', 'NO', '-maximum-concurrent-test-simulator-destinations', '1',
         '-derivedDataPath', 'build/simulator', '-resultBundlePath', str(result),
         'CODE_SIGNING_ALLOWED=YES', 'CODE_SIGN_IDENTITY=-'],
        log=ROOT / f'{result.stem}.log', timeout=minutes * 60, env=env)
    return passed_count(result)


def execute(plan):
    """Run exactly the planned tests; returns the proof for this tree and plan."""
    udid = prepare()
    unit = ui = 0
    if plan['only_testing']:
        unit = xcodebuild_test(udid, plan['only_testing'], ROOT / 'TestResults.xcresult', UNIT_MINUTES)
    if plan['ui']:
        shots = ROOT / 'build/screenshots'
        temporary = Path('/tmp/lossless-screenshots')
        shots.mkdir(parents=True, exist_ok=True)
        try:
            ui = xcodebuild_test(udid, plan['ui_testing'], ROOT / 'build/UIResults.xcresult', UI_MINUTES,
                                 env=dict(os.environ, TEST_RUNNER_SCREENSHOT_DIR=str(shots)))
        finally:
            # Keep screenshots for diagnosis even when an interaction test fails.
            if temporary.is_dir():
                shutil.copytree(temporary, shots, dirs_exist_ok=True)
        if plan['ui_testing'] == ['-only-testing:LosslessPlayerUITests']:
            missing = [n for n in SCREENSHOTS if not (shots / n).is_file() or not (shots / n).stat().st_size]
            if missing:
                raise Failure(f'缺少截图：{missing}')
    if not unit and not ui:
        raise Failure('计划里没有实际执行的测试，零项不算通过')
    return dict(schema=1, sha=plan['head'], tree=plan['tree'], plan_key=plan_key(plan),
                unit_passed=unit, ui_passed=ui, run_id=os.environ.get('GITHUB_RUN_ID'))


# ---- packaging and publication --------------------------------------------

def build_ipa(build):
    """Unsigned arm64 Debug app for re-signing with AltStore/SideStore."""
    run(['xcodebuild', 'build', '-project', 'LosslessPlayer.xcodeproj', '-scheme', 'LosslessPlayer',
         '-configuration', 'Debug', '-sdk', 'iphoneos', '-destination', 'generic/platform=iOS',
         '-derivedDataPath', 'build/device', 'CODE_SIGNING_ALLOWED=NO',
         f'CURRENT_PROJECT_VERSION={build}'], log=ROOT / 'ipa-build.log', timeout=IPA_MINUTES * 60)
    payload = ROOT / 'build/ipa/Payload'
    if payload.exists():
        shutil.rmtree(payload)
    payload.mkdir(parents=True)
    app = payload / 'LosslessPlayer.app'
    shutil.copytree(ROOT / 'build/device/Build/Products/Debug-iphoneos/LosslessPlayer.app', app, symlinks=True)
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    checks = {
        'bundle id': info['CFBundleIdentifier'] == BUNDLE_ID,
        'iPhoneOS': 'iPhoneOS' in info['CFBundleSupportedPlatforms'],
        'audio background': 'audio' in info.get('UIBackgroundModes', []),
        'icon': info['CFBundleIcons']['CFBundlePrimaryIcon']['CFBundleIconName'] == 'AppIcon',
        'SDK 26': str(info['DTSDKName']).startswith('iphoneos26'),
        'Xcode 26': str(info['DTXcode']).startswith('26'),
        'iOS 17': info['MinimumOSVersion'] == '17.0',
        'build': str(info['CFBundleVersion']) == str(build),
    }
    bad = [name for name, ok in checks.items() if not ok]
    if bad:
        raise Failure(f'安装包校验失败：{bad}')
    run(['lipo', str(app / info['CFBundleExecutable']), '-verify_arch', 'arm64'])
    dist = ROOT / 'dist'
    dist.mkdir(exist_ok=True)
    ipa = dist / IPA_NAME
    if ipa.exists():
        ipa.unlink()
    run(['ditto', '-c', '-k', '--keepParent', str(payload), str(ipa)])
    with zipfile.ZipFile(ipa) as archive:
        if archive.testzip() is not None:
            raise Failure('IPA 压缩包损坏')
    digest = hashlib.sha256(ipa.read_bytes()).hexdigest()
    (dist / 'SHA256SUMS.txt').write_text(f'{digest}  {IPA_NAME}\n')
    return ipa, info


def source_entry(previous, info, tag, size, description):
    entry = dict(previous)
    entry.update({
        'version': info['CFBundleShortVersionString'],
        'buildVersion': str(info['CFBundleVersion']),
        'date': datetime.date.today().isoformat(),
        'downloadURL': f'https://github.com/{REPO}/releases/download/{tag}/{IPA_NAME}',
        'size': size,
        'localizedDescription': description,
    })
    return entry


def updated_source(source, entry, keep=10):
    """Newest first. Only the newest preview is listed, and a dev build drops older previews."""
    app = source['apps'][0]
    build = int(entry['buildVersion'].split('.')[0])
    preview = '.' in entry['buildVersion']

    def kept(version):
        number = str(version.get('buildVersion', ''))
        if number == entry['buildVersion']:
            return False
        if '.' in number:
            return not preview and int(number.split('.')[0]) >= build
        return True

    versions = [v for v in app.get('versions', []) if kept(v)]
    versions.insert(0, entry)
    app['versions'] = versions[:keep]
    return source


def push_source(entry, tag):
    """Update main's apps.json (the subscribed AltStore URL); retry when main moved."""
    for attempt in range(3):
        run(['git', 'fetch', '-q', 'origin', 'main'])
        run(['git', 'checkout', '-q', '-B', 'source-update', 'origin/main'])
        path = ROOT / 'apps.json'
        source = updated_source(json.loads(path.read_text()), entry)
        path.write_text(json.dumps(source, ensure_ascii=False, indent=2) + '\n')
        run(['git', 'add', 'apps.json'])
        run(['git', 'commit', '-q', '-m', f'Update AltStore source for {tag} [skip ci]'])
        if subprocess.run(['git', 'push', 'origin', 'HEAD:main'], cwd=ROOT).returncode == 0:
            return
        print(f'安装源推送被拒绝，第 {attempt + 1} 次重试', flush=True)
    raise Failure('安装源三次推送都失败；安装包已发布，安装源未更新')


def notes(kind, plan, proof, sha):
    scope = (f'测试由 PR 检查完成并复用：{proof["url"]}' if proof.get('url')
             else f'本次运行：单元测试通过 {proof["unit_passed"]} 项，界面测试通过 {proof["ui_passed"]} 项')
    head = ('Lossless 预览包，合并前上手机确认用；下一个开发版会覆盖它。'
            if kind == 'preview' else 'Lossless 开发版（iOS 17+，arm64，Debug）。')
    return '\n\n'.join([
        head,
        f'源码：{sha}。{scope}' if proof else f'源码：{sha}。预览包只编译，不跑模拟器测试（测试由 PR 检查负责）。',
        f'测试范围：{plan["reason"]}；基线 {plan["base_tag"] or "无"}。' if plan else '',
        '本 IPA 未经过 Apple 开发者证书签名，请用 AltStore 等工具以自己的 Apple ID 重新签名后安装。'
        '可用 SHA256SUMS.txt 校验下载文件。',
    ]).strip()


def publish(kind, tag, ipa, info, text, sha):
    notes_file = ROOT / 'dist/release-notes.md'
    notes_file.write_text(text + '\n')
    title = f'Lossless {"预览" if kind == "preview" else "开发版"} {info["CFBundleVersion"]}'
    run(['gh', 'release', 'create', tag, '-R', REPO, '--target', sha, '--prerelease',
         '--title', title, '--notes-file', str(notes_file), str(ipa), str(ROOT / 'dist/SHA256SUMS.txt')])
    description = (f'{tag}：预览包（合并前确认用）。' if kind == 'preview' else f'{tag}：最新开发版。')
    push_source(source_entry(json.loads((ROOT / 'apps.json').read_text())['apps'][0]['versions'][0],
                             info, tag, ipa.stat().st_size, description), tag)


def require_latest_main(sha):
    remote = git('ls-remote', 'origin', 'refs/heads/main').split()[0]
    if remote != sha:
        raise Failure(f'main 已前进到 {remote[:7]}，旧源码不能发布开发版；请在最新 main 上重新运行')


# ---- commands -------------------------------------------------------------

def cmd_check(_):
    run([sys.executable, '-m', 'unittest', 'discover', '-s', 'tools', '-p', 'test_*.py'])
    run(['git', 'diff', '--check', 'HEAD'])
    for path in sorted((ROOT / '.github/workflows').glob('*.yml')):
        text = path.read_text()
        if '\t' in text:
            raise Failure(f'{path.name} 含制表符')


def cmd_gate(_):
    plan = make_plan()
    summary(describe(plan, 'PR 测试范围（与开发版相同）'))
    write_json(PLAN, plan)
    proof = execute(plan)
    if git('rev-parse', 'HEAD') != plan['head']:
        raise Failure('测试期间源码有变化，未留下 PR 测试记录')
    write_json(PROOF, proof)
    summary(f'PR 门禁通过：单元 {proof["unit_passed"]} 项，界面 {proof["ui_passed"]} 项；未发布安装包')


def cmd_test(args):
    plan = make_plan(full=args.full or not args.only, only=args.only)
    summary(describe(plan, '手动 / 每周测试范围'))
    write_json(PLAN, plan)
    proof = execute(plan)
    write_json(PROOF, proof)
    summary(f'测试通过：单元 {proof["unit_passed"]} 项，界面 {proof["ui_passed"]} 项；只验证，不发布')


def cmd_dev(_):
    sha = git('rev-parse', 'HEAD')
    if os.environ.get('GITHUB_REF') != 'refs/heads/main':
        raise Failure('开发版只能在 main 上发布')
    require_latest_main(sha)
    plan = make_plan()
    summary(describe(plan, '开发版测试范围'))
    write_json(PLAN, plan)
    proof = find_pr_proof(plan)
    if proof:
        summary(f'复用 PR 测试记录：{proof["url"]}（文件树和测试范围一致），只编译发布')
        prepare(simulator=False)
    else:
        summary('没有可复用的 PR 测试记录，运行同样的测试')
        proof = execute(plan)  # execute() already prepared Xcode and the project
    write_json(PROOF, proof)
    build = next_build(all_tags(), json.loads((ROOT / 'apps.json').read_text()))
    ipa, info = build_ipa(build)
    require_latest_main(sha)
    publish('dev', f'dev-{build}', ipa, info, notes('dev', plan, proof, sha), sha)
    summary(f'开发版 dev-{build} 已发布，安装源已更新')


def cmd_preview(_):
    sha = git('rev-parse', 'HEAD')
    build = preview_build(all_tags(), json.loads((ROOT / 'apps.json').read_text()))
    prepare(simulator=False)
    ipa, info = build_ipa(build)
    branch = os.environ.get('GITHUB_REF_NAME', git('rev-parse', '--abbrev-ref', 'HEAD'))
    text = notes('preview', None, None, sha) + f'\n\n分支：{branch}。预览包不能代替开发版。'
    publish('preview', f'preview-{build}', ipa, info, text, sha)
    summary(f'预览包 preview-{build} 已发布（分支 {branch}）')


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('check').set_defaults(func=cmd_check)
    commands.add_parser('gate').set_defaults(func=cmd_gate)
    test = commands.add_parser('test')
    test.add_argument('--full', action='store_true')
    test.add_argument('--only', nargs='*', default=[], help='Target/Class[/method]')
    test.set_defaults(func=cmd_test)
    commands.add_parser('dev').set_defaults(func=cmd_dev)
    commands.add_parser('preview').set_defaults(func=cmd_preview)
    args = parser.parse_args(argv)
    try:
        args.func(args)
    except (Failure, subprocess.CalledProcessError, OSError) as error:
        print(f'::error::{error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
