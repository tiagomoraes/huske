"""``huske models`` — see, choose, download and try transcription models.

Built for both a person at a terminal (a readable table, a numbered picker)
and Huske.app (``--json`` everywhere; ``download --json`` streams progress
lines). The catalog and resolution rules live in ``huske.transcribe.catalog``;
this module only presents them and writes the choice through the same
validated config path as ``huske config set``.
"""

from __future__ import annotations

import json
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from collections.abc import Callable
from pathlib import Path
from typing import Any

from huske.config import RuntimeConfig, load_config, update_user_config
from huske.transcribe import catalog
from huske.transcribe.catalog import (
    ModelSpec,
    is_downloaded,
    lookup,
    resolve_model,
    with_models_root,
)
from huske.transcribe.engines import FAMILIES

_SAMPLES: dict[str, str] = {
    "pt": "Bom dia, pessoal. Hoje a gente vai revisar o planejamento do trimestre, "
    "conferir os números da última semana e combinar os próximos passos com o time.",
    "en": "Good morning, everyone. Today we're reviewing the plan for the quarter, "
    "checking last week's numbers and agreeing on the next steps with the team.",
    "es": "Buenos días a todos. Hoy vamos a revisar el plan del trimestre, mirar los "
    "números de la semana pasada y acordar los próximos pasos con el equipo.",
    "fr": "Bonjour à tous. Aujourd'hui, on revoit le plan du trimestre, on regarde les "
    "chiffres de la semaine dernière et on se met d'accord sur la suite.",
    "de": "Guten Morgen zusammen. Heute schauen wir uns den Plan für das Quartal an, "
    "prüfen die Zahlen der letzten Woche und besprechen die nächsten Schritte.",
    "it": "Buongiorno a tutti. Oggi rivediamo il piano del trimestre, controlliamo i "
    "numeri della settimana scorsa e decidiamo i prossimi passi con il team.",
}
_VOICES: dict[str, str] = {
    "pt": "Luciana", "en": "Samantha", "es": "Mónica", "fr": "Thomas", "de": "Anna", "it": "Alice",
}


def _out(payload: dict[str, Any]) -> None:
    print(json.dumps(payload, ensure_ascii=False), flush=True)


def _err(message: str, json_output: bool, **extra: Any) -> None:
    if json_output:
        _out({"error": message, **extra})
    else:
        print(f"[error] {message}", file=sys.stderr, flush=True)


def _load(config_path: Path | None) -> RuntimeConfig:
    return load_config(config_path=config_path)


def _find(value: str, cfg: RuntimeConfig) -> ModelSpec:
    """``lookup`` plus the converted-folder location from the config."""
    return with_models_root(lookup(value), cfg.models_root)


def model_payload(spec: ModelSpec, current: ModelSpec | None = None) -> dict[str, Any]:
    family = FAMILIES.get(spec.family)
    return {
        "id": spec.id,
        "name": spec.name,
        "family": spec.family,
        "family_label": family.label if family else spec.family,
        "repo": spec.repo,
        "label": spec.label,
        "summary": spec.summary,
        "note": spec.note,
        "languages": list(spec.languages) if spec.languages is not None else None,
        "language_count": len(spec.language_codes),
        "pins_language": spec.pins_language,
        "dictionary": family.dictionary if family else "none",
        "size_mb": spec.size_mb,
        "speed": spec.speed,
        "accuracy": spec.accuracy,
        "measured": spec.measured,
        "default": spec.default,
        "recommended": spec.recommended,
        "in_catalog": spec.in_catalog,
        "needs_conversion": spec.needs_conversion,
        "local_path": spec.local_path,
        "downloaded": is_downloaded(spec),
        "in_use": current is not None and current.repo == spec.repo,
        "runtime_available": bool(family and family.available()),
    }


def _languages_text(spec: ModelSpec) -> str:
    if spec.languages == ("en",):
        return "English"
    count = len(spec.language_codes)
    how = "pins" if spec.pins_language else "detects"
    return f"{count} languages, {how}"


def _size_text(size_mb: int | None) -> str:
    if not size_mb:
        return "—"
    return f"{size_mb / 1000:.1f} GB" if size_mb >= 1000 else f"{size_mb} MB"


# -- list ----------------------------------------------------------------------


def run_list(*, json_output: bool, config_path: Path | None) -> int:
    try:
        cfg = _load(config_path)
        current: ModelSpec | None = resolve_model(cfg)
    except ValueError as exc:
        if json_output:
            current = None
        else:
            _err(str(exc), json_output)
            return 2
    root = cfg.models_root if current is not None else None
    models = [with_models_root(m, root) for m in catalog.models()]
    models += [m for m in catalog.local_models(root) if current is None or m.repo != current.repo]
    if current is not None and not current.in_catalog:
        models = [current, *models]
    if json_output:
        _out(
            {
                "current": model_payload(current, current) if current else None,
                "models": [model_payload(m, current) for m in models],
                "families": [
                    {
                        "name": f.name,
                        "label": f.label,
                        "pins_language": f.pins_language,
                        "dictionary": f.dictionary,
                        "available": f.available(),
                    }
                    for f in FAMILIES.values()
                ],
            }
        )
        return 0
    rows = []
    for m in models:
        mark = "●" if current is not None and m.repo == current.repo else " "
        state = "downloaded" if is_downloaded(m) else ""
        rows.append((mark, m.id, _languages_text(m), _size_text(m.size_mb), m.speed or "—",
                     m.accuracy or "—", state))
    widths = [max(len(r[i]) for r in rows) for i in range(len(rows[0]))]
    header = ("", "model", "languages", "size", "speed", "accuracy", "")
    widths = [max(w, len(h)) for w, h in zip(widths, header, strict=True)]
    print("  ".join(h.ljust(w) for h, w in zip(header, widths, strict=True)).rstrip(), flush=True)
    for r in rows:
        print("  ".join(c.ljust(w) for c, w in zip(r, widths, strict=True)).rstrip(), flush=True)
    if current is not None:
        print(f"\n● in use: {current.name} — {current.summary or current.repo}", flush=True)
    print(
        "\nhuske models use <model>   choose one (or a Hugging Face repo / local folder)\n"
        "huske models info <model>  details · huske models try <model>  speed on this Mac",
        flush=True,
    )
    return 0


# -- info ----------------------------------------------------------------------


def run_info(model: str, *, json_output: bool, config_path: Path | None) -> int:
    try:
        cfg = _load(config_path)
        spec = _find(model, cfg)
        current = resolve_model(cfg)
    except ValueError as exc:
        _err(str(exc), json_output)
        return 2
    payload = model_payload(spec, current)
    if json_output:
        _out(payload)
        return 0
    family = FAMILIES[spec.family]
    lines = [
        f"{spec.name}{'  (in use)' if payload['in_use'] else ''}",
        f"  {spec.summary}" if spec.summary else "",
        f"  id:        {spec.id}",
        f"  repo:      {spec.repo}",
        f"  engine:    {family.label}",
        "  language:  " + ("pinned to the one you choose" if spec.pins_language
                           else "worked out from the audio (can't be pinned)"),
        f"  covers:    {', '.join(spec.language_codes) if spec.languages else 'every Whisper language'}",
        "  dictionary: " + {"prompt": "steers decoding (prompt)",
                            "boost": "listens for the words with parakeet_word_boost (slower)",
                            "none": "corrections and cleanup only"}[family.dictionary],
        f"  size:      {_size_text(spec.size_mb)} — "
        + ("downloaded" if payload["downloaded"] else "downloads on first use"),
        f"  speed:     {spec.speed or '—'}, accuracy: {spec.accuracy or '—'}",
        f"  measured:  {spec.measured}" if spec.measured else "",
        f"  note:      {spec.note}" if spec.note else "",
        f"  converted: {spec.local_path} (from the transformers checkpoint)"
        if spec.needs_conversion else "",
    ]
    print("\n".join(line for line in lines if line), flush=True)
    return 0


# -- use -----------------------------------------------------------------------


def _pick_interactively() -> ModelSpec | None:
    models = catalog.models()
    for i, m in enumerate(models, 1):
        flags = " (default)" if m.default else ""
        print(f"{i:>3}. {m.name}{flags} — {m.summary}", flush=True)
        print(f"     {_languages_text(m)} · {_size_text(m.size_mb)} · {m.speed}", flush=True)
    answer = input(f"\nChoose a model [1-{len(models)}], or paste a repo: ").strip()
    if not answer:
        return None
    if answer.isdigit() and 1 <= int(answer) <= len(models):
        return models[int(answer) - 1]
    return lookup(answer)


def run_use(model: str | None, *, json_output: bool, config_path: Path | None) -> int:
    try:
        cfg = _load(config_path)
        if model:
            spec = _find(model, cfg)
        elif sys.stdin.isatty() and not json_output:
            picked = _pick_interactively()
            if picked is None:
                print("Nothing changed.", flush=True)
                return 1
            spec = with_models_root(picked, cfg.models_root)
        else:
            _err("name a model: huske models use <model>", json_output)
            return 2
    except ValueError as exc:
        _err(str(exc), json_output)
        return 2
    family = FAMILIES[spec.family]
    if not family.available():
        _err(f"{spec.name} needs {family.runtime.replace('_', '-')}, which isn't installed",
             json_output)
        return 2
    if not spec.in_catalog:
        problem = catalog.layout_problem(spec)
        if problem:
            code = "needs_conversion" if "huske models convert" in problem else "unloadable"
            _err(problem, json_output, code=code, repo=spec.repo)
            return 2
    updates: dict[str, Any] = {"asr_model": spec.id, **catalog.legacy_settings(spec)}
    try:
        RuntimeConfig(**{**cfg.model_dump(), **updates})
    except ValueError as exc:
        _err(str(exc), json_output)
        return 2
    update_user_config(updates, config_path=config_path)
    notes: list[str] = []
    codes: list[str] = []
    if cfg.language and spec.language_support(cfg.language) == "unsupported":
        notes.append(f"{spec.name} doesn't transcribe '{cfg.language}' — change `language` too.")
        codes.append("language_unsupported")
    elif cfg.language and not spec.pins_language:
        notes.append(f"{spec.name} can't be told the language; '{cfg.language}' is used to "
                     "catch stretches that slip into English.")
        codes.append("language_detected")
    if not is_downloaded(spec) and spec.needs_conversion:
        notes.append(f"Run `huske models download {spec.id}` before recording: it downloads "
                     "and converts the model once.")
        codes.append("needs_conversion")
    elif not is_downloaded(spec):
        notes.append(f"Downloads {_size_text(spec.size_mb)} the first time it's used "
                     f"(`huske models download {spec.id}` fetches it now).")
        codes.append("needs_download")
    notes.append("A running session keeps its model; the next one uses this.")
    codes.append("applies_next_session")
    if json_output:
        # `note_codes` parallels `notes` so a UI can say each in its own words.
        _out({"model": model_payload(spec, spec), "written": updates, "notes": notes,
              "note_codes": codes, "error": None})
    else:
        print(f"Now using {spec.name}.", flush=True)
        for note in notes:
            print(f"  {note}", flush=True)
    return 0


# -- download ------------------------------------------------------------------


def _repo_total_bytes(repo: str) -> int | None:
    try:
        from huggingface_hub import HfApi

        info = HfApi().model_info(repo, files_metadata=True)
        return sum(int(s.size or 0) for s in info.siblings or [])
    except Exception:
        return None


def _blobs_dir(repo: str) -> Path:
    from huggingface_hub.constants import HF_HUB_CACHE

    return Path(HF_HUB_CACHE) / f"models--{repo.replace('/', '--')}" / "blobs"


def _dir_bytes(path: Path) -> int:
    try:
        return sum(p.stat().st_size for p in path.iterdir() if p.is_file())
    except OSError:
        return 0


def download(
    spec: ModelSpec, on_progress: Callable[[int, int | None], None] | None = None
) -> Path:
    """Fetch ``spec`` into the Hugging Face cache, reporting bytes as they land."""
    from huggingface_hub import snapshot_download

    if spec.needs_conversion:
        from huske.transcribe.convert import fetch_and_convert

        target = Path(spec.local_path or catalog.converted_folder(spec))
        return fetch_and_convert(spec.repo, target, on_progress=on_progress)
    if spec.repo.startswith(("/", "~", ".")):
        return Path(spec.repo).expanduser()
    total = _repo_total_bytes(spec.repo) or (spec.size_mb * 1_000_000 if spec.size_mb else None)
    blobs = _blobs_dir(spec.repo)
    start = _dir_bytes(blobs)
    done = threading.Event()

    def watch() -> None:
        while not done.wait(0.5):
            if on_progress is not None:
                on_progress(_dir_bytes(blobs), total)

    watcher = threading.Thread(target=watch, daemon=True)
    watcher.start()
    try:
        path = Path(snapshot_download(spec.repo))
    finally:
        done.set()
        watcher.join(timeout=1.0)
    if on_progress is not None:
        final = _dir_bytes(blobs)
        on_progress(max(final, start), total or final)
    return path


def run_download(model: str | None, *, json_output: bool, config_path: Path | None) -> int:
    try:
        cfg = _load(config_path)
        spec = _find(model, cfg) if model else resolve_model(cfg)
    except ValueError as exc:
        _err(str(exc), json_output, event="error", id=model)
        return 2
    if not spec.in_catalog:
        problem = catalog.layout_problem(spec)
        if problem:
            _err(problem, json_output, event="error", id=spec.id)
            return 2
    if is_downloaded(spec):
        if json_output:
            _out({"event": "done", "id": spec.id, "already": True, "error": None})
        else:
            print(f"{spec.name} is already downloaded.", flush=True)
        return 0
    if json_output:
        try:
            import importlib

            # Lives in huggingface_hub.utils (not re-exported at the top level).
            importlib.import_module("huggingface_hub.utils").disable_progress_bars()
        except Exception:
            pass

    last = [0.0]

    def report(done_bytes: int, total: int | None) -> None:
        now = time.monotonic()
        if json_output:
            _out({"event": "progress", "id": spec.id, "bytes": done_bytes, "total": total})
        elif now - last[0] > 0.5 or (total and done_bytes >= total):
            last[0] = now
            pct = f"{100 * done_bytes / total:5.1f}%" if total else ""
            print(f"\r  {spec.name}: {done_bytes / 1e6:,.0f} MB {pct}", end="", flush=True)

    try:
        download(spec, report)
    except Exception as exc:
        if not json_output:
            print(flush=True)
        _err(f"download failed: {exc}", json_output, event="error", id=spec.id)
        return 1
    if json_output:
        _out({"event": "done", "id": spec.id, "already": False, "error": None})
    else:
        print(f"\n{spec.name} is ready.", flush=True)
    return 0


# -- try -----------------------------------------------------------------------


def _voice_for(language: str) -> str | None:
    """A macOS `say` voice for ``language`` that is installed, or ``None``."""
    say = shutil.which("say")
    if say is None:
        return None
    try:
        listing = subprocess.run(
            [say, "-v", "?"], capture_output=True, text=True, timeout=10, check=False
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    preferred = _VOICES.get(language)
    names = []
    for line in listing.splitlines():
        match = re.match(r"^(?P<name>.+?)\s+(?P<locale>[a-z]{2,3})_[A-Za-z0-9]+\s+#", line)
        if match and match.group("locale") == language:
            names.append(match.group("name").strip())
    if preferred and any(n == preferred or n.startswith(f"{preferred} ") for n in names):
        return preferred
    return names[0] if names else None


def _synthetic_sample(language: str, folder: Path) -> Path | None:
    voice = _voice_for(language)
    if voice is None:
        return None
    text = _SAMPLES.get(language, _SAMPLES["en"])
    aiff, wav = folder / "sample.aiff", folder / "sample.wav"
    try:
        subprocess.run(["say", "-v", voice, "-o", str(aiff), text], check=True,
                       capture_output=True, timeout=60)
        subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1",
                        str(aiff), str(wav)], check=True, capture_output=True, timeout=60)
    except (OSError, subprocess.SubprocessError):
        return None
    return wav


def run_try(
    model: str | None, *, audio: Path | None, json_output: bool, config_path: Path | None
) -> int:
    """Transcribe a sample with ``model`` and report the speed on this Mac."""
    from huske.transcribe.engines import build_engine
    from huske.transcribe.engines.base import load_mono_16k
    from huske.transcribe.vocabulary import Vocabulary

    try:
        cfg = _load(config_path)
        spec = _find(model, cfg) if model else resolve_model(cfg)
    except ValueError as exc:
        _err(str(exc), json_output, ok=False)
        return 2
    if spec.needs_conversion and not is_downloaded(spec):
        if not json_output:
            print(f"Converting {spec.name} first (one time)…", flush=True)
        try:
            download(spec)
        except Exception as exc:
            _err(f"could not prepare {spec.name}: {exc}", json_output, ok=False)
            return 1
    if not spec.in_catalog:
        problem = catalog.layout_problem(spec)
        if problem:
            _err(problem, json_output, ok=False)
            return 2
    language = cfg.language
    if language and spec.language_support(language) == "unsupported":
        language = None
    sample_language = language or (spec.languages[0] if spec.languages else "en")
    with tempfile.TemporaryDirectory(prefix="huske-try-") as tmp:
        path = audio
        if path is None:
            path = _synthetic_sample(sample_language, Path(tmp))
            if path is None:
                _err("no audio to try: pass --audio FILE (macOS `say` couldn't make a sample)",
                     json_output, ok=False)
                return 2
        try:
            samples = load_mono_16k(str(path))
        except Exception as exc:
            _err(f"could not read {path}: {exc}", json_output, ok=False)
            return 2
        seconds_audio = samples.size / 16000
        engine = build_engine(spec.family, repo=spec.load_from, label=spec.label,
                              language=language, compute_type=cfg.compute_type)
        set_options = getattr(engine, "set_options", None)
        if callable(set_options):
            set_options(language=language, vocabulary=Vocabulary.from_runtime_config(cfg),
                        word_boost=cfg.parakeet_word_boost)
        started = time.monotonic()
        try:
            engine.transcribe(samples[: 16000 * 3])  # loads (and downloads) the model
            loaded = time.monotonic() - started
            t0 = time.monotonic()
            segments = engine.transcribe(samples)
            elapsed = max(time.monotonic() - t0, 1e-6)
        except Exception as exc:
            _err(f"{spec.name} failed: {exc}", json_output, ok=False)
            return 1
    text = " ".join(s.text for s in segments).strip()
    payload = {
        "ok": True,
        "model": model_payload(spec, resolve_model(cfg)),
        "audio_seconds": round(seconds_audio, 1),
        "load_seconds": round(loaded, 1),
        "seconds": round(elapsed, 2),
        "x_realtime": round(seconds_audio / elapsed, 1),
        "language": language,
        "synthetic": audio is None,
        "text": text,
        "error": None,
    }
    if json_output:
        _out(payload)
    else:
        source = "a synthetic sample" if audio is None else str(audio)
        print(
            f"{spec.name}: {payload['audio_seconds']}s of {source} in {payload['seconds']}s "
            f"({payload['x_realtime']}x real time; loading took {payload['load_seconds']}s)\n",
            flush=True,
        )
        print(text or "(no speech recognised)", flush=True)
    return 0



# -- convert -------------------------------------------------------------------


def run_convert(
    repo: str, *, name: str | None, json_output: bool, config_path: Path | None
) -> int:
    """Convert a transformers Whisper fine-tune into ``models_root``."""
    from huske.transcribe.convert import ConvertError, fetch_and_convert

    try:
        cfg = _load(config_path)
    except ValueError as exc:
        _err(str(exc), json_output, event="error")
        return 2
    folder_name = name or repo.rstrip("/").rsplit("/", 1)[-1]
    if not re.fullmatch(r"[\w.-]+", folder_name):
        _err("--name may only use letters, digits, '.', '_' and '-'", json_output, event="error")
        return 2
    target = Path(cfg.models_root).expanduser() / folder_name
    if json_output:
        try:
            import importlib

            importlib.import_module("huggingface_hub.utils").disable_progress_bars()
        except Exception:
            pass

    def report(done_bytes: int, total: int | None) -> None:
        if json_output:
            _out({"event": "progress", "id": repo, "bytes": done_bytes, "total": total})
        else:
            pct = f"{100 * done_bytes / total:5.1f}%" if total else ""
            print(f"\r  {repo}: {done_bytes / 1e6:,.0f} MB {pct}", end="", flush=True)

    try:
        out = fetch_and_convert(repo, target, on_progress=report)
    except (ConvertError, OSError) as exc:
        if not json_output:
            print(flush=True)
        _err(str(exc), json_output, event="error", id=repo)
        return 1
    if json_output:
        _out({"event": "done", "id": repo, "path": str(out), "error": None})
    else:
        print(f"\nConverted to {out}\nUse it: huske models use {out}", flush=True)
    return 0
