import importlib.util
import io
import json
import os
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('relink', Path(__file__).with_name('relink.py'))
relink = importlib.util.module_from_spec(spec)
spec.loader.exec_module(relink)


class RelinkTests(unittest.TestCase):
    def archive(self, directory, members):
        path = directory / 'fixture.tar.gz'
        with tarfile.open(path, 'w:gz') as archive:
            for member in members:
                contents = b'fixture'
                if member.isfile():
                    member.size = len(contents)
                archive.addfile(member, io.BytesIO(contents) if member.isfile() else None)
        return path

    def test_library_extracts_sources_and_preserves_configure_executable(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            configure = tarfile.TarInfo('gettext-0.26/configure'); configure.mode = 0o4755
            archive = self.archive(root, [configure, tarfile.TarInfo('gettext-0.26/intl/source.c')])
            destination = root / 'sources'; destination.mkdir()
            relink.extract_library(archive, destination, 'gettext-0.26')
            self.assertEqual((destination / 'gettext-0.26/configure').read_bytes(), b'fixture')
            self.assertEqual((destination / 'gettext-0.26/configure').stat().st_mode & 0o7777, 0o755)

    def test_library_rejects_links_and_special_files_before_any_write(self):
        for kind in [tarfile.SYMTYPE, tarfile.LNKTYPE, tarfile.FIFOTYPE, tarfile.CHRTYPE, tarfile.BLKTYPE]:
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                escape = tarfile.TarInfo('gettext-0.26/escape')
                escape.type = kind; escape.linkname = str(root / 'outside')
                archive = self.archive(root, [tarfile.TarInfo('gettext-0.26/valid.c'), escape,
                                              tarfile.TarInfo('gettext-0.26/escape/file')])
                destination = root / 'sources'; destination.mkdir()
                with self.assertRaisesRegex(ValueError, 'Unsafe library archive'):
                    relink.extract_library(archive, destination, 'gettext-0.26')
                self.assertEqual(list(destination.iterdir()), [])
                self.assertFalse((root / 'outside').exists())

    def test_library_rejects_parent_absolute_and_other_library_paths(self):
        for name in ['../escaped', '/tmp/escaped', 'gettext-0.26/../../escaped', 'other-library/source.c']:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                archive = self.archive(root, [tarfile.TarInfo(name)])
                destination = root / 'sources'; destination.mkdir()
                with self.assertRaisesRegex(ValueError, 'Unsafe library archive'):
                    relink.extract_library(archive, destination, 'gettext-0.26')
                self.assertEqual(list(destination.iterdir()), [])

    def test_library_rejects_existing_filesystem_symlink_escape(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            outside = root / 'outside'; outside.mkdir()
            destination = root / 'sources'; destination.mkdir()
            (destination / 'gettext-0.26').symlink_to(outside)
            archive = self.archive(root, [tarfile.TarInfo('gettext-0.26/source.c')])
            with self.assertRaisesRegex(ValueError, 'Unsafe library archive'):
                relink.extract_library(archive, destination, 'gettext-0.26')
            self.assertEqual(list(outside.iterdir()), [])

    def fixture(self, root):
        (root / 'php').mkdir(parents=True)
        (root / 'libraries/lib').mkdir(parents=True)
        config = {'architecture': 'arm64', 'originalPHPDirectory': '/private/tmp/original/php',
                  'originalLibraryPrefix': '/private/tmp/original/libraries'}
        (root / 'kit.json').write_text(json.dumps(config))
        for name in ['configure', 'libtool', 'config.status']:
            (root / 'php' / name).write_text('#!/bin/sh\n')
            (root / 'php' / name).chmod(0o644)
        return config

    def test_prepare_relocates_metadata_preserving_objects_sources_and_mtimes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); source = root / 'kit'; self.fixture(source)
            original = ('/private/tmp/original/php/source.c /tmp/original/libraries/lib/libintl.a '
                        '/Applications/Xcode-old.app/SDKs/MacOSX14.0.sdk')
            metadata = source / 'php/Makefile'; metadata.write_text(original)
            os.utime(metadata, ns=(1234567890000000000, 1234567890000000000))
            (source / 'php/source.c').write_text(original)
            (source / 'php/source.o').write_bytes(b'\x00\xff/private/tmp/original/php')
            workspace = root / 'relocated'
            with patch.object(relink, 'environment', return_value={'SDKROOT': '/SDKs/MacOSX-current.sdk'}):
                relink.prepare(source, workspace)
            expected = f'{workspace}/php/source.c {workspace}/libraries/lib/libintl.a /SDKs/MacOSX-current.sdk'
            self.assertEqual((workspace / 'php/Makefile').read_text(), expected)
            self.assertEqual((workspace / 'php/Makefile').stat().st_mtime_ns, metadata.stat().st_mtime_ns)
            self.assertEqual((workspace / 'php/source.c').read_text(), original)
            self.assertEqual((workspace / 'php/source.o').read_bytes(), (source / 'php/source.o').read_bytes())
            self.assertEqual((workspace / 'php/libtool').stat().st_mode & 0o777, 0o755)
            self.assertTrue(json.loads((workspace / 'kit.json').read_text())['prepared'])

    def test_prepare_rejects_existing_workspace_without_altering_it(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); source = root / 'kit'; self.fixture(source)
            destination = root / 'existing'; destination.mkdir()
            sentinel = destination / 'keep'; sentinel.write_text('keep')
            with self.assertRaises(ValueError): relink.prepare(source, destination)
            self.assertEqual(sentinel.read_text(), 'keep')


if __name__ == '__main__': unittest.main()
