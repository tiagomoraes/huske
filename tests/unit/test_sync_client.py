"""IngestClient: request shape, response parsing, error classification.

Network is stubbed by monkeypatching ``urllib.request.urlopen`` — no socket.
"""

from __future__ import annotations

import io
import json
import urllib.error
import urllib.request
from typing import Any

import pytest

from huske.sync.client import IngestClient, SyncError, sha256_hex


class _FakeResponse:
    def __init__(self, payload: dict[str, Any]) -> None:
        self._data = json.dumps(payload).encode("utf-8")

    def read(self) -> bytes:
        return self._data

    def __enter__(self) -> _FakeResponse:
        return self

    def __exit__(self, *exc: object) -> None:
        return None


def test_sha256_hex_is_stable() -> None:
    assert sha256_hex("hello") == sha256_hex("hello")
    assert sha256_hex("hello") != sha256_hex("world")


def test_push_sends_bearer_and_json(monkeypatch: pytest.MonkeyPatch) -> None:
    captured: dict[str, Any] = {}

    def fake_urlopen(req: urllib.request.Request, **kwargs: Any) -> _FakeResponse:
        captured["url"] = req.full_url
        captured["method"] = req.get_method()
        captured["auth"] = req.headers.get("Authorization")
        captured["body"] = json.loads(req.data.decode("utf-8"))  # type: ignore[union-attr]
        return _FakeResponse({"status": "stored", "rel_path": "2026-06-02/a.md"})

    monkeypatch.setattr(urllib.request, "urlopen", fake_urlopen)

    client = IngestClient("https://huske.example.com/", "tok123")
    result = client.push("2026-06-02/a.md", "content", sha256_hex("content"))

    assert result.status == "stored"
    assert captured["url"] == "https://huske.example.com/ingest"
    assert captured["method"] == "POST"
    assert captured["auth"] == "Bearer tok123"
    assert captured["body"]["rel_path"] == "2026-06-02/a.md"
    assert captured["body"]["content"] == "content"


def test_http_error_is_non_retryable_for_4xx(monkeypatch: pytest.MonkeyPatch) -> None:
    def fake_urlopen(req: urllib.request.Request, **kwargs: Any) -> _FakeResponse:
        raise urllib.error.HTTPError(
            req.full_url, 401, "Unauthorized", {}, io.BytesIO(b'{"error":"unauthorized"}')  # type: ignore[arg-type]
        )

    monkeypatch.setattr(urllib.request, "urlopen", fake_urlopen)
    client = IngestClient("https://huske.example.com", "tok")
    with pytest.raises(SyncError) as exc:
        client.push("2026-06-02/a.md", "c", sha256_hex("c"))
    assert exc.value.status == 401
    assert exc.value.retryable is False


def test_http_error_is_retryable_for_5xx(monkeypatch: pytest.MonkeyPatch) -> None:
    def fake_urlopen(req: urllib.request.Request, **kwargs: Any) -> _FakeResponse:
        raise urllib.error.HTTPError(req.full_url, 503, "Unavailable", {}, io.BytesIO(b""))  # type: ignore[arg-type]

    monkeypatch.setattr(urllib.request, "urlopen", fake_urlopen)
    client = IngestClient("https://huske.example.com", "tok")
    with pytest.raises(SyncError) as exc:
        client.push("2026-06-02/a.md", "c", sha256_hex("c"))
    assert exc.value.status == 503
    assert exc.value.retryable is True


def test_non_json_200_is_retryable(monkeypatch: pytest.MonkeyPatch) -> None:
    class _HTMLResp:
        def read(self) -> bytes:
            return b"<html><body>Bad Gateway</body></html>"

        def __enter__(self) -> _HTMLResp:
            return self

        def __exit__(self, *args: object) -> None:
            return None

    def fake_urlopen(req: urllib.request.Request, **kwargs: Any) -> _HTMLResp:
        return _HTMLResp()

    monkeypatch.setattr(urllib.request, "urlopen", fake_urlopen)
    client = IngestClient("https://huske.example.com", "tok")
    with pytest.raises(SyncError) as exc:
        client.push("2026-06-02/a.md", "c", sha256_hex("c"))
    assert exc.value.status is None  # no HTTP status code (decode error)
    assert exc.value.retryable is True  # retryable, not a 4xx logic error


def test_network_error_is_retryable(monkeypatch: pytest.MonkeyPatch) -> None:
    def fake_urlopen(req: urllib.request.Request, **kwargs: Any) -> _FakeResponse:
        raise urllib.error.URLError("no route to host")

    monkeypatch.setattr(urllib.request, "urlopen", fake_urlopen)
    client = IngestClient("https://huske.example.com", "tok")
    with pytest.raises(SyncError) as exc:
        client.push("2026-06-02/a.md", "c", sha256_hex("c"))
    assert exc.value.status is None
    assert exc.value.retryable is True
