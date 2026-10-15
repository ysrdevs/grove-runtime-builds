import base64
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('package', Path(__file__).with_name('package.py'))
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)

class PackagingTests(unittest.TestCase):
    def test_parity_source_provenance_matches_each_php_branch(self):
        repo = Path(__file__).resolve().parents[2]
        for version in ["8.2.33", "8.3.33", "8.4.26", "8.5.11"]:
            metadata = {"version": version, "source": [{"filename": f"php-{version}.tar.xz", "sha256": "a" * 64}]}
            with patch.object(package.urllib.request, "urlopen", return_value=io.BytesIO(json.dumps(metadata).encode())):
                result = package.source_provenance(repo, version, "arm64")
            sources = result["sources"]
            php_extensions = {source["name"]: source for source in sources if source["kind"] == "source"}
            for name in ["imagick", "mongodb", "zstd", "lz4", "sqlsrv", "pdo_sqlsrv"]:
                self.assertIn(name, php_extensions)
            self.assertEqual(php_extensions["sqlsrv"]["version"], "5.13.3")
            self.assertEqual(php_extensions["pdo_sqlsrv"]["version"], "5.13.3")
            self.assertEqual("imap" in php_extensions, version.startswith(("8.4.", "8.5.")))
            self.assertIn("codeload.github.com/kjdev/php-ext-lz4/", php_extensions["lz4"]["url"])
            odbc = [source for source in sources if source["name"] == "unixodbc"]
            self.assertEqual(len(odbc), 1)
            self.assertEqual(odbc[0]["url"], "https://www.unixodbc.org/unixODBC-2.3.14.tar.gz")
            self.assertIn("Grove/Grove/Core/ManagedPHPParityDependencies.swift", result["recipeFiles"])
            self.assertTrue(all(len(source["sha256"]) == 64 for source in sources))

    def fixture(self, root):
        for name in ['bin/php', 'bin/php-fpm', 'modules/intl.so', 'modules/sodium.so', 'modules/xdebug.so', 'modules/spx.so', 'web-ui/index.html', 'licenses/PHP/LICENSE']:
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(('fixture ' + name).encode())

    def test_deterministic_archive_ignores_local_metadata(self):
        import os, tarfile
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / 'payload'; self.fixture(root)
            a, b = Path(directory) / 'a.tar.gz', Path(directory) / 'b.tar.gz'
            package.archive(root, a)
            for path in root.rglob('*'):
                os.utime(path, (1234567890, 1234567890))
                path.chmod(0o700)
            package.archive(root, b)
            self.assertEqual(a.read_bytes(), b.read_bytes())
            with tarfile.open(a) as bundle:
                for member in bundle.getmembers():
                    self.assertEqual(member.uid, 0)
                    self.assertEqual(member.mtime, 0)
                    self.assertEqual(member.mode, 0o755 if member.isdir() or member.name in ['bin/php','bin/php-fpm'] else 0o644)

    def test_inventory_detects_mutated_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); self.fixture(root)
            original = package.inventory(root)
            (root / 'modules/sodium.so').write_bytes(b'changed')
            self.assertNotEqual(original, package.inventory(root))
            self.assertEqual(len(original), 8)

    def test_inventory_rejects_links_missing_files_and_oversize(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); self.fixture(root)
            target = root / 'modules/intl.so'
            target.unlink(); target.symlink_to('/etc/passwd')
            with self.assertRaises(ValueError): package.inventory(root)
            target.unlink()
            with self.assertRaises(ValueError): package.inventory(root)
            target.write_bytes(b'x')
            previous = package.MAX_EXPANDED
            try:
                package.MAX_EXPANDED = 1
                with self.assertRaises(ValueError): package.inventory(root)
            finally: package.MAX_EXPANDED = previous

    def test_manifest_rejects_duplicate_variants_and_excessive_lifetime(self):
        import argparse
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); descriptor = root / 'package.json'
            descriptor.write_text(json.dumps({'phpVersion':'8.4.26','architecture':'arm64'}))
            args = argparse.Namespace(packages=[descriptor, descriptor], output=root/'manifest.json', valid_days=30)
            with self.assertRaises(ValueError): package.manifest(args)
            args.packages = [descriptor]; args.valid_days = 91
            with self.assertRaises(ValueError): package.manifest(args)

if __name__ == '__main__': unittest.main()
