"""Marketing version parsing shared by the local command and release notes."""
import re


VERSION = r'(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)'
MARKETING = re.compile(rf"^(\s*MARKETING_VERSION:\s*)(['\"]?)({VERSION})\2([ \t]*(?:#.*)?)$", re.MULTILINE)


def version_tuple(value):
    if not re.fullmatch(VERSION, value):
        raise ValueError(f'版本号必须是 X.Y.Z：{value}')
    return tuple(map(int, value.split('.')))


def marketing_match(text):
    matches = list(MARKETING.finditer(text))
    if len(matches) != 1:
        raise ValueError('project.yml 必须有且仅有一个有效的 MARKETING_VERSION')
    return matches[0]
