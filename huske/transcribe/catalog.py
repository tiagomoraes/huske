"""The transcription model catalog and the one place models are resolved.

``models.toml`` (next to this file) lists the models Huske offers by name:
what each is good at, which languages it covers, how big the download is,
and how fast it ran on a reference Mac. It is data on purpose — a new model of
an existing family is one entry, no code. Any compatible Hugging Face repo or
local folder also works without a catalog entry (an *ad-hoc* model), so a model
released today can be tried today: ``huske models use owner/new-model``.

:func:`resolve_model` turns a ``RuntimeConfig`` into one :class:`ModelSpec`.
Every consumer — the ASR worker, ``huske doctor``, the language checks, the
CLI and Huske.app — goes through it, so the precedence lives here:

1. ``asr_model`` (a catalog id, a repo, or a local path), when set;
2. otherwise the legacy keys: ``asr_engine`` + ``parakeet_model`` / ``model``,
   which keep working unchanged and map onto the same catalog entries (and so
   onto the same ``model:`` frontmatter labels as before).
"""

from __future__ import annotations

import json
import re
import tomllib
from dataclasses import dataclass, field, replace
from functools import cache
from pathlib import Path
from typing import Any

from huske.languages import WHISPER_LANGUAGES, LanguageSupport

CATALOG_PATH = Path(__file__).with_name("models.toml")

SPEEDS = ("fastest", "fast", "moderate", "slow")
ACCURACIES = ("basic", "good", "very good", "best")

#: Legacy ``model`` sizes (whisper) → catalog ids.
WHISPER_SIZES: dict[str, str] = {
    "tiny": "whisper-tiny",
    "base": "whisper-base",
    "small": "whisper-small",
    "medium": "whisper-medium",
    "large-v3": "whisper-large-v3",
    "large-v3-turbo": "whisper-large-v3-turbo",
}

_REPO_RE = re.compile(r"^[A-Za-z0-9][\w.-]*/[\w.-]+$")


@dataclass(frozen=True)
class ModelSpec:
    """One transcription model: catalog entry or ad-hoc repo/folder."""

    id: str
    family: str
    repo: str
    name: str
    summary: str = ""
    #: Language codes the model transcribes; ``None`` = every code the family knows.
    languages: tuple[str, ...] | None = None
    size_mb: int | None = None
    speed: str | None = None
    accuracy: str | None = None
    #: A measured speed, e.g. "58x real time on an M3 Pro".
    measured: str | None = None
    note: str = ""
    default: bool = False
    recommended: bool = False
    in_catalog: bool = True
    #: ``mlx`` (loads as published) or ``transformers`` (a Whisper fine-tune
    #: Huske converts on download into ``models_root``, see convert.py).
    source_format: str = "mlx"
    #: Where a converted model lives (set by :func:`with_models_root`).
    local_path: str | None = None
    extra: dict[str, Any] = field(default_factory=dict, compare=False)

    @property
    def load_from(self) -> str:
        """What the family's runtime loads: the converted folder, else the repo."""
        return self.local_path or self.repo

    @property
    def needs_conversion(self) -> bool:
        return self.source_format == "transformers"

    @property
    def short_name(self) -> str:
        """Repo tail without the family prefix or ``-mlx``: ``large-v3-turbo``."""
        from huske.transcribe.engines import FAMILIES

        tail = self.repo.rstrip("/").rsplit("/", 1)[-1]
        fam = FAMILIES.get(self.family)
        if fam and fam.repo_prefix and tail.startswith(fam.repo_prefix):
            tail = tail[len(fam.repo_prefix) :]
        return tail.removesuffix("-mlx")

    @property
    def label(self) -> str:
        """The transcript's ``model:`` value, e.g. ``parakeet:tdt-0.6b-v3``."""
        from huske.transcribe.engines import FAMILIES

        fam = FAMILIES.get(self.family)
        prefix = fam.label_prefix if fam else self.family
        return f"{prefix}:{self.short_name}"

    @property
    def pins_language(self) -> bool:
        from huske.transcribe.engines import FAMILIES

        fam = FAMILIES.get(self.family)
        return bool(fam and fam.pins_language)

    @property
    def language_codes(self) -> tuple[str, ...]:
        if self.languages is not None:
            return self.languages
        return tuple(WHISPER_LANGUAGES)

    def language_support(self, code: str) -> LanguageSupport:
        if code not in self.language_codes:
            return "unsupported"
        return "pinned" if self.pins_language else "detected"


def _spec_from_entry(entry: dict[str, Any]) -> ModelSpec:
    known = {
        "id", "family", "repo", "name", "summary", "languages", "size_mb", "speed",
        "accuracy", "measured", "note", "default", "recommended", "source_format",
    }
    langs = entry.get("languages")
    return ModelSpec(
        id=str(entry["id"]),
        family=str(entry["family"]),
        repo=str(entry["repo"]),
        name=str(entry["name"]),
        summary=str(entry.get("summary", "")),
        languages=tuple(str(c) for c in langs) if isinstance(langs, list) else None,
        size_mb=int(entry["size_mb"]) if entry.get("size_mb") is not None else None,
        speed=entry.get("speed"),
        accuracy=entry.get("accuracy"),
        measured=entry.get("measured"),
        note=str(entry.get("note", "")),
        default=bool(entry.get("default", False)),
        recommended=bool(entry.get("recommended", False)),
        source_format=str(entry.get("source_format", "mlx")),
        extra={k: v for k, v in entry.items() if k not in known},
    )


@cache
def _load(path: Path = CATALOG_PATH) -> tuple[ModelSpec, ...]:
    with path.open("rb") as handle:
        data = tomllib.load(handle)
    return tuple(_spec_from_entry(e) for e in data.get("model", []))


def models() -> list[ModelSpec]:
    """Every catalog model, in catalog order."""
    return list(_load())


def default_model() -> ModelSpec:
    return next(m for m in _load() if m.default)


def by_id(model_id: str) -> ModelSpec:
    for m in _load():
        if m.id == model_id:
            return m
    raise KeyError(model_id)


def by_repo(repo: str) -> ModelSpec | None:
    wanted = repo.rstrip("/").lower()
    for m in _load():
        if m.repo.lower() == wanted:
            return m
    return None


def infer_family(value: str) -> str | None:
    """The family that can load ``value`` (a repo id or a local folder)."""
    from huske.transcribe.engines import FAMILIES

    path = Path(value).expanduser()
    if path.is_dir():
        config = path / "config.json"
        try:
            data = json.loads(config.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            data = {}
        if isinstance(data, dict):
            if "n_mels" in data or "n_text_ctx" in data:
                return "whisper"
            if "nemo" in str(data.get("target", "")).lower():
                return "parakeet"
    tail = value.rstrip("/").rsplit("/", 1)[-1].lower()
    for name in FAMILIES:
        if name in tail:
            return name
    return None


def lookup(value: str) -> ModelSpec:
    """A catalog id, a catalog repo, or an ad-hoc repo/folder → :class:`ModelSpec`.

    Raises ``ValueError`` when ``value`` is neither listed nor loadable by a
    known family — checked without network access.
    """
    text = value.strip()
    if not text:
        raise ValueError("asr_model cannot be empty")
    try:
        return by_id(text)
    except KeyError:
        pass
    listed = by_repo(text)
    if listed is not None:
        return listed
    is_path = text.startswith(("/", "~", "."))
    if not is_path and not _REPO_RE.match(text):
        raise ValueError(
            f"{text!r} is not a model Huske knows: use an id from `huske models`, a "
            "Hugging Face repo (owner/name) or a local folder"
        )
    family = infer_family(text)
    if family is None:
        from huske.transcribe.engines import FAMILIES

        raise ValueError(
            f"Huske can't tell which engine runs {text!r} (it knows: "
            f"{', '.join(FAMILIES)}). Repos are matched by name, folders by their "
            "config.json."
        )
    repo = str(Path(text).expanduser()) if is_path else text
    spec = ModelSpec(id=text, family=family, repo=repo, name=text, in_catalog=False)
    return replace(spec, name=spec.short_name)


DEFAULT_MODELS_ROOT = Path.home() / "huske" / "models"


def converted_folder(spec: ModelSpec, models_root: Path | None = None) -> Path:
    """Where a converted copy of ``spec`` lives (or will live)."""
    root = Path(models_root or DEFAULT_MODELS_ROOT).expanduser()
    return root / spec.repo.rstrip("/").rsplit("/", 1)[-1]


def with_models_root(spec: ModelSpec, models_root: Path | None) -> ModelSpec:
    """Point a model that needs conversion at its converted folder."""
    if not spec.needs_conversion:
        return spec
    return replace(spec, local_path=str(converted_folder(spec, models_root)))


def local_models(models_root: Path | None) -> list[ModelSpec]:
    """Models converted into ``models_root`` that aren't catalog entries."""
    root = Path(models_root or DEFAULT_MODELS_ROOT).expanduser()
    if not root.is_dir():
        return []
    listed = {converted_folder(m, root) for m in _load() if m.needs_conversion}
    out: list[ModelSpec] = []
    for folder in sorted(p for p in root.iterdir() if p.is_dir()):
        if folder in listed or not (folder / "config.json").exists():
            continue
        family = infer_family(str(folder))
        if family is None:
            continue
        source = ""
        try:
            meta = json.loads((folder / "huske-model.json").read_text(encoding="utf-8"))
            source = str(meta.get("source") or "")
        except (OSError, ValueError):
            pass
        out.append(
            ModelSpec(
                id=str(folder), family=family, repo=str(folder), name=folder.name,
                summary=f"Converted from {source}" if source else "", in_catalog=False,
            )
        )
    return out


def resolve_model(cfg: Any) -> ModelSpec:
    """The model ``cfg`` transcribes with (see the module docstring)."""
    return with_models_root(_resolve(cfg), getattr(cfg, "models_root", None))


def _resolve(cfg: Any) -> ModelSpec:
    chosen = getattr(cfg, "asr_model", None)
    if chosen:
        return lookup(str(chosen))
    engine = getattr(cfg, "asr_engine", "parakeet")
    if engine == "whisper":
        size = str(getattr(cfg, "model", "base"))
        return by_id(WHISPER_SIZES.get(size, "whisper-base"))
    repo = str(getattr(cfg, "parakeet_model", "") or default_model().repo)
    listed = by_repo(repo)
    if listed is not None:
        return listed
    spec = ModelSpec(id=repo, family="parakeet", repo=repo, name=repo, in_catalog=False)
    return replace(spec, name=spec.short_name)


def legacy_settings(spec: ModelSpec) -> dict[str, str]:
    """Equivalent legacy keys, so older engines sharing the config agree."""
    if spec.family == "parakeet":
        return {"asr_engine": "parakeet", "parakeet_model": spec.repo}
    if spec.family == "whisper":
        sizes = {v: k for k, v in WHISPER_SIZES.items()}
        out = {"asr_engine": "whisper"}
        if spec.in_catalog and spec.id in sizes:
            out["model"] = sizes[spec.id]
        return out
    return {}


def is_downloaded(spec: ModelSpec) -> bool:
    """True when the weights are on disk (HF cache or a local folder). No network."""
    if spec.needs_conversion:
        folder = Path(spec.local_path or converted_folder(spec)).expanduser()
        return (folder / "config.json").exists() and (folder / "weights.safetensors").exists()
    path = Path(spec.repo).expanduser()
    if spec.repo.startswith(("/", "~", ".")):
        return path.is_dir()
    try:
        from huggingface_hub import snapshot_download

        folder = Path(snapshot_download(spec.repo, local_files_only=True))
    except Exception:
        return False
    names = {p.name for p in folder.iterdir()} if folder.is_dir() else set()
    has_weights = any(n.endswith((".safetensors", ".npz")) for n in names)
    return "config.json" in names and has_weights


#: Files each family's runtime needs to load a model (any one of each group).
_LAYOUTS: dict[str, tuple[tuple[str, ...], ...]] = {
    "whisper": (("config.json",), ("weights.npz", "weights.safetensors")),
    "parakeet": (("config.json",), ("model.safetensors",)),
}


def layout_problem(spec: ModelSpec, files: list[str] | None = None) -> str | None:
    """Why ``spec``'s repo/folder can't be loaded by its family, or ``None``.

    Names alone don't prove compatibility: ``openai/whisper-large-v3`` is a
    PyTorch checkpoint mlx-whisper can't read. Checks the file list — the local
    folder, or the Hugging Face listing (one small request). Returns ``None``
    when the listing can't be fetched (offline): loading will tell then.
    """
    needed = _LAYOUTS.get(spec.family)
    if not needed:
        return None
    if files is None:
        path = Path(spec.repo).expanduser()
        if spec.repo.startswith(("/", "~", ".")):
            if not path.is_dir():
                return f"{spec.repo} is not a folder"
            files = [p.name for p in path.iterdir()]
        else:
            try:
                from huggingface_hub import HfApi

                files = list(HfApi().list_repo_files(spec.repo))
            except Exception as exc:
                if type(exc).__name__ in ("RepositoryNotFoundError", "GatedRepoError"):
                    return f"{spec.repo} doesn't exist on Hugging Face (or isn't public)"
                return None
    names = {f.rsplit("/", 1)[-1] for f in files}
    if spec.needs_conversion:
        return None  # converted on download
    transformers_layout = "model.safetensors" in names or "model.safetensors.index.json" in names
    if spec.family == "whisper" and transformers_layout and not names & set(needed[1]):
        return (
            f"{spec.repo} is a transformers checkpoint; convert it first: "
            f"huske models convert {spec.repo}"
        )
    for group in needed:
        if not names & set(group):
            from huske.transcribe.engines import FAMILIES

            label = FAMILIES[spec.family].label if spec.family in FAMILIES else spec.family
            return (
                f"{spec.repo} isn't in the format {label} loads (it has no "
                f"{' or '.join(group)}); look for an MLX build of it"
            )
    return None
