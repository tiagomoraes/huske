"""HTTP LLM backends: OpenAI-compatible ``/chat/completions`` and Anthropic Messages.

Dependency-free (stdlib ``urllib``), like ``huske.distill.client``. One class
covers OpenAI, OpenRouter and any OpenAI-compatible server (LM Studio,
llama.cpp, vLLM, Ollama's ``/v1``); Anthropic uses its native Messages API.

Rules every request follows:

* **Consent first.** A backend whose target leaves this Mac refuses to send
  anything unless the user allowed exactly that host
  (``providers.consent_granted``). This is checked at send time, not only in
  the UI, so no code path can skip it.
* **The key comes from the Keychain at call time** and lives only in the
  request header — never in a log line, an error message or an exception.
* **Optional speed knobs degrade gracefully.** ``temperature: 0``, reasoning
  off, a token cap: some models reject one of them with a 400. The backend
  then retries once with the bare request and remembers that for the model.
* **A truncated or refused reply is an error, not a result**
  (``kind="truncated"`` / ``"refused"``), so the correction loop splits the
  batch or keeps the raw text instead of saving half a line.
"""

from __future__ import annotations

import json
import ssl
import urllib.error
import urllib.request
from collections.abc import Callable
from typing import Any

from huske import __version__
from huske.distill.client import DistillError, ErrorKind
from huske.distill.providers import Target

ANTHROPIC_VERSION = "2023-06-01"
_USER_AGENT = f"huske/{__version__}"
_CONTEXT_HINTS = (
    "context length",
    "context window",
    "maximum context",
    "too many tokens",
    "prompt is too long",
    "input is too long",
    "exceeds the context",
    "context_length_exceeded",
)


def _ssl_context() -> ssl.SSLContext:
    try:
        import certifi

        return ssl.create_default_context(cafile=certifi.where())
    except Exception:
        return ssl.create_default_context()


def _error_detail(raw: bytes) -> str:
    """The provider's error message, short; never the request body."""
    try:
        data = json.loads(raw.decode("utf-8", errors="replace"))
    except (ValueError, UnicodeDecodeError):
        return ""
    err = data.get("error") if isinstance(data, dict) else None
    if isinstance(err, dict):
        msg = err.get("message") or err.get("type") or ""
    elif isinstance(err, str):
        msg = err
    else:
        msg = data.get("message", "") if isinstance(data, dict) else ""
    return " ".join(str(msg).split())[:200]


def _classify_http(status: int, detail: str) -> ErrorKind:
    low = detail.lower()
    if status in (401, 403):
        return "auth"
    if status == 429:
        return "rate_limited"
    if status in (400, 413, 422) and any(h in low for h in _CONTEXT_HINTS):
        return "context"
    if status == 404:
        return "config"
    if status in (408, 504):
        return "timeout"
    if status >= 500:
        return "unavailable"
    return "http"


class _HTTPBackend:
    """Shared transport: JSON POST/GET with consent, timeouts, error mapping."""

    def __init__(
        self,
        target: Target,
        *,
        consented: bool,
        api_key: str | None,
        timeout: float = 120.0,
        opener: Callable[..., Any] | None = None,
    ) -> None:
        if not target.endpoint:
            raise DistillError(f"{target.provider.label} has no endpoint", kind="config")
        self.target = target
        self.provider = target.name
        self.model_id = target.model or ""
        self._base = target.endpoint.rstrip("/")
        self._consented = consented
        self._key = api_key
        self._timeout = timeout
        self._open = opener or urllib.request.urlopen
        self._ssl = _ssl_context() if self._base.startswith("https") else None

    def _check_consent(self) -> None:
        if self.target.leaves_mac and not self._consented:
            raise DistillError(
                f"sending transcripts to {self.target.host} needs your consent "
                "(Huske.app → Configuration, or `huske llm allow-cloud`)",
                kind="consent",
            )

    def _headers(self) -> dict[str, str]:
        return {"Content-Type": "application/json", "User-Agent": _USER_AGENT}

    def _request(self, method: str, path: str, payload: dict[str, Any] | None) -> dict[str, Any]:
        self._check_consent()
        data = json.dumps(payload).encode("utf-8") if payload is not None else None
        req = urllib.request.Request(
            self._base + path, data=data, method=method, headers=self._headers()
        )
        kwargs: dict[str, Any] = {"timeout": self._timeout}
        if self._ssl is not None:
            kwargs["context"] = self._ssl
        try:
            with self._open(req, **kwargs) as resp:
                raw = resp.read()
        except urllib.error.HTTPError as exc:
            detail = _error_detail(exc.read() if exc.fp is not None else b"")
            kind = _classify_http(exc.code, detail)
            label = self.target.provider.label
            message = f"{label} returned HTTP {exc.code}" + (f": {detail}" if detail else "")
            if kind == "auth":
                message = (
                    f"{label} rejected the API key (HTTP {exc.code}); update it in "
                    "Huske.app or with `huske llm key set`"
                )
            raise DistillError(message, status=exc.code, kind=kind) from None
        except TimeoutError:
            raise DistillError(
                f"{self.target.provider.label} did not answer within {self._timeout:.0f}s",
                kind="timeout",
            ) from None
        except (urllib.error.URLError, OSError) as exc:
            reason = getattr(exc, "reason", exc)
            raise DistillError(
                f"could not reach {self.target.host or self._base}: {reason}", kind="transport"
            ) from None
        try:
            parsed = json.loads(raw.decode("utf-8") or "{}")
        except (ValueError, UnicodeDecodeError):
            raise DistillError(
                f"{self.target.provider.label} returned a response that is not JSON",
                kind="http",
            ) from None
        if not isinstance(parsed, dict):
            raise DistillError(f"{self.target.provider.label} returned unexpected JSON", kind="http")
        return parsed

    def _post_with_fallback(
        self, path: str, required: dict[str, Any], optional: dict[str, Any]
    ) -> dict[str, Any]:
        """POST ``required + optional``; on a 400/422, retry once with ``required`` only."""
        if optional and not getattr(self, "_bare", False):
            try:
                return self._request("POST", path, {**required, **optional})
            except DistillError as exc:
                if exc.status not in (400, 422) or exc.kind == "context":
                    raise
                self._bare = True  # this model rejects a knob; stop sending them
        return self._request("POST", path, required)


class OpenAICompatibleBackend(_HTTPBackend):
    """``POST {base}/chat/completions`` — OpenAI, OpenRouter, LM Studio, vLLM, …"""

    def _headers(self) -> dict[str, str]:
        headers = super()._headers()
        if self._key:
            headers["Authorization"] = f"Bearer {self._key}"
        return headers

    def resolve_model(self) -> str:
        """The configured model, or the first one a local server lists."""
        if self.model_id:
            return self.model_id
        models = self.list_models()
        if not models:
            raise DistillError(
                f"{self.target.provider.label} at {self._base} lists no models; load one "
                "or set distill_model",
                kind="config",
            )
        self.model_id = models[0]
        return self.model_id

    def list_models(self) -> list[str]:
        body = self._request("GET", "/models", None)
        data = body.get("data")
        out: list[str] = []
        if isinstance(data, list):
            for item in data:
                if isinstance(item, dict) and isinstance(item.get("id"), str):
                    out.append(item["id"])
        return out

    def complete(self, instructions: str, prompt: str, *, max_tokens: int) -> str:
        model = self.resolve_model()
        required: dict[str, Any] = {
            "model": model,
            "messages": [
                {"role": "system", "content": instructions},
                {"role": "user", "content": prompt},
            ],
            "stream": False,
        }
        optional: dict[str, Any] = {"temperature": 0}
        if self.provider == "openai":
            # Reasoning models spend hidden tokens before answering; cleanup
            # needs none. Rejected by non-reasoning models → bare retry.
            optional["reasoning_effort"] = "none"
        elif self.provider == "openrouter":
            optional["reasoning"] = {"effort": "none", "exclude": True}
        else:
            optional["max_tokens"] = max_tokens
        body = self._post_with_fallback("/chat/completions", required, optional)
        choices = body.get("choices")
        if not isinstance(choices, list) or not choices or not isinstance(choices[0], dict):
            raise DistillError(f"{self.target.provider.label} returned no choices", kind="http")
        choice = choices[0]
        finish = choice.get("finish_reason")
        raw_message = choice.get("message")
        message: dict[str, Any] = raw_message if isinstance(raw_message, dict) else {}
        if finish == "length":
            raise DistillError("the reply hit the model's output limit", kind="truncated")
        if finish == "content_filter" or message.get("refusal"):
            raise DistillError("the model declined this excerpt", kind="refused")
        content = message.get("content")
        if isinstance(content, list):  # some servers return content parts
            content = "".join(
                str(p.get("text", "")) for p in content if isinstance(p, dict)
            )
        if not isinstance(content, str):
            raise DistillError(f"{self.target.provider.label} returned no text", kind="http")
        return content


class AnthropicBackend(_HTTPBackend):
    """Anthropic's native ``POST /v1/messages``."""

    def _headers(self) -> dict[str, str]:
        headers = super()._headers()
        headers["anthropic-version"] = ANTHROPIC_VERSION
        if self._key:
            headers["x-api-key"] = self._key
        return headers

    def list_models(self) -> list[str]:
        body = self._request("GET", "/models?limit=1000", None)
        data = body.get("data")
        return [
            item["id"]
            for item in (data if isinstance(data, list) else [])
            if isinstance(item, dict) and isinstance(item.get("id"), str)
        ]

    def complete(self, instructions: str, prompt: str, *, max_tokens: int) -> str:
        if not self.model_id:
            raise DistillError("choose an Anthropic model (distill_model)", kind="config")
        # Current models think adaptively by default and count that against
        # max_tokens; leave room so a short cleanup is never cut off. Current
        # models also reject a non-default temperature, so none is sent.
        required: dict[str, Any] = {
            "model": self.model_id,
            "max_tokens": min(16_000, max(max_tokens * 2, max_tokens + 2048)),
            "system": instructions,
            "messages": [{"role": "user", "content": prompt}],
        }
        optional: dict[str, Any] = {"output_config": {"effort": "low"}}
        body = self._post_with_fallback("/messages", required, optional)
        stop = body.get("stop_reason")
        if stop == "max_tokens":
            raise DistillError("the reply hit max_tokens", kind="truncated")
        if stop == "refusal":
            raise DistillError("the model declined this excerpt", kind="refused")
        blocks = body.get("content")
        if not isinstance(blocks, list):
            raise DistillError("Anthropic returned no content", kind="http")
        return "".join(
            str(b.get("text", ""))
            for b in blocks
            if isinstance(b, dict) and b.get("type") == "text"
        )
