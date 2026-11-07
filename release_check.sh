#!/bin/sh
set -eu
cd "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

# This checks the source bundle, not every file in the parent directory.
/usr/bin/env python3 - <<'PY'
from pathlib import Path
import re, sys
base = Path.cwd()
files = [base/'Core.swift', base/'Localization.swift', base/'main.swift', base/'Tests/CoreTests.swift', base/'Tests/WindowLifecycleTests.py', base/'Tests/TopBarSourceTests.py',
         base/'locales/en.json', base/'locales/zh-Hant.json', base/'locales/ja.json',
         base/'README.md', base/'build_app.sh', base/'.gitignore', base/'release_check.sh']
missing = [p.name for p in files if not p.is_file()]
if missing:
    sys.exit('Missing release files: ' + ', '.join(missing))
checks = {
    'possible team ID': re.compile(r'(?<!\w)[STOI]\d{4,6}(?!\w)'),
    'possible email': re.compile(r'(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b'),
    'common token format': re.compile(r'(?:\b(?:gh[pousr]|github_pat)_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9]{16,})'),
}
found = []
for p in files:
    data = p.read_text(encoding='utf-8')
    for label, pattern in checks.items():
        if pattern.search(data): found.append(f'{p.name}: {label}')
if found:
    sys.exit('Potential sensitive data found; manually review: ' + ', '.join(found))
# A release bundle must never include local config and session captures.
allowed = {p.resolve() for p in files}
for p in base.rglob('*'):
    if p.is_file() and p.resolve() not in allowed:
        found.append(p.relative_to(base).as_posix())
if found:
    sys.exit('Unexpected files in release folder: ' + ', '.join(found))
# Ensure all locale files parse as mapping documents and that translated
# placeholders match their source counterparts.
import json
packs = {}
for code in ('en', 'zh-Hant', 'ja'):
    file = base/'locales'/f'{code}.json'
    packs[code] = json.loads(file.read_text(encoding='utf-8'))
    if not isinstance(packs[code], dict) or not all(isinstance(k, str) and isinstance(v, str) for k,v in packs[code].items()):
        sys.exit(f'Invalid language pack: {code}')
    for k,v in packs[code].items():
        src_tokens = set(re.findall(r'{{[a-zA-Z0-9_]+}}', k))
        dst_tokens = set(re.findall(r'{{[a-zA-Z0-9_]+}}', v))
        if src_tokens != dst_tokens:
            sys.exit(f'Placeholder mismatch in {code}: {k}')
print('Privacy/source packaging and language-pack checks passed.')
PY
if command -v swiftc >/dev/null 2>&1; then
    swiftc -parse Core.swift Localization.swift main.swift Tests/CoreTests.swift
    echo 'Swift source syntax parse passed.'
fi
