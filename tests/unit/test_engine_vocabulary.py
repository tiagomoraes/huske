"""How each ASR engine uses the language and the custom dictionary.

No model weights: Whisper's decode is replaced by a recorder, Parakeet's
booster is built against a toy vocabulary.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, ClassVar

import pytest

from huske.transcribe.engines.parakeet import ParakeetEngine
from huske.transcribe.engines.whisper import WhisperEngine, _carry_prompt, looks_like_prompt
from huske.transcribe.vocabulary import Vocabulary

VOCAB = Vocabulary(terms=("Kubernetes", "OKR", "Huske"), replacements=(("husky", "Huske"),))


def test_whisper_builds_a_prompt_only_with_a_dictionary() -> None:
    engine = WhisperEngine("tiny", language="pt")
    assert engine.initial_prompt() is None
    engine.set_options(language="pt", vocabulary=VOCAB)
    prompt = engine.initial_prompt()
    assert prompt is not None
    assert "Kubernetes" in prompt and "husky" not in prompt


def test_prompt_echo_is_recognized_but_speech_is_not() -> None:
    prompt = "Nesta conversa aparecem: Kubernetes, OKR, Huske."
    spellings = ["Kubernetes", "OKR", "Huske"]
    assert looks_like_prompt("Kubernetes, OKR, Huske.", prompt, spellings)
    assert looks_like_prompt("Nesta conversa aparecem", prompt, spellings)
    assert not looks_like_prompt("O deploy do Kubernetes caiu ontem.", prompt, spellings)
    assert not looks_like_prompt("OKR", prompt, spellings)  # one word is real speech
    assert not looks_like_prompt("Kubernetes, OKR, Huske.", None, spellings)


@dataclass(frozen=True)
class _Options:
    prompt: list[int] | None = None
    temperature: float = 0.0


@dataclass
class _Recorder:
    seen: list[Any] = field(default_factory=list)


def test_carry_prompt_fills_only_empty_window_prompts(monkeypatch: pytest.MonkeyPatch) -> None:
    pytest.importorskip("mlx_whisper")
    from mlx_whisper import whisper as whisper_module

    recorder = _Recorder()

    def fake_decode(model: Any, mel: Any, options: Any = None, **_: Any) -> Any:
        recorder.seen.append(options.prompt)
        return "ok"

    monkeypatch.setattr(whisper_module.Whisper, "decode", fake_decode)
    model = whisper_module.Whisper.__new__(whisper_module.Whisper)
    with _carry_prompt([1, 2, 3]):
        whisper_module.Whisper.decode(model, "mel", _Options(prompt=[]))  # empty → carried
        whisper_module.Whisper.decode(model, "mel", _Options(prompt=[9]))  # kept
    whisper_module.Whisper.decode(model, "mel", _Options(prompt=[]))  # outside → untouched
    assert recorder.seen == [[1, 2, 3], [9], []]
    assert whisper_module.Whisper.decode is fake_decode  # restored


class _ToyModel:
    vocabulary: ClassVar[list[str]] = ["▁", "▁Ku", "ber", "netes", "▁OK", "R", "▁Hu", "ske", "a", "e"]


def test_parakeet_decodes_greedy_without_boost() -> None:
    pytest.importorskip("parakeet_mlx")
    from parakeet_mlx.parakeet import Greedy

    engine = ParakeetEngine()
    engine.set_options(language="pt", vocabulary=VOCAB, word_boost=False)
    assert engine.boost_terms() == ()
    assert isinstance(engine._decoding_config(_ToyModel()).decoding, Greedy)


def test_parakeet_boost_switches_to_beam_with_the_dictionary() -> None:
    boost = pytest.importorskip("parakeet_mlx.boost")
    del boost
    from parakeet_mlx.parakeet import Beam

    engine = ParakeetEngine()
    engine.set_options(language="pt", vocabulary=VOCAB, word_boost=True)
    assert engine.boost_terms() == ("Kubernetes", "OKR", "Huske")
    config = engine._decoding_config(_ToyModel())
    assert isinstance(config.decoding, Beam)
    assert config.decoding.beam_size == 5
    # Cached while the dictionary is unchanged.
    assert engine._decoding_config(_ToyModel()) is config
    engine.set_options(language="pt", vocabulary=Vocabulary(terms=("Jira",)), word_boost=True)
    assert engine._decoding_config(_ToyModel()) is not config
