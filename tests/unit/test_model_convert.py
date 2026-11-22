"""Converting a Hugging Face `transformers` Whisper checkpoint to mlx-whisper.

Uses a tiny random Whisper written in the transformers layout — no download.
"""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import pytest

mx = pytest.importorskip("mlx.core")
pytest.importorskip("mlx_whisper")

from huske.transcribe import convert  # noqa: E402

DIMS = {
    "model_type": "whisper",
    "num_mel_bins": 8,
    "max_source_positions": 6,
    "d_model": 16,
    "encoder_attention_heads": 2,
    "encoder_layers": 2,
    "vocab_size": 51866,
    "max_target_positions": 10,
    "decoder_attention_heads": 2,
    "decoder_layers": 1,
    "architectures": ["WhisperForConditionalGeneration"],
}


def _hf_state(prefix: str = "model.") -> dict[str, np.ndarray]:
    d, mels, vocab = DIMS["d_model"], DIMS["num_mel_bins"], DIMS["vocab_size"]
    rng = np.random.default_rng(0)

    def t(*shape: int) -> np.ndarray:
        return rng.standard_normal(shape).astype(np.float32)

    state: dict[str, np.ndarray] = {
        f"{prefix}encoder.conv1.weight": t(d, mels, 3),
        f"{prefix}encoder.conv1.bias": t(d),
        f"{prefix}encoder.conv2.weight": t(d, d, 3),
        f"{prefix}encoder.conv2.bias": t(d),
        f"{prefix}encoder.embed_positions.weight": t(6, d),
        f"{prefix}encoder.layer_norm.weight": t(d),
        f"{prefix}encoder.layer_norm.bias": t(d),
        f"{prefix}decoder.embed_tokens.weight": t(vocab, d),
        f"{prefix}decoder.embed_positions.weight": t(10, d),
        f"{prefix}decoder.layer_norm.weight": t(d),
        f"{prefix}decoder.layer_norm.bias": t(d),
        "proj_out.weight": t(vocab, d),
    }

    def block(base: str, cross: bool) -> None:
        attns = ["self_attn"] + (["encoder_attn"] if cross else [])
        for attn in attns:
            for proj in ("q_proj", "v_proj", "out_proj"):
                state[f"{base}.{attn}.{proj}.weight"] = t(d, d)
                state[f"{base}.{attn}.{proj}.bias"] = t(d)
            state[f"{base}.{attn}.k_proj.weight"] = t(d, d)
            state[f"{base}.{attn}_layer_norm.weight"] = t(d)
            state[f"{base}.{attn}_layer_norm.bias"] = t(d)
        state[f"{base}.fc1.weight"] = t(4 * d, d)
        state[f"{base}.fc1.bias"] = t(4 * d)
        state[f"{base}.fc2.weight"] = t(d, 4 * d)
        state[f"{base}.fc2.bias"] = t(d)
        state[f"{base}.final_layer_norm.weight"] = t(d)
        state[f"{base}.final_layer_norm.bias"] = t(d)

    for i in range(DIMS["encoder_layers"]):
        block(f"{prefix}encoder.layers.{i}", cross=False)
    for i in range(DIMS["decoder_layers"]):
        block(f"{prefix}decoder.layers.{i}", cross=True)
    return state


def _write_source(folder: Path, state: dict[str, np.ndarray]) -> Path:
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "config.json").write_text(json.dumps(DIMS))
    mx.save_safetensors(str(folder / "model.safetensors"), {k: mx.array(v) for k, v in state.items()})
    return folder


@pytest.mark.parametrize(
    ("hf", "mlx"),
    [
        ("model.encoder.layers.3.self_attn.q_proj.weight", "encoder.blocks.3.attn.query.weight"),
        ("model.encoder.layers.0.self_attn_layer_norm.bias", "encoder.blocks.0.attn_ln.bias"),
        ("model.encoder.layers.1.fc2.bias", "encoder.blocks.1.mlp2.bias"),
        ("model.encoder.layer_norm.weight", "encoder.ln_post.weight"),
        ("model.decoder.layers.0.encoder_attn.k_proj.weight", "decoder.blocks.0.cross_attn.key.weight"),
        ("model.decoder.layers.0.encoder_attn_layer_norm.weight", "decoder.blocks.0.cross_attn_ln.weight"),
        ("model.decoder.layers.0.final_layer_norm.bias", "decoder.blocks.0.mlp_ln.bias"),
        ("model.decoder.embed_tokens.weight", "decoder.token_embedding.weight"),
        ("model.decoder.embed_positions.weight", "decoder.positional_embedding"),
        ("model.decoder.layer_norm.bias", "decoder.ln.bias"),
        ("encoder.conv1.weight", "encoder.conv1.weight"),  # WhisperModel (no "model.")
        ("model.encoder.embed_positions.weight", None),  # sinusoids are computed
        ("proj_out.weight", None),  # tied to the token embedding
    ],
)
def test_key_mapping(hf: str, mlx: str | None) -> None:
    assert convert.mlx_key(hf) == mlx


def test_dims_from_config() -> None:
    assert convert.dims_from_hf_config(DIMS) == {
        "n_mels": 8, "n_audio_ctx": 6, "n_audio_state": 16, "n_audio_head": 2,
        "n_audio_layer": 2, "n_vocab": 51866, "n_text_ctx": 10, "n_text_state": 16,
        "n_text_head": 2, "n_text_layer": 1,
    }


def test_converts_a_checkpoint_mlx_whisper_can_load(tmp_path: Path) -> None:
    state = _hf_state()
    source = _write_source(tmp_path / "src", state)
    out = convert.convert_hf_whisper(source, tmp_path / "out", source_repo="someone/tiny-pt")

    from mlx.utils import tree_flatten
    from mlx_whisper.load_models import load_model

    model = load_model(str(out), dtype=mx.float16)
    params = dict(tree_flatten(model.parameters()))
    conv = np.array(params["encoder.conv1.weight"].astype(mx.float32))
    expected = state["model.encoder.conv1.weight"].transpose(0, 2, 1)
    np.testing.assert_allclose(conv, expected, rtol=1e-2, atol=1e-2)  # fp16 round trip
    query = np.array(params["decoder.blocks.0.cross_attn.query.weight"].astype(mx.float32))
    np.testing.assert_allclose(query, state["model.decoder.layers.0.encoder_attn.q_proj.weight"],
                               rtol=1e-2, atol=1e-2)
    meta = json.loads((out / "huske-model.json").read_text())
    assert meta["source"] == "someone/tiny-pt" and meta["family"] == "whisper"
    assert not (tmp_path / "out.tmp").exists()


def test_incomplete_checkpoint_is_refused(tmp_path: Path) -> None:
    state = _hf_state()
    state.pop("model.decoder.layers.0.fc1.weight")
    source = _write_source(tmp_path / "src", state)
    with pytest.raises(convert.ConvertError, match="missing"):
        convert.convert_hf_whisper(source, tmp_path / "out", source_repo="x/y")
    assert not (tmp_path / "out").exists()


def test_non_whisper_checkpoints_are_refused(tmp_path: Path) -> None:
    source = tmp_path / "src"
    source.mkdir()
    (source / "config.json").write_text(json.dumps({"model_type": "wav2vec2"}))
    with pytest.raises(convert.ConvertError, match="not a Whisper"):
        convert.convert_hf_whisper(source, tmp_path / "out", source_repo="x/y")


def test_weight_files_prefer_the_index_and_ignore_extras() -> None:
    files = ["config.json", "model.safetensors", "model_1.safetensors", "optimizer.bin"]
    assert convert.weight_files(files, index=None) == ["model.safetensors"]
    index = {"weight_map": {"a": "model-00001-of-00002.safetensors",
                            "b": "model-00002-of-00002.safetensors"}}
    assert convert.weight_files(["model.safetensors.index.json"], index=index) == [
        "model-00001-of-00002.safetensors", "model-00002-of-00002.safetensors"
    ]
    with pytest.raises(convert.ConvertError):
        convert.weight_files(["pytorch_model.bin"], index=None)
