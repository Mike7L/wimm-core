"""Build the Chrome Web Store package with manifest.json at the ZIP root."""
import hashlib
import json
import re
import zipfile
from pathlib import Path

repo = Path(__file__).resolve().parents[1]
source = repo / 'extension'
manifest = json.loads((source / 'manifest.json').read_text('utf-8'))
version = manifest['version']
if not re.fullmatch(r'(?:0|[1-9]\d*)(?:\.(?:0|[1-9]\d*)){0,3}', version) or max(map(int, version.split('.'))) > 65535 or not any(map(int, version.split('.'))):
    raise SystemExit('Invalid extension version')
build = repo / 'dist'
build.mkdir(exist_ok=True)
target = build / f'Wimm-{version}.zip'
with zipfile.ZipFile(target, 'w') as package:
    for file in sorted(source.rglob('*')):
        if not file.is_file():
            continue
        name = file.relative_to(source).as_posix()
        item = zipfile.ZipInfo(name, date_time=(2026,1,1,0,0,0))
        item.external_attr = 0o100644 << 16
        item.compress_type = zipfile.ZIP_STORED if name.endswith('.gz') else zipfile.ZIP_DEFLATED
        package.writestr(item,file.read_bytes())
digest = hashlib.sha256(target.read_bytes()).hexdigest()
(build / 'SHA256SUMS').write_text(f'{digest}  {target.name}\n')
print(target)
