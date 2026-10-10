#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Create an allowlisted source-only DoD Sandbags ZIP, with no server/game data."""
import hashlib
import json
from pathlib import Path
import re
import zipfile

ROOT = Path(__file__).resolve().parents[1]
FILES = {
    'plugins/dod_sandbag.sma': 'addons/amxmodx/scripting/dod_sandbag.sma',
    'configs/dod_sandbag.cfg': 'addons/amxmodx/configs/plugins/dod_sandbag.cfg.example',
    'configs/lang/dod_sandbag.txt': 'addons/amxmodx/data/lang/dod_sandbag.txt',
    'scripts/generate-sandbag-model.py': 'tools/generate-sandbag-model.py',
    'README.md': 'README.md',
    'CONTRIBUTING.md': 'CONTRIBUTING.md',
    'CHANGELOG.md': 'CHANGELOG.md',
    'LICENSE.md': 'LICENSE.md',
    'LICENSES/GPL-3.0.txt': 'LICENSES/GPL-3.0.txt',
}


def package(destination=None):
    source = (ROOT / 'plugins/dod_sandbag.sma').read_text()
    version = re.search(r'#define PLUGIN_VERSION "([0-9]+\.[0-9]+\.[0-9]+)"', source)[1]
    directory = Path(destination) if destination else ROOT / 'build/releases'
    directory.mkdir(parents=True, exist_ok=True)
    archive = directory / f'dod_sandbag-{version}-source.zip'
    payloads = {target: (ROOT / origin).read_bytes() for origin, target in FILES.items()}
    manifest = {'plugin': 'dod_sandbag', 'version': version, 'type': 'source-only',
                'game': 'GoldSrc Day of Defeat 1.3', 'license': 'GPL-3.0-or-later',
                'files_sha256': {name: hashlib.sha256(data).hexdigest()
                                 for name, data in sorted(payloads.items())}}
    payloads['MANIFEST.json'] = (json.dumps(manifest, indent=2, sort_keys=True) + '\n').encode()
    with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_DEFLATED) as output:
        for name, data in sorted(payloads.items()):
            # Stable metadata permits byte-for-byte reproducible source archives.
            entry = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
            entry.compress_type = zipfile.ZIP_DEFLATED
            entry.external_attr = 0o100644 << 16
            output.writestr(entry, data)
    with zipfile.ZipFile(archive) as check:
        assert check.testzip() is None
        assert set(check.namelist()) == set(payloads)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    archive.with_suffix('.zip.sha256').write_text(f'{digest}  {archive.name}\n')
    return archive


if __name__ == '__main__':
    print(package())
