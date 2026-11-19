"""Private, transactionally saved aligned cues and confirmed translations."""
from __future__ import annotations

import fcntl
import hashlib
import json
import math
import os
import sqlite3
import stat
from contextlib import closing, contextmanager
from pathlib import Path

from .common import PipelineError, Segment


def _stamp(value):
    return value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns, value.st_ctime_ns


def _digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def _source_identity(source):
    # Avoid a second full read of multi-gigabyte inputs, including on external disks.
    sample = hashlib.sha256()
    with source.open("rb") as handle:
        stamp = _stamp(os.fstat(handle.fileno()))
        size = stamp[2]
        length = 64 * 1024
        for start in sorted({0, max(0, (size - length) // 2), max(0, size - length)}):
            handle.seek(start)
            sample.update(handle.read(length))
    if _stamp(source.stat()) != stamp:
        raise PipelineError("The selected video changed while preparing its subtitle checkpoint")
    return stamp, sample.hexdigest()


def _model_identity(paths):
    # The supervisor verifies these pinned assets before each run. Include the
    # manifest and file identities so in-place replacements also start fresh.
    manifest = (Path(__file__).resolve().parents[1] / "assets.json").read_bytes()
    identity = [hashlib.sha256(manifest).hexdigest()]
    for model in json.loads(manifest)["models"]:
        if model["id"] not in paths:
            continue
        root = Path(paths[model["id"]])
        files = []
        for artifact in model["artifacts"]:
            item = root / Path(artifact["path"]).relative_to(model["directory"])
            try:
                files.append(_stamp(item.stat()))
            except FileNotFoundError:
                files.append(None)
        identity.append((model["id"], str(root), files))
    return identity


def _private_entry(path, directory=False):
    info = path.lstat()
    correct_type = stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode) and info.st_nlink == 1
    if not correct_type or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise PipelineError("The subtitle checkpoint location is not private or contains an unexpected link")


def _intact(db):
    try:
        return db.execute("PRAGMA quick_check").fetchall() == [("ok",)]
    except sqlite3.DatabaseError as exc:
        code = getattr(exc, "sqlite_errorcode", 0) & 0xff
        if code in {sqlite3.SQLITE_CORRUPT, sqlite3.SQLITE_NOTADB}:
            return False
        raise


def _private_database(path):
    descriptor = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    os.close(descriptor)
    _private_entry(path)
    return sqlite3.connect(path)


class SubtitleCheckpoint:
    def __init__(self, db, identity, source, stamp):
        self.db = db
        self.identity = identity
        self.source = source
        self.stamp = stamp
        self.completed = False
        with db:
            db.execute("CREATE TABLE IF NOT EXISTS transcript (identity TEXT NOT NULL, count INTEGER NOT NULL)")
            db.execute("""CREATE TABLE IF NOT EXISTS cues (
                id INTEGER PRIMARY KEY, start REAL NOT NULL, end REAL NOT NULL,
                source TEXT NOT NULL, language TEXT NOT NULL, translation TEXT)""")

    def check_source(self):
        if _stamp(self.source.stat()) != self.stamp:
            raise PipelineError("The selected video changed during subtitle generation; select it again")

    def load(self):
        record = self.db.execute("SELECT identity, count FROM transcript").fetchone()
        if not record or record[0] != self.identity:
            return [], {}
        segments, restored = [], {}
        for index, start, end, source, language, translation in self.db.execute(
                "SELECT id, start, end, source, language, translation FROM cues ORDER BY id"):
            if (index != len(segments) or not isinstance(source, str) or not source.strip()
                    or not isinstance(language, str) or not isinstance(start, (int, float))
                    or not isinstance(end, (int, float)) or not math.isfinite(start)
                    or not math.isfinite(end) or not 0 <= start < end):
                return [], {}
            segments.append(Segment(start, end, source, language=language))
            if translation is not None:
                if not isinstance(translation, str) or not translation.strip():
                    return [], {}
                restored[index] = translation
        return (segments, restored) if len(segments) == record[1] else ([], {})

    def save_transcript(self, segments):
        self.check_source()
        # ASR normalization may populate Segment.text with the original language.
        # Only the translator may populate the separate translation column.
        with self.db:
            self.db.execute("DELETE FROM transcript")
            self.db.execute("DELETE FROM cues")
            self.db.executemany("INSERT INTO cues (id, start, end, source, language) VALUES (?, ?, ?, ?, ?)",
                                ((i, s.start, s.end, s.source_text, s.language) for i, s in enumerate(segments)))
            self.db.execute("INSERT INTO transcript VALUES (?, ?)", (self.identity, len(segments)))

    def save_translations(self, translated):
        if any(type(i) is not int or not isinstance(text, str) or not text.strip() for i, text in translated.items()):
            raise PipelineError("Invalid subtitle translation checkpoint")
        with self.db:
            cursor = self.db.executemany("UPDATE cues SET translation = ? WHERE id = ?",
                                         ((text, i) for i, text in translated.items()))
            if cursor.rowcount != len(translated):
                raise PipelineError("The translation checkpoint does not match the aligned subtitles")


@contextmanager
def open_checkpoint(data_dir, source, language, paths, on_retained=None):
    stamp, sample = _source_identity(source)
    data = Path(data_dir).expanduser() if data_dir else None
    if data is None or not data.is_absolute():
        # Preserve standalone requests without persisting subtitles in an implicit cwd.
        with closing(sqlite3.connect(":memory:")) as db:
            yield SubtitleCheckpoint(db, "", source, stamp)
        return

    if data.is_symlink():
        raise PipelineError("The subtitle data directory cannot be a symbolic link")
    root = data / "subtitle-checkpoints"
    root.mkdir(mode=0o700, exist_ok=True, parents=True)
    _private_entry(root, directory=True)
    directory = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        # The supervisor already serializes subtitle operations in this data directory.
        # Keep standalone workers from reading or retiring another worker's database.
        try:
            fcntl.flock(directory, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise PipelineError("Another subtitle operation is using the local checkpoints") from exc
        target = root / (_digest([str(source), language]) + ".sqlite")
        identity = _digest([1, str(source), stamp, sample, language, _model_identity(paths)])
        companions = []
        for suffix in ("-journal", "-wal", "-shm"):
            sidecar = Path(str(target) + suffix)
            if os.path.lexists(sidecar):
                _private_entry(sidecar)
                companions.append(sidecar)
        db = _private_database(target)
        try:
            if not _intact(db):
                db.close()
                for path in companions:
                    path.unlink(missing_ok=True)
                target.unlink()
                db = _private_database(target)
            checkpoint = SubtitleCheckpoint(db, identity, source, stamp)
            try:
                yield checkpoint
            except Exception:
                if on_retained:
                    try:
                        checkpoint.check_source()
                        if target.is_file() and checkpoint.load()[0]:
                            on_retained()
                    except (OSError, sqlite3.Error, PipelineError, MemoryError):
                        pass  # Keep the original failure and omit an unconfirmed recovery hint.
                raise
        finally:
            db.close()
        # Only delete after the caller has finished publishing all requested output.
        if checkpoint.completed:
            target.unlink()
    finally:
        os.close(directory)
