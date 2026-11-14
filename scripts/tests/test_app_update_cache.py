import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('app_update_cache', Path(__file__).parents[1] / 'app_update_cache.py')
cache = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cache)


class UpdateCacheTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.binary = self.root / '.build/release/wimm'
        self.cli = self.binary.with_name('WimmCLI')
        for path in (self.binary, self.cli, self.root / 'Wimm.app/Contents/MacOS/Wimm',
                     self.root / 'WimmCLI.app/Contents/MacOS/WimmCLI'):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('executable')
        self.addCleanup(patch.stopall)
        patch.object(Path, 'home', return_value=self.root / 'home').start()
        patch.dict(os.environ, {}, clear=True).start()
        self.run = patch.object(cache.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, stdout='42')).start()

    def action(self, action):
        with patch('sys.argv', ['cache', action, '--root', str(self.root),
                                '--binary', str(self.binary), '--cli', str(self.cli)]):
            return cache.main()

    def test_unchanged_update_and_no_plaintext_secrets(self):
        os.environ['GEMINI_API_KEY'] = 'test-secret-never-persist'
        self.assertEqual(self.action('record'), 0)
        self.assertEqual(self.action('check'), 0)
        receipt = self.root / '.build/wimm-update-receipt.json'
        self.assertNotIn('test-secret', receipt.read_text())

    def test_changed_binary_with_preserved_timestamp(self):
        self.assertEqual(self.action('record'), 0)
        stat = self.binary.stat()
        self.binary.write_text('changed executable')
        os.utime(self.binary, ns=(stat.st_atime_ns, stat.st_mtime_ns))
        self.assertEqual(self.action('check'), 1)

    def test_resource_added_and_removed(self):
        resource = self.binary.parent / 'Resources.bundle/data'
        resource.parent.mkdir()
        resource.write_text('resource')
        self.assertEqual(self.action('record'), 0)
        resource.unlink()
        self.assertEqual(self.action('check'), 1)
        resource.write_text('resource')
        self.assertEqual(self.action('check'), 0)
        resource.with_name('new').write_text('new')
        self.assertEqual(self.action('check'), 1)

    def test_changed_signing_settings_or_output(self):
        self.assertEqual(self.action('record'), 0)
        os.environ['CODESIGN_ID'] = 'another identity'
        self.assertEqual(self.action('check'), 1)
        del os.environ['CODESIGN_ID']
        (self.root / 'Wimm.app/Contents/MacOS/Wimm').write_text('tampered')
        self.assertEqual(self.action('check'), 1)

    def test_invalid_signature_never_reused_or_recorded(self):
        self.assertEqual(self.action('record'), 0)
        self.run.side_effect = lambda args, **kw: subprocess.CompletedProcess(args, 1 if args[0] == 'codesign' else 0, stdout='42')
        self.assertEqual(self.action('check'), 1)
        self.assertEqual(self.action('record'), 1)

    def test_studio_has_separate_receipt_and_tracks_packaging_inputs(self):
        app = self.root / 'Wimm Studio.app/Contents/MacOS/wimm-studio'
        app.parent.mkdir(parents=True)
        app.write_text('studio')
        args = ['cache', 'record', '--kind', 'studio', '--root', str(self.root),
                '--binary', str(self.binary)]
        with patch('sys.argv', args):
            self.assertEqual(cache.main(), 0)
        args[1] = 'check'
        with patch('sys.argv', args):
            self.assertEqual(cache.main(), 0)
            entitlements = self.root / 'WimmLocal.entitlements'
            entitlements.write_text('changed permissions')
            self.assertEqual(cache.main(), 1)
        self.assertTrue((self.root / '.build/studio-update-receipt.json').is_file())
        self.assertFalse((self.root / '.build/wimm-update-receipt.json').exists())

    def test_no_receipt_is_a_cache_miss(self):
        self.assertEqual(self.action('check'), 1)

    def test_studio_signing_changes_invalidate_package(self):
        original = cache.input_digest(self.root, self.binary, None, 'studio')
        os.environ['CODESIGN_ID'] = 'Apple Development: Test'
        signed = cache.input_digest(self.root, self.binary, None, 'studio')
        self.assertNotEqual(original, signed)
        os.environ['WIMM_BUILD_SIGNING_IDENTITIES'] = 'new certificate'
        self.assertNotEqual(signed, cache.input_digest(self.root, self.binary, None, 'studio'))


if __name__ == '__main__':
    unittest.main()
