"""Custom dictionary: deterministic replacements, case fixes, prompt budgets.

Synthetic text only.
"""

from __future__ import annotations

import pytest

from huske.transcribe.vocabulary import Vocabulary, estimate_tokens


def test_empty_vocabulary_is_identity() -> None:
    vocab = Vocabulary()
    assert vocab.is_empty
    assert vocab.apply("nada muda aqui") == "nada muda aqui"
    assert vocab.whisper_prompt("pt") is None
    assert vocab.glossary() == ""


def test_replacement_is_case_insensitive_and_word_bounded() -> None:
    vocab = Vocabulary(replacements=(("cube ernetes", "Kubernetes"),))
    assert (
        vocab.apply("O cluster de Cube Ernetes caiu, cube   ernetes de novo.")
        == "O cluster de Kubernetes caiu, Kubernetes de novo."
    )
    # Inside a longer word it is not a match.
    assert vocab.apply("supercube ernetesx") == "supercube ernetesx"


def test_replacement_respects_unicode_word_boundaries() -> None:
    vocab = Vocabulary(replacements=(("ana", "Anna"),))
    assert vocab.apply("a ana chegou") == "a Anna chegou"
    # "banana" and "anaçã" contain the letters but are different words.
    assert vocab.apply("banana anaçã") == "banana anaçã"


def test_longest_replacement_wins() -> None:
    vocab = Vocabulary(
        replacements=(("hub", "HUB"), ("hub spot", "HubSpot")),
    )
    assert vocab.apply("abre o hub spot e o hub") == "abre o HubSpot e o HUB"


def test_replacement_text_is_literal_not_a_regex_template() -> None:
    vocab = Vocabulary(replacements=(("dolar", r"$1 \g<0>"),))
    assert vocab.apply("um dolar") == r"um $1 \g<0>"


def test_heard_phrase_with_regex_metacharacters_is_escaped() -> None:
    vocab = Vocabulary(replacements=(("c++", "C++"), ("a.b", "AB")),)
    assert vocab.apply("uso c++ e axb") == "uso C++ e axb"


def test_distinctive_terms_fix_casing_only() -> None:
    vocab = Vocabulary(terms=("OKR", "GitHub", "iPhone", "Kubernetes", "Go"))
    text = "os okrs do github e do Iphone; okr no github. kubernetes e go."
    out = vocab.apply(text)
    # Distinctive capitalisation (an upper-case letter after the first) is
    # restored; whole words only ("okrs" is a different word).
    assert "okrs" in out
    assert "OKR no GitHub" in out
    assert "do GitHub" in out
    assert "iPhone" in out
    # Plain title-case terms could be ordinary words ("go"), so they are left
    # to the ASR prompt and the LLM, never rewritten deterministically.
    assert out.endswith("kubernetes e go.")


def test_replacements_run_before_case_fixes() -> None:
    vocab = Vocabulary(terms=("GitHub",), replacements=(("get hub", "github"),))
    assert vocab.apply("abre o get hub") == "abre o GitHub"


def test_from_config_cleans_and_dedupes() -> None:
    vocab = Vocabulary.from_config(
        ["  OKR ", "", "okr", "Huske"],
        {" husky ": " Huske ", "": "x", "y": ""},
    )
    assert vocab.terms == ("OKR", "Huske")
    assert vocab.replacements == (("husky", "Huske"),)


def test_job_round_trip() -> None:
    vocab = Vocabulary(terms=("OKR",), replacements=(("husky", "Huske"),))
    job = vocab.to_job()
    assert job == {"vocabulary": ["OKR"], "vocabulary_replacements": {"husky": "Huske"}}
    assert Vocabulary.from_job(job) == vocab
    assert Vocabulary.from_job({}) == Vocabulary()
    # Garbage in a job never raises.
    assert Vocabulary.from_job({"vocabulary": "nope", "vocabulary_replacements": [1]}) == Vocabulary()


def test_whisper_prompt_mentions_terms_and_replacement_targets() -> None:
    vocab = Vocabulary(terms=("OKR", "Kubernetes"), replacements=(("husky", "Huske"),))
    prompt = vocab.whisper_prompt("pt")
    assert prompt is not None
    for word in ("OKR", "Kubernetes", "Huske"):
        assert word in prompt
    # The misheard form is never fed to the model as a spelling to imitate.
    assert "husky" not in prompt


def test_whisper_prompt_fits_the_token_budget() -> None:
    terms = tuple(f"Termo{i:03d}" for i in range(400))
    vocab = Vocabulary(terms=terms)
    prompt = vocab.whisper_prompt("pt", max_tokens=60, count_tokens=lambda s: len(s.split()))
    assert prompt is not None
    assert len(prompt.split()) <= 60
    # Earlier entries are kept first: the list is in the user's priority order.
    assert "Termo000" in prompt
    assert "Termo399" not in prompt


def test_glossary_lists_spellings_and_mishearings_within_budget() -> None:
    vocab = Vocabulary(terms=("OKR", "Kubernetes"), replacements=(("husky", "Huske"),))
    text = vocab.glossary()
    assert "OKR" in text and "Kubernetes" in text
    assert "husky" in text and "Huske" in text
    many = Vocabulary(terms=tuple(f"Word{i}" for i in range(2000)))
    assert estimate_tokens(many.glossary(max_tokens=100)) <= 100


@pytest.mark.parametrize(
    ("text", "low", "high"),
    [("", 0, 0), ("hello world", 2, 5), ("ação " * 100, 100, 260)],
)
def test_estimate_tokens_is_conservative(text: str, low: int, high: int) -> None:
    assert low <= estimate_tokens(text) <= high
