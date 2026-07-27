"""Language-drift detection and the Parakeet re-decode guard.

Background (see ``huske/transcribe/engines/parakeet.py``): Parakeet has no
language input — it infers one per decode window — and on speech that mixes a
non-English language with English jargon it can collapse a whole window into
English. These tests cover the detector that notices it and the split-and-retry
that the engine responds with. The engine half runs against a scripted fake
model so it needs neither Apple Silicon nor the real weights.
"""

from __future__ import annotations

import sys
import types
from dataclasses import dataclass, field

import pytest

from huske.transcribe import langdrift

# Real sentences from a Portuguese meeting transcript, as decoded correctly.
PT_CLEAN = (
    "E aí, tipo, coisas que eu preciso fazer pra Natura, que está aqui já no "
    "pipe. São subir quatro apps, que é o app do front e dos três hubs, tá "
    "ligado? E aí, subindo o app, ele cria o repositório na organização da "
    "Natura automaticamente."
)
# The same speech after the window collapsed into English.
PT_DRIFTED = (
    "But when you log on GitHub, you can talk about this, and the uses no SCL "
    "da Microsoft will see your name that VPN. And you can come to the "
    "configuration of the LLM deles, or the interface visual do Natura OS."
)


class TestDetector:
    def test_clean_portuguese_is_not_drift(self) -> None:
        assert langdrift.drifted(PT_CLEAN, "pt") is False

    def test_collapsed_window_is_drift(self) -> None:
        assert langdrift.drifted(PT_DRIFTED, "pt") is True

    def test_loanwords_alone_do_not_trip_it(self) -> None:
        """Portuguese carrying English nouns is normal speech, not drift.

        This is the false positive that matters: the whole point of counting
        *function* words is that a sentence can be packed with English product
        and jargon nouns and still be unambiguously Portuguese.
        """
        text = (
            "O webhook do AppHub vai receber a mensagem e o front manda um JWT "
            "com access token e refresh token pro backend, que faz o deploy no "
            "cluster com Terraform e Kubernetes."
        )
        assert langdrift.drifted(text, "pt") is False

    def test_english_transcript_when_english_configured(self) -> None:
        """English is the attractor, so it is never itself a drift target."""
        assert langdrift.supports("en") is False
        assert langdrift.drifted(PT_DRIFTED, "en") is False

    @pytest.mark.parametrize("language", [None, "", "auto", "xx", "ja"])
    def test_unguardable_languages_are_inert(self, language: str | None) -> None:
        """No marker table (or no language) means the guard stays out of the way."""
        assert langdrift.supports(language) is False
        assert langdrift.drifted(PT_DRIFTED, language) is False

    def test_short_text_yields_no_verdict(self) -> None:
        """Too few marker words to score: say nothing rather than guess."""
        assert langdrift.english_ratio("Beleza. Certo.", "pt") is None
        assert langdrift.drifted("Beleza. Certo.", "pt") is False

    def test_ratio_separates_the_two_cases(self) -> None:
        clean = langdrift.english_ratio(PT_CLEAN, "pt")
        drift = langdrift.english_ratio(PT_DRIFTED, "pt")
        assert clean is not None and drift is not None
        assert clean < langdrift.DRIFT_THRESHOLD < drift

    def test_language_code_is_normalized(self) -> None:
        """`pt-BR`, `PT` and `pt` are the same language for guarding purposes."""
        assert langdrift.supports("pt-BR") is True
        assert langdrift.drifted(PT_DRIFTED, "PT") is True


# --- the engine-side guard ------------------------------------------------


@dataclass
class _FakeToken:
    text: str
    start: float = 0.0
    end: float = 0.0
    duration: float = 0.1


@dataclass
class _FakeSentence:
    tokens: list[_FakeToken]


@dataclass
class _FakeResult:
    sentences: list[_FakeSentence] = field(default_factory=list)

    @property
    def tokens(self) -> list[_FakeToken]:
        return [t for s in self.sentences for t in s.tokens]

    @property
    def text(self) -> str:
        return "".join(t.text for t in self.tokens)


def _result(text: str) -> _FakeResult:
    toks = [_FakeToken(text=w + " ", start=float(i) / 10) for i, w in enumerate(text.split())]
    return _FakeResult(sentences=[_FakeSentence(tokens=toks)])


class _FakeModel:
    """Returns drifted text for a full window and clean text for any sub-window."""

    def __init__(self, full_len: int) -> None:
        self.preprocessor_config = types.SimpleNamespace(sample_rate=16000, hop_length=160)
        self._full_len = full_len
        self.calls: list[int] = []

    def generate(self, mel, *, decoding_config=None):
        length = int(mel)  # the fake get_logmel passes the slice length through
        self.calls.append(length)
        drifted = length >= self._full_len
        return [_result(PT_DRIFTED if drifted else PT_CLEAN)]


@pytest.fixture
def fake_parakeet(monkeypatch: pytest.MonkeyPatch) -> None:
    """Stub the parakeet_mlx surface ``_decode_window`` reaches for."""
    audio_mod = types.ModuleType("parakeet_mlx.audio")
    audio_mod.get_logmel = lambda chunk, cfg: len(chunk)  # type: ignore[attr-defined]

    align_mod = types.ModuleType("parakeet_mlx.alignment")
    align_mod.merge_longest_contiguous = lambda a, b, overlap_duration: a + b  # type: ignore[attr-defined]
    align_mod.merge_longest_common_subsequence = lambda a, b, overlap_duration: a + b  # type: ignore[attr-defined]

    monkeypatch.setitem(sys.modules, "parakeet_mlx.audio", audio_mod)
    monkeypatch.setitem(sys.modules, "parakeet_mlx.alignment", align_mod)


class TestParakeetGuard:
    def _engine(self, language: str | None):
        from huske.transcribe.engines.parakeet import ParakeetEngine

        return ParakeetEngine(language=language)

    def test_drifted_window_is_split_and_re_decoded(self, fake_parakeet: None) -> None:
        sr = 16000
        n = 120 * sr
        model = _FakeModel(full_len=n)
        engine = self._engine("pt")

        tokens = engine._decode_window(model, list(range(n)), 0, n, sr, None)

        # One decode of the whole window, then one per half.
        assert len(model.calls) == 3
        assert model.calls[0] == n
        assert all(c < n for c in model.calls[1:])
        assert not langdrift.drifted("".join(t.text for t in tokens), "pt")

    def test_clean_window_costs_one_decode(self, fake_parakeet: None) -> None:
        sr = 16000
        n = 120 * sr
        model = _FakeModel(full_len=n + 1)  # nothing counts as drifted
        engine = self._engine("pt")

        engine._decode_window(model, list(range(n)), 0, n, sr, None)

        assert model.calls == [n]

    def test_guard_is_off_without_a_language(self, fake_parakeet: None) -> None:
        """Unset language keeps the pre-existing single-decode behaviour."""
        sr = 16000
        n = 120 * sr
        model = _FakeModel(full_len=n)
        engine = self._engine(None)

        engine._decode_window(model, list(range(n)), 0, n, sr, None)

        assert model.calls == [n]

    def test_short_window_is_never_split(self, fake_parakeet: None) -> None:
        """Below the minimum, splitting would cost context and buy nothing."""
        sr = 16000
        n = 30 * sr  # < 2 * _GUARD_MIN_WINDOW_SECONDS
        model = _FakeModel(full_len=n)
        engine = self._engine("pt")

        engine._decode_window(model, list(range(n)), 0, n, sr, None)

        assert model.calls == [n]

    def test_tokens_are_timed_absolutely_after_a_split(self, fake_parakeet: None) -> None:
        """A re-decoded half must still carry whole-chunk timestamps."""
        sr = 16000
        n = 120 * sr
        start = 60 * sr
        model = _FakeModel(full_len=n)
        engine = self._engine("pt")

        tokens = engine._decode_window(model, list(range(start + n)), start, start + n, sr, None)

        assert tokens
        assert min(t.start for t in tokens) >= start / sr
