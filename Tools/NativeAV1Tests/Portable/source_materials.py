"""Offline corresponding sources using the project's existing verified playback locks."""
from __future__ import annotations

import importlib.util
import hashlib
import io
import json
from pathlib import Path
import shutil
import subprocess
import tarfile


def safe_relative(name: str) -> bool:
    path = Path(name)
    return bool(name) and not path.is_absolute() and '..' not in path.parts and str(path) == name


def verify_archive(archive: Path, snapshots: dict, source_manifest: bytes) -> None:
    seen = set()
    with tarfile.open(archive, 'r:gz') as packed:
        for member in packed:
            if not member.name.startswith('ChengYingAV1-Source/'):
                raise ValueError('Unexpected corresponding-source prefix')
            name = member.name.removeprefix('ChengYingAV1-Source/')
            if not member.isfile() or not safe_relative(name) or name in seen:
                raise ValueError('Unsafe or duplicate corresponding-source archive entry')
            seen.add(name)
            stream = packed.extractfile(member)
            if name == 'SOURCE_FILE_SHA256.json':
                if stream.read() != source_manifest:
                    raise ValueError('Changed source archive manifest')
            elif name not in snapshots or hashlib.sha256(stream.read()).hexdigest() != snapshots[name]:
                raise ValueError('Unexpected or changed source archive member')
    if seen != set(snapshots) | {'SOURCE_FILE_SHA256.json'}:
        raise ValueError('Missing corresponding-source archive member')


def create(root: Path, deps: Path, cache: Path, bundle: Path, hash_file, verify_file) -> dict:
    """Never fetch: a missing or changed cached source is a packaging failure."""
    spec = importlib.util.spec_from_file_location('av1_source_distribution', root / 'other/verify_playback_distribution.py')
    distribution = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(distribution)
    records = distribution.locked_sources()
    distribution.verify_distribution(deps, sources=records, source_cache=cache)
    record = deps / 'playback-build-record'
    config = (record / 'config.h').read_text()
    if '#define CONFIG_GPL 1' not in config or '#define CONFIG_VERSION3 1' not in config:
        raise ValueError('The source notice must be reviewed for a different FFmpeg license configuration')

    # Same locked archives, actual build record and build recipes as the release
    # source flow. Its App-wide wrapper also requires unrelated media/helper deps;
    # this isolated CLI deliberately includes the complete playback source superset.
    selections = [
        'LICENSE', 'NOTICE.md', 'Legal/THIRD_PARTY_NOTICES.md', 'iina/Credits.rtf',
        'iina/NativePlayback/CYNMediaDecoder.m', 'iina/NativePlayback/CYNMediaDecoder.h',
        'Tools/NativeAV1Tests', 'other/build_playback_libraries.sh', 'other/build_subtitle_libraries.sh',
        'other/playback_sources.sh', 'other/third_party_sources.sh', 'other/playback_patches.sh',
        'other/playback_ffmpeg_patches.sh', 'other/playback_pkg_config.sh',
        'other/verify_playback_distribution.py', 'other/patches',
    ]
    listed = subprocess.run(['git', 'ls-files', '-z', '--', *selections], cwd=root,
                            check=True, capture_output=True).stdout.decode().split('\0')
    project = {name: root / name for name in listed if name}
    for name in project:
        if not safe_relative(name):
            raise ValueError('Unsafe project source path')
    portable = root / 'Tools/NativeAV1Tests/Portable'
    for path in portable.iterdir():
        if path.is_file() and path.suffix in {'.py', '.md', '.in', '.txt'}:
            project[str(path.relative_to(root))] = path
    inputs = dict(project)
    for path in record.rglob('*'):
        if path.is_symlink():
            raise ValueError('Linked playback source record')
        if path.is_file():
            inputs['playback-build-record/' + str(path.relative_to(record))] = path
    for _, _, filename, _, digest in records.values():
        source = cache / filename
        verify_file(source, digest)
        inputs['third-party-sources/' + filename] = source
    snapshots = {name: hash_file(path) for name, path in inputs.items()}
    legal = bundle / 'Legal'
    legal.mkdir()
    shutil.copyfile(root / 'LICENSE', legal / 'LICENSE')
    shutil.copyfile(root / 'NOTICE.md', legal / 'PROJECT_NOTICE.md')
    shutil.copyfile(root / 'Legal/THIRD_PARTY_NOTICES.md', legal / 'PROJECT_THIRD_PARTY_NOTICES.md')
    shutil.copyfile(portable / 'SOURCE_README.txt', legal / 'README.txt')
    shutil.copytree(record / 'licenses', legal / 'licenses')
    shutil.copyfile(record / 'config.h', legal / 'ffmpeg-config.h')
    shutil.copyfile(record / 'sources.tsv', legal / 'SOURCE_MANIFEST.tsv')
    for relative, original in {
        'LICENSE': root / 'LICENSE', 'PROJECT_NOTICE.md': root / 'NOTICE.md',
        'PROJECT_THIRD_PARTY_NOTICES.md': root / 'Legal/THIRD_PARTY_NOTICES.md',
        'README.txt': portable / 'SOURCE_README.txt', 'ffmpeg-config.h': record / 'config.h',
        'SOURCE_MANIFEST.tsv': record / 'sources.tsv',
    }.items():
        verify_file(legal / relative, hash_file(original))
    for original in (record / 'licenses').rglob('*'):
        if original.is_file():
            verify_file(legal / 'licenses' / original.relative_to(record / 'licenses'),
                        snapshots['playback-build-record/' + str(original.relative_to(record))])
    archive = legal / 'Corresponding-Source.tar.gz'
    with tarfile.open(archive, 'w:gz') as output:
        for name, path in sorted(inputs.items()):
            if not safe_relative(name):
                raise ValueError('Unsafe corresponding-source path')
            verify_file(path, snapshots[name])
            info = output.gettarinfo(str(path), arcname='ChengYingAV1-Source/' + name)
            info.uid = info.gid = 0
            info.uname = info.gname = ''
            with path.open('rb') as stream:
                output.addfile(info, stream)
        source_manifest = json.dumps({'schema': 1, 'files': snapshots}, sort_keys=True, indent=2).encode() + b'\n'
        info = tarfile.TarInfo('ChengYingAV1-Source/SOURCE_FILE_SHA256.json')
        info.size = len(source_manifest)
        info.mode = 0o644
        output.addfile(info, io.BytesIO(source_manifest))
    for name, path in inputs.items():
        verify_file(path, snapshots[name])
    # Verify exact bytes inside the finished archive, not merely its directory listing.
    verify_archive(archive, snapshots, source_manifest)
    return {str(path.relative_to(bundle)): hash_file(path) for path in legal.rglob('*') if path.is_file()}
