"""Detect a decode window that collapsed into the wrong language.

``parakeet-tdt-0.6b-v3`` picks its output language *implicitly*, once per decode
window, from the acoustic evidence alone — there is no language input. (Its
vocabulary carries ``<|pt|>``-style tags inherited from the NeMo/Canary
tokenizer, but the TDT decoder was never trained to condition on them: priming
the prediction network with one changes nothing.) On speech that code-switches
— Portuguese dense with English technical jargon, say — that implicit choice is
unstable, and when it lands on English the model transcribes the *whole window*
phonetically into English words. Empirically the flip is a knife edge: moving a
window boundary by 0.2 s can flip two minutes of Portuguese into English.

English is the attractor (it dominates the training mix), so the failure has a
consistent shape: a window whose function words are suddenly English while the
configured language's are absent. That is what this module measures, so the
engine can re-decode the affected window instead of writing the garbled text.

Deliberately dependency-free and deliberately dumb: a function-word ratio, not a
language identifier. It only has to separate "this window drifted" from "this
window is fine", including for text that legitimately carries loanwords and
product names (``webhook``, ``front``, ``deploy``), which is why it counts
*function* words — the closed class a drifted decode cannot avoid emitting and a
loanword-heavy sentence in the target language never uses.
"""

from __future__ import annotations

import re

#: Closed-class markers per language, lowercase and accent-bearing as written.
#: ~30 of the highest-frequency function words each — enough to score a window
#: of a few dozen words, small enough to eyeball. Add a language by adding a
#: row; anything absent simply leaves the guard off (see ``supports``).
_MARKERS: dict[str, frozenset[str]] = {
    "en": frozenset(
        "the of that is and to it for you was are with this they be have from on "
        "at as but not what all were when we there can an your which their said "
        "if do would about into than them been".split()
    ),
    "pt": frozenset(
        "que não para uma com ele ela isso então aqui pra você tu dos das são "
        "vai já também porque mas ser está muito quando aí tem ter num nos "
        "pelo pela isso essa esse nesse dele".split()
    ),
    "es": frozenset(
        "que no para una con él ella esto entonces aquí usted los las son "
        "va ya también porque pero ser está muy cuando tiene tener unos "
        "por ese esa este esta del sus".split()
    ),
    "fr": frozenset(
        "que ne pas pour une avec il elle cela alors ici vous les des sont "
        "va déjà aussi parce mais être est très quand ont avoir dans "
        "par ce cette celui leur sur".split()
    ),
    "de": frozenset(
        "und der die das nicht für eine mit er sie es dann hier ihr den dem "
        "sind wird schon auch weil aber sein ist sehr wenn haben aus "
        "von diese dieser bei noch".split()
    ),
    "it": frozenset(
        "che non per una con lui lei questo allora qui voi gli delle sono "
        "va già anche perché ma essere è molto quando hanno avere nel "
        "dal questa questo suoi loro più".split()
    ),
    "nl": frozenset(
        "dat niet voor een met hij zij het dan hier jij de van zijn "
        "gaat al ook omdat maar wezen is heel wanneer hebben uit "
        "deze die bij nog naar".split()
    ),
    "pl": frozenset(
        "że nie dla jeden z on ona to wtedy tutaj wy się jest są "
        "już także ponieważ ale być bardzo kiedy mają mieć w "
        "ten ta te ich na".split()
    ),
    "ru": frozenset(
        # The Cyrillic ES below is a Latin-"c" homoglyph, which is exactly why
        # it belongs in a table that has to tell the two alphabets apart.
        "что не для один с он она это тогда здесь вы себя есть "  # noqa: RUF001
        "уже также потому но быть очень когда их иметь в "
        "этот эта эти на как".split()
    ),
    "tr": frozenset(
        "ve bir bu için ile o da de ne çok zaman var yok "
        "ama çünkü gibi daha sonra kadar olarak her şey "
        "ben sen biz onlar değil".split()
    ),
    "sv": frozenset(
        "att inte för en med han hon det då här ni sig är "
        "redan också eftersom men vara mycket när har ha i "
        "den denna dessa på som".split()
    ),
}

_WORD_RE = re.compile(r"[^\W\d_]+", re.UNICODE)

#: Fraction of *marker* words that must be English before a window counts as
#: drifted. Measured on real code-switched Portuguese meeting audio: clean
#: windows score 0.02-0.19, drifted ones 0.65-0.82. 0.45 sits in the empty
#: middle, biased high so a legitimately jargon-heavy sentence is never
#: re-decoded for nothing.
DRIFT_THRESHOLD = 0.45

#: Below this many marker words the ratio is noise, so no verdict is returned.
MIN_MARKERS = 6


def supports(language: str | None) -> bool:
    """True when ``language`` can be guarded (known, and not English itself)."""
    if not language:
        return False
    code = language.strip().lower()[:2]
    return code != "en" and code in _MARKERS


def english_ratio(text: str, language: str) -> float | None:
    """Share of marker words that are English rather than ``language``.

    ``None`` when the text is too short to judge. 0.0 means "every marker word
    belongs to the target language", 1.0 "every one of them is English".
    """
    code = language.strip().lower()[:2]
    target = _MARKERS.get(code)
    if target is None:
        return None
    words = [w.lower() for w in _WORD_RE.findall(text)]
    english = _MARKERS["en"]
    # A word in both lists (Portuguese "a", English "a") is evidence for
    # neither, so score only the markers unique to one side.
    n_en = sum(1 for w in words if w in english and w not in target)
    n_target = sum(1 for w in words if w in target and w not in english)
    total = n_en + n_target
    if total < MIN_MARKERS:
        return None
    return n_en / total


def drifted(text: str, language: str | None) -> bool:
    """True when ``text`` reads as English but ``language`` was configured.

    Conservative on both ends: an unguardable language, an empty window, or a
    window too short to score all return False, so the caller transcribes
    exactly as it does today.
    """
    if not text or not supports(language):
        return False
    ratio = english_ratio(text, language or "")
    return ratio is not None and ratio >= DRIFT_THRESHOLD
