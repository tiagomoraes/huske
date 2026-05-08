"""Render Transcript objects as Markdown + YAML frontmatter, atomic write."""

from __future__ import annotations

import os
from datetime import datetime, timedelta
from pathlib import Path

import yaml

from huske import __version__
from huske.models import Transcript


_DAYS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]


def _heading(t: Transcript) -> str:
    day = _DAYS[t.start_time.weekday()]
    return (
        f"# {t.start_time.strftime('%H:%M')} – {t.end_time.strftime('%H:%M')} "
        f"({day} {t.start_time.date().isoformat()})"
    )


def render_transcript(t: Transcript) -> str:
    """Return the full file contents as a string."""
    front: dict[str, object] = {
        "session_id": t.session_id,
        "chunk_seq": t.chunk_seq,
        "date": t.date,
        "start_time": t.start_time.isoformat(timespec="seconds"),
        "end_time": t.end_time.isoformat(timespec="seconds"),
        "duration_seconds": int(t.duration_seconds),
        "duration_actual_seconds": round(float(t.actual_duration_seconds), 3),
        "gap_seconds": round(float(t.gap_seconds), 3),
        "audio_sources": list(t.audio_sources),
        "model": t.model,
        "language": t.language,
        "incomplete": bool(t.incomplete),
        "huske_version": t.huske_version,
    }
    body = t.body.strip() if t.body and t.body.strip() else "_(no speech detected)_"

    fm = yaml.safe_dump(front, sort_keys=False, allow_unicode=True).rstrip("\n")
    return f"---\n{fm}\n---\n\n{_heading(t)}\n\n{body}\n"


def write_transcript(t: Transcript, target: Path) -> Path:
    """Atomically write the rendered transcript at ``target``.

    Returns the actual path written (may differ from ``target`` if
    a collision was detected — we never overwrite).
    """

    from huske.paths import disambiguate_if_collides  # local import dodges cycle

    target.parent.mkdir(parents=True, exist_ok=True)
    final = disambiguate_if_collides(target)
    rendered = render_transcript(t)

    tmp = final.with_suffix(final.suffix + ".tmp")
    tmp.write_text(rendered, encoding="utf-8")
    os.replace(tmp, final)
    return final


def build_transcript_from_segments(
    *,
    session_id: str,
    chunk_seq: int,
    start_time: datetime,
    end_time: datetime,
    expected_duration_seconds: float,
    actual_duration_seconds: float,
    gap_seconds: float,
    audio_sources: list[str],
    model: str,
    language: str,
    incomplete: bool,
    text: str,
    segments: list[dict] | None = None,
) -> Transcript:
    return Transcript(
        session_id=session_id,
        chunk_seq=chunk_seq,
        start_time=start_time,
        end_time=end_time,
        duration_seconds=int(expected_duration_seconds),
        actual_duration_seconds=actual_duration_seconds,
        gap_seconds=gap_seconds,
        audio_sources=audio_sources,
        model=model,
        language=language,
        incomplete=incomplete,
        body=text,
        huske_version=__version__,
        segments=segments,
    )


_SOURCE_LABEL = {"microphone": "mic", "system": "system"}


def _label_for(source: str) -> str:
    return _SOURCE_LABEL.get(source, source)


def body_from_source_segments(
    chunk_start: datetime, segments: list[dict]
) -> str:
    """Render merged-by-source segments as paragraphs prefixed with ``[HH:MM:SS · source]``.

    ``segments`` is a list of dicts with at least ``start`` (seconds offset
    inside the chunk's WAV), ``text``, and ``source``. Empty/whitespace-only
    text is skipped. Returns ``""`` if nothing remains — the caller (the
    transcript renderer) substitutes the "no speech detected" placeholder.
    """
    lines: list[str] = []
    for seg in segments:
        text = (seg.get("text") or "").strip()
        if not text:
            continue
        offset = float(seg.get("start", 0.0))
        ts = (chunk_start + timedelta(seconds=offset)).strftime("%H:%M:%S")
        source = _label_for(str(seg.get("source", "")))
        lines.append(f"[{ts} · {source}] {text}")
    return "\n\n".join(lines)
