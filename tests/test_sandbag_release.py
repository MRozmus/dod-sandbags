#!/usr/bin/env python3
"""Public source/configuration/package invariants (standard-library only)."""
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import tempfile
import unittest
import zipfile
import sys
sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[1]


class SandbagRelease(unittest.TestCase):
    def test_config_matches_registered_defaults(self):
        source = (ROOT / 'plugins/dod_sandbag.sma').read_text()
        registered = dict(re.findall(r'(?:bounded_cvar|create_cvar)\("(dod_sandbag_[a-z_]+)", "([^"\n]*)"', source))
        configured = dict(re.findall(r'^(dod_sandbag_[a-z_]+) "([^"\n]*)"$',
                                    (ROOT / 'configs/dod_sandbag.cfg').read_text(), re.M))
        self.assertEqual(registered, configured)
        self.assertEqual(len(registered), 12)
        self.assertIn('AutoExecConfig(true, "dod_sandbag")', source)
        self.assertIn('OnConfigsExecuted()', source)
        self.assertIn('create_cvar(name, value, FCVAR_NONE, description, true, minimum, true, maximum)', source)

    def test_english_dictionary_is_complete(self):
        source = (ROOT / 'plugins/dod_sandbag.sma').read_text()
        dictionary = (ROOT / 'configs/lang/dod_sandbag.txt').read_text()
        required = set(re.findall(r'"(SB_[A-Z_]+)"', source))
        keys = re.findall(r'^(SB_[A-Z_]+) = ', dictionary, re.M)
        self.assertEqual(required, set(keys))
        self.assertEqual(len(keys), len(set(keys)))
        self.assertIn('[en]', dictionary)
        self.assertTrue(source.isascii())
        self.assertTrue(dictionary.isascii())

    def test_documentation_matches_release(self):
        source = (ROOT / 'plugins/dod_sandbag.sma').read_text()
        version = re.search(r'#define PLUGIN_VERSION "([^"\n]+)"', source)[1]
        self.assertIn(f'# DoD Sandbags {version}', (ROOT / 'README.md').read_text())
        self.assertIn(f'// DoD Sandbags {version}', (ROOT / 'configs/dod_sandbag.cfg').read_text())
        releases = re.findall(r'^## ([0-9]+\.[0-9]+\.[0-9]+) - ',
                              (ROOT / 'CHANGELOG.md').read_text(), re.M)
        self.assertEqual(releases[0], version)
        for name in ('README.md', 'CONTRIBUTING.md', 'LICENSE.md', 'CHANGELOG.md'):
            for target in re.findall(r'\[[^\]]+\]\(([^)]+)\)', (ROOT / name).read_text()):
                if '://' not in target and not target.startswith('#'):
                    self.assertTrue((ROOT / target.split('#')[0]).is_file(), target)

    def test_package_has_only_public_source_files(self):
        spec = importlib.util.spec_from_file_location('sandbag_package', ROOT / 'scripts/package-sandbag.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as directory:
            archive = module.package(directory)
            first = archive.read_bytes()
            self.assertEqual(module.package(directory).read_bytes(), first)
            with zipfile.ZipFile(archive) as files:
                self.assertIsNone(files.testzip())
                manifest = json.loads(files.read('MANIFEST.json'))
                self.assertEqual(manifest['type'], 'source-only')
                for name, digest in manifest['files_sha256'].items():
                    self.assertEqual(hashlib.sha256(files.read(name)).hexdigest(), digest)
                for name in files.namelist():
                    self.assertFalse(name.endswith(('.amxx', '.mdl', '.log')))
                    self.assertFalse('environment.md' in name or 'server.cfg' in name)
                    self.assertFalse(name.startswith('/') or '..' in Path(name).parts)
                self.assertIn('addons/amxmodx/scripting/dod_sandbag.sma', files.namelist())
                self.assertIn('LICENSES/GPL-3.0.txt', files.namelist())
                self.assertIn('CONTRIBUTING.md', files.namelist())
                self.assertNotIn('PUBLISHING.md', files.namelist())
                public_text = b'\n'.join(files.read(name) for name in files.namelist())
                self.assertIsNone(re.search(rb'\b(?:10\.\d+\.\d+\.\d+|192\.168\.\d+\.\d+|172\.(?:1[6-9]|2[0-9]|3[01])\.\d+\.\d+)\b', public_text))
                self.assertIsNone(re.search(rb'/(?:Users|home)/[A-Za-z0-9_.-]+', public_text))


if __name__ == '__main__':
    unittest.main()
