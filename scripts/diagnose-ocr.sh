#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/ocr-diagnostics
xcrun swiftc -swift-version 5 -parse-as-library -target arm64-apple-macos26.0 \
  -framework AppKit -framework Vision -framework CoreImage -framework CoreVideo \
  -framework CoreText -framework ImageIO scripts/diagnose-ocr.swift \
  -o .build/ocr-diagnostics/OCRDiagnostics
python3 - <<'PY'
from pathlib import Path
import plistlib
import shutil
import subprocess

root = Path('.build/ocr-diagnostics')
app = root / 'OCRDiagnostics.app'
macos = app / 'Contents/MacOS'
macos.mkdir(parents=True, exist_ok=True)
shutil.copy2(root / 'OCRDiagnostics', macos / 'OCRDiagnostics')
(app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
    'CFBundleIdentifier': 'com.radja.yuzu.qa.ocr-diagnostics',
    'CFBundleExecutable': 'OCRDiagnostics',
    'CFBundlePackageType': 'APPL',
    'CFBundleVersion': '1',
    'LSMinimumSystemVersion': '26.0',
    'LSUIElement': True,
    'NSPrincipalClass': 'NSApplication',
}))
subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
cases = ['rgba-device-cpu', 'rgba-cpu-only', 'gray-buffer-device-cpu',
         'rgba-accurate-auto', 'rgba-accurate-en', 'large-rgba-accurate-auto',
         'large-gray-accurate-auto', 'gray-accurate-auto', 'gray-accurate-en',
         'gray-fast-en', 'gray-buffer-accurate-en', 'gray-buffer-cpu',
         'gray-buffer-fast-cpu', 'png-data-auto', 'gray-png-data-auto',
         'jpeg-data-en', 'revision1-gray-fast', 'revision2-gray-accurate', 'capabilities']
for case in cases:
    try:
        subprocess.run([str(macos / 'OCRDiagnostics'), case], check=True, timeout=60)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        print('OCR_PROCESS_ERROR', case, str(error), flush=True)
PY
