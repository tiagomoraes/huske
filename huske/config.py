"""Runtime configuration: defaults, TOML file, CLI flag merging."""

from __future__ import annotations

import platform
import sys
from pathlib import Path
from typing import Any, Literal

from pydantic import BaseModel, Field, field_validator, model_validator

if sys.version_info >= (3, 11):
    import tomllib
else:  # pragma: no cover - older Pythons
    import tomli as tomllib  # type: ignore[no-redef]


ModelSize = Literal["tiny", "base", "small", "medium", "large-v3"]
ComputeType = Literal["int8", "int8_float16", "float16", "float32"]
Device = Literal["auto", "cpu", "cuda"]
SystemAudioBackend = Literal["auto", "tap", "sck", "off"]


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
    screenshots_interval_seconds: float = Field(default=10.0, gt=0.0, le=3600.0)
    screenshots_max_displays: int = Field(default=4, ge=1, le=16)

    log_level: Literal["DEBUG", "INFO", "WARNING", "ERROR"] = "INFO"
    no_ui: bool = False

    # Backend used to capture system audio on macOS.
    #   auto: Core Audio tap on macOS 14.4+ (resilient to screen-share
    #         conflicts), ScreenCaptureKit on older macOS.
    #   tap : force Core Audio tap (errors on unsupported macOS).
    #   sck : force ScreenCaptureKit (the legacy backend).
    #   off : disable system audio capture entirely (mic-only).
    system_audio_backend: SystemAudioBackend = "auto"

    @field_validator("output_root", "audio_root", "logs_root", "screenshots_root", mode="before")
    @classmethod
    def _expand(cls, v: Any) -> Path:
        return Path(str(v)).expanduser()

    @model_validator(mode="after")
    def _no_cuda_on_mac(self) -> "RuntimeConfig":
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


def load_config(
    config_path: Path | None = None,
    cli_overrides: dict[str, Any] | None = None,
) -> RuntimeConfig:
    """Three-layer config merge: defaults → TOML → CLI flags.

    `config_path` defaults to ``~/.config/huske/config.toml`` (silently ignored
    if absent). `cli_overrides` are applied last and win on conflict.
    """

    file_path = config_path or (Path.home() / ".config" / "huske" / "config.toml")
    file_data = _read_toml(file_path) if file_path.exists() else {}
    overrides = {k: v for k, v in (cli_overrides or {}).items() if v is not None}
    merged = {**file_data, **overrides}
    return RuntimeConfig(**merged)
