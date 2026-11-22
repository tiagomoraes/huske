"""The custom dictionary: words that should come out spelled a certain way.

Two config keys feed it (see ``RuntimeConfig.vocabulary`` and
``vocabulary_replacements``):

* **terms** — names, products and jargon in the user's spelling ("OKR",
  "Kubernetes", "Huske"), in priority order;
* **replacements** — "heard as X, write Y" pairs for mishearings the user has
  seen ("cube ernetes" → "Kubernetes").

The dictionary reaches a transcript three ways, from strongest to weakest
guarantee:

1. :meth:`Vocabulary.apply` — deterministic, after ASR, on every engine:
   case-insensitive, whole-word replacements, then a casing fix for terms with
   *distinctive* capitalisation (an upper-case letter after the first: "OKR",
   "GitHub", "iPhone"). Plain title-case terms ("Kubernetes", "Go") are never
   rewritten here, because they can be ordinary words; they are left to the
   two biasing paths below.
2. :meth:`Vocabulary.whisper_prompt` — Whisper's ``initial_prompt``, which
   biases decoding toward the spellings it has just "seen". Parakeet has no
   equivalent input (see ``engines/parakeet.py``).
3. :meth:`Vocabulary.glossary` — a short block in the optional LLM
   post-processing prompt (``huske/distill``).

Dependency-free and pure, so the worker subprocess, the post-processing thread
and the tests share one implementation.
"""

from __future__ import annotations

import math
import re
from collections.abc import Callable, Iterable, Mapping
from dataclasses import dataclass
from functools import cached_property
from typing import Any

#: Whisper keeps at most ``n_text_ctx // 2 - 1`` prompt tokens (223 for every
#: released model) and silently drops the *oldest* ones beyond that. We stay
#: well under it so the language/task tokens and our sentence frame fit too.
WHISPER_PROMPT_MAX_TOKENS = 200

#: Upper bound on entries per list. A dictionary is a few dozen words in
#: practice; this only keeps a pasted novel from becoming a regex.
MAX_ENTRIES = 500
MAX_ENTRY_CHARS = 80

# Short natural frames per language. Whisper imitates the prompt's style, so
# a sentence in the spoken language biases spelling without nudging the
# transcript toward a bare comma-separated list. Anything else gets the
# neutral list form.
_PROMPT_FRAMES: dict[str, str] = {
    "pt": "Nesta conversa aparecem: {terms}.",
    "en": "This conversation mentions: {terms}.",
    "es": "En esta conversación aparecen: {terms}.",
    "fr": "Dans cette conversation, on parle de : {terms}.",
    "de": "In diesem Gespräch geht es um: {terms}.",
    "it": "In questa conversazione si parla di: {terms}.",
}


def estimate_tokens(text: str) -> int:
    """A conservative token estimate without a tokenizer.

    BPE tokenizers average ~4 bytes of UTF-8 per token on English and a bit
    less on accented Latin text; CJK is roughly one character (3 bytes) per
    token. ``bytes / 3`` over-counts all of these, which is the safe side when
    the number decides whether a prompt fits a context window.
    """
    if not text:
        return 0
    return math.ceil(len(text.encode("utf-8")) / 3)


def _clean(value: object) -> str | None:
    if not isinstance(value, str):
        return None
    text = " ".join(value.split())
    if not text or len(text) > MAX_ENTRY_CHARS:
        return None
    if any(ord(ch) < 32 for ch in text):
        return None
    return text


def _has_distinctive_case(term: str) -> bool:
    letters = [ch for ch in term if ch.isalpha()]
    return any(ch.isupper() for ch in letters[1:])


def _phrase_pattern(phrase: str) -> str:
    """Regex for ``phrase`` as whole words, any run of spaces between words."""
    words = [re.escape(w) for w in phrase.split()]
    body = r"\s+".join(words)
    # Lookarounds instead of ``\b`` so a phrase that starts or ends with a
    # symbol ("C++", ".NET") still anchors on the neighbouring characters.
    return rf"(?<!\w){body}(?!\w)"


@dataclass(frozen=True)
class Vocabulary:
    """Preferred spellings plus "heard as → write" replacements."""

    terms: tuple[str, ...] = ()
    replacements: tuple[tuple[str, str], ...] = ()

    # -- construction --------------------------------------------------------

    @classmethod
    def from_config(
        cls, terms: Iterable[object] | None, replacements: Mapping[object, object] | None
    ) -> Vocabulary:
        """Clean user input: trim, collapse spaces, drop empties and duplicates."""
        seen: set[str] = set()
        clean_terms: list[str] = []
        for raw in terms or ():
            term = _clean(raw)
            if term is None or term.casefold() in seen:
                continue
            seen.add(term.casefold())
            clean_terms.append(term)
        pairs: dict[str, tuple[str, str]] = {}
        for raw_heard, raw_written in (replacements or {}).items():
            heard, written = _clean(raw_heard), _clean(raw_written)
            if heard is None or written is None:
                continue
            pairs[heard.casefold()] = (heard, written)  # last one wins
        return cls(
            terms=tuple(clean_terms[:MAX_ENTRIES]),
            replacements=tuple(list(pairs.values())[:MAX_ENTRIES]),
        )

    @classmethod
    def from_runtime_config(cls, cfg: Any) -> Vocabulary:
        return cls.from_config(
            getattr(cfg, "vocabulary", None), getattr(cfg, "vocabulary_replacements", None)
        )

    @classmethod
    def from_job(cls, job: Mapping[str, Any]) -> Vocabulary:
        """Rebuild from a worker job dict; malformed fields are ignored."""
        terms = job.get("vocabulary")
        replacements = job.get("vocabulary_replacements")
        return cls.from_config(
            terms if isinstance(terms, (list, tuple)) else None,
            replacements if isinstance(replacements, Mapping) else None,
        )

    def to_job(self) -> dict[str, Any]:
        """The JSON-safe fields a worker job carries."""
        return {
            "vocabulary": list(self.terms),
            "vocabulary_replacements": dict(self.replacements),
        }

    @property
    def is_empty(self) -> bool:
        return not self.terms and not self.replacements

    # -- deterministic pass --------------------------------------------------

    @cached_property
    def _replacement_re(self) -> tuple[re.Pattern[str], dict[str, str]] | None:
        if not self.replacements:
            return None
        # Longest first so "hub spot" wins over "hub" at the same position.
        ordered = sorted(self.replacements, key=lambda p: len(p[0]), reverse=True)
        lookup = {" ".join(h.casefold().split()): w for h, w in ordered}
        pattern = "|".join(_phrase_pattern(h) for h, _ in ordered)
        return re.compile(pattern, re.IGNORECASE), lookup

    @cached_property
    def _case_re(self) -> tuple[re.Pattern[str], dict[str, str]] | None:
        distinctive = [t for t in self.terms if _has_distinctive_case(t)]
        if not distinctive:
            return None
        ordered = sorted(distinctive, key=len, reverse=True)
        lookup = {" ".join(t.casefold().split()): t for t in ordered}
        pattern = "|".join(_phrase_pattern(t) for t in ordered)
        return re.compile(pattern, re.IGNORECASE), lookup

    def apply(self, text: str) -> str:
        """Apply replacements, then restore distinctive casing. Pure."""
        if not text or self.is_empty:
            return text
        out = text
        compiled = self._replacement_re
        if compiled is not None:
            regex, lookup = compiled
            out = regex.sub(
                lambda m: lookup.get(" ".join(m.group(0).casefold().split()), m.group(0)), out
            )
        compiled = self._case_re
        if compiled is not None:
            regex, lookup = compiled
            out = regex.sub(
                lambda m: lookup.get(" ".join(m.group(0).casefold().split()), m.group(0)), out
            )
        return out

    # -- biasing prompts -----------------------------------------------------

    def spellings(self) -> list[str]:
        """Every target spelling, in priority order: terms, then replacement targets."""
        seen: set[str] = set()
        out: list[str] = []
        for word in [*self.terms, *(w for _, w in self.replacements)]:
            if word.casefold() in seen:
                continue
            seen.add(word.casefold())
            out.append(word)
        return out

    def whisper_prompt(
        self,
        language: str | None,
        *,
        max_tokens: int = WHISPER_PROMPT_MAX_TOKENS,
        count_tokens: Callable[[str], int] | None = None,
    ) -> str | None:
        """An ``initial_prompt`` naming the spellings, or ``None`` if there are none.

        Only target spellings go in — never the misheard forms, which the model
        would learn to imitate. Entries are dropped from the end until the
        prompt fits ``max_tokens`` (measured with ``count_tokens``, the real
        tokenizer in the worker, or :func:`estimate_tokens`).
        """
        words = self.spellings()
        if not words:
            return None
        count = count_tokens or estimate_tokens
        frame = _PROMPT_FRAMES.get((language or "").lower(), "{terms}.")
        while words:
            prompt = frame.format(terms=", ".join(words))
            if count(prompt) <= max_tokens:
                return prompt
            words = words[:-1]
        return None

    def glossary(self, *, max_tokens: int = 400) -> str:
        """Plain-text dictionary block for an LLM prompt (empty if none)."""
        if self.is_empty:
            return ""
        lines: list[str] = []
        used = 0

        def add(line: str) -> bool:
            nonlocal used
            cost = estimate_tokens(line) + 1
            if used + cost > max_tokens:
                return False
            lines.append(line)
            used += cost
            return True

        words = self.spellings()
        if words and add("Spell these exactly as written when they occur:"):
            for word in words:
                if not add(f"- {word}"):
                    break
        if self.replacements and add("Known mishearings (heard → correct):"):
            for heard, written in self.replacements:
                if not add(f"- {heard} → {written}"):
                    break
        return "\n".join(lines)
