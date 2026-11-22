#!/usr/bin/env python3
"""Local entry point. This Mac only edits, checks and dispatches; GitHub runs every build and test.

    uv run tools/ship.py check                    static checks and tool tests, same as the cloud's first step
    uv run tools/ship.py test [--full] [--only Target/Class[/method] ...]
                                                   verify the pushed current branch; never publishes
    uv run tools/ship.py preview                  pushed branch: build a phone preview (N.k), no simulator tests
    uv run tools/ship.py dev                      latest main: reuse the PR proof or test, then publish dev
    uv run tools/ship.py version patch|minor|major|X.Y.Z
                                                   raise marketing version and start a changelog section
    uv run tools/ship.py watch [--once]           follow the newest cloud runs
"""
import argparse
import os
from pathlib import Path
import re
import subprocess
import sys

from versioning import marketing_match, version_tuple

ROOT = Path(__file__).resolve().parents[1]
REPO = 'iskerwin/LosslessPlayer'


class Failure(Exception):
    pass


def out(*command):
    return subprocess.check_output(command, cwd=ROOT, text=True).strip()


def require_pushed(main_only):
    """Cloud runs check out GitHub's copy, so local edits must already be there."""
    branch = out('git', 'rev-parse', '--abbrev-ref', 'HEAD')
    if main_only and branch != 'main':
        raise Failure('只能在 main 上发起开发版；先 git checkout main && git pull')
    if not main_only and branch == 'main':
        raise Failure('test / preview 针对已推送的分支；main 上用 dev，或手动 CI')
    if out('git', 'status', '--porcelain', '--untracked-files=no'):
        raise Failure('有未提交的改动；云端只会测已推送的提交')
    subprocess.run(['git', 'fetch', '-q', 'origin', branch], cwd=ROOT, check=True)
    local, remote = out('git', 'rev-parse', 'HEAD'), out('git', 'rev-parse', f'origin/{branch}')
    if local != remote:
        raise Failure(f'{branch} 与 GitHub 不一致（本地 {local[:7]}，远端 {remote[:7]}）；先推送或拉取')
    return branch


def dispatch(workflow, branch, fields=()):
    command = ['gh', 'workflow', 'run', workflow, '-R', REPO, '--ref', branch]
    for key, value in fields:
        command += ['-f', f'{key}={value}']
    subprocess.run(command, cwd=ROOT, check=True)
    print(f'已发起 {workflow}（{branch}）；用 uv run tools/ship.py watch 查看进度')


def check(_):
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE='1')
    return subprocess.run([sys.executable, 'tools/ci.py', 'check'], cwd=ROOT, env=env).returncode


def test(args):
    branch = require_pushed(main_only=False)
    dispatch('ci.yml', branch, [('full', str(args.full or not args.only).lower()),
                                ('only', ' '.join(args.only))])


def preview(_):
    dispatch('preview.yml', require_pushed(main_only=False))


def dev(_):
    dispatch('dev.yml', require_pushed(main_only=True))


def version(args):
    project = ROOT / 'project.yml'
    text = project.read_text()
    try:
        match = marketing_match(text)
        current = version_tuple(match[3])
        if args.value in ('patch', 'minor', 'major'):
            index = {'major': 0, 'minor': 1, 'patch': 2}[args.value]
            parts = list(current)
            parts[index] += 1
            parts[index + 1:] = [0] * (2 - index)
            new = '.'.join(map(str, parts))
        else:
            new = args.value
        if version_tuple(new) <= current:
            raise ValueError(f'新版本 {new} 必须高于当前版本 {match[3]}')
    except ValueError as error:
        raise Failure(str(error)) from error
    changelog = ROOT / 'CHANGELOG.md'
    updated = None
    if changelog.exists():
        old = changelog.read_text()
        # Preserve the document title/preamble and all previous releases.
        section = re.search(r'^## ', old, re.MULTILINE)
        position = section.start() if section else len(old)
        preamble = old[:position].rstrip()
        updated = (preamble + '\n\n' if preamble else '') + f'## {new}（开发中）\n\n' + old[position:]
    project.write_text(text[:match.start(3)] + new + text[match.end(3):])
    if updated is not None:
        changelog.write_text(updated)
    else:
        print('CHANGELOG.md 不存在，已跳过新版本小节；文件引入后再维护更新记录。')
    print(f'版本已提高：{match[3]} → {new}')


def watch(args):
    subprocess.run(['gh', 'run', 'list', '-R', REPO, '-L', '8'], cwd=ROOT, check=True)
    if not args.once:
        run_id = out('gh', 'run', 'list', '-R', REPO, '-L', '1', '--json', 'databaseId', '-q', '.[0].databaseId')
        subprocess.run(['gh', 'run', 'watch', run_id, '-R', REPO, '--exit-status'], cwd=ROOT)


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('check').set_defaults(func=check)
    parsed = commands.add_parser('test')
    parsed.add_argument('--full', action='store_true')
    parsed.add_argument('--only', nargs='*', default=[])
    parsed.set_defaults(func=test)
    commands.add_parser('preview').set_defaults(func=preview)
    commands.add_parser('dev').set_defaults(func=dev)
    parsed = commands.add_parser('version')
    parsed.add_argument('value', help='patch / minor / major / X.Y.Z，必须高于当前版本')
    parsed.set_defaults(func=version)
    parsed = commands.add_parser('watch')
    parsed.add_argument('--once', action='store_true')
    parsed.set_defaults(func=watch)
    args = parser.parse_args(argv)
    try:
        return args.func(args) or 0
    except (Failure, subprocess.CalledProcessError) as error:
        print(f'未发起：{error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
