#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/prepare-native.sh
python3 - "$@" <<'PY'
import os
import plistlib
import shutil
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
# Exercise the same bundle/signature boundary as the production application.
# System Vision services may treat a bare linker-signed executable differently.
app = Path('.build/debug/YuzuGUIValidation.app')
contents = app / 'Contents'
macos = contents / 'MacOS'
resources = contents / 'Resources'
macos.mkdir(parents=True, exist_ok=True)
resources.mkdir(parents=True, exist_ok=True)
shutil.copy2(output, macos / output.name)
shutil.copy2('.build/native/libyuzuwebp.dylib', resources / 'libyuzuwebp.dylib')
for notice in ['libwebp-COPYING.txt', 'libwebp-PATENTS.txt']:
    shutil.copy2(Path('Resources') / notice, resources / notice)
(contents / 'Info.plist').write_bytes(plistlib.dumps({
    'CFBundleIdentifier': 'com.radja.yuzu.qa',
    'CFBundleExecutable': output.name,
    'CFBundleName': 'Yuzu GUI Validation',
    'CFBundlePackageType': 'APPL',
    'CFBundleVersion': '1',
    'LSMinimumSystemVersion': '26.0',
    'LSUIElement': True,
    'NSPrincipalClass': 'NSApplication',
    'NSSupportsAutomaticTermination': False,
}))
subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
environment = dict(os.environ, YUZU_OWNED_GUI_TESTS='1', YUZU_QA_DEFAULTS_SUITE='YuzuQA-GUI-' + str(uuid.uuid4()))
try:
    result = subprocess.run([str(macos / output.name)], env=environment, timeout=600)
finally:
    subprocess.run(['/usr/bin/defaults', 'delete', environment['YUZU_QA_DEFAULTS_SUITE']], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
raise SystemExit(result.returncode)
PY
