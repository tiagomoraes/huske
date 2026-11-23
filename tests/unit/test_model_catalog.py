"""Transcription model catalog, family registry and model resolution."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from huske.config import RuntimeConfig
from huske.transcribe import catalog
from huske.transcribe.catalog import ModelSpec, resolve_model
from huske.transcribe.engines import FAMILIES


def test_every_catalog_entry_is_well_formed() -> None:
    models = catalog.models()
    assert models, "the catalog must not be empty"
    ids = [m.id for m in models]
    assert len(ids) == len(set(ids)), "catalog ids must be unique"
    repos = [m.repo for m in models]
    assert len(repos) == len(set(repos)), "catalog repos must be unique"
    defaults = [m for m in models if m.default]
    assert len(defaults) == 1
    for m in models:
        assert m.family in FAMILIES, f"{m.id}: unknown family {m.family!r}"
        assert m.name and m.summary and m.repo
        assert m.speed in catalog.SPEEDS, m.id
        assert m.accuracy in catalog.ACCURACIES, m.id
        if m.languages is not None:
            assert m.languages, m.id
            from huske.languages import WHISPER_LANGUAGES

            assert set(m.languages) <= set(WHISPER_LANGUAGES), m.id


def test_default_model_is_todays_default() -> None:
    assert catalog.default_model().repo == "mlx-community/parakeet-tdt-0.6b-v3"
    assert resolve_model(RuntimeConfig()).repo == "mlx-community/parakeet-tdt-0.6b-v3"


@pytest.mark.parametrize(
    ("size", "repo", "label"),
    [
        ("tiny", "mlx-community/whisper-tiny-mlx", "mlx-whisper:tiny"),
        ("base", "mlx-community/whisper-base-mlx", "mlx-whisper:base"),
        ("small", "mlx-community/whisper-small-mlx", "mlx-whisper:small"),
        ("medium", "mlx-community/whisper-medium-mlx", "mlx-whisper:medium"),
        ("large-v3", "mlx-community/whisper-large-v3-mlx", "mlx-whisper:large-v3"),
        ("large-v3-turbo", "mlx-community/whisper-large-v3-turbo", "mlx-whisper:large-v3-turbo"),
    ],
)
def test_legacy_whisper_settings_resolve_to_the_same_model_and_label(
    size: str, repo: str, label: str
) -> None:
    spec = resolve_model(RuntimeConfig(asr_engine="whisper", model=size))  # type: ignore[arg-type]
    assert spec.family == "whisper" and spec.repo == repo
    assert spec.label == label  # transcripts keep their `model:` value


def test_legacy_parakeet_repo_resolves_to_its_catalog_entry() -> None:
    spec = resolve_model(
        RuntimeConfig(asr_engine="parakeet", parakeet_model="mlx-community/parakeet-tdt-0.6b-v2")
    )
    assert spec.in_catalog and spec.languages == ("en",)
    assert spec.label == "parakeet:tdt-0.6b-v2"


def test_asr_model_wins_over_legacy_keys() -> None:
    cfg = RuntimeConfig(asr_engine="parakeet", asr_model="whisper-large-v3-turbo")
    spec = resolve_model(cfg)
    assert spec.family == "whisper" and spec.id == "whisper-large-v3-turbo"


def test_asr_model_accepts_a_catalog_repo() -> None:
    spec = resolve_model(RuntimeConfig(asr_model="mlx-community/whisper-large-v3-turbo"))
    assert spec.id == "whisper-large-v3-turbo"


def test_an_unlisted_repo_is_an_ad_hoc_model_with_an_inferred_family() -> None:
    spec = resolve_model(RuntimeConfig(asr_model="someone/parakeet-tdt-0.6b-v9"))
    assert not spec.in_catalog
    assert spec.family == "parakeet" and spec.repo == "someone/parakeet-tdt-0.6b-v9"
    assert spec.label == "parakeet:tdt-0.6b-v9"
    whisper = resolve_model(RuntimeConfig(asr_model="someone/whisper-large-v4"))
    assert whisper.family == "whisper" and whisper.label == "mlx-whisper:large-v4"


def test_family_is_read_from_a_local_model_folder(tmp_path: Path) -> None:
    folder = tmp_path / "my-model"
    folder.mkdir()
    (folder / "config.json").write_text(json.dumps({"n_mels": 128, "n_text_ctx": 448}))
    spec = resolve_model(RuntimeConfig(asr_model=str(folder)))
    assert spec.family == "whisper" and spec.repo == str(folder)
    nemo = tmp_path / "nemo-model"
    nemo.mkdir()
    (nemo / "config.json").write_text(
        json.dumps({"target": "nemo.collections.asr.models.rnnt_bpe_models.EncDecRNNTBPEModel"})
    )
    assert resolve_model(RuntimeConfig(asr_model=str(nemo))).family == "parakeet"


def test_an_unknown_model_is_rejected_by_the_config() -> None:
    with pytest.raises(ValueError, match="which engine"):
        RuntimeConfig(asr_model="someone/mystery-asr")
    with pytest.raises(ValueError):
        RuntimeConfig(asr_model="not a model")


def test_language_support_is_per_model() -> None:
    v3 = catalog.by_id("parakeet-tdt-0.6b-v3")
    assert v3.language_support("pt") == "detected"
    assert v3.language_support("ja") == "unsupported"
    v2 = catalog.by_id("parakeet-tdt-0.6b-v2")
    assert v2.language_support("pt") == "unsupported"
    turbo = catalog.by_id("whisper-large-v3-turbo")
    assert turbo.language_support("pt") == "pinned"
    assert turbo.language_support("ja") == "pinned"


def test_families_declare_their_capabilities() -> None:
    assert FAMILIES["whisper"].pins_language is True
    assert FAMILIES["whisper"].dictionary == "prompt"
    assert FAMILIES["parakeet"].pins_language is False
    assert FAMILIES["parakeet"].dictionary == "boost"


def test_legacy_settings_for_a_model() -> None:
    assert catalog.legacy_settings(catalog.by_id("whisper-large-v3-turbo")) == {
        "asr_engine": "whisper",
        "model": "large-v3-turbo",
    }
    assert catalog.legacy_settings(catalog.by_id("parakeet-tdt-0.6b-v2")) == {
        "asr_engine": "parakeet",
        "parakeet_model": "mlx-community/parakeet-tdt-0.6b-v2",
    }
    q4 = ModelSpec(
        id="x", family="whisper", repo="mlx-community/whisper-large-v3-turbo-q4", name="x"
    )
    assert catalog.legacy_settings(q4) == {"asr_engine": "whisper"}


def test_layout_problem_checks_the_files_a_family_needs() -> None:
    whisper = ModelSpec(id="x", family="whisper", repo="openai/whisper-large-v3", name="x")
    assert catalog.layout_problem(whisper, ["config.json", "model.safetensors", "pytorch_model.bin"])
    assert catalog.layout_problem(whisper, ["config.json", "weights.npz"]) is None
    parakeet = ModelSpec(id="y", family="parakeet", repo="a/parakeet-x", name="y")
    assert catalog.layout_problem(parakeet, ["config.json", "model.safetensors"]) is None
    assert catalog.layout_problem(parakeet, ["model.nemo"])


def test_layout_problem_reads_a_local_folder(tmp_path: Path) -> None:
    (tmp_path / "config.json").write_text("{}")
    spec = ModelSpec(id="z", family="whisper", repo=str(tmp_path), name="z")
    assert catalog.layout_problem(spec)
    (tmp_path / "weights.safetensors").write_text("")
    assert catalog.layout_problem(spec) is None


def test_a_transformers_entry_loads_from_its_converted_folder(tmp_path: Path) -> None:
    spec = ModelSpec(id="pt-ft", family="whisper", repo="someone/whisper-pt-ft", name="PT",
                     source_format="transformers")
    pointed = catalog.with_models_root(spec, tmp_path)
    assert pointed.load_from == str(tmp_path / "whisper-pt-ft")
    assert catalog.is_downloaded(pointed) is False
    folder = tmp_path / "whisper-pt-ft"
    folder.mkdir()
    (folder / "config.json").write_text("{}")
    (folder / "weights.safetensors").write_text("")
    assert catalog.is_downloaded(pointed) is True
    native = catalog.by_id("whisper-large-v3-turbo")
    assert catalog.with_models_root(native, tmp_path).load_from == native.repo


def test_converted_folders_are_listed_as_local_models(tmp_path: Path) -> None:
    folder = tmp_path / "my-ptbr"
    folder.mkdir()
    (folder / "config.json").write_text(json.dumps({"n_mels": 128, "n_text_ctx": 448}))
    (folder / "huske-model.json").write_text(json.dumps({"source": "someone/whisper-ptbr"}))
    (tmp_path / "not-a-model").mkdir()
    [local] = catalog.local_models(tmp_path)
    assert local.family == "whisper" and local.repo == str(folder)
    assert "someone/whisper-ptbr" in local.summary


def test_layout_problem_suggests_converting_a_transformers_whisper() -> None:
    spec = ModelSpec(id="x", family="whisper", repo="someone/whisper-large-v3-pt", name="x")
    message = catalog.layout_problem(spec, ["config.json", "model.safetensors", "tokenizer.json"])
    assert message is not None and "huske models convert someone/whisper-large-v3-pt" in message
