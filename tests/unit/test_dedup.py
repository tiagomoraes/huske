"""Tests for cross-channel echo de-duplication."""

from __future__ import annotations

from huske.transcribe.dedup import mark_cross_channel_echoes, token_set_ratio
from huske.transcribe.engines.base import Segment


def _seg(start: float, end: float, text: str, source: str) -> Segment:
    return Segment(start=start, end=end, text=text, source=source)


def test_token_set_ratio_identical_and_reordered() -> None:
    assert token_set_ratio("hello world", "hello world") == 100.0
    # Order-insensitive: same token set scores perfectly.
    assert token_set_ratio("world hello", "hello world") == 100.0
    assert token_set_ratio("totally different", "nothing alike") < 50.0


def test_marks_mic_echo_of_system_segment() -> None:
    phrase = "de acordo com a sua agenda você tem uma reunião às onze horas"
    segs = [
        _seg(0.0, 3.0, "quais são as próximas reuniões de hoje", "microphone"),
        _seg(3.0, 8.0, phrase, "system"),
        _seg(4.0, 9.0, phrase, "microphone"),  # acoustic bleed of the system line
    ]
    marked = mark_cross_channel_echoes(segs)
    assert marked == 1
    assert segs[2].echo is True
    # The human's own mic line and the system line are untouched.
    assert segs[0].echo is False
    assert segs[1].echo is False


def test_marks_partial_fragment_echo() -> None:
    """A mic run that is only a *fragment* of the system run is still an echo."""
    full = "according to the latest report quarterly revenue increased fifteen percent across all regions"
    segs = [
        _seg(0.0, 6.0, full, "system"),
        # The bleed transcribed only the middle of the system line.
        _seg(2.0, 5.0, "quarterly revenue increased fifteen percent", "microphone"),
    ]
    marked = mark_cross_channel_echoes(segs)
    assert marked == 1
    assert segs[1].echo is True


def test_fragment_must_be_contiguous_run_not_scattered_words() -> None:
    """A human reply reusing a few of the system's words (not as a run) survives."""
    segs = [
        _seg(0.0, 6.0, "the migration to the new database cluster improved latency a lot", "system"),
        _seg(2.0, 5.0, "honestly the latency still worries me on mobile", "microphone"),
    ]
    marked = mark_cross_channel_echoes(segs)
    assert marked == 0
    assert segs[1].echo is False


def test_never_marks_system_segments() -> None:
    phrase = "this exact sentence appears on both channels at once"
    segs = [
        _seg(0.0, 4.0, phrase, "system"),
        _seg(0.2, 4.2, phrase, "microphone"),
    ]
    mark_cross_channel_echoes(segs)
    assert segs[0].echo is False  # system is the clean source — always kept
    assert segs[1].echo is True


def test_does_not_suppress_unrelated_mic_speech() -> None:
    segs = [
        _seg(0.0, 4.0, "vamos falar sobre o orçamento do próximo trimestre", "system"),
        _seg(0.5, 4.5, "eu discordo dessa abordagem completamente", "microphone"),
    ]
    marked = mark_cross_channel_echoes(segs)
    assert marked == 0
    assert segs[1].echo is False


def test_short_coincidental_overlap_not_marked() -> None:
    # A one-word match must not be removed on similarity alone.
    segs = [
        _seg(0.0, 1.0, "ok", "system"),
        _seg(0.3, 1.3, "ok", "microphone"),
    ]
    marked = mark_cross_channel_echoes(segs)
    assert marked == 0


def test_far_apart_in_time_not_matched() -> None:
    phrase = "uma frase bastante longa que aparece nos dois canais"
    segs = [
        _seg(0.0, 4.0, phrase, "system"),
        _seg(120.0, 124.0, phrase, "microphone"),  # 2 minutes later — not an echo
    ]
    marked = mark_cross_channel_echoes(segs)
    assert marked == 0


def test_no_system_segments_is_noop() -> None:
    segs = [
        _seg(0.0, 2.0, "olá tudo bem", "microphone"),
        _seg(2.0, 4.0, "como você está", "microphone"),
    ]
    assert mark_cross_channel_echoes(segs) == 0
    assert all(not s.echo for s in segs)
