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
_MAX_LAG_SECONDS = 12.0
# Token-set similarity in [0, 100]. >= this and the mic segment is an echo.
_SIMILARITY_THRESHOLD = 82.0
# Don't remove very short mic segments — a one- or two-word match ("ok", "sim
# claro") is too easily a genuine human reply that happens to echo a system
# word, so it stays even at high similarity.
_MIN_ECHO_WORDS = 3

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


def _temporally_near(mic: Segment, sys: Segment, max_lag: float) -> bool:
    # Overlap, or mic starts within the lag window around the system span.
    if mic.start <= sys.end and sys.start <= mic.end:
        return True
    return (sys.start - max_lag) <= mic.start <= (sys.end + max_lag)


def mark_cross_channel_echoes(
    segments: list[Segment],
    *,
    similarity_threshold: float = _SIMILARITY_THRESHOLD,
    max_lag_seconds: float = _MAX_LAG_SECONDS,
    min_echo_words: int = _MIN_ECHO_WORDS,
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
        mic_word_count = len(_tokens(mic.text))
        # Length guard: a short mic segment is never removed on similarity
        # alone — it is too likely to be a genuine brief human reply.
        if mic_word_count < min_echo_words:
            continue
        best = 0.0
        for sys in sys_segments:
            if not _temporally_near(mic, sys, max_lag_seconds):
                continue
            score = token_set_ratio(mic.text, sys.text)
            if score > best:
                best = score
        if best >= similarity_threshold:
            mic.echo = True
            marked += 1
    return marked
