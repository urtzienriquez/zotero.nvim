#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
python3 -c "
import zipfile
files = ['bootstrap.js', 'prefs.js', 'manifest.json']
out = 'zotero-nvim-connector@urtzi.xpi'
with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as zf:
    for f in files:
        zf.write(f, f)
print(f'Built: {out}')
"
