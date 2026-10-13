"""Offline corresponding-source archive integrity controls."""
import hashlib
import importlib.util
import io
from pathlib import Path
import tarfile
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('portable_source_materials', HERE / 'source_materials.py')
materials = importlib.util.module_from_spec(spec)
spec.loader.exec_module(materials)


class SourceArchiveTests(unittest.TestCase):
    def test_paths_are_relative(self):
        for name in ('/absolute', '../outside', 'dir/../outside', '', 'a//b', './name'):
            self.assertFalse(materials.safe_relative(name), name)
        self.assertTrue(materials.safe_relative('other/patches/locked.patch'))

    def test_archive_identity_and_completeness(self):
        asset = b'locked source'
        manifest = b'{"test":"source manifest"}'
        snapshots = {'main.m': hashlib.sha256(asset).hexdigest()}
        with tempfile.TemporaryDirectory(prefix='av1-source-offline.') as temporary:
            path = Path(temporary) / 'source.tar.gz'
            for scenario in ('valid', 'missing', 'duplicate', 'changed', 'extra', 'traversal', 'symlink', 'manifest'):
                with self.subTest(scenario=scenario):
                    entries = [('main.m', asset), ('SOURCE_FILE_SHA256.json', manifest)]
                    if scenario == 'missing': entries.pop(0)
                    if scenario == 'duplicate': entries.append(entries[0])
                    if scenario == 'changed': entries[0] = ('main.m', b'wrong')
                    if scenario == 'extra': entries.append(('extra', b'foreign'))
                    if scenario == 'traversal': entries[0] = ('../main.m', asset)
                    if scenario == 'manifest': entries[1] = ('SOURCE_FILE_SHA256.json', b'wrong')
                    with tarfile.open(path, 'w:gz') as archive:
                        for name, data in entries:
                            info = tarfile.TarInfo('ChengYingAV1-Source/' + name)
                            info.size = len(data)
                            if scenario == 'symlink' and name == 'main.m':
                                info.type = tarfile.SYMTYPE
                                info.linkname = '/foreign'
                            archive.addfile(info, io.BytesIO(data))
                    if scenario == 'valid': materials.verify_archive(path, snapshots, manifest)
                    else:
                        with self.assertRaises(ValueError): materials.verify_archive(path, snapshots, manifest)


if __name__ == '__main__':
    unittest.main()
