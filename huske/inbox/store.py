"""On-disk inbox: layout, ids, atomic staging and status writes, the lock.

Layout (``specs/002-phone-sync/contracts/inbox.md``)::

    <inbox_root>/
    ├── .lock              # flock(2) held by the one process transcribing
    ├── .staging/          # half-copied items (never processed)
    └── <id>/
        ├── recording.json # immutable producer metadata
        ├── audio.<ext>    # original audio (removed or moved once done)
        └── status.json    # engine-owned progress, replaced atomically

Only the lock holder writes ``status.json`` after an item exists; ``add``
writes the initial one inside ``.staging/`` before the atomic rename, so
readers (Huske.app polls these files directly) never see a partial item.
"""

from __future__ import annotations

import contextlib
import fcntl
import hashlib
import json
import math
import os
import re
import shutil
import subprocess
import tempfile
import time
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any

ID_PATTERN = re.compile(r"^[A-Za-z0-9._-]{1,64}$")
ORIGINS = ("phone", "file")
STATES = ("queued", "processing", "done", "failed")
MAX_ATTEMPTS = 3
DONE_RETENTION = timedelta(days=30)
# A `.staging/` entry this old belongs to an `add` that crashed mid-copy.
STAGING_MAX_AGE_SECONDS = 24 * 3600.0

LOCK_FILE = ".lock"
STAGING_DIR = ".staging"
RECORDING_FILE = "recording.json"
STATUS_FILE = "status.json"
WORK_DIR = "work"

_AFINFO = Path("/usr/bin/afinfo")
_EXT_PATTERN = re.compile(r"^[a-z0-9]{1,10}$")


class InboxError(ValueError):
    """A validation error (bad id, missing file, bad timestamp). CLI exit 1."""


def now_local() -> datetime:
    return datetime.now().astimezone()


def iso(dt: datetime) -> str:
    return dt.isoformat(timespec="seconds")


def parse_timestamp(value: str) -> datetime:
    """Parse ISO 8601; a naive timestamp is taken as the Mac's local time."""
    try:
        parsed = datetime.fromisoformat(value.strip())
    except ValueError as exc:
        raise InboxError(f"not an ISO 8601 timestamp: {value!r}") from exc
    return parsed if parsed.tzinfo is not None else parsed.astimezone()


def validate_id(item_id: str) -> str:
    """Return ``item_id`` if it is a valid inbox id, else raise ``InboxError``.

    ``^[A-Za-z0-9._-]{1,64}$`` and, additionally, no leading dot: ``.``,
    ``..``, ``.lock`` and ``.staging`` would otherwise name the inbox itself.
    """
    if not isinstance(item_id, str) or not ID_PATTERN.fullmatch(item_id) or item_id.startswith("."):
        raise InboxError(
            f"invalid inbox id {item_id!r}: use 1-64 of A-Z a-z 0-9 . _ - "
            "(not starting with '.')"
        )
    return item_id


def session_id_for(item_id: str, started_at: datetime) -> str:
    """Deterministic session id of an imported recording.

    ``<started_at local YYYYMMDDTHHMMSS>_<first 8 hex of sha1(id)>`` — local
    to this Mac, like every live transcript, so imports file under the same
    day folders. Deterministic so a retry rewrites the same transcripts.
    """
    local = started_at.astimezone()
    digest = hashlib.sha1(item_id.encode("utf-8")).hexdigest()[:8]
    return f"{local.strftime('%Y%m%dT%H%M%S')}_{digest}"


def derive_id(path: Path) -> str:
    """Default id for an item added without ``--id``: a content hash.

    Re-adding the same bytes is then the same idempotent no-op as re-adding
    the same explicit id, so re-running ``huske import`` cannot duplicate
    transcripts.
    """
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return f"file-{digest.hexdigest()[:24]}"


def probe_duration_seconds(path: Path) -> float | None:
    """Best-effort audio duration: soundfile first, then macOS ``afinfo``."""
    try:
        import soundfile as sf

        info = sf.info(str(path))
        if info.samplerate > 0 and info.frames > 0:
            return float(info.frames) / float(info.samplerate)
    except Exception:
        pass
    if not _AFINFO.exists():
        return None
    try:
        out = subprocess.run(
            [str(_AFINFO), str(path)],
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    match = re.search(r"estimated duration:\s*([0-9.]+)\s*sec", out)
    if match is None:
        return None
    try:
        return float(match.group(1))
    except ValueError:
        return None


def _safe_ext(path: Path) -> str:
    ext = path.suffix.lower().lstrip(".")
    return ext if _EXT_PATTERN.fullmatch(ext) else "bin"


def _write_json_atomic(path: Path, data: dict[str, Any]) -> None:
    tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    tmp.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    os.replace(tmp, path)


def _read_json(path: Path) -> dict[str, Any] | None:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def initial_status(item_id: str, session_id: str, now: datetime) -> dict[str, Any]:
    return {
        "id": item_id,
        "state": "queued",
        "updated_at": iso(now),
        "attempts": 0,
        "chunks_total": 0,
        "chunks_done": 0,
        "session_id": session_id,
        "transcripts": [],
        "error": None,
    }


@dataclass
class InboxItem:
    """One recording in the inbox: its directory and both JSON documents."""

    id: str
    dir: Path
    recording: dict[str, Any]
    status: dict[str, Any]

    @property
    def state(self) -> str:
        return str(self.status.get("state", "queued"))

    @property
    def attempts(self) -> int:
        try:
            return int(self.status.get("attempts", 0))
        except (TypeError, ValueError):
            return 0

    @property
    def started_at(self) -> datetime:
        raw = self.recording.get("started_at")
        if isinstance(raw, str):
            with contextlib.suppress(InboxError):
                return parse_timestamp(raw)
        return self.added_at

    @property
    def added_at(self) -> datetime:
        raw = self.recording.get("added_at")
        if isinstance(raw, str):
            with contextlib.suppress(InboxError):
                return parse_timestamp(raw)
        return datetime.fromtimestamp(self.dir.stat().st_mtime).astimezone()

    @property
    def updated_at(self) -> datetime:
        raw = self.status.get("updated_at")
        if isinstance(raw, str):
            with contextlib.suppress(InboxError):
                return parse_timestamp(raw)
        return self.added_at

    @property
    def audio_path(self) -> Path:
        name = str(self.recording.get("audio_file") or "")
        # recording.json is producer-written; never follow it outside the item.
        if not name or "/" in name or name.startswith("."):
            name = "audio.bin"
        return self.dir / name

    @property
    def label(self) -> str:
        title = self.recording.get("title")
        if isinstance(title, str) and title.strip():
            return title.strip()
        source = self.recording.get("source_filename")
        if isinstance(source, str) and source.strip():
            return source.strip()
        return self.id

    def to_dict(self) -> dict[str, Any]:
        """The public item shape: ``recording.json`` fields + status object."""
        return {**self.recording, **self.status}


class InboxStore:
    """Filesystem view of ``inbox_root``. Cheap to construct; holds no state."""

    def __init__(self, root: Path) -> None:
        self.root = Path(root).expanduser()

    # ---- reading -------------------------------------------------------

    def get(self, item_id: str) -> InboxItem | None:
        try:
            validate_id(item_id)
        except InboxError:
            return None
        return self._load(self.root / item_id)

    def items(self) -> list[InboxItem]:
        """Every complete item, in no particular order."""
        if not self.root.is_dir():
            return []
        found: list[InboxItem] = []
        for entry in self.root.iterdir():
            if entry.name.startswith(".") or not entry.is_dir():
                continue
            item = self._load(entry)
            if item is not None:
                found.append(item)
        return found

    def list_newest_first(self) -> list[InboxItem]:
        return sorted(self.items(), key=lambda i: (i.added_at, i.id), reverse=True)

    def _load(self, directory: Path) -> InboxItem | None:
        if not ID_PATTERN.fullmatch(directory.name) or directory.name.startswith("."):
            return None
        recording = _read_json(directory / RECORDING_FILE)
        if recording is None:
            return None
        status = _read_json(directory / STATUS_FILE)
        if status is None:
            started = recording.get("started_at")
            try:
                when = parse_timestamp(started) if isinstance(started, str) else now_local()
            except InboxError:
                when = now_local()
            status = initial_status(directory.name, session_id_for(directory.name, when), now_local())
        return InboxItem(id=directory.name, dir=directory, recording=recording, status=status)

    # ---- writing -------------------------------------------------------

    def write_status(self, item: InboxItem, **changes: Any) -> dict[str, Any]:
        """Merge ``changes`` into the item's status and replace it atomically."""
        status = {**item.status, **changes, "id": item.id, "updated_at": iso(now_local())}
        _write_json_atomic(item.dir / STATUS_FILE, status)
        item.status = status
        return status

    def add(
        self,
        source: Path,
        *,
        item_id: str | None = None,
        title: str | None = None,
        device: str | None = None,
        origin: str = "file",
        started_at: datetime | None = None,
        duration_seconds: float | None = None,
        move: bool = False,
    ) -> tuple[InboxItem, bool]:
        """Stage ``source`` as an inbox item. Returns ``(item, created)``.

        Idempotent per id: if the id already exists, nothing is touched (not
        even ``source`` under ``move``) and the existing item comes back with
        ``created=False``. The item directory appears atomically: everything
        is written under ``.staging/`` and then renamed into place.
        """
        source = Path(source).expanduser()
        if not source.is_file():
            raise InboxError(f"no such file: {source}")
        if origin not in ORIGINS:
            raise InboxError(f"invalid origin {origin!r} (expected one of: {', '.join(ORIGINS)})")
        if duration_seconds is not None and (
            not math.isfinite(duration_seconds) or duration_seconds < 0
        ):
            raise InboxError(f"invalid duration: {duration_seconds!r}")

        item_id = validate_id(item_id) if item_id is not None else derive_id(source)
        existing = self.get(item_id)
        if existing is not None:
            return existing, False

        if duration_seconds is None:
            duration_seconds = probe_duration_seconds(source)
        if started_at is None:
            # Unknown start: assume the file was written when recording ended.
            mtime = datetime.fromtimestamp(source.stat().st_mtime).astimezone()
            started_at = mtime - timedelta(seconds=duration_seconds or 0.0)
        elif started_at.tzinfo is None:
            started_at = started_at.astimezone()

        now = now_local()
        ext = _safe_ext(source)
        recording: dict[str, Any] = {
            "id": item_id,
            "title": title or None,
            "origin": origin,
            "device": device or None,
            "started_at": iso(started_at),
            "duration_seconds": (
                round(float(duration_seconds), 3) if duration_seconds is not None else None
            ),
            "audio_file": f"audio.{ext}",
            "source_filename": source.name,
            "added_at": iso(now),
        }
        status = initial_status(item_id, session_id_for(item_id, started_at), now)

        staging_root = self.root / STAGING_DIR
        staging_root.mkdir(parents=True, exist_ok=True)
        stage = Path(tempfile.mkdtemp(prefix=f"{item_id}.", dir=staging_root))
        audio_dst = stage / recording["audio_file"]
        moved = False
        try:
            if move:
                shutil.move(str(source), str(audio_dst))
                moved = True
            else:
                shutil.copyfile(source, audio_dst)
            _write_json_atomic(stage / RECORDING_FILE, recording)
            _write_json_atomic(stage / STATUS_FILE, status)
            final = self.root / item_id
            try:
                os.rename(stage, final)
            except OSError:
                # Lost a race with a concurrent add of the same id: theirs wins.
                winner = self.get(item_id)
                if winner is None:
                    raise
                if moved:
                    shutil.move(str(audio_dst), str(source))
                    moved = False
                shutil.rmtree(stage, ignore_errors=True)
                return winner, False
        except BaseException:
            if moved and audio_dst.exists():
                with contextlib.suppress(OSError):
                    shutil.move(str(audio_dst), str(source))
            shutil.rmtree(stage, ignore_errors=True)
            raise
        item = self.get(item_id)
        assert item is not None
        return item, True

    def prune(self, now: datetime | None = None) -> list[str]:
        """Remove ``done`` items older than 30 days and abandoned staging dirs.

        Only the lock holder calls this. Returns the pruned item ids.
        """
        now = now or now_local()
        pruned: list[str] = []
        for item in self.items():
            if item.state == "done" and now - item.updated_at > DONE_RETENTION:
                shutil.rmtree(item.dir, ignore_errors=True)
                pruned.append(item.id)
        staging_root = self.root / STAGING_DIR
        if staging_root.is_dir():
            cutoff = time.time() - STAGING_MAX_AGE_SECONDS
            for entry in staging_root.iterdir():
                try:
                    stale = entry.stat().st_mtime < cutoff
                except OSError:
                    continue
                if stale:
                    if entry.is_dir():
                        shutil.rmtree(entry, ignore_errors=True)
                    else:
                        with contextlib.suppress(OSError):
                            entry.unlink()
        return pruned


class InboxLock:
    """The ``flock(2)`` on ``inbox_root/.lock`` that elects the transcriber.

    Non-blocking. Released by :meth:`release` or by the kernel when the holder
    dies, so there are no stale locks. The descriptor is non-inheritable
    (PEP 446), so the spawned ASR child never keeps the lock alive.
    """

    def __init__(self, root: Path) -> None:
        self.path = Path(root).expanduser() / LOCK_FILE
        self._fd: int | None = None

    @property
    def held(self) -> bool:
        return self._fd is not None

    def try_acquire(self) -> bool:
        if self._fd is not None:
            return True
        self.path.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(self.path, os.O_RDWR | os.O_CREAT, 0o644)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            os.close(fd)
            return False
        with contextlib.suppress(OSError):
            os.ftruncate(fd, 0)
            os.write(fd, f"{os.getpid()}\n".encode())
        self._fd = fd
        return True

    def release(self) -> None:
        fd, self._fd = self._fd, None
        if fd is None:
            return
        with contextlib.suppress(OSError):
            fcntl.flock(fd, fcntl.LOCK_UN)
        with contextlib.suppress(OSError):
            os.close(fd)

    def locked_elsewhere(self) -> bool:
        """True when another open of the lock file currently holds it."""
        if self._fd is not None:
            return False
        if not self.try_acquire():
            return True
        self.release()
        return False
