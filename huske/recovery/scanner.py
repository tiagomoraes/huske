"""Scan ``audio_root`` for orphaned sessions left by hard-killed runs."""

from __future__ import annotations

import re
import shutil
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

import soundfile as sf

from huske.config import RuntimeConfig
from huske.session import is_lock_alive


# Per-source filename: ``<seq>_<HHMMSS>_<source>.wav``. The unsuffixed legacy
# form (``<seq>_<HHMMSS>.wav``) is still accepted so sessions captured before
# the source-split change can be recovered.
_FNAME_RE = re.compile(
    r"^(?P<seq>\d{4})_(?P<hhmmss>\d{6})(?:_(?P<source>microphone|system))?\.wav$"
)


@dataclass
class OrphanChunk:
    audio_path: Path  # primary (first valid) path; mirrors the AudioChunk field
    audio_paths: dict[str, Path]  # source -> path (valid sources only)
    chunk_seq: int
    start_time: datetime  # reconstructed from filename + session_id
    duration_seconds: float
    valid: bool
    invalid_paths: list[Path] = field(default_factory=list)


@dataclass
class OrphanSession:
    session_id: str
    audio_dir: Path
    chunks: list[OrphanChunk] = field(default_factory=list)


@dataclass
class RecoveryReport:
    sessions_scanned: int = 0
    chunks_valid: int = 0
    chunks_incomplete: int = 0
    moved_to_incomplete: list[Path] = field(default_factory=list)


def _parse_session_start(session_id: str) -> datetime | None:
    # session_id looks like "20260507T091500_8a3f"
    head = session_id.split("_", 1)[0]
    try:
        return datetime.strptime(head, "%Y%m%dT%H%M%S").astimezone()
    except ValueError:
        return None


def _wav_duration_seconds(path: Path) -> float | None:
    try:
        info = sf.info(str(path))
    except Exception:  # noqa: BLE001
        return None
    if info.frames <= 0 or info.samplerate <= 0:
        return None
    return float(info.frames) / float(info.samplerate)


def _transcript_already_exists(
    cfg: RuntimeConfig, session_id: str, chunk_seq: int, start_time: datetime
) -> bool:
    """Check whether a transcript matching this chunk is already on disk.

    Matches by `<output>/<YYYY-MM-DD>/<HHMMSS>_<sid8>_<seq>*.md` (disambiguation suffix tolerated).
    """
    sid_short = session_id.split("_", 1)[1][:8].ljust(8, "0") if "_" in session_id else session_id[:8]
    pattern = (
        f"{start_time.strftime('%H%M%S')}_{sid_short}_{chunk_seq:03d}*.md"
    )
    day_dir = cfg.output_root / start_time.date().isoformat()
    return any(day_dir.glob(pattern))


def scan_orphans(cfg: RuntimeConfig) -> list[OrphanSession]:
    """Identify session directories under ``cfg.audio_root`` that have no live lock.

    Per-source WAVs of the same chunk are grouped into a single
    ``OrphanChunk``. A chunk is considered valid if at least one of its WAVs
    has > 0.5s of usable audio. Already-transcribed chunks are auto-cleaned.
    """
    if not cfg.audio_root.exists():
        return []

    orphans: list[OrphanSession] = []
    for entry in sorted(cfg.audio_root.iterdir()):
        if not entry.is_dir():
            continue
        if entry.name == "incomplete":
            continue

        lock = entry / ".lock"
        # Either the lock is gone (clean ungraceful exit), or it points at a dead PID.
        if lock.exists() and is_lock_alive(lock):
            continue

        session_start = _parse_session_start(entry.name)

        # Group per-source WAVs of the same chunk together.
        groups: dict[tuple[int, str], list[tuple[str, Path]]] = {}
        for wav in sorted(entry.glob("*.wav")):
            m = _FNAME_RE.match(wav.name)
            if m is None:
                continue
            seq = int(m.group("seq"))
            hhmmss = m.group("hhmmss")
            source = m.group("source") or "microphone"
            groups.setdefault((seq, hhmmss), []).append((source, wav))

        chunks: list[OrphanChunk] = []
        for (seq, hhmmss), files in sorted(groups.items()):
            if session_start is None:
                start_time = datetime.now().astimezone()
            else:
                start_time = session_start.replace(
                    hour=int(hhmmss[0:2]),
                    minute=int(hhmmss[2:4]),
                    second=int(hhmmss[4:6]),
                )
            if _transcript_already_exists(cfg, entry.name, seq, start_time):
                for _, wav in files:
                    try:
                        wav.unlink()
                    except OSError:
                        pass
                continue

            valid_paths: dict[str, Path] = {}
            invalid_paths: list[Path] = []
            max_dur = 0.0
            for source, wav in files:
                dur = _wav_duration_seconds(wav)
                if dur is not None and dur > 0.5:
                    valid_paths[source] = wav
                    if dur > max_dur:
                        max_dur = dur
                else:
                    invalid_paths.append(wav)

            valid = bool(valid_paths)
            primary = (
                next(iter(valid_paths.values()))
                if valid
                else files[0][1]
            )
            chunks.append(
                OrphanChunk(
                    audio_path=primary,
                    audio_paths=dict(valid_paths),
                    chunk_seq=seq,
                    start_time=start_time,
                    duration_seconds=max_dur,
                    valid=valid,
                    invalid_paths=invalid_paths,
                )
            )
        if chunks or lock.exists():
            orphans.append(
                OrphanSession(session_id=entry.name, audio_dir=entry, chunks=chunks)
            )
    return orphans


def move_to_incomplete(cfg: RuntimeConfig, session_id: str, chunk: Path) -> Path:
    target_dir = cfg.audio_root / "incomplete" / session_id
    target_dir.mkdir(parents=True, exist_ok=True)
    target = target_dir / chunk.name
    shutil.move(str(chunk), str(target))
    return target


def cleanup_session_dir(session_dir: Path) -> None:
    """Delete the session directory if it's empty (apart from the lock file)."""
    try:
        leftovers = [
            p for p in session_dir.iterdir() if p.name not in {".lock"}
        ]
    except FileNotFoundError:
        return
    if not leftovers:
        for p in session_dir.iterdir():
            try:
                p.unlink()
            except OSError:
                pass
        try:
            session_dir.rmdir()
        except OSError:
            pass
