#!/usr/bin/env python3
"""Local entry point. This Mac only edits, checks and dispatches; GitHub runs every build and test.

    python3 tools/ship.py check                    static checks and tool tests, same as the cloud's first step
    python3 tools/ship.py test [--full] [--only Target/Class[/method] ...]
                                                   verify the pushed current branch; never publishes
    python3 tools/ship.py preview                  pushed branch: build a phone preview (N.k), no simulator tests
    python3 tools/ship.py dev                      latest main: reuse the PR proof or test, then publish dev
    python3 tools/ship.py watch [--once]           follow the newest cloud runs
"""
import argparse
import os
from pathlib import Path
import subprocess
import sys

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
    print(f'已发起 {workflow}（{branch}）；用 python3 tools/ship.py watch 查看进度')


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
