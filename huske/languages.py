"""Spoken languages, and what each transcription engine can do with them.

``language`` in the config is an ISO 639-1 code (``"pt"``) or unset. How much it
*guarantees* depends on the engine, and the difference is the whole point of
this module:

* **whisper** — the decoder takes a language token, so the language is
  *pinned*: every one of the codes below is supported.
* **parakeet** (``parakeet-tdt-0.6b-v3``) — multilingual over 25 European
  languages, but the language is *not an input*: the model infers it per decode
  window from the audio. ``language`` there only arms the drift guard
  (``huske.transcribe.langdrift``) that re-decodes a window which slid into
  English. See ``huske/transcribe/engines/parakeet.py``.

The code table is Whisper's own (``whisper/tokenizer.py`` in openai/whisper,
MIT), so a code this module accepts is one ``mlx-whisper`` accepts.
"""

from __future__ import annotations

from typing import Literal

LanguageSupport = Literal["pinned", "detected", "unsupported"]

#: Whisper's language codes → English names, in Whisper's order.
WHISPER_LANGUAGES: dict[str, str] = {
    "en": "english",
    "zh": "chinese",
    "de": "german",
    "es": "spanish",
    "ru": "russian",
    "ko": "korean",
    "fr": "french",
    "ja": "japanese",
    "pt": "portuguese",
    "tr": "turkish",
    "pl": "polish",
    "ca": "catalan",
    "nl": "dutch",
    "ar": "arabic",
    "sv": "swedish",
    "it": "italian",
    "id": "indonesian",
    "hi": "hindi",
    "fi": "finnish",
    "vi": "vietnamese",
    "he": "hebrew",
    "uk": "ukrainian",
    "el": "greek",
    "ms": "malay",
    "cs": "czech",
    "ro": "romanian",
    "da": "danish",
    "hu": "hungarian",
    "ta": "tamil",
    "no": "norwegian",
    "th": "thai",
    "ur": "urdu",
    "hr": "croatian",
    "bg": "bulgarian",
    "lt": "lithuanian",
    "la": "latin",
    "mi": "maori",
    "ml": "malayalam",
    "cy": "welsh",
    "sk": "slovak",
    "te": "telugu",
    "fa": "persian",
    "lv": "latvian",
    "bn": "bengali",
    "sr": "serbian",
    "az": "azerbaijani",
    "sl": "slovenian",
    "kn": "kannada",
    "et": "estonian",
    "mk": "macedonian",
    "br": "breton",
    "eu": "basque",
    "is": "icelandic",
    "hy": "armenian",
    "ne": "nepali",
    "mn": "mongolian",
    "bs": "bosnian",
    "kk": "kazakh",
    "sq": "albanian",
    "sw": "swahili",
    "gl": "galician",
    "mr": "marathi",
    "pa": "punjabi",
    "si": "sinhala",
    "km": "khmer",
    "sn": "shona",
    "yo": "yoruba",
    "so": "somali",
    "af": "afrikaans",
    "oc": "occitan",
    "ka": "georgian",
    "be": "belarusian",
    "tg": "tajik",
    "sd": "sindhi",
    "gu": "gujarati",
    "am": "amharic",
    "yi": "yiddish",
    "lo": "lao",
    "uz": "uzbek",
    "fo": "faroese",
    "ht": "haitian creole",
    "ps": "pashto",
    "tk": "turkmen",
    "nn": "nynorsk",
    "mt": "maltese",
    "sa": "sanskrit",
    "lb": "luxembourgish",
    "my": "myanmar",
    "bo": "tibetan",
    "tl": "tagalog",
    "mg": "malagasy",
    "as": "assamese",
    "tt": "tatar",
    "haw": "hawaiian",
    "ln": "lingala",
    "ha": "hausa",
    "ba": "bashkir",
    "jw": "javanese",
    "su": "sundanese",
    "yue": "cantonese",
}

#: The 25 languages ``parakeet-tdt-0.6b-v3`` transcribes (NVIDIA model card).
#: The English-only v2 model is handled by :func:`engine_support`.
PARAKEET_V3_LANGUAGES: frozenset[str] = frozenset(
    "bg hr cs da nl en et fi fr de el hu it lv lt mt pl pt ro sk sl es sv ru uk".split()
)

_ALIASES: dict[str, str] = {name: code for code, name in WHISPER_LANGUAGES.items()}
_ALIASES.update(
    {
        "burmese": "my",
        "valencian": "ca",
        "flemish": "nl",
        "haitian": "ht",
        "letzeburgesch": "lb",
        "pushto": "ps",
        "panjabi": "pa",
        "moldavian": "ro",
        "moldovan": "ro",
        "sinhalese": "si",
        "castilian": "es",
        "mandarin": "zh",
        "português": "pt",
        "portugues": "pt",
        "español": "es",
        "deutsch": "de",
        "français": "fr",
        "italiano": "it",
    }
)


def normalize_language(value: object) -> str | None:
    """``"pt-BR"`` / ``"PT"`` / ``"portuguese"`` → ``"pt"``; empty or ``auto`` → ``None``.

    Raises ``ValueError`` for anything Whisper would not accept, so a typo is
    caught by ``huske config set`` instead of failing the first chunk.
    """
    if value is None:
        return None
    if not isinstance(value, str):
        raise ValueError("language must be a string such as 'pt'")
    text = value.strip().lower()
    if not text or text == "auto":
        return None
    base = text.replace("_", "-").split("-", 1)[0]
    if base in WHISPER_LANGUAGES:
        return base
    if text in _ALIASES:
        return _ALIASES[text]
    raise ValueError(
        f"unknown language {value!r}: use an ISO 639-1 code such as 'pt', 'en' or 'es' "
        "(see `huske languages`)"
    )


def language_name(code: str | None) -> str:
    """English display name for ``code`` (``"pt"`` → ``"Portuguese"``)."""
    if not code:
        return "auto-detect"
    name = WHISPER_LANGUAGES.get(code)
    return name.title() if name else code


def engine_support(engine: str, code: str, *, parakeet_model: str = "") -> LanguageSupport:
    """How ``engine`` treats ``code``: pinned, detected (hint only), or unsupported."""
    if engine == "whisper":
        return "pinned" if code in WHISPER_LANGUAGES else "unsupported"
    if engine == "parakeet":
        english_only = "v2" in parakeet_model.rsplit("/", 1)[-1]
        if english_only:
            return "detected" if code == "en" else "unsupported"
        return "detected" if code in PARAKEET_V3_LANGUAGES else "unsupported"
    return "unsupported"


def can_pin_language(engine: str) -> bool:
    """True when ``engine`` takes the language as an input (only Whisper)."""
    return engine == "whisper"
