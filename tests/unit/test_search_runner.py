"""`huske index` end-to-end via the CLI (hashing embedder, no MLX needed)."""

from __future__ import annotations

from datetime import datetime, timedelta
from pathlib import Path

import pytest

pytest.importorskip("sqlite_vec")

from typer.main import get_command

from huske.cli import app
from huske.search.embedder import HashingEmbedder
from huske.search.store import PassageStore
from huske.transcribe.writer import (
    body_from_source_segments,
    build_transcript_from_segments,
    write_transcript,
)


def _make_transcript(out: Path, phrase: str) -> Path:
    start = datetime(2026, 5, 7, 9, 30, 0).astimezone()
    segs = [
        {"start": 0.0, "end": 2.0, "text": phrase, "source": "system"},
        {"start": 3.0, "end": 4.0, "text": "perfeito, vamos seguir", "source": "microphone"},
    ]
    t = build_transcript_from_segments(
        session_id="20260507T093000_8a3f2c19",
        chunk_seq=1,
        start_time=start,
        end_time=start + timedelta(minutes=15),
        expected_duration_seconds=900,
        actual_duration_seconds=900.0,
        gap_seconds=0.0,
        audio_sources=["microphone", "system"],
        model="mlx-whisper:base",
        language="pt",
        incomplete=False,
        text=body_from_source_segments(start, segs),
        segments=segs,
    )
    day = out / "2026-05-07"
    day.mkdir(parents=True, exist_ok=True)
    return write_transcript(t, day / "093000_8a3f2c19_001.md")


def _config(tmp_path: Path) -> Path:
    out = tmp_path / "transcripts"
    idx = tmp_path / "index"
    cfg = tmp_path / "config.toml"
    cfg.write_text(
        f'output_root = "{out}"\n'
        f'index_root = "{idx}"\n'
        'embedding_model = "hashing"\n',
        encoding="utf-8",
    )
    return cfg


def _invoke(args: list[str]):
    from click.testing import CliRunner

    return CliRunner().invoke(get_command(app), args)


def test_index_cli_builds_and_is_incremental(tmp_path: Path) -> None:
    cfg = _config(tmp_path)
    out = tmp_path / "transcripts"
    _make_transcript(out, "discussão sobre migração de banco de dados")

    r1 = _invoke(["index", "--config", str(cfg)])
    assert r1.exit_code == 0, r1.output
    assert "1 indexed" in r1.output

    # Index is queryable.
    emb = HashingEmbedder()
    store = PassageStore.open(
        tmp_path / "index" / "passages.db",
        embedding_model="hashing",
        dim=emb.dim,
        create=False,
    )
    hits = store.search(emb.embed_query("migração de banco"), k=3)
    assert hits and "banco de dados" in hits[0].text
    store.close()

    # Second run skips unchanged.
    r2 = _invoke(["index", "--config", str(cfg)])
    assert "0 indexed, 1 unchanged" in r2.output, r2.output

    # Rebuild re-embeds.
    r3 = _invoke(["index", "--config", str(cfg), "--rebuild"])
    assert "1 indexed" in r3.output, r3.output


def test_index_model_mismatch_is_refused(tmp_path: Path) -> None:
    cfg = _config(tmp_path)
    _make_transcript(tmp_path / "transcripts", "conteúdo qualquer")
    assert _invoke(["index", "--config", str(cfg)]).exit_code == 0

    # Switch the model id without rebuilding → refused.
    cfg.write_text(
        cfg.read_text(encoding="utf-8").replace('"hashing"', '"hashing:128"'),
        encoding="utf-8",
    )
    r = _invoke(["index", "--config", str(cfg)])
    assert r.exit_code == 1
    assert "rebuild" in r.output.lower()
