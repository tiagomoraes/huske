"""Cross-channel echo de-duplication.

When huske records both microphone and system audio on a laptop *without*
headphones, whatever the speakers play (a call's remote participant, a TTS
voice, a video) is captured twice: once cleanly on the ``system`` channel and
once as acoustic bleed on the ``microphone`` channel. Both get transcribed, so
the same utterance appears on both sources a few seconds apart — exactly the
duplication seen in real transcripts.

This pass marks the *mic* copy as an echo of a near-simultaneous, textually
near-identical *system* segment. It is deliberately:

* **One-way** — only a mic segment is ever marked; the cleaner system segment
  is always kept. The human's own speech (which the system never emits) is
  never marked.
* **Self-gating** — it only fires when the bleed actually produced matching
  text. With headphones there is no matching mic segment, so nothing is
  marked.
* **Conservative** — a high text-similarity threshold plus a length guard means
  a coincidental short overlap ("ok", "sim") is never removed.

Similarity uses a token-set ratio (à la rapidfuzz's ``token_set_ratio``) built
on the stdlib ``difflib`` — no third-party dependency.
"""

from __future__ import annotations

import re
from difflib import SequenceMatcher

from huske.transcribe.engines.base import Segment

# A mic segment is considered for echo removal only if some system segment is
# near it in time. ASR segments the two channels independently, so the same
# words can land several seconds apart even though the acoustic delay is tiny;
# the window is generous because the high text-similarity bar is what actually
# prevents false matches.
_MAX_LAG_SECONDS = 15.0
# Token-set similarity in [0, 100]. >= this and the mic segment is an echo.
_SIMILARITY_THRESHOLD = 82.0
# A mic run can also be a *fragment* of a system run (the bleed transcribed only
# part of it, or a different split): if this fraction of the mic run's tokens
# form a contiguous run that also appears in a near system run, it is an echo.
_CONTAINMENT_THRESHOLD = 0.8
# Don't remove very short mic segments — a one- or two-word match ("ok", "sim
# claro") is too easily a genuine human reply that happens to echo a system
# word, so it stays even at high similarity.
_MIN_ECHO_WORDS = 3
# Fragments may be marked with fewer words, but never a bare one-word run.
_MIN_FRAGMENT_WORDS = 2

_WORD_RE = re.compile(r"\w+", re.UNICODE)


def _tokens(text: str) -> list[str]:
    return _WORD_RE.findall(text.lower())


def _ratio(a: str, b: str) -> float:
    if not a and not b:
        return 100.0
    if not a or not b:
        return 0.0
    return SequenceMatcher(None, a, b).ratio() * 100.0


def token_set_ratio(a: str, b: str) -> float:
    """Order-insensitive fuzzy similarity in [0, 100] (rapidfuzz-compatible).

    Compares the sorted intersection of the two token sets against each side's
    sorted (intersection + remainder), so reordered or partially-overlapping
    phrases still score high. This is what makes it robust to the small
    word-level differences between a clean system transcript and its noisier
    mic echo.
    """
    ta, tb = set(_tokens(a)), set(_tokens(b))
    if not ta and not tb:
        return 100.0
    inter = sorted(ta & tb)
    diff_a = sorted(ta - tb)
    diff_b = sorted(tb - ta)
    s_inter = " ".join(inter)
    s_a = " ".join(inter + diff_a)
    s_b = " ".join(inter + diff_b)
    # rapidfuzz semantics: the intersection string is compared against each
    # combined string, and the two combined strings against each other.
    return max(
        _ratio(s_inter, s_a),
        _ratio(s_inter, s_b),
        _ratio(s_a, s_b),
    )


def _containment(mic_tokens: list[str], sys_tokens: list[str]) -> float:
    """Fraction of ``mic_tokens`` covered by their longest contiguous run that
    also appears contiguously in ``sys_tokens``.

    ~1.0 when the mic run is a verbatim chunk of the system run (a partial echo
    the whole-string ratio would miss); low when the mic run is the local
    speaker's own words, which do not appear contiguously in the system audio.
    """
    if not mic_tokens:
        return 0.0
    match = SequenceMatcher(None, mic_tokens, sys_tokens).find_longest_match(
        0, len(mic_tokens), 0, len(sys_tokens)
    )
    return match.size / len(mic_tokens)


def _temporally_near(mic: Segment, sys: Segment, max_lag: float) -> bool:
    # Overlap, or mic starts within the lag window around the system span.
    if mic.start <= sys.end and sys.start <= mic.end:
        return True
    return (sys.start - max_lag) <= mic.start <= (sys.end + max_lag)


def mark_cross_channel_echoes(
    segments: list[Segment],
    *,
    similarity_threshold: float = _SIMILARITY_THRESHOLD,
    containment_threshold: float = _CONTAINMENT_THRESHOLD,
    max_lag_seconds: float = _MAX_LAG_SECONDS,
    min_echo_words: int = _MIN_ECHO_WORDS,
    min_fragment_words: int = _MIN_FRAGMENT_WORDS,
) -> int:
    """Flag mic segments that echo a system segment (sets ``.echo = True``).

    Returns the number of segments newly marked. Pure and in-place; the caller
    decides whether to drop or annotate the flagged segments.
    """
    sys_segments = [s for s in segments if s.source == "system"]
    if not sys_segments:
        return 0

    marked = 0
    for mic in segments:
        if mic.source != "microphone" or mic.echo:
            continue
        mic_tokens = _tokens(mic.text)
        mic_word_count = len(mic_tokens)
        if mic_word_count < min_fragment_words:
            # A bare one-word run is too easily a genuine brief human reply.
            continue
        is_echo = False
        for sys in sys_segments:
            if not _temporally_near(mic, sys, max_lag_seconds):
                continue
            # Full match: the runs say (nearly) the same thing.
            if mic_word_count >= min_echo_words and (
                token_set_ratio(mic.text, sys.text) >= similarity_threshold
            ):
                is_echo = True
                break
            # Fragment match: the mic run is a verbatim chunk of the system run
            # (a partial bleed). The contiguous-run requirement keeps a genuine
            # short human reply — whose words don't line up as a run inside the
            # system audio — from being removed.
            if _containment(mic_tokens, _tokens(sys.text)) >= containment_threshold:
                is_echo = True
                break
        if is_echo:
            mic.echo = True
            marked += 1
    return marked
