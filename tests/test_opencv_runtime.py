"""Offline portability checks, compatible with stock Command Line Tools Python3.9."""

import hashlib
import importlib.machinery
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/prepare-opencv-runtime'
LOADER = importlib.machinery.SourceFileLoader('board_runtime', str(SCRIPT))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
runtime = importlib.util.module_from_spec(SPEC)
LOADER.exec_module(runtime)


class OpenCVRuntimeChecks(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()

    def archive(self, entries):
        archive = self.root / 'fixture.tar.gz'
        with tarfile.open(archive, 'w:gz') as package:
            for name, kind, content in entries:
                item = tarfile.TarInfo(name)
                item.type = kind
                if kind == tarfile.REGTYPE:
                    item.size = len(content)
                    package.addfile(item, io.BytesIO(content))
                else:
                    item.linkname = content.decode('utf-8')
                    package.addfile(item)
        return archive

    def test_extracts_required_regular_files_and_skips_unrelated_programs(self):
        required = runtime.SOURCES['libgfortran.5.dylib']
        archive = self.archive([(required, tarfile.REGTYPE, b'library'),
                                ('gcc/15.2.0/COPYING.RUNTIME', tarfile.REGTYPE, b'license'),
                                ('gcc/15.2.0/bin/gcc', tarfile.REGTYPE, b'do not install'),
                                ('gcc/15.2.0/lib/ignored-link', tarfile.SYMTYPE, b'/outside')])
        destination = self.root / 'extract'
        runtime.extract_selected(archive, destination, 'gcc/15.2.0')
        self.assertEqual((destination / required).read_bytes(), b'library')
        self.assertEqual((destination / 'gcc/15.2.0/COPYING.RUNTIME').read_bytes(), b'license')
        self.assertFalse((destination / 'gcc/15.2.0/bin').exists())
        self.assertFalse((destination / 'gcc/15.2.0/lib/ignored-link').exists())

    def test_extracts_opencv_headers_without_tarfile_filter_support(self):
        header = 'opencv@4/4.14.0_11/include/opencv4/opencv2/core.hpp'
        archive = self.archive([(header, tarfile.REGTYPE, b'header')])
        destination = self.root / 'extract'
        runtime.extract_selected(archive, destination, 'opencv@4/4.14.0_11')
        self.assertEqual((destination / header).read_bytes(), b'header')

    def test_rejects_absolute_and_traversing_members(self):
        for name in ['/outside/file', '../outside', 'gcc/15.2.0/../../outside']:
            with self.subTest(name=name):
                archive = self.archive([(name, tarfile.REGTYPE, b'unsafe')])
                with self.assertRaisesRegex(runtime.RuntimeFailure, 'Unsafe bottle member'):
                    runtime.extract_selected(archive, self.root / 'extract', 'gcc/15.2.0')

    def test_rejects_required_symlinks_hardlinks_and_special_files(self):
        required = runtime.SOURCES['libgfortran.5.dylib']
        for kind in [tarfile.SYMTYPE, tarfile.LNKTYPE, tarfile.FIFOTYPE]:
            with self.subTest(kind=kind):
                archive = self.archive([(required, kind, b'/outside')])
                with self.assertRaisesRegex(runtime.RuntimeFailure, 'Unexpected bottle member'):
                    runtime.extract_selected(archive, self.root / 'extract', 'gcc/15.2.0')

    def test_rejects_duplicate_selected_members(self):
        required = runtime.SOURCES['libgfortran.5.dylib']
        archive = self.archive([(required, tarfile.REGTYPE, b'first'), (required, tarfile.REGTYPE, b'second')])
        with self.assertRaisesRegex(runtime.RuntimeFailure, 'Unexpected bottle member'):
            runtime.extract_selected(archive, self.root / 'extract', 'gcc/15.2.0')
        self.assertEqual((self.root / 'extract' / required).read_bytes(), b'first')

    def test_verified_download_and_cache_need_no_account_or_network(self):
        source = self.root / 'public-fixture'
        source.write_bytes(b'public pinned bottle')
        destination = self.root / 'download.tar.gz'
        digest = runtime.sha(source)
        runtime.download(source.as_uri(), destination, digest, source.stat().st_size, None)
        self.assertEqual(destination.read_bytes(), source.read_bytes())
        source.unlink()
        # A verified cached bottle remains usable with the source unavailable.
        runtime.download(source.as_uri(), destination, digest, 100, None)

    def test_hash_mismatch_discards_partial_download(self):
        source = self.root / 'fixture'
        source.write_bytes(b'changed bottle')
        destination = self.root / 'download.tar.gz'
        with self.assertRaisesRegex(runtime.RuntimeFailure, 'SHA256 mismatch'):
            runtime.download(source.as_uri(), destination, '0' * 64, 100, None)
        self.assertFalse(destination.exists())
        self.assertEqual(list(self.root.glob('*.part-*')), [])

    def test_download_size_limit_discards_partial_download(self):
        source = self.root / 'fixture'
        source.write_bytes(b'too big')
        destination = self.root / 'download.tar.gz'
        with self.assertRaisesRegex(runtime.RuntimeFailure, 'size limit'):
            runtime.download(source.as_uri(), destination, runtime.sha(source), 2, None)
        self.assertFalse(destination.exists())
        self.assertEqual(list(self.root.glob('*.part-*')), [])

    def make_cached_runtime(self):
        target = self.root / 'runtime'
        inventory = {'recipe': runtime.RECIPE, 'libraries': {}, 'licenses': {}, 'headers': {}}
        groups = [('lib', 'libraries', runtime.SOURCES),
                  ('licenses', 'licenses', list(runtime.LICENSES) + [runtime.LLVM_LICENSE_NAME]),
                  ('include/opencv4', 'headers', ['opencv2/core.hpp', 'opencv2/other.hpp'])]
        for folder, key, names in groups:
            for name in names:
                path = target / folder / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(name.encode('utf-8'))
                inventory[key][name] = runtime.sha(path)
        for module in runtime.MODULES:
            (target / 'lib' / ('libopencv_' + module + '.dylib')).symlink_to('libopencv_' + module + '.414.dylib')
        (target / 'runtime.json').write_text(json.dumps(inventory))
        return target, inventory

    def test_cached_runtime_checks_libraries_headers_and_licenses(self):
        target, _ = self.make_cached_runtime()
        self.assertTrue(runtime.cached_runtime_valid(target))
        for relative in ['lib/libomp.dylib', 'include/opencv4/opencv2/other.hpp',
                         'licenses/GCC-15.2.0-COPYING.RUNTIME']:
            with self.subTest(file=relative):
                path = target / relative
                contents = path.read_bytes()
                path.write_bytes(b'corrupted')
                self.assertFalse(runtime.cached_runtime_valid(target))
                path.write_bytes(contents)

    def test_empty_or_incomplete_manifest_cannot_validate_cache(self):
        target, inventory = self.make_cached_runtime()
        for key in ['libraries', 'licenses', 'headers']:
            with self.subTest(key=key):
                broken = dict(inventory)
                broken[key] = {}
                (target / 'runtime.json').write_text(json.dumps(broken))
                self.assertFalse(runtime.cached_runtime_valid(target))

    def test_cache_rejects_manifest_traversal_and_wrong_library_links(self):
        target, inventory = self.make_cached_runtime()
        inventory['headers']['../../../outside'] = hashlib.sha256(b'anything').hexdigest()
        (target / 'runtime.json').write_text(json.dumps(inventory))
        self.assertFalse(runtime.cached_runtime_valid(target))
        del inventory['headers']['../../../outside']
        (target / 'runtime.json').write_text(json.dumps(inventory))
        link = target / 'lib/libopencv_core.dylib'
        link.unlink()
        link.symlink_to('libopencv_flann.414.dylib')
        self.assertFalse(runtime.cached_runtime_valid(target))


if __name__ == '__main__':
    unittest.main()
