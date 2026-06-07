"""The loopback LLM call: ``POST /api/generate`` against a local Ollama daemon.

Dependency-free (stdlib ``urllib`` + ``json``), mirroring ``huske.sync.client``.
Ollama's HTTP API runs on ``127.0.0.1:11434`` by default; we hit ``/api/generate``
for a single-turn completion and ``/api/tags`` to enumerate pulled models (used
by ``huske doctor``). Errors are classified retryable/not the same way the sync
client does, so a worker can back off on a transient blip but give up on a 4xx.
"""

from __future__ import annotations

import json
import urllib.error
import urllib.request
from typing import Any

_GENERATE_PATH = "/api/generate"
_TAGS_PATH = "/api/tags"


class DistillError(RuntimeError):
    """An LLM call failed. ``status`` is the HTTP code when there was a response."""

    def __init__(self, message: str, *, status: int | None = None) -> None:
        super().__init__(message)
        self.status = status

    @property
    def retryable(self) -> bool:
        # A daemon that's down/starting (network error) or a 5xx may recover; a
        # 4xx (bad model name, malformed request) will not.
        if self.status is None:
            return True
        return self.status >= 500


class OllamaClient:
    """Minimal Ollama HTTP client over stdlib ``urllib`` (loopback by default)."""

    def __init__(self, endpoint: str, *, timeout: float = 120.0) -> None:
        self._base = endpoint.rstrip("/")
        self._timeout = timeout

    def generate(
        self,
        model: str,
        prompt: str,
        *,
        json_format: bool = True,
        options: dict[str, Any] | None = None,
    ) -> str:
        """Run one non-streaming completion; return the model's ``response`` text.

        ``json_format`` asks Ollama to constrain output to valid JSON (its
        ``format: "json"`` mode), which makes parsing the statement list robust.
        """
        payload: dict[str, Any] = {"model": model, "prompt": prompt, "stream": False}
        if json_format:
            payload["format"] = "json"
        if options:
            payload["options"] = options
        body = self._post(_GENERATE_PATH, payload)
        response = body.get("response")
        if not isinstance(response, str):
            raise DistillError(
                f"unexpected /api/generate response (no 'response' field): {str(body)[:120]!r}"
            )
        return response

    def list_models(self) -> list[str]:
        """Return the names of locally pulled models (``GET /api/tags``)."""
        body = self._get(_TAGS_PATH)
        models = body.get("models")
        if not isinstance(models, list):
            return []
        names: list[str] = []
        for m in models:
            if isinstance(m, dict) and isinstance(m.get("name"), str):
                names.append(m["name"])
        return names

    # -- transport ---------------------------------------------------------

    def _post(self, path: str, payload: dict[str, Any]) -> dict[str, Any]:
        req = urllib.request.Request(
            self._base + path,
            data=json.dumps(payload).encode("utf-8"),
            method="POST",
            headers={"Content-Type": "application/json"},
        )
        return self._send(req)

    def _get(self, path: str) -> dict[str, Any]:
        req = urllib.request.Request(self._base + path, method="GET")
        return self._send(req)

    def _send(self, req: urllib.request.Request) -> dict[str, Any]:
        try:
            with urllib.request.urlopen(req, timeout=self._timeout) as resp:
                raw = resp.read().decode("utf-8")
        except urllib.error.HTTPError as exc:
            raise DistillError(
                f"LLM daemon rejected request: HTTP {exc.code} {_safe_error_detail(exc)}",
                status=exc.code,
            ) from exc
        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            raise DistillError(
                f"could not reach LLM daemon at {self._base}: {exc}"
            ) from exc

        try:
            parsed = json.loads(raw or "{}")
        except json.JSONDecodeError as exc:
            raise DistillError(
                f"LLM daemon returned non-JSON response: {raw[:120]!r}"
            ) from exc
        if not isinstance(parsed, dict):
            raise DistillError(f"LLM daemon returned non-object JSON: {raw[:120]!r}")
        return parsed


def _safe_error_detail(exc: urllib.error.HTTPError) -> str:
    try:
        raw = exc.read().decode("utf-8")
    except Exception:
        return ""
    try:
        return str(json.loads(raw).get("error", raw))[:200]
    except Exception:
        return raw[:200]
