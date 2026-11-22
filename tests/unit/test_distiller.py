"""Distiller: prompt, JSON parsing, routing, and the transcript correction pass.

Uses the dependency-free HeuristicDistiller — no LLM daemon, no network.
"""

from __future__ import annotations

import hashlib
from datetime import datetime, timedelta
from pathlib import Path
from typing import cast

from huske.config import RuntimeConfig
from huske.distill.correction import parse_reply
from huske.distill.distiller import (
    HeuristicDistiller,
    TranscriptCorrector,
    build_backend,
    build_distiller,
    distill_transcript,
)
from huske.distill.ollama_backend import OllamaBackend
from huske.paths import asr_raw_path
from huske.transcribe.vocabulary import Vocabulary
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


def test_heuristic_distiller_echoes_numbered_lines() -> None:
    reply = HeuristicDistiller().complete(
        "rules", "<transcript>\n[1] First claim.\n[2] Second?\n</transcript>", max_tokens=50
    )
    assert parse_reply(reply, 2) == {1: "First claim.", 2: "Second?"}


def test_build_backend_routing() -> None:
    assert isinstance(build_backend(RuntimeConfig(distill_model="heuristic")), HeuristicDistiller)
    real = build_backend(RuntimeConfig(distill_backend="ollama", distill_model="qwen3.5:0.8b"))
    assert isinstance(real, OllamaBackend)
    assert real.model_id == "qwen3.5:0.8b"
    assert real._think is False  # non-reasoning by default
    thinking = build_backend(RuntimeConfig(distill_backend="ollama", distill_think=True))
    assert isinstance(thinking, OllamaBackend) and thinking._think is True
    # The default backend is the built-in MLX runtime (no daemon).
    from huske.distill.mlx_backend import MLXDistiller

    builtin = build_backend(RuntimeConfig(distill_model="qwen3.5:0.8b"))
    assert isinstance(builtin, MLXDistiller)
    assert builtin.model_id == "mlx-community/Qwen3.5-0.8B-4bit"  # tag mapped
    builtin.close()


def test_cloud_backend_without_a_key_is_a_setup_error(monkeypatch) -> None:  # type: ignore[no-untyped-def]
    from huske.distill import keychain
    from huske.distill.client import DistillError

    monkeypatch.setattr(keychain, "get_key", lambda _p: None)
    try:
        build_backend(RuntimeConfig(distill_backend="anthropic"))
    except DistillError as exc:
        assert exc.kind == "auth"
    else:  # pragma: no cover
        raise AssertionError("expected a missing-key error")


def test_build_distiller_carries_dictionary_language_and_instructions() -> None:
    cfg = RuntimeConfig(
        distill_model="heuristic",
        language="pt",
        vocabulary=["OKR"],
        distill_instructions="Remove filler words.",
    )
    corrector = build_distiller(cfg)
    assert corrector.vocabulary.terms == ("OKR",)
    assert corrector.fallback_language == "pt"
    assert corrector.instructions == "Remove filler words."
    assert corrector.label == "fake:heuristic"


def test_ollama_backend_calls_chat_no_thinking_by_default() -> None:
    calls: dict[str, object] = {}

    class _FakeClient:
        def chat(self, model, prompt, *, system, json_format, think, options):  # type: ignore[no-untyped-def]
            calls.update(
                model=model, system=system, think=think, json_format=json_format, options=options
            )
            return "[1] some text"

    out = OllamaBackend(_FakeClient(), "qwen3.5:0.8b").complete("rules", "[1] x", max_tokens=77)
    assert out == "[1] some text"
    assert calls["think"] is False  # default: no reasoning pass
    assert calls["json_format"] is False  # numbered lines, not JSON
    assert calls["system"] == "rules"
    assert cast(dict, calls["options"]) == {"temperature": 0.0, "num_predict": 77}

    OllamaBackend(_FakeClient(), "qwen3.5:0.8b", think=True).complete("r", "[1] t", max_tokens=5)
    assert calls["think"] is True  # opt-in reasoning is forwarded


def test_distill_transcript_produces_statements_with_provenance(tmp_path: Path) -> None:
    transcript = _write_transcript(tmp_path / "2026-05-07")
    sidecar = distill_transcript(transcript, HeuristicDistiller())

    assert sidecar.session_id == "20260507T093000_8a3f2c19"
    assert sidecar.model == "heuristic"
    assert sidecar.transcript_path == str(transcript.resolve())
    assert len(sidecar.source_sha256) == 64
    assert sidecar.statements, "heuristic should emit one polished run per source run"
    for s in sidecar.statements:
        assert s.text
        assert set(s.sources) <= {"mic", "system"} and s.sources  # inherited provenance
        assert s.end >= s.start
    raw = asr_raw_path(transcript)
    assert raw.exists()
    assert raw.suffix == ".txt"
    assert sidecar.source_sha256 == hashlib.sha256(raw.read_bytes()).hexdigest()


class _TypoDistiller(HeuristicDistiller):
    provider = "fake"
    model_id = "typo-fixer"

    def complete(self, instructions: str, prompt: str, *, max_tokens: int) -> str:
        reply = super().complete(instructions, prompt, max_tokens=max_tokens)
        return reply.replace("teh", "the").replace("recieve", "receive")


def test_distill_transcript_rewrites_md_and_keeps_raw(tmp_path: Path) -> None:
    start = datetime(2026, 5, 7, 9, 30, 0).astimezone()
    segs = [
        {"start": 0.0, "end": 3.0, "text": "please recieve teh file", "source": "system"},
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
        audio_sources=["system"],
        model="mlx-whisper:base",
        language="en",
        incomplete=False,
        text=body,
        segments=segs,
    )
    day = tmp_path / "2026-05-07"
    day.mkdir(parents=True)
    transcript = write_transcript(t, day / "093000_8a3f2c19_001.md")
    original = transcript.read_text(encoding="utf-8")

    sidecar = distill_transcript(transcript, _TypoDistiller())
    polished = transcript.read_text(encoding="utf-8")
    raw = asr_raw_path(transcript).read_text(encoding="utf-8")

    assert raw == original
    assert "please receive the file" in polished
    assert "recieve teh" not in polished
    assert sidecar.statements[0].text == "please receive the file"
    # The polished file says who processed it and where the raw text lives.
    assert "postprocessed_by: fake:typo-fixer" in polished
    assert "raw_transcript: 093000_8a3f2c19_001.asr.txt" in polished
    assert "postprocessed_at:" in polished
    # Everything else in the frontmatter is untouched, byte for byte.
    front_before = original.split("---")[1]
    front_after = polished.split("---")[1]
    assert front_after.startswith(front_before.rstrip("\n"))
    # Re-run must hash the raw snapshot, not the polished .md, and must not
    # stack a second set of markers.
    again = distill_transcript(transcript, _TypoDistiller())
    assert again.source_sha256 == sidecar.source_sha256
    assert transcript.read_text(encoding="utf-8").count("postprocessed_by:") == 1


def test_failed_cleanup_leaves_the_raw_transcript_untouched(tmp_path: Path) -> None:
    from huske.distill.client import DistillError

    class _Down(HeuristicDistiller):
        def complete(self, instructions: str, prompt: str, *, max_tokens: int) -> str:
            raise DistillError("connection refused", kind="transport")

    transcript = _write_transcript(tmp_path / "2026-05-07")
    original = transcript.read_text(encoding="utf-8")
    try:
        distill_transcript(transcript, _Down())
    except DistillError:
        pass
    assert transcript.read_text(encoding="utf-8") == original
    assert "postprocessed_by" not in original


def test_dictionary_reaches_the_cleanup_pass(tmp_path: Path) -> None:
    transcript = _write_transcript(tmp_path / "2026-05-07")
    corrector = TranscriptCorrector(
        backend=HeuristicDistiller(),
        vocabulary=Vocabulary(replacements=(("the roadmap", "the Roadmap™"),)),
    )
    distill_transcript(transcript, corrector)
    assert "the Roadmap™" in transcript.read_text(encoding="utf-8")
