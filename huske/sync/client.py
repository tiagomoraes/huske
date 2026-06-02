"""The ``POST /ingest`` call: push one transcript to the huske server.

Dependency-free (stdlib ``urllib`` + ``ssl`` + ``json`` + ``hashlib``). The
wire format is a small JSON envelope — ``rel_path`` locates the transcript under
the server's ``output_root`` (the same ``YYYY-MM-DD/<name>.md`` layout), ``content``
is the Markdown, and ``sha256`` lets the server reject a corrupted body and lets
the client key its outbox idempotently.
"""

from __future__ import annotations

import hashlib
import json
import ssl
import urllib.error
import urllib.request
from dataclasses import dataclass

from huske.sync import INGEST_PATH


def sha256_hex(text: str) -> str:
    """Hash the UTF-8 bytes the client sends (and the server will write)."""
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


class SyncError(RuntimeError):
    """A push failed. ``status`` is the HTTP code when there was a response."""

    def __init__(self, message: str, *, status: int | None = None) -> None:
        super().__init__(message)
        self.status = status

    @property
    def retryable(self) -> bool:
        # Auth/validation failures won't fix themselves on retry; network blips
        # and 5xx will. ``None`` (no response) is a network error → retry.
        if self.status is None:
            return True
        return self.status >= 500


@dataclass(frozen=True)
class IngestResult:
    status: str  # "stored" | "unchanged"
    rel_path: str


class IngestClient:
    """Posts transcripts to ``{endpoint}/ingest`` with a bearer write token."""

    def __init__(
        self,
        endpoint: str,
        token: str,
        *,
        verify_tls: bool = True,
        timeout: float = 30.0,
    ) -> None:
        self._url = endpoint.rstrip("/") + INGEST_PATH
        self._token = token
        self._timeout = timeout
        self._ssl_ctx: ssl.SSLContext | None = None
        if not verify_tls:
            ctx = ssl.create_default_context()
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
            self._ssl_ctx = ctx

    def push(self, rel_path: str, content: str, sha256: str) -> IngestResult:
        body = json.dumps(
            {"rel_path": rel_path, "sha256": sha256, "content": content}
        ).encode("utf-8")
        req = urllib.request.Request(
            self._url,
            data=body,
            method="POST",
            headers={
                "Authorization": f"Bearer {self._token}",
                "Content-Type": "application/json",
            },
        )
        try:
            with urllib.request.urlopen(req, timeout=self._timeout, context=self._ssl_ctx) as resp:
                payload = json.loads(resp.read().decode("utf-8") or "{}")
        except urllib.error.HTTPError as exc:
            detail = _safe_error_detail(exc)
            raise SyncError(
                f"server rejected {rel_path}: HTTP {exc.code} {detail}", status=exc.code
            ) from exc
        except (urllib.error.URLError, TimeoutError, ssl.SSLError, OSError) as exc:
            raise SyncError(f"could not reach huske server: {exc}") from exc

        status = str(payload.get("status", "stored"))
        return IngestResult(status=status, rel_path=rel_path)


def _safe_error_detail(exc: urllib.error.HTTPError) -> str:
    try:
        raw = exc.read().decode("utf-8")
    except Exception:
        return ""
    try:
        return str(json.loads(raw).get("error", raw))[:200]
    except Exception:
        return raw[:200]
