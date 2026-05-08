"""Path derivation: session ids, audio chunks, transcripts, day folders.

Single source of truth for the on-disk layout documented in
``contracts/transcript-format.md``.
"""

from __future__ import annotations

import secrets
from datetime import date, datetime
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from huske.config import RuntimeConfig
    from huske.models import AudioChunk


SESSION_ID_FMT = "%Y%m%dT%H%M%S"


def generate_session_id(now: datetime | None = None) -> str:
    """Return a sortable, unique session id like ``20260507T091500_8a3f``."""
    when = now or datetime.now().astimezone()
    suffix = secrets.token_hex(2)  # 4 hex chars
    return f"{when.strftime(SESSION_ID_FMT)}_{suffix}"


def session_id_short(session_id: str) -> str:
    """Return the 8-char id portion used in transcript filenames."""
    if "_" in session_id:
        suffix = session_id.split("_", 1)[1]
    else:
        suffix = session_id
    return suffix[:8].ljust(8, "0")


def output_root(cfg: "RuntimeConfig") -> Path:
    return cfg.output_root


def audio_root(cfg: "RuntimeConfig", session_id: str) -> Path:
    return cfg.audio_root / session_id


def logs_path(cfg: "RuntimeConfig", session_id: str) -> Path:
    return cfg.logs_root / f"{session_id}.log"


def lock_path(audio_root: Path) -> Path:
    return audio_root / ".lock"


def day_folder(cfg: "RuntimeConfig", when: datetime | date) -> Path:
    d = when.date() if isinstance(when, datetime) else when
    return cfg.output_root / d.isoformat()


def transcript_filename(chunk: "AudioChunk", suffix: str | None = None) -> Path:
    """Per ``contracts/transcript-format.md``:
    ``<HHMMSS>_<sessionid8>_<chunk_seq:03d>.md``.
    """
    from huske.config import RuntimeConfig  # noqa: F401  (typing-only loop dodge)

    hhmmss = chunk.start_time.strftime("%H%M%S")
    sid = session_id_short(chunk.session_id)
    seq = f"{chunk.chunk_seq:03d}"
    name = f"{hhmmss}_{sid}_{seq}"
    if suffix:
        name = f"{name}_{suffix}"
    return Path(f"{name}.md")


def transcript_path(cfg: "RuntimeConfig", chunk: "AudioChunk") -> Path:
    folder = day_folder(cfg, chunk.start_time)
    return folder / transcript_filename(chunk).name


def disambiguate_if_collides(target: Path) -> Path:
    """If ``target`` already exists, append a 4-hex suffix until it doesn't."""
    if not target.exists():
        return target
    for _ in range(64):
        suffix = secrets.token_hex(2)
        stem = target.stem
        candidate = target.with_name(f"{stem}_{suffix}{target.suffix}")
        if not candidate.exists():
            return candidate
    raise RuntimeError(f"Could not find a non-colliding name for {target}")


def audio_chunk_path(
    cfg: "RuntimeConfig",
    session_id: str,
    chunk_seq: int,
    start_time: datetime,
) -> Path:
    folder = audio_root(cfg, session_id)
    name = f"{chunk_seq:04d}_{start_time.strftime('%H%M%S')}.wav"
    return folder / name


def incomplete_root(cfg: "RuntimeConfig") -> Path:
    return cfg.audio_root / "incomplete"


def screenshots_session_dir(
    cfg: "RuntimeConfig", session_id: str, when: datetime
) -> Path:
    """Per-day, per-session screenshot directory.

    ``~/huske/screenshots/YYYY-MM-DD/<session_id>/`` so downstream LLMs can
    correlate screenshots with that day's transcripts by timestamp.
    """
    return cfg.screenshots_root / when.date().isoformat() / session_id


def screenshot_filename(when: datetime, display_index: int) -> str:
    """``HHMMSS_dN.jpg`` per the layout in the spec."""
    return f"{when.strftime('%H%M%S')}_d{display_index}.jpg"


def ensure_dirs(cfg: "RuntimeConfig", session_id: str) -> None:
    """Create the per-session directories. Idempotent."""
    cfg.output_root.mkdir(parents=True, exist_ok=True)
    cfg.audio_root.mkdir(parents=True, exist_ok=True)
    cfg.logs_root.mkdir(parents=True, exist_ok=True)
    audio_root(cfg, session_id).mkdir(parents=True, exist_ok=True)
