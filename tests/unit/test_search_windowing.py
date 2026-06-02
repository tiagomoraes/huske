"""Passage windowing: multi-source grouping, gap breaks, token caps."""

from __future__ import annotations

from datetime import datetime, timedelta

from huske.search.models import Run, TranscriptDoc
from huske.search.windowing import MAX_TOKENS, window

_BASE = datetime(2026, 5, 7, 9, 30, 0).astimezone()


def _doc(runs: list[Run]) -> TranscriptDoc:
    return TranscriptDoc(
        path=__import__("pathlib").Path("/x/093000_s_002.md"),
        session_id="20260507T093000_s",
        chunk_seq=2,
        start_time=_BASE,
        end_time=_BASE + timedelta(minutes=15),
        language="pt",
        runs=runs,
    )


def _run(offset_s: float, source: str, text: str) -> Run:
    return Run(start=_BASE + timedelta(seconds=offset_s), source=source, text=text)


def test_small_runs_merge_into_one_multisource_passage() -> None:
    runs = [
        _run(0, "system", "Olá, vamos começar a reunião."),
        _run(1, "mic", "Oi, tudo certo."),
        _run(8, "system", "Hoje queria revisar o roadmap."),
    ]
    passages = window(_doc(runs))
    assert len(passages) == 1
    p = passages[0]
    # Multi-source: both sources captured, in first-seen order.
    assert p.sources == ["system", "mic"]
    assert p.has_mic and p.has_system
    assert "roadmap" in p.text and "tudo certo" in p.text
    assert p.uid == "/x/093000_s_002.md#0"
    assert p.day == 20260507


def test_large_gap_breaks_passages() -> None:
    runs = [
        _run(0, "system", "primeira parte da conversa aqui."),
        _run(600, "system", "muito depois, outro assunto."),  # 10 min gap
    ]
    passages = window(_doc(runs))
    assert len(passages) == 2
    assert "primeira" in passages[0].text
    assert "depois" in passages[1].text


def test_token_target_splits_into_multiple_passages() -> None:
    # 30 runs of ~10 words each ≈ 450 words ≈ 675 tokens > target 320.
    runs = [_run(i * 2, "mic", "palavra " * 10) for i in range(30)]
    passages = window(_doc(runs))
    assert len(passages) >= 2
    # Every passage stays under the hard cap (no e5 truncation).

    def toks(s: str) -> int:
        return max(1, round(len(s.split()) * 1.5))

    assert all(toks(p.text) <= MAX_TOKENS for p in passages)


def test_oversized_single_run_is_split() -> None:
    huge = " ".join(f"w{i}" for i in range(800))  # ~1200 tokens, one run
    passages = window(_doc([_run(0, "system", huge)]))
    assert len(passages) >= 2
    assert all(p.sources == ["system"] for p in passages)


def test_uids_are_sequential_and_unique() -> None:
    runs = [_run(i * 300, "mic", f"assunto numero {i}") for i in range(4)]  # gaps → 4 passages
    passages = window(_doc(runs))
    uids = [p.uid for p in passages]
    assert uids == [f"/x/093000_s_002.md#{i}" for i in range(len(passages))]
    assert len(set(uids)) == len(uids)
