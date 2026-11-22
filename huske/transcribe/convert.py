"""Convert a Hugging Face ``transformers`` Whisper checkpoint for mlx-whisper.

Most Whisper fine-tunes on Hugging Face — Brazilian Portuguese, medical,
names-and-numbers, … — are published in the ``transformers`` layout
(``WhisperForConditionalGeneration``: ``config.json`` + ``model.safetensors``
or sharded safetensors). mlx-whisper reads the OpenAI-style layout instead
(``config.json`` with ``ModelDimensions`` + ``weights.safetensors``). The two
hold the same tensors under different names, so conversion is a rename, a
transpose of the two convolutions, and a cast to float16 — no PyTorch, no
network beyond the download.

``huske models convert <repo>`` downloads only the weights it needs into a
temporary folder (never the shared Hugging Face cache), writes the result
under ``models_root`` (default ``~/huske/models/<name>``), checks that every
tensor mlx-whisper expects is present, and deletes the download. The folder
then works like any model: ``huske models use ~/huske/models/<name>``. Catalog
entries with ``source_format = "transformers"`` are converted the same way on
``huske models download``.
"""

from __future__ import annotations

import json
import os
import re
import shutil
from datetime import datetime
from pathlib import Path
from typing import Any

from huske import __version__


class ConvertError(RuntimeError):
    """The checkpoint can't be converted (message says why, in plain words)."""


_PREFIXES = ("model.",)
_BLOCK_RE = re.compile(r"^(encoder|decoder)\.layers\.(\d+)\.(.+)$")
_ATTN = {"self_attn": "attn", "encoder_attn": "cross_attn"}
_PROJ = {"q_proj": "query", "k_proj": "key", "v_proj": "value", "out_proj": "out"}
_BLOCK_PARTS = {
    "self_attn_layer_norm": "attn_ln",
    "encoder_attn_layer_norm": "cross_attn_ln",
    "fc1": "mlp1",
    "fc2": "mlp2",
    "final_layer_norm": "mlp_ln",
}
_TOP = {
    "encoder.conv1": "encoder.conv1",
    "encoder.conv2": "encoder.conv2",
    "encoder.layer_norm": "encoder.ln_post",
    "decoder.embed_tokens": "decoder.token_embedding",
    "decoder.layer_norm": "decoder.ln",
}


def mlx_key(name: str) -> str | None:
    """mlx-whisper's name for a transformers tensor, or ``None`` to drop it."""
    for prefix in _PREFIXES:
        if name.startswith(prefix):
            name = name[len(prefix) :]
            break
    if name == "proj_out.weight" or name.startswith("encoder.embed_positions"):
        return None  # tied output projection; the encoder's sinusoids are computed
    if name == "decoder.embed_positions.weight":
        return "decoder.positional_embedding"
    match = _BLOCK_RE.match(name)
    if match:
        side, index, rest = match.groups()
        head, _, tail = rest.partition(".")
        if head in _ATTN:
            proj, _, leaf = tail.partition(".")
            if proj in _PROJ:
                return f"{side}.blocks.{index}.{_ATTN[head]}.{_PROJ[proj]}.{leaf}"
            return None
        if head in _BLOCK_PARTS:
            return f"{side}.blocks.{index}.{_BLOCK_PARTS[head]}.{tail}"
        return None
    module, _, leaf = name.rpartition(".")
    if module in _TOP:
        return f"{_TOP[module]}.{leaf}"
    return None


def dims_from_hf_config(config: dict[str, Any]) -> dict[str, int]:
    """mlx-whisper ``ModelDimensions`` from a transformers ``config.json``."""
    if config.get("model_type") != "whisper":
        raise ConvertError(
            f"this is not a Whisper checkpoint (model_type: {config.get('model_type')!r})"
        )
    try:
        return {
            "n_mels": int(config["num_mel_bins"]),
            "n_audio_ctx": int(config["max_source_positions"]),
            "n_audio_state": int(config["d_model"]),
            "n_audio_head": int(config["encoder_attention_heads"]),
            "n_audio_layer": int(config["encoder_layers"]),
            "n_vocab": int(config["vocab_size"]),
            "n_text_ctx": int(config["max_target_positions"]),
            "n_text_state": int(config["d_model"]),
            "n_text_head": int(config["decoder_attention_heads"]),
            "n_text_layer": int(config["decoder_layers"]),
        }
    except (KeyError, TypeError, ValueError) as exc:
        raise ConvertError(f"config.json is missing a Whisper field: {exc}") from exc


def weight_files(files: list[str], *, index: dict[str, Any] | None) -> list[str]:
    """Which safetensors files hold the model (skips optimizer states and extras)."""
    if index is not None:
        shards = sorted({str(v) for v in (index.get("weight_map") or {}).values()})
        if shards:
            return shards
    if "model.safetensors" in files:
        return ["model.safetensors"]
    raise ConvertError(
        "no safetensors weights (model.safetensors or a sharded index) — only "
        "safetensors checkpoints can be converted"
    )


def _expected_keys(dims: dict[str, int]) -> set[str]:
    from mlx.utils import tree_flatten
    from mlx_whisper import whisper

    model = whisper.Whisper(whisper.ModelDimensions(**dims))
    # `alignment_heads` is computed by the model (word timestamps), not loaded.
    flat: list[Any] = list(tree_flatten(model.parameters()))
    return {str(item[0]) for item in flat if item[0] != "alignment_heads"}


def convert_hf_whisper(
    source: Path, out: Path, *, source_repo: str, license: str | None = None
) -> Path:
    """Convert the checkpoint in ``source`` into the mlx-whisper folder ``out``."""
    import mlx.core as mx

    try:
        config = json.loads((source / "config.json").read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise ConvertError(f"can't read config.json: {exc}") from exc
    dims = dims_from_hf_config(config)
    index_path = source / "model.safetensors.index.json"
    index = json.loads(index_path.read_text(encoding="utf-8")) if index_path.exists() else None
    files = [p.name for p in source.iterdir()]
    weights: dict[str, Any] = {}
    for name in weight_files(files, index=index):
        shard = mx.load(str(source / name))
        assert isinstance(shard, dict)
        for key, value in shard.items():
            target = mlx_key(key)
            if target is None:
                continue
            if target.endswith(("conv1.weight", "conv2.weight")):
                value = value.transpose(0, 2, 1)  # (out, in, k) -> (out, k, in)
            weights[target] = value.astype(mx.float16)
        del shard
    missing = sorted(_expected_keys(dims) - set(weights))
    if missing:
        raise ConvertError(
            f"the checkpoint is missing {len(missing)} tensor(s) mlx-whisper needs "
            f"(first: {missing[0]})"
        )
    tmp = out.with_name(out.name + ".tmp")
    shutil.rmtree(tmp, ignore_errors=True)
    tmp.mkdir(parents=True)
    try:
        mx.save_safetensors(str(tmp / "weights.safetensors"), weights)
        (tmp / "config.json").write_text(
            json.dumps({**dims, "model_type": "whisper"}, indent=2), encoding="utf-8"
        )
        (tmp / "huske-model.json").write_text(
            json.dumps(
                {
                    "source": source_repo,
                    "family": "whisper",
                    "license": license,
                    "converted_at": datetime.now().astimezone().isoformat(timespec="seconds"),
                    "huske_version": __version__,
                },
                indent=2,
            ),
            encoding="utf-8",
        )
        if out.exists():
            shutil.rmtree(out)
        os.replace(tmp, out)
    except Exception:
        shutil.rmtree(tmp, ignore_errors=True)
        raise
    return out


def fetch_and_convert(
    repo: str,
    out: Path,
    *,
    on_progress: Any = None,
) -> Path:
    """Download ``repo``'s weights to a temporary folder, convert into ``out``."""
    import tempfile

    from huggingface_hub import HfApi, snapshot_download

    api = HfApi()
    try:
        info = api.model_info(repo, files_metadata=True)
    except Exception as exc:
        raise ConvertError(f"can't find {repo} on Hugging Face: {type(exc).__name__}") from exc
    sizes = {s.rfilename: int(s.size or 0) for s in info.siblings or []}
    license_ = None
    card = getattr(info, "card_data", None)
    if card is not None:
        license_ = getattr(card, "license", None) or (
            card.get("license") if hasattr(card, "get") else None
        )
    with tempfile.TemporaryDirectory(prefix="huske-convert-") as tmp:
        folder = Path(tmp)
        index = None
        if "model.safetensors.index.json" in sizes:
            snapshot_download(repo, local_dir=folder, allow_patterns=["model.safetensors.index.json"])
            index = json.loads((folder / "model.safetensors.index.json").read_text())
        wanted = weight_files(list(sizes), index=index)
        total = sum(sizes.get(f, 0) for f in wanted) or None
        patterns = ["config.json", "model.safetensors.index.json", *wanted]

        import threading

        done = threading.Event()

        def watch() -> None:
            while not done.wait(0.5):
                if on_progress is not None:
                    got = sum(p.stat().st_size for p in folder.rglob("*") if p.is_file())
                    on_progress(got, total)

        watcher = threading.Thread(target=watch, daemon=True)
        watcher.start()
        try:
            snapshot_download(repo, local_dir=folder, allow_patterns=patterns)
        finally:
            done.set()
            watcher.join(timeout=1.0)
        if on_progress is not None and total:
            on_progress(total, total)
        return convert_hf_whisper(folder, out, source_repo=repo, license=license_)
