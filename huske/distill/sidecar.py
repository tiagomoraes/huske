"""Read/write the ``<name>.statements.json`` sidecar — the distillation artifact.

Atomic write (temp + ``os.replace``) so a reader (the embedder, the off-device
sync, a human) never sees a half-written file. ``read_sidecar`` returns ``None``
on a missing or unparseable file — a corrupt sidecar is treated as "not yet
distilled" so the backfill simply regenerates it.
"""

from __future__ import annotations

import json
import os
from pathlib import Path

from huske.distill.models import StatementSidecar
from huske.paths import statements_sidecar_path


def write_sidecar(transcript_path: Path, sidecar: StatementSidecar) -> Path:
    """Atomically write ``sidecar`` next to ``transcript_path``; return its path."""
    target = statements_sidecar_path(transcript_path)
    target.parent.mkdir(parents=True, exist_ok=True)
    tmp = target.with_name(f"{target.name}.tmp")
    tmp.write_text(
        json.dumps(sidecar.to_dict(), ensure_ascii=False, indent=1), encoding="utf-8"
    )
    os.replace(tmp, target)
    return target


def read_sidecar(transcript_path: Path) -> StatementSidecar | None:
    """Return the sidecar for ``transcript_path``, or ``None`` if absent/corrupt."""
    target = statements_sidecar_path(transcript_path)
    if not target.exists():
        return None
    try:
        data = json.loads(target.read_text(encoding="utf-8"))
        return StatementSidecar.from_dict(data)
    except (OSError, ValueError, KeyError):
        return None


def sidecar_is_current(transcript_path: Path, source_sha256: str) -> bool:
    """True if a sidecar exists and was distilled from this exact transcript content."""
    sidecar = read_sidecar(transcript_path)
    return sidecar is not None and sidecar.source_sha256 == source_sha256
