"""``huske distill`` orchestration: config → distiller → correct transcripts.

Mirrors ``huske.search.runner``: gentle (low-impact) by default so a one-shot
backfill of a long transcript history can't pin the machine. The heavy work is
the LLM daemon's; here "gentle" just lowers our own CPU priority while we feed it.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from huske.config import load_config
from huske.distill.client import DistillError, OllamaClient
from huske.distill.distiller import build_distiller, distill_transcript, source_sha256_for
from huske.distill.sidecar import sidecar_is_current, write_sidecar
from huske.distill.worker import iter_transcripts
from huske.search.parser import ParseError

_GENTLE_NICE = 10  # yield CPU to interactive work during a backfill


@dataclass
class DistillSummary:
    files_seen: int = 0
    files_distilled: int = 0
    files_skipped: int = 0
    files_failed: int = 0
    statements: int = 0
    errors: list[str] = field(default_factory=list)


def _print(msg: str) -> None:
    print(msg, flush=True)


def _lower_process_priority(nice_increment: int = _GENTLE_NICE) -> None:
    """Best-effort deprioritize (a seam tests neutralize, like search.runner)."""
    try:
        os.nice(nice_increment)
    except (OSError, AttributeError):  # pragma: no cover - platform dependent
        pass


def _preflight(cfg: Any) -> str | None:
    """Confirm the backend can serve ``distill_model`` before a long backfill.

    Returns an error message (caller should abort) or ``None`` when good. The
    heuristic/fake distiller needs nothing; the built-in mlx backend goes
    through the shared readiness probe (runtime importable — the model itself
    downloads on first use); the ollama backend checks daemon + pulled model.
    """
    if cfg.distill_model in ("heuristic", "fake"):
        return None
    if cfg.distill_backend != "ollama":
        from huske.distill.health import probe_distill

        r = probe_distill(
            cfg.distill_model, backend=cfg.distill_backend, endpoint=cfg.distill_endpoint
        )
        if r.ok:
            return None
        return f"{r.detail}\n  hint: {r.hint or ''}".rstrip()
    client = OllamaClient(cfg.distill_endpoint, timeout=cfg.distill_timeout_seconds)
    try:
        models = client.list_models()
    except DistillError as exc:
        return (
            f"{exc}\n  hint: start the daemon (`ollama serve`) or set distill_endpoint."
        )
    # Ollama tags carry a ``:latest`` suffix when none is given; match loosely.
    wanted = cfg.distill_model
    if wanted not in models and f"{wanted}:latest" not in models and not any(
        m.split(":", 1)[0] == wanted.split(":", 1)[0] and wanted in m for m in models
    ):
        return (
            f"model {wanted!r} is not pulled (have: {', '.join(models) or 'none'}).\n"
            f"  hint: `ollama pull {wanted}`"
        )
    return None


def run_distill(
    config_path: Path | None = None,
    cli_overrides: dict[str, Any] | None = None,
    *,
    force: bool = False,
    low_impact: bool | None = None,
) -> int:
    """Correct every transcript lacking a current sidecar. Returns an exit code."""
    try:
        cfg = load_config(config_path=config_path, cli_overrides=cli_overrides)
    except ValueError as exc:
        _print(f"[error] config: {exc}")
        return 2

    gentle = cfg.distill_low_impact if low_impact is None else low_impact

    err = _preflight(cfg)
    if err is not None:
        _print(f"[error] {err}")
        return 1

    distiller = build_distiller(
        cfg.distill_model,
        backend=cfg.distill_backend,
        endpoint=cfg.distill_endpoint,
        timeout=cfg.distill_timeout_seconds,
        max_statements=cfg.distill_max_statements_per_passage,
        think=cfg.distill_think,
    )

    if gentle:
        _lower_process_priority()
        _print(f"[huske] low-impact mode: nice +{_GENTLE_NICE}. Pass --fast to run flat out.")
    _print(
        f"[huske] correcting transcripts under {cfg.output_root} "
        f"(model {cfg.distill_model} via {cfg.distill_backend})…"
    )

    summary = DistillSummary()
    for path in iter_transcripts(cfg.output_root):
        summary.files_seen += 1
        try:
            source_sha = source_sha256_for(path)
            if not force and sidecar_is_current(path, source_sha):
                summary.files_skipped += 1
                continue
            sidecar = distill_transcript(
                path, distiller, max_statements_per_passage=cfg.distill_max_statements_per_passage
            )
            write_sidecar(path, sidecar)
            summary.files_distilled += 1
            summary.statements += len(sidecar.statements)
        except (ParseError, DistillError) as exc:
            summary.files_failed += 1
            summary.errors.append(f"{path.name}: {exc}")
        except Exception as exc:
            summary.files_failed += 1
            summary.errors.append(f"{path.name}: {exc}")

    _print(
        f"\n{summary.files_distilled} corrected, {summary.files_skipped} unchanged, "
        f"{summary.files_failed} failed across {summary.files_seen} transcript(s); "
        f"{summary.statements} run(s) polished."
    )
    for e in summary.errors[:10]:
        _print(f"  [warn] {e.splitlines()[0]}")
    if len(summary.errors) > 10:
        _print(f"  …and {len(summary.errors) - 10} more")
    return 0 if summary.files_failed == 0 else 1
