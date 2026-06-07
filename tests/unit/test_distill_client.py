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


def test_chat_posts_json_and_returns_content(monkeypatch: pytest.MonkeyPatch) -> None:
    captured: dict[str, Any] = {}

    def fake_urlopen(req: urllib.request.Request, **kwargs: Any) -> _FakeResponse:
        captured["url"] = req.full_url
        captured["method"] = req.get_method()
        captured["body"] = json.loads(req.data.decode("utf-8"))  # type: ignore[union-attr]
        return _FakeResponse(
            {"message": {"role": "assistant", "content": '{"statements": ["a claim"]}'}, "done": True}
        )

    monkeypatch.setattr(urllib.request, "urlopen", fake_urlopen)

    client = OllamaClient("http://127.0.0.1:11434/")
    out = client.chat("qwen3.5:0.8b", "hello", options={"temperature": 0.0})

    assert out == '{"statements": ["a claim"]}'
    # /api/chat (not /api/generate) — that's where Ollama honors top-level think.
    assert captured["url"] == "http://127.0.0.1:11434/api/chat"
    assert captured["method"] == "POST"
    assert captured["body"]["model"] == "qwen3.5:0.8b"
    assert captured["body"]["messages"] == [{"role": "user", "content": "hello"}]
    assert captured["body"]["stream"] is False
    assert captured["body"]["think"] is False  # non-reasoning by default
    assert captured["body"]["format"] == "json"  # json_format default
    assert captured["body"]["options"] == {"temperature": 0.0}


def test_chat_missing_content_raises(monkeypatch: pytest.MonkeyPatch) -> None:
    def fake_urlopen(req: urllib.request.Request, **kwargs: Any) -> _FakeResponse:
        return _FakeResponse({"done": True})  # no "message"

    monkeypatch.setattr(urllib.request, "urlopen", fake_urlopen)
    with pytest.raises(DistillError):
        OllamaClient("http://127.0.0.1:11434").chat("m", "p")


def test_chat_think_flag_is_forwarded(monkeypatch: pytest.MonkeyPatch) -> None:
    captured: dict[str, Any] = {}

    def fake_urlopen(req: urllib.request.Request, **kwargs: Any) -> _FakeResponse:
        captured["body"] = json.loads(req.data.decode("utf-8"))  # type: ignore[union-attr]
        return _FakeResponse({"message": {"content": "{}"}})

    monkeypatch.setattr(urllib.request, "urlopen", fake_urlopen)
    OllamaClient("http://127.0.0.1:11434").chat("m", "p", think=True)
    assert captured["body"]["think"] is True


def test_list_models_parses_tags(monkeypatch: pytest.MonkeyPatch) -> None:
    def fake_urlopen(req: urllib.request.Request, **kwargs: Any) -> _FakeResponse:
        assert req.full_url.endswith("/api/tags")
        assert req.get_method() == "GET"
        return _FakeResponse(
            {"models": [{"name": "qwen3.5:0.8b"}, {"name": "llama3.2:3b"}, {"bad": 1}]}
        )

    monkeypatch.setattr(urllib.request, "urlopen", fake_urlopen)
    names = OllamaClient("http://127.0.0.1:11434").list_models()
    assert names == ["qwen3.5:0.8b", "llama3.2:3b"]


def test_http_4xx_is_non_retryable(monkeypatch: pytest.MonkeyPatch) -> None:
    def fake_urlopen(req: urllib.request.Request, **kwargs: Any) -> _FakeResponse:
        raise urllib.error.HTTPError(
            req.full_url, 404, "Not Found", {}, io.BytesIO(b'{"error":"model not found"}')  # type: ignore[arg-type]
        )

    monkeypatch.setattr(urllib.request, "urlopen", fake_urlopen)
    with pytest.raises(DistillError) as exc:
        OllamaClient("http://127.0.0.1:11434").chat("nope", "p")
    assert exc.value.status == 404
    assert exc.value.retryable is False


def test_http_5xx_is_retryable(monkeypatch: pytest.MonkeyPatch) -> None:
    def fake_urlopen(req: urllib.request.Request, **kwargs: Any) -> _FakeResponse:
        raise urllib.error.HTTPError(req.full_url, 503, "Unavailable", {}, io.BytesIO(b""))  # type: ignore[arg-type]

    monkeypatch.setattr(urllib.request, "urlopen", fake_urlopen)
    with pytest.raises(DistillError) as exc:
        OllamaClient("http://127.0.0.1:11434").chat("m", "p")
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
