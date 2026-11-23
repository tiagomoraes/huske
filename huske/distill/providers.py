"""Where LLM post-processing can run, and where the transcript text goes.

One table answers every per-provider question the engine, ``huske doctor``,
the CLI and Huske.app ask: the label to show, whether text leaves the Mac,
the default endpoint and model, whether a Keychain key is needed, the context
window to chunk against, and whether the model competes with ASR for Metal.

The privacy rule lives here too, in one place: :func:`resolve_target` decides
whether a target is *off this Mac* (a cloud provider, or any non-loopback
endpoint), and :func:`consent_granted` says whether the user agreed to send
transcript text to exactly that host. The HTTP backends refuse to send
without it (``huske.distill.http_llm``).
"""

from __future__ import annotations

import ipaddress
from dataclasses import dataclass
from typing import Any, Literal
from urllib.parse import urlsplit

Placement = Literal["on_device", "local", "cloud"]

DEFAULT_MLX_MODEL = "mlx-community/Qwen3.5-0.8B-4bit"
APPLE_MODEL_ID = "apple-on-device"


@dataclass(frozen=True)
class Provider:
    name: str
    label: str
    #: ``on_device`` never opens a socket; ``local`` talks to a server on this
    #: Mac (unless its endpoint points elsewhere); ``cloud`` always leaves it.
    placement: Placement
    default_endpoint: str | None
    default_model: str | None
    #: An API key is required (cloud) / accepted but optional (local servers).
    needs_key: bool
    accepts_key: bool
    #: Total context window assumed for chunking when the user sets none.
    context_tokens: int
    #: Upper bound on one reply, so a chunk's correction always fits.
    max_output_tokens: int
    #: Runs on this Mac's GPU next to ASR — share the Metal gate.
    gpu_gated: bool


PROVIDERS: dict[str, Provider] = {
    "mlx": Provider(
        name="mlx",
        label="Built-in model",
        placement="on_device",
        default_endpoint=None,
        default_model=DEFAULT_MLX_MODEL,
        needs_key=False,
        accepts_key=False,
        # The child caps its KV cache at 2,048 tokens (mlx_backend._MAX_KV_SIZE).
        context_tokens=2048,
        max_output_tokens=900,
        gpu_gated=True,
    ),
    "apple": Provider(
        name="apple",
        label="Apple Intelligence",
        placement="on_device",
        default_endpoint=None,
        default_model=APPLE_MODEL_ID,
        needs_key=False,
        accepts_key=False,
        # Apple's on-device model: 4,096 tokens for instructions, prompt and
        # reply together on macOS 26 (TN3193), 8,192 on macOS 27 with AFM 3
        # Core Advanced. Context is capped at what the helper reports at run
        # time (ADR 0013), so the larger figure is safe as the ceiling.
        context_tokens=8192,
        max_output_tokens=1800,
        gpu_gated=False,
    ),
    "ollama": Provider(
        name="ollama",
        label="Ollama",
        placement="local",
        default_endpoint="http://127.0.0.1:11434",
        default_model="qwen3.5:0.8b",
        needs_key=False,
        accepts_key=False,
        context_tokens=4096,
        max_output_tokens=1800,
        gpu_gated=True,
    ),
    "openai_compatible": Provider(
        name="openai_compatible",
        label="OpenAI-compatible server",
        placement="local",
        default_endpoint="http://127.0.0.1:1234/v1",
        default_model=None,  # first model the server lists
        needs_key=False,
        accepts_key=True,
        context_tokens=4096,
        max_output_tokens=1800,
        gpu_gated=True,
    ),
    "openai": Provider(
        name="openai",
        label="OpenAI",
        placement="cloud",
        default_endpoint="https://api.openai.com/v1",
        default_model=None,
        needs_key=True,
        accepts_key=True,
        context_tokens=32_000,
        max_output_tokens=8000,
        gpu_gated=False,
    ),
    "anthropic": Provider(
        name="anthropic",
        label="Anthropic",
        placement="cloud",
        default_endpoint="https://api.anthropic.com/v1",
        default_model="claude-haiku-5-5",
        needs_key=True,
        accepts_key=True,
        context_tokens=32_000,
        max_output_tokens=8000,
        gpu_gated=False,
    ),
    "openrouter": Provider(
        name="openrouter",
        label="OpenRouter",
        placement="cloud",
        default_endpoint="https://openrouter.ai/api/v1",
        default_model=None,
        needs_key=True,
        accepts_key=True,
        context_tokens=32_000,
        max_output_tokens=8000,
        gpu_gated=False,
    ),
}


def provider(name: str) -> Provider:
    try:
        return PROVIDERS[name]
    except KeyError as exc:
        raise ValueError(f"unknown LLM backend: {name!r}") from exc


def is_loopback_host(host: str | None) -> bool:
    """True for ``localhost`` and loopback addresses — the only "same Mac" hosts.

    A ``.local`` name or a LAN address is another machine: text sent there
    leaves this Mac, so it needs consent like any cloud provider.
    """
    if not host:
        return False
    name = host.strip("[]").lower().rstrip(".")
    if name == "localhost" or name.endswith(".localhost"):
        return True
    try:
        return ipaddress.ip_address(name).is_loopback
    except ValueError:
        return False


@dataclass(frozen=True)
class Target:
    """A fully resolved destination for post-processing requests."""

    provider: Provider
    endpoint: str | None
    model: str | None
    #: The host transcript text is sent to (``None`` on-device).
    host: str | None
    leaves_mac: bool
    context_tokens: int

    @property
    def name(self) -> str:
        return self.provider.name

    @property
    def model_label(self) -> str:
        """``<provider>:<model>`` as recorded in ``postprocessed_by``."""
        return f"{self.provider.name}:{self.model or 'default'}"


def resolve_target(cfg: Any) -> Target:
    """Resolve backend, endpoint, model and placement from a ``RuntimeConfig``."""
    prov = provider(str(cfg.distill_backend))
    if prov.placement == "cloud":
        # Named cloud providers always use their official endpoint: a stale
        # `distill_endpoint` left over from Ollama must never receive an
        # OpenAI key. Proxies and other hosts go through openai_compatible.
        endpoint = prov.default_endpoint
    else:
        endpoint = getattr(cfg, "distill_endpoint", None) or prov.default_endpoint
    if prov.name == "openai_compatible" and endpoint:
        endpoint = normalize_openai_base(endpoint)
    model = getattr(cfg, "distill_model", None) or prov.default_model
    if prov.name == "mlx" and model:
        from huske.distill.mlx_backend import resolve_mlx_model

        model = resolve_mlx_model(model)
    host = urlsplit(endpoint).hostname if endpoint else None
    leaves_mac = prov.placement == "cloud" or (
        prov.placement == "local" and not is_loopback_host(host)
    )
    context = getattr(cfg, "distill_context_tokens", None) or prov.context_tokens
    return Target(
        provider=prov,
        endpoint=endpoint,
        model=model,
        host=host.lower() if host else None,
        leaves_mac=leaves_mac,
        context_tokens=int(context),
    )


def normalize_openai_base(endpoint: str) -> str:
    """An OpenAI-compatible base URL; a bare host gets ``/v1`` (LM Studio, Ollama)."""
    url = endpoint.rstrip("/")
    parts = urlsplit(url)
    if parts.path in ("", "/"):
        return f"{url}/v1"
    return url


def consent_granted(target: Target, cfg: Any) -> bool:
    """True when nothing leaves the Mac, or the user allowed exactly this host."""
    if not target.leaves_mac:
        return True
    allowed = getattr(cfg, "distill_cloud_consent", None)
    return bool(allowed) and allowed == target.host
