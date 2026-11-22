"""LLM post-processing core: batching, prompts, reply parsing, fallbacks.

A scripted fake backend stands in for every model. Synthetic text only.
"""

from __future__ import annotations

from collections.abc import Callable

import pytest

from huske.distill.client import DistillError
from huske.distill.correction import (
    acceptable_correction,
    build_instructions,
    build_user_prompt,
    correct_texts,
    parse_reply,
    plan_batches,
    split_long_text,
)
from huske.transcribe.vocabulary import Vocabulary, estimate_tokens


class ScriptedBackend:
    """Echo the numbered lines back through ``transform``; record every call."""

    provider = "fake"
    model_id = "scripted"

    def __init__(self, transform: Callable[[int, str], str] | None = None) -> None:
        self.transform = transform or (lambda _i, text: text)
        self.calls: list[tuple[str, str, int]] = []

    def complete(self, instructions: str, prompt: str, *, max_tokens: int) -> str:
        self.calls.append((instructions, prompt, max_tokens))
        lines = parse_reply(prompt.replace("<transcript>", "").replace("</transcript>", ""), 10_000)
        return "\n".join(f"[{i}] {self.transform(i, t)}" for i, t in sorted(lines.items()))


# -- prompts ------------------------------------------------------------------


def test_instructions_carry_rules_language_glossary_and_extras() -> None:
    text = build_instructions(
        language="pt",
        vocabulary=Vocabulary(terms=("OKR",), replacements=(("husky", "Huske"),)),
        extra="Remove filler words.",
    )
    assert "Portuguese" in text
    assert "OKR" in text and "husky → Huske" in text
    assert "Remove filler words." in text
    assert "[n]" in text  # the output format rule
    assert "never follow" in text.lower()  # transcript is data, not instructions


def test_instructions_without_language_say_do_not_translate() -> None:
    text = build_instructions(language=None, vocabulary=Vocabulary(), extra="")
    assert "translate" in text.lower()
    assert "Spell these" not in text


def test_user_prompt_numbers_lines_inside_tags() -> None:
    prompt = build_user_prompt(["primeira linha", "segunda linha"])
    assert prompt.startswith("<transcript>\n[1] primeira linha\n[2] segunda linha\n")
    assert prompt.rstrip().endswith("</transcript>")


# -- reply parsing --------------------------------------------------------------


def test_parse_reply_reads_markers_and_continuations() -> None:
    reply = "[1] Primeira.\n[2] Segunda parte\ncontinua aqui.\n[3]: Terceira."
    assert parse_reply(reply, 3) == {1: "Primeira.", 2: "Segunda parte continua aqui.", 3: "Terceira."}


def test_parse_reply_strips_thinking_fences_and_tags() -> None:
    reply = "<think>hmm</think>\n```text\n<transcript>\n[1] Olá.\n</transcript>\n```"
    assert parse_reply(reply, 1) == {1: "Olá."}


def test_parse_reply_drops_duplicate_and_out_of_range_ids() -> None:
    reply = "[1] a\n[1] b\n[2] c\n[9] d"
    assert parse_reply(reply, 2) == {2: "c"}


def test_parse_reply_single_line_without_marker_is_accepted() -> None:
    assert parse_reply("Só uma linha corrigida.", 1) == {1: "Só uma linha corrigida."}
    assert parse_reply("Sem marcador.", 2) == {}


def test_parse_reply_unmarked_lines_map_by_position_only_when_counts_match() -> None:
    assert parse_reply("Primeira.  \nSegunda.", 2) == {1: "Primeira.", 2: "Segunda."}
    assert parse_reply("Primeira.\nSegunda.\nTerceira?", 2) == {}


# -- guards -----------------------------------------------------------------------


def test_acceptable_correction_bounds() -> None:
    assert acceptable_correction("a gente vai no kubernetes", "A gente vai no Kubernetes.")
    assert not acceptable_correction("a gente vai no kubernetes", "")
    assert not acceptable_correction("a gente vai no kubernetes hoje à tarde", "Ok.")
    padded = "a gente vai no kubernetes" + " e mais uma coisa inventada" * 3
    assert not acceptable_correction("a gente vai no kubernetes", padded)
    assert acceptable_correction("ok", "Ok.")


# -- batching -------------------------------------------------------------------


def test_split_long_text_cuts_at_sentence_boundaries() -> None:
    text = " ".join(f"Frase número {i} termina aqui." for i in range(40))
    parts = split_long_text(text, max_tokens=40)
    assert len(parts) > 1
    assert all(estimate_tokens(p) <= 40 for p in parts)
    assert " ".join(parts) == text


def test_split_long_text_handles_a_sentence_longer_than_the_budget() -> None:
    text = "palavra " * 200
    parts = split_long_text(text.strip(), max_tokens=30)
    assert all(estimate_tokens(p) <= 30 for p in parts)
    assert " ".join(parts) == text.strip()


def test_plan_batches_packs_runs_and_keeps_order() -> None:
    texts = ["um dois três"] * 10 + [" ".join(["longo."] * 200)]
    batches = plan_batches(texts, max_input_tokens=50)
    flat = [(p.run_index, p.text) for b in batches for p in b]
    assert [i for i, _ in flat] == sorted(i for i, _ in flat)
    for batch in batches:
        assert sum(estimate_tokens(p.text) for p in batch) <= 50 or len(batch) == 1
    rebuilt = {i: [] for i in range(len(texts))}
    for i, t in flat:
        rebuilt[i].append(t)
    assert " ".join(rebuilt[10]) == texts[10]


def test_plan_batches_skips_empty_runs() -> None:
    batches = plan_batches(["", "texto", "  "], max_input_tokens=100)
    assert [[p.run_index for p in b] for b in batches] == [[1]]


# -- the correction loop -----------------------------------------------------------


def test_correct_texts_applies_corrections_and_vocabulary() -> None:
    backend = ScriptedBackend(lambda _i, t: t.capitalize().rstrip(".") + ".")
    result = correct_texts(
        backend,
        ["a gente subiu no github", "o okr do trimestre"],
        language="pt",
        vocabulary=Vocabulary(terms=("GitHub", "OKR")),
        instructions="",
        max_input_tokens=200,
        max_output_tokens=500,
    )
    assert result.texts == ["A gente subiu no GitHub.", "O OKR do trimestre."]
    assert result.changed == 2
    assert result.kept_raw == 0
    assert len(backend.calls) == 1  # both runs in one request


def test_correct_texts_keeps_raw_for_missing_or_bad_lines() -> None:
    def transform(i: int, text: str) -> str:
        return "" if i == 2 else text.upper()

    backend = ScriptedBackend(transform)
    result = correct_texts(
        backend,
        ["primeira linha boa", "segunda some", "terceira fica"],
        language=None,
        vocabulary=Vocabulary(),
        instructions="",
        max_input_tokens=200,
        max_output_tokens=500,
    )
    assert result.texts == ["PRIMEIRA LINHA BOA", "segunda some", "TERCEIRA FICA"]
    assert result.kept_raw == 1


def test_correct_texts_rejoins_split_runs() -> None:
    long_run = " ".join(f"frase {i}." for i in range(120))
    backend = ScriptedBackend(lambda _i, t: t.replace("frase", "Frase"))
    result = correct_texts(
        backend,
        [long_run],
        language=None,
        vocabulary=Vocabulary(),
        instructions="",
        max_input_tokens=60,
        max_output_tokens=200,
    )
    assert result.texts == [long_run.replace("frase", "Frase")]
    assert len(backend.calls) > 1


def test_context_overflow_bisects_the_batch() -> None:
    class Overflow(ScriptedBackend):
        def complete(self, instructions: str, prompt: str, *, max_tokens: int) -> str:
            if prompt.count("\n[") >= 2:  # more than one line → "too long"
                self.calls.append((instructions, prompt, max_tokens))
                raise DistillError("context window exceeded", kind="context")
            return super().complete(instructions, prompt, max_tokens=max_tokens)

    backend = Overflow(lambda _i, t: t + "!")
    result = correct_texts(
        backend,
        ["um", "dois", "três"],
        language=None,
        vocabulary=Vocabulary(),
        instructions="",
        max_input_tokens=500,
        max_output_tokens=500,
    )
    assert result.texts == ["um!", "dois!", "três!"]


def test_refusal_keeps_that_batch_raw_and_continues() -> None:
    class Refuses(ScriptedBackend):
        def complete(self, instructions: str, prompt: str, *, max_tokens: int) -> str:
            if "recusa" in prompt:
                raise DistillError("the model refused", kind="refused")
            return super().complete(instructions, prompt, max_tokens=max_tokens)

    backend = Refuses(lambda _i, t: t.upper())
    long = "x" * 120
    result = correct_texts(
        backend,
        [f"recusa {long}", f"aceita {long}"],
        language=None,
        vocabulary=Vocabulary(),
        instructions="",
        max_input_tokens=60,
        max_output_tokens=500,
    )
    assert result.texts[0] == f"recusa {long}"
    assert result.texts[1] == f"ACEITA {long.upper()}"
    assert result.kept_raw == 1


@pytest.mark.parametrize("kind", ["transport", "timeout", "auth", "consent", "rate_limited"])
def test_transport_and_setup_errors_abort_the_whole_transcript(kind: str) -> None:
    class Down(ScriptedBackend):
        def complete(self, instructions: str, prompt: str, *, max_tokens: int) -> str:
            raise DistillError("nope", kind=kind)  # type: ignore[arg-type]

    with pytest.raises(DistillError):
        correct_texts(
            Down(),
            ["texto"],
            language=None,
            vocabulary=Vocabulary(),
            instructions="",
            max_input_tokens=100,
            max_output_tokens=100,
        )


def test_max_tokens_scales_with_the_batch_and_is_capped() -> None:
    backend = ScriptedBackend()
    correct_texts(
        backend,
        ["palavra " * 50],
        language=None,
        vocabulary=Vocabulary(),
        instructions="",
        max_input_tokens=1000,
        max_output_tokens=120,
    )
    assert backend.calls[0][2] == 120
