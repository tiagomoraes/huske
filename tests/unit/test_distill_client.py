"""OllamaClient: request shape, response parsing, error classification.

Network is stubbed by monkeypatching ``urllib.request.urlopen`` — no socket.
Mirrors tests/unit/test_sync_client.py.
"""

from __future__ import annotations

import io
import json
import urllib.error
import urllib.request
from typing import Any

import pytest

from huske.distill.client import DistillError, OllamaClient


class _FakeResponse:
    def __init__(self, payload: dict[str, Any]) -> None:
        self._data = json.dumps(payload).encode("utf-8")

    def read(self) -> bytes:
        return self._data

    def __enter__(self) -> _FakeResponse:
        return self

    def __exit__(self, *exc: object) -> None:
        return None


def test_generate_posts_json_and_returns_response(monkeypatch: pytest.MonkeyPatch) -> None:
    captured: dict[str, Any] = {}

    def fake_urlopen(req: urllib.request.Request, **kwargs: Any) -> _FakeResponse:
        captured["url"] = req.full_url
        captured["method"] = req.get_method()
        captured["body"] = json.loads(req.data.decode("utf-8"))  # type: ignore[union-attr]
        return _FakeResponse({"response": '{"statements": ["a claim"]}', "done": True})

    monkeypatch.setattr(urllib.request, "urlopen", fake_urlopen)

    client = OllamaClient("http://127.0.0.1:11434/")
    out = client.generate("gemma4:e2b", "hello", options={"temperature": 0.0})

    assert out == '{"statements": ["a claim"]}'
    assert captured["url"] == "http://127.0.0.1:11434/api/generate"
    assert captured["method"] == "POST"
    assert captured["body"]["model"] == "gemma4:e2b"
    assert captured["body"]["prompt"] == "hello"
    assert captured["body"]["stream"] is False
    assert captured["body"]["format"] == "json"  # json_format default
    assert captured["body"]["options"] == {"temperature": 0.0}


def test_generate_missing_response_field_raises(monkeypatch: pytest.MonkeyPatch) -> None:
    def fake_urlopen(req: urllib.request.Request, **kwargs: Any) -> _FakeResponse:
        return _FakeResponse({"done": True})  # no "response"

    monkeypatch.setattr(urllib.request, "urlopen", fake_urlopen)
    with pytest.raises(DistillError):
        OllamaClient("http://127.0.0.1:11434").generate("m", "p")


def test_list_models_parses_tags(monkeypatch: pytest.MonkeyPatch) -> None:
    def fake_urlopen(req: urllib.request.Request, **kwargs: Any) -> _FakeResponse:
        assert req.full_url.endswith("/api/tags")
        assert req.get_method() == "GET"
        return _FakeResponse(
            {"models": [{"name": "gemma4:e2b"}, {"name": "qwen3:4b"}, {"bad": 1}]}
        )

    monkeypatch.setattr(urllib.request, "urlopen", fake_urlopen)
    names = OllamaClient("http://127.0.0.1:11434").list_models()
    assert names == ["gemma4:e2b", "qwen3:4b"]


def test_http_4xx_is_non_retryable(monkeypatch: pytest.MonkeyPatch) -> None:
    def fake_urlopen(req: urllib.request.Request, **kwargs: Any) -> _FakeResponse:
        raise urllib.error.HTTPError(
            req.full_url, 404, "Not Found", {}, io.BytesIO(b'{"error":"model not found"}')  # type: ignore[arg-type]
        )

    monkeypatch.setattr(urllib.request, "urlopen", fake_urlopen)
    with pytest.raises(DistillError) as exc:
        OllamaClient("http://127.0.0.1:11434").generate("nope", "p")
    assert exc.value.status == 404
    assert exc.value.retryable is False


def test_http_5xx_is_retryable(monkeypatch: pytest.MonkeyPatch) -> None:
    def fake_urlopen(req: urllib.request.Request, **kwargs: Any) -> _FakeResponse:
        raise urllib.error.HTTPError(req.full_url, 503, "Unavailable", {}, io.BytesIO(b""))  # type: ignore[arg-type]

    monkeypatch.setattr(urllib.request, "urlopen", fake_urlopen)
    with pytest.raises(DistillError) as exc:
        OllamaClient("http://127.0.0.1:11434").generate("m", "p")
    assert exc.value.status == 503
    assert exc.value.retryable is True


def test_daemon_unreachable_is_retryable(monkeypatch: pytest.MonkeyPatch) -> None:
    def fake_urlopen(req: urllib.request.Request, **kwargs: Any) -> _FakeResponse:
        raise urllib.error.URLError("connection refused")

    monkeypatch.setattr(urllib.request, "urlopen", fake_urlopen)
    with pytest.raises(DistillError) as exc:
        OllamaClient("http://127.0.0.1:11434").list_models()
    assert exc.value.status is None
    assert exc.value.retryable is True
