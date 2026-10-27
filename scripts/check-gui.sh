#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/prepare-native.sh
python3 - "$@" <<'PY'
import os
import subprocess
import re
import sys
import uuid
from pathlib import Path

manifest = Path('.brisk.toml').read_text()
framework_block = re.search(r'frameworks\s*=\s*\[(.*?)\]', manifest, re.S)
if framework_block is None:
    raise SystemExit('Missing framework list in .brisk.toml')
frameworks = re.findall(r'"([A-Za-z0-9_]+)"', framework_block.group(1))
output = Path('.build/debug/YuzuGUIValidation')
sources = sorted(str(p) for p in Path('Sources').rglob('*.swift') if p != Path('Sources/App.swift'))
tests = sorted(str(p) for p in Path('Tests').rglob('*.swift'))
command = ['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', '-D', 'YUZU_OWNED_GUI_BINARY', '-target', 'arm64-apple-macos26.0', *sources, *tests]
for framework in frameworks:
    command += ['-framework', framework]
command += ['-o', str(output)]
if '--no-build' not in sys.argv[1:]:
    subprocess.run(command, check=True)
elif not output.is_file():
    raise SystemExit('No GUI test binary; run without --no-build first')
environment = dict(os.environ, YUZU_OWNED_GUI_TESTS='1', YUZU_QA_DEFAULTS_SUITE='YuzuQA-GUI-' + str(uuid.uuid4()))
try:
    result = subprocess.run([str(output)], env=environment, timeout=600)
finally:
    subprocess.run(['/usr/bin/defaults', 'delete', environment['YUZU_QA_DEFAULTS_SUITE']], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
raise SystemExit(result.returncode)
PY
