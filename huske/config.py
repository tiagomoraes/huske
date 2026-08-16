"""Runtime configuration: defaults, TOML file, CLI flag merging."""

from __future__ import annotations

import platform
import tomllib
from pathlib import Path
from typing import Any, Literal

from pydantic import BaseModel, Field, field_validator, model_validator

ModelSize = Literal["tiny", "base", "small", "medium", "large-v3", "large-v3-turbo"]
# Which ASR backend transcribes finalized chunks. `parakeet` (NVIDIA Parakeet
# via parakeet-mlx) is the default: non-autoregressive, so it emits nothing on
# silence/noise instead of hallucinating repeated phrases the way Whisper does,
# and it covers ~25 languages. It cannot be *told* which one, though (the
# language is inferred per decode window), so `whisper` — whose decoder takes a
# language token — stays selectable and is the right pick when `language` must be
# enforced. See `huske/transcribe/engines/parakeet.py`.
ASREngine = Literal["parakeet", "whisper"]
# What to do with a microphone segment detected as an acoustic echo of a system
# segment (speaker bleed when not wearing headphones): drop it, keep it but tag
# it `· echo`, or skip the de-duplication entirely.
EchoDedup = Literal["drop", "annotate", "off"]
# Kept for back-compat with existing config files. `compute_type` and `device`
# were CTranslate2 knobs; the mlx-whisper backend always runs fp16 on Metal.
# We accept and store them but the worker only honors `float32` to opt out of fp16.
ComputeType = Literal["int8", "int8_float16", "float16", "float32"]
Device = Literal["auto", "cpu", "cuda"]
SystemAudioBackend = Literal["auto", "tap", "sck", "off"]
# Format for retained audio when `keep_audio` is on. Whisper transcribes the raw
# WAV first, so the kept copy can be compressed freely: `opus` (lossy, ~12-20x
# smaller, speech-optimized) or `flac` (lossless, ~2x), or `wav` to keep the
# uncompressed original. Encoded via libsndfile (soundfile) — no extra dependency.
AudioKeepFormat = Literal["opus", "flac", "wav"]
# Backend that turns a finalized transcript into searchable Statements.
#   mlx    : built-in (default) — huske runs the LLM itself via mlx-lm in an
#            isolated subprocess; the model downloads from Hugging Face on
#            first use, exactly like the Parakeet weights. Nothing to install.
#   ollama : delegate to a local Ollama daemon (for users who already run one
#            or want a model MLX doesn't serve).
DistillBackend = Literal["mlx", "ollama"]


_MLX_WHISPER_REPO_BY_SIZE: dict[str, str] = {
    "tiny": "mlx-community/whisper-tiny-mlx",
    "base": "mlx-community/whisper-base-mlx",
    "small": "mlx-community/whisper-small-mlx",
    "medium": "mlx-community/whisper-medium-mlx",
    "large-v3": "mlx-community/whisper-large-v3-mlx",
    # Distilled large-v3: measurably *faster* than `medium` on Apple Silicon
    # (~19x vs ~14x realtime) and more accurate, which makes it the size to
    # reach for when `language` has to be enforced. Same weights class as
    # large-v3 but 4 decoder layers instead of 32.
    "large-v3-turbo": "mlx-community/whisper-large-v3-turbo",
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

    # Maximum length of one chunk. With speech-gated segmentation on (the
    # default), this is a *safety cap*, not the usual boundary — chunks normally
    # close on a real pause in speech (see `silence_split_seconds`), so a quiet
    # period no longer wastes a 15-min file and a conversation is no longer cut
    # mid-sentence at a fixed clock tick. The cap still bounds a single chunk's
    # WAV/transcription memory for an unbroken monologue (default 15 min so
    # peak RAM stays bounded even before windowed AEC). With `speech_gated`
    # off, this reverts to the legacy fixed-interval rotation.
    chunk_minutes: float = Field(default=15.0, gt=0.0, le=60.0)
    # Segment audio on speech activity instead of a fixed clock. A chunk opens
    # when speech is first heard and closes after `silence_split_seconds` of
    # continuous silence (or at the `chunk_minutes` cap). Silent gaps between
    # chunks are not recorded, so there are no large near-empty files. Set false
    # for the legacy behavior (open immediately, rotate strictly on the clock).
    speech_gated: bool = True
    # How long speech must be absent before the current chunk is finalized. A
    # natural pause/turn boundary; tune lower to split more aggressively.
    silence_split_seconds: float = Field(default=60.0, ge=2.0, le=600.0)
    output_root: Path = Field(default=Path.home() / "huske" / "transcripts")
    audio_root: Path = Field(default=Path.home() / "huske" / "audio")
    logs_root: Path = Field(default=Path.home() / "huske" / "logs")
    screenshots_root: Path = Field(default=Path.home() / "huske" / "screenshots")
    # Where `huske export` writes its one-file-per-day Markdown digests. Nothing
    # is written here unless you run `huske export`; it exists so a folder-reading
    # tool (a Claude Project, NotebookLM, Obsidian, or a synced Drive folder) has
    # a single document per day instead of one per chunk. Point a sync client at
    # this directory only if you accept plaintext transcripts leaving the machine
    # — see docs/integrations.md.
    export_root: Path = Field(default=Path.home() / "huske" / "export")

    # Transcription backend. Parakeet by default (silence-robust, multilingual,
    # MLX-accelerated); `whisper` keeps the legacy mlx-whisper path.
    asr_engine: ASREngine = "parakeet"
    # Parakeet model id (HF repo or local dir), used when `asr_engine="parakeet"`.
    # The v3 TDT model is multilingual and auto-detects language. `model`/
    # `compute_type` below apply to the whisper engine only.
    parakeet_model: str = "mlx-community/parakeet-tdt-0.6b-v3"
    model: ModelSize = "base"
    compute_type: ComputeType = "int8"
    device: Device = "auto"
    # Expected spoken language (ISO 639-1, e.g. "pt"). None lets the engine
    # decide. How much this *guarantees* depends on the engine, and the
    # difference matters: `whisper` takes a real language token, so the language
    # is enforced. `parakeet` has no language input at all — it infers one per
    # decode window from the audio — so here `language` only powers a drift
    # guard that re-decodes a window which collapsed into English (a real failure
    # mode on speech mixing a non-English language with English jargon). If your
    # transcripts must be in one language, use `asr_engine = "whisper"`.
    language: str | None = None
    # When recording mic + system audio on speakers (no headphones), the system
    # output is played acoustically and re-captured by the mic. `echo_cancel`
    # *reduces* it before transcription via coherence-based echo suppression
    # (it attenuates the mic content coherent with the clean system channel).
    # Self-gating — with headphones there is no echo and the mic is untouched —
    # and it cannot remove the local voice (incoherent with the system). Audio
    # capture uses independent clocks (PortAudio mic, Core Audio system tap), so
    # sample-precise cancellation is infeasible; this suppresses rather than
    # eliminates, and `echo_dedup` below removes the residual at the text level.
    echo_cancel: bool = True
    # Primary removal of the duplicate: a mic run that echoes a near-simultaneous
    # system run (full or partial) is dropped (default), tagged (`· echo`), or
    # kept. One-way, so the local voice and the clean system line are never lost.
    echo_dedup: EchoDedup = "drop"

    # When true, the transcription worker drops the whisper model from memory
    # after `whisper_idle_unload_seconds` of inactivity, letting the OS reclaim
    # the resident weights (~150 MB for `base`, up to ~3 GB for `large-v3`)
    # during the long idle gaps between chunks. The next chunk pays a one-off
    # reload from the local model cache (a few seconds, no network) — a cheap
    # trade, since recording idles far more than it transcribes and held RAM
    # costs more than a network-free re-read. On by default; pass
    # `--no-idle-unload` (or set this false) to keep the model warm for
    # back-to-back transcription. See the transcribe worker's idle loop for the
    # queue-empty/timeout guard that keeps it warm through recovery bursts.
    whisper_idle_unload: bool = True
    whisper_idle_unload_seconds: float = Field(default=120.0, ge=5.0)
    # After idle-unload, exit the ASR child so macOS can reclaim the Metal
    # heap. ``mx.clear_cache()`` alone does not shrink Activity Monitor RSS.
    # The parent respawns (and re-inits Metal) on the next chunk.
    recycle_idle_process: bool = True
    # MLX buffer-cache cap in the ASR child (MiB). 0 disables the cache.
    metal_cache_limit_mb: int = Field(default=512, ge=0, le=65536)
    # MLX evaluation memory guideline in the ASR child (MiB). The default
    # without this is ~1.5x the GPU recommended working set (often the whole)
    # machine). Distill uses a smaller hard-coded cap.
    metal_memory_limit_mb: int = Field(default=8192, ge=0, le=131072)

    keep_audio: bool = False
    # When `keep_audio` is on, the per-chunk WAV is transcoded to this format
    # after transcription (and the WAV removed) — so retained audio stays small.
    # Default `opus` (lossy, smallest); `flac` for a lossless archival copy;
    # `wav` to keep the uncompressed original. No effect unless `keep_audio`.
    keep_audio_format: AudioKeepFormat = "opus"
    input_device: str | None = None

    sample_rate: int = Field(default=48000, gt=0)
    block_size: int = Field(default=1024, gt=0)
    channels: int = Field(default=2, ge=1, le=2)

    screenshots_enabled: bool = False
    # Default cadence is 60s — screen content changes slowly relative to speech,
    # and a slower tick keeps the screenshot directory small. Filenames are
    # second-precision (`HHMMSS_dN.jpg`), so subsecond intervals can overwrite
    # the prior capture for the same display.
    screenshots_interval_seconds: float = Field(default=60.0, ge=1.0, le=3600.0)
    screenshots_max_displays: int = Field(default=4, ge=1, le=16)
    # Each captured JPEG is post-processed (macOS `sips`, no extra dependency)
    # to shrink it for storage and as LLM input: downscaled so its longest edge
    # is at most `screenshots_max_dimension` px (0 disables resize; it never
    # *upscales* a smaller display) and re-encoded at `screenshots_jpeg_quality`
    # (1-100). 1568 px is the long edge Claude's vision API targets — a good
    # "legible but small" default. If `sips` is unavailable the raw
    # `screencapture` JPEG is kept untouched.
    screenshots_max_dimension: int = Field(default=1568, ge=0, le=10000)
    screenshots_jpeg_quality: int = Field(default=60, ge=1, le=100)

    log_level: Literal["DEBUG", "INFO", "WARNING", "ERROR"] = "INFO"
    # Deprecated no-op: `huske run` is always headless since the Rich terminal
    # panel was retired in favor of the macOS app. Accepted so existing config
    # files and launchers (`--no-ui`) keep working.
    no_ui: bool = False
    menu_bar_enabled: bool = True
    menu_bar_label_style: Literal["text", "icon"] = "text"
    # Explicit control-socket path for an external UI (the native macOS app in
    # ``macos/``). When set, `huske run` serves its JSON-line control protocol
    # at this exact path and does NOT spawn the bundled Python menu bar helper
    # — the external UI owns all presentation. Normally passed as
    # ``--control-socket`` by the app rather than written to the config file.
    control_socket: Path | None = None

    # Backend used to capture system audio on macOS.
    #   auto: Core Audio tap on macOS 14.4+ (resilient to screen-share
    #         conflicts), ScreenCaptureKit on older macOS.
    #   tap : force Core Audio tap (errors on unsupported macOS).
    #   sck : force ScreenCaptureKit (the legacy backend).
    #   off : disable system audio capture entirely (mic-only).
    system_audio_backend: SystemAudioBackend = "auto"

    # --- Cloud transcript sync (Git first; provider boundary is explicit) ---
    # See docs/adr/0009-git-replica-and-isolated-mcp-service.md.
    #
    # The recording app publishes immutable transcript files to a private Git
    # repository. It never hosts a read/MCP surface. Git is the first storage
    # provider (GitHub is the documented setup), while `sync_provider` keeps the
    # config contract open for a future object-store implementation.
    sync_enabled: bool = False
    sync_provider: Literal["git"] = "git"
    # SSH is recommended (`git@github.com:owner/private-repo.git`) because the
    # credential stays in the user's normal ssh-agent / Keychain instead of in
    # huske's config. HTTPS also works with the user's Git credential helper.
    sync_remote: str | None = None
    sync_branch: str = "main"
    # A dedicated managed checkout. Only transcript Markdown is copied into its
    # `transcripts/` directory; audio, screenshots, logs, and local config never
    # enter the repository.
    sync_root: Path = Field(default=Path.home() / "huske" / "sync")
    sync_push_timeout_seconds: float = Field(default=60.0, ge=5.0, le=600.0)

    # --- LLM correction of ASR transcripts (opt-in) -------------------------
    # See docs/adr/0005-llm-distillation.md. When enabled, each finalized
    # transcript is polished by a tiny LOCAL LLM (typos, obvious ASR
    # mishears). The raw snapshot stays in `<name>.asr.txt`; the canonical
    # `.md` is rewritten in place. Off by default; failures never block
    # recording or Git sync.
    distill_enabled: bool = False
    # Where the LLM runs (see DistillBackend). "mlx" is self-contained.
    distill_backend: DistillBackend = "mlx"
    # The model. For the built-in mlx backend this is a Hugging Face repo
    # (default: Qwen3.5 0.8B 4-bit, ~0.6 GB — small enough to only correct
    # the transcript). 2B / 4B repos stay selectable. The known Ollama tags
    # (`qwen3.5:0.8b`, `:2b`, `:4b`) are auto-mapped to their MLX builds so
    # older configs keep working. For the ollama backend this is the daemon's
    # tag (e.g. `qwen3.5:0.8b`).
    distill_model: str = "mlx-community/Qwen3.5-0.8B-4bit"
    # Loopback endpoint of the local LLM daemon (Ollama's default).
    distill_endpoint: str = "http://127.0.0.1:11434"
    # Per-call ceiling. A local model is slow; this bounds one run's correction.
    distill_timeout_seconds: float = Field(default=120.0, gt=0.0)
    # Kept for config compatibility. Correction is one-in/one-out per run, so
    # this cap is unused by the current prompt.
    distill_max_statements_per_passage: int = Field(default=8, ge=1, le=50)
    # `huske distill` backfill runs gentle by default (lower CPU priority).
    distill_low_impact: bool = True
    # Distillation runs a NON-reasoning call by default. Thinking-capable models
    # (e.g. Qwen3.5) otherwise spend their budget on a hidden reasoning pass —
    # slower, and on `/api/generate` it can swallow the whole reply — when ASR
    # correction needs none. huske calls Ollama's `/api/chat` with
    # `think: false`, which the daemon honors for thinking models and ignores for
    # the rest. Set true only if a model's reasoning measurably helps correction.
    distill_think: bool = False
    # Ollama backend only — inert on the default `mlx` backend, which downloads
    # its own model. When distillation is enabled (at launch or via the app /
    # menu-bar toggle), huske will best-effort make the local Ollama daemon ready
    # instead of only warning: start `ollama serve` if the CLI is installed but
    # the daemon is down, and `ollama pull` the configured model if it is missing.
    # Both are bounded and still degrade to the same actionable warning. Set false
    # to manage Ollama yourself. Only ever runs the local `ollama` CLI — never
    # installs it.
    distill_auto_manage: bool = True

    @field_validator(
        "output_root",
        "audio_root",
        "logs_root",
        "screenshots_root",
        "export_root",
        "sync_root",
        mode="before",
    )
    @classmethod
    def _expand(cls, v: Any) -> Path:
        return Path(str(v)).expanduser()

    @field_validator("control_socket", mode="before")
    @classmethod
    def _expand_optional(cls, v: Any) -> Path | None:
        if v is None:
            return None
        return Path(str(v)).expanduser()

    @field_validator("sync_branch")
    @classmethod
    def _valid_sync_branch(cls, value: str) -> str:
        branch = value.strip()
        if (
            not branch
            or branch == "@"
            or branch.startswith(("-", ".", "/"))
            or branch.endswith(("/", "."))
            or ".." in branch
            or "//" in branch
            or "@{" in branch
            or any(
                ch.isspace()
                or ord(ch) < 32
                or ord(ch) == 127
                or ch in "~^:?*[\\\\"
                for ch in branch
            )
            or any(
                part.startswith(".") or part.endswith(".lock")
                for part in branch.split("/")
            )
        ):
            raise ValueError("sync_branch is not a safe Git branch name")
        return branch

    @field_validator("sync_remote")
    @classmethod
    def _valid_sync_remote(cls, value: str | None) -> str | None:
        if value is None:
            return None
        remote = value.strip()
        if not remote:
            raise ValueError("sync_remote cannot be empty")
        if remote.startswith("-") or any(
            character in remote for character in ("\n", "\r", "\0")
        ):
            raise ValueError("sync_remote is not a safe Git repository location")
        return remote

    @model_validator(mode="after")
    def _sync_has_remote(self) -> RuntimeConfig:
        if self.sync_enabled and not (self.sync_remote and self.sync_remote.strip()):
            raise ValueError("sync_enabled=true requires sync_remote")
        return self

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


# Removed in ADR 0009. Ignore these on read so an existing installation starts
# cleanly after upgrade; the next config write removes them from the file.
_RETIRED_CONFIG_KEYS = {
    "index_root",
    "indexing_enabled",
    "embedding_model",
    "embed_batch_size",
    "index_low_impact",
    "index_memory_limit_mb",
    "mcp_host",
    "mcp_port",
    "mcp_public_url",
    "mcp_access_token_ttl_seconds",
    "mcp_refresh_token_ttl_seconds",
    "mcp_allowed_origins",
    "sync_endpoint",
    "sync_verify_tls",
    "ingest_host",
    "ingest_port",
    "public_host",
}


def without_retired_config(values: dict[str, Any]) -> dict[str, Any]:
    return {key: value for key, value in values.items() if key not in _RETIRED_CONFIG_KEYS}


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

    # Typer's ctx.invoke passes raw OptionInfo objects for unset params instead
    # of None. Accept only actual Path values; treat anything else as "not set".
    if not isinstance(config_path, Path):
        config_path = None

    file_path = config_path or default_user_config_path()
    file_data = without_retired_config(_read_toml(file_path)) if file_path.exists() else {}
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
    existing = without_retired_config(_read_toml(target))
    merged: dict[str, Any] = dict(existing)
    for k, v in updates.items():
        if v is None:
            merged.pop(k, None)
        else:
            merged[k] = v
    with target.open("wb") as f:
        tomli_w.dump(merged, f)
    return target
