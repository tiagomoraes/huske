"""Distiller: prompt, JSON parsing, routing, and the transcript → sidecar pass.

Uses the dependency-free HeuristicDistiller — no LLM daemon, no network.
"""

from __future__ import annotations

from datetime import datetime, timedelta
from pathlib import Path
from typing import cast

from huske.distill.distiller import (
    HeuristicDistiller,
    OllamaDistiller,
    build_distiller,
    build_prompt,
    distill_transcript,
    parse_statements,
)
from huske.transcribe.writer import (
    body_from_source_segments,
    build_transcript_from_segments,
    write_transcript,
)


def _write_transcript(day_dir: Path) -> Path:
    start = datetime(2026, 5, 7, 9, 30, 0).astimezone()
    segs = [
        {
            "start": 0.0,
            "end": 3.0,
            "text": "We decided to ship the roadmap on Friday. The budget is approved.",
            "source": "system",
        },
        {"start": 4.0, "end": 5.0, "text": "I will send the deck. Can you review it?", "source": "microphone"},
    ]
    body = body_from_source_segments(start, segs)
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
        language="en",
        incomplete=False,
        text=body,
        segments=segs,
    )
    day_dir.mkdir(parents=True, exist_ok=True)
    return write_transcript(t, day_dir / "093000_8a3f2c19_001.md")


def test_parse_statements_tolerates_shapes() -> None:
    assert parse_statements('{"statements": ["a", "b"]}', 8) == ["a", "b"]
    assert parse_statements('["x", "y"]', 8) == ["x", "y"]  # bare list
    assert parse_statements('{"claims": ["only value"]}', 8) == ["only value"]  # single-key dict
    assert parse_statements("not json at all", 8) == []
    assert parse_statements('{"statements": []}', 8) == []


def test_parse_statements_dedups_and_clamps() -> None:
    raw = '{"statements": ["dup", "DUP", "  dup ", "other", "third"]}'
    assert parse_statements(raw, 2) == ["dup", "other"]  # case-insensitive dedup + clamp to 2


def test_build_prompt_has_rules_and_excerpt() -> None:
    p = build_prompt("the meeting text", sources=["mic"], language="en", max_statements=5)
    assert "the meeting text" in p
    assert "JSON" in p
    assert "at most 5" in p
    assert "user" in p  # source legend


def test_heuristic_distiller_splits_sentences() -> None:
    d = HeuristicDistiller(max_statements=8)
    out = d.distill_passage("First claim. Second claim! Third?", sources=["mic"], language="en")
    assert out == ["First claim.", "Second claim!", "Third?"]


def test_build_distiller_routing() -> None:
    assert isinstance(build_distiller("heuristic"), HeuristicDistiller)
    real = build_distiller(
        "qwen3.5:0.8b", backend="ollama", endpoint="http://127.0.0.1:11434"
    )
    assert isinstance(real, OllamaDistiller)
    assert real.model_id == "qwen3.5:0.8b"
    assert real.backend == "ollama"
    assert real._think is False  # non-reasoning by default
    assert build_distiller("qwen3.5:0.8b", backend="ollama", think=True)._think is True
    # The default backend is the built-in MLX runtime (no daemon).
    from huske.distill.mlx_backend import MLXDistiller

    builtin = build_distiller("qwen3.5:0.8b")
    assert isinstance(builtin, MLXDistiller)
    assert builtin.backend == "mlx"
    builtin.close()


def test_ollama_distiller_calls_chat_no_thinking_by_default() -> None:
    calls: dict[str, object] = {}

    class _FakeClient:
        def chat(self, model, prompt, *, json_format, think, options):  # type: ignore[no-untyped-def]
            calls.update(model=model, think=think, json_format=json_format, options=options)
            return '{"statements": ["one", "two"]}'

    out = OllamaDistiller(_FakeClient(), "qwen3.5:0.8b").distill_passage(
        "some text", sources=["mic"], language="en"
    )
    assert out == ["one", "two"]
    assert calls["think"] is False  # default: no reasoning pass
    assert calls["json_format"] is True
    assert cast(dict, calls["options"])["temperature"] == 0.0

    OllamaDistiller(_FakeClient(), "qwen3.5:0.8b", think=True).distill_passage(
        "t", sources=["mic"], language="en"
    )
    assert calls["think"] is True  # opt-in reasoning is forwarded


def test_distill_transcript_produces_statements_with_provenance(tmp_path: Path) -> None:
    transcript = _write_transcript(tmp_path / "2026-05-07")
    sidecar = distill_transcript(transcript, HeuristicDistiller(), max_statements_per_passage=8)

    assert sidecar.session_id == "20260507T093000_8a3f2c19"
    assert sidecar.model == "heuristic"
    assert sidecar.transcript_path == str(transcript.resolve())
    assert len(sidecar.source_sha256) == 64
    assert sidecar.statements, "heuristic should split the passage into sentence claims"
    for s in sidecar.statements:
        assert s.text
        assert set(s.sources) <= {"mic", "system"} and s.sources  # inherited provenance
        assert s.end >= s.start
