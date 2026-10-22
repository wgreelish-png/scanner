#!/usr/bin/env python3
"""Check bundled recognition dependency closure and pinned asset integrity (no network)."""
import hashlib
import json
from pathlib import Path
import posixpath
import re

ROOT = Path(__file__).resolve().parents[1] / 'CardShowScanner/Resources/ScannerRuntime'
manifest = json.loads((ROOT / 'manifest.json').read_text())
paths = {item['path'] for item in manifest['files']}
required = {'/newscanplus/assets/js/' + p for p in (
    'core/pack.js', 'core/overlay.js', 'app/quickscan.js', 'app/scan-backends.js',
    'app/quickscan-worker.js', 'app/module-graph.js', 'app/scan-engine.js',
    'app/image-scan.js', 'app/image-ocr.js', 'app/shared.js')}
required |= {'/newscanplus/assets/vendor/' + p for p in ('opencv-nsp-412.js', 'opencv-nsp-412-simd.js')}
assert required <= paths, f'Missing runtime entry points: {required - paths}'
for item in manifest['files']:
    file = ROOT / item['path'].lstrip('/')
    data = file.read_bytes()
    assert len(data) == item['bytes'], f'Wrong asset length: {file}'
    assert hashlib.sha256(data).hexdigest() == item['sha256'], f'Changed asset: {file}'
    assert not data.lstrip().lower().startswith(b'<!doctype html'), f'HTML response saved as JavaScript: {file}'
    if '/assets/js/' not in item['path']:
        continue
    source = re.sub(r'/\*[\s\S]*?\*/', '', data.decode())
    for spec in re.findall(r'''['"]((?:\.{1,2}/|/newscanplus/)[^'"]+\.js)['"]''', source):
        path = posixpath.normpath(posixpath.join(posixpath.dirname(item['path']), spec)) if spec.startswith('.') else spec
        assert path in paths, f'Missing dependency: {item["path"]} -> {path}'
html = (ROOT / 'index.html').read_text()
assert 'src="https://' not in html, 'Scanner startup must not load remote scripts'
print(f'PASS: {len(paths)} pinned recognition assets, dependency closure, and local entry page')
