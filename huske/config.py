"""Runtime configuration: defaults, TOML file, CLI flag merging."""

from __future__ import annotations

import platform
import tomllib
from pathlib import Path
from typing import Any, Literal

from pydantic import BaseModel, Field, field_validator, model_validator

ModelSize = Literal["tiny", "base", "small", "medium", "large-v3"]
# Kept for back-compat with existing config files. `compute_type` and `device`
# were CTranslate2 knobs; the mlx-whisper backend always runs fp16 on Metal.
# We accept and store them but the worker only honors `float32` to opt out of fp16.
ComputeType = Literal["int8", "int8_float16", "float16", "float32"]
Device = Literal["auto", "cpu", "cuda"]
SystemAudioBackend = Literal["auto", "tap", "sck", "off"]


_MLX_WHISPER_REPO_BY_SIZE: dict[str, str] = {
    "tiny": "mlx-community/whisper-tiny-mlx",
    "base": "mlx-community/whisper-base-mlx",
    "small": "mlx-community/whisper-small-mlx",
    "medium": "mlx-community/whisper-medium-mlx",
    "large-v3": "mlx-community/whisper-large-v3-mlx",
}


def mlx_whisper_repo(model_size: str) -> str:
    """Return the HF repo id mlx-whisper should load for ``model_size``."""
    try:
        return _MLX_WHISPER_REPO_BY_SIZE[model_size]
    except KeyError as exc:  # pragma: no cover — Pydantic Literal already guards
        raise ValueError(f"unknown model size: {model_size}") from exc


class RuntimeConfig(BaseModel):
    """Effective configuration for a single huske session.

    Frozen by convention after session start; do not mutate live.
    """

    model_config = {"frozen": True, "extra": "forbid"}

    chunk_minutes: float = Field(default=15.0, gt=0.0, le=60.0)
    output_root: Path = Field(default=Path.home() / "huske" / "transcripts")
    audio_root: Path = Field(default=Path.home() / "huske" / "audio")
    logs_root: Path = Field(default=Path.home() / "huske" / "logs")
    screenshots_root: Path = Field(default=Path.home() / "huske" / "screenshots")
    # Local semantic search index (sqlite-vec passage store). See
    # docs/adr/0002-local-search-stack.md.
    index_root: Path = Field(default=Path.home() / "huske" / "index")

    model: ModelSize = "base"
    compute_type: ComputeType = "int8"
    device: Device = "auto"
    language: str | None = None

    keep_audio: bool = False
    input_device: str | None = None

    sample_rate: int = Field(default=48000, gt=0)
    block_size: int = Field(default=1024, gt=0)
    channels: int = Field(default=2, ge=1, le=2)

    screenshots_enabled: bool = False
    # Filenames are second-precision (`HHMMSS_dN.jpg`), so subsecond intervals
    # can overwrite the prior capture for the same display.
    screenshots_interval_seconds: float = Field(default=10.0, ge=1.0, le=3600.0)
    screenshots_max_displays: int = Field(default=4, ge=1, le=16)

    log_level: Literal["DEBUG", "INFO", "WARNING", "ERROR"] = "INFO"
    no_ui: bool = False
    menu_bar_enabled: bool = True
    menu_bar_label_style: Literal["text", "icon"] = "text"

    # Backend used to capture system audio on macOS.
    #   auto: Core Audio tap on macOS 14.4+ (resilient to screen-share
    #         conflicts), ScreenCaptureKit on older macOS.
    #   tap : force Core Audio tap (errors on unsupported macOS).
    #   sck : force ScreenCaptureKit (the legacy backend).
    #   off : disable system audio capture entirely (mic-only).
    system_audio_backend: SystemAudioBackend = "auto"

    # --- Local semantic search + MCP server (opt-in, `huske[mcp]` extra) ---
    # When true, `huske run` indexes each finalized transcript into the passage
    # store via an isolated embedding subprocess. Off by default so recording
    # never pays the embedding cost unless explicitly opted in. See
    # docs/adr/0003-embed-worker-isolation.md.
    indexing_enabled: bool = False
    # Embedding model id. Changing this invalidates the index (different vector
    # space) — the store refuses to mix spaces; run `huske index --rebuild`.
    embedding_model: str = "mlx-community/multilingual-e5-base"
    # `huske mcp` daemon bind address. Loopback-only by default; a bearer token
    # and Origin/Host validation guard it. See docs/adr/0001-http-only-mcp-daemon.md.
    mcp_host: str = "127.0.0.1"
    mcp_port: int = Field(default=7641, gt=0, le=65535)

    @field_validator(
        "output_root",
        "audio_root",
        "logs_root",
        "screenshots_root",
        "index_root",
        mode="before",
    )
    @classmethod
    def _expand(cls, v: Any) -> Path:
        return Path(str(v)).expanduser()

    @model_validator(mode="after")
    def _no_cuda_on_mac(self) -> RuntimeConfig:
        if self.device == "cuda" and platform.system() == "Darwin":
            raise ValueError(
                "device='cuda' is not available on macOS / Apple Silicon. "
                "Use 'auto' or 'cpu' instead."
            )
        return self

    @property
    def chunk_seconds(self) -> float:
        return self.chunk_minutes * 60.0


def _read_toml(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    with path.open("rb") as f:
        return tomllib.load(f)


def default_user_config_path() -> Path:
    return Path.home() / ".config" / "huske" / "config.toml"


def load_config(
    config_path: Path | None = None,
    cli_overrides: dict[str, Any] | None = None,
) -> RuntimeConfig:
    """Three-layer config merge: defaults → TOML → CLI flags.

    `config_path` defaults to ``~/.config/huske/config.toml`` (silently ignored
    if absent). `cli_overrides` are applied last and win on conflict.
    """

    file_path = config_path or default_user_config_path()
    file_data = _read_toml(file_path) if file_path.exists() else {}
    overrides = {k: v for k, v in (cli_overrides or {}).items() if v is not None}
    merged = {**file_data, **overrides}
    return RuntimeConfig(**merged)


def update_user_config(
    updates: dict[str, Any], config_path: Path | None = None
) -> Path:
    """Upsert keys in the user's TOML config, preserving any other keys.

    A key set to ``None`` is removed (so callers can clear a field by passing
    ``{"input_device": None}``). The file is created if it does not exist.
    Returns the path that was written.
    """
    import tomli_w

    target = config_path or default_user_config_path()
    target.parent.mkdir(parents=True, exist_ok=True)
    existing = _read_toml(target)
    merged: dict[str, Any] = dict(existing)
    for k, v in updates.items():
        if v is None:
            merged.pop(k, None)
        else:
            merged[k] = v
    with target.open("wb") as f:
        tomli_w.dump(merged, f)
    return target
