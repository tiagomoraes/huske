"""HTTP LLM backends against a fake transport — no network, synthetic text."""

from __future__ import annotations

import io
import json
import urllib.error
from typing import Any

import pytest

from huske.config import RuntimeConfig
from huske.distill.client import DistillError
from huske.distill.http_llm import AnthropicBackend, OpenAICompatibleBackend
from huske.distill.providers import consent_granted, resolve_target


class _Resp(io.BytesIO):
    def __enter__(self) -> _Resp:
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()


class FakeOpener:
    def __init__(self, *responses: Any) -> None:
        self.responses = list(responses)
        self.requests: list[Any] = []

    def __call__(self, req: Any, **kwargs: Any) -> _Resp:
        self.requests.append(req)
        item = self.responses.pop(0)
        if isinstance(item, Exception):
            raise item
        return _Resp(json.dumps(item).encode())

    def body(self, i: int = -1) -> dict[str, Any]:
        return json.loads(self.requests[i].data.decode())


def _http_error(code: int, message: str) -> urllib.error.HTTPError:
    payload = json.dumps({"error": {"message": message}}).encode()
    return urllib.error.HTTPError("http://x", code, "err", {}, io.BytesIO(payload))  # type: ignore[arg-type]


def _openai(opener: FakeOpener, **cfg: Any) -> OpenAICompatibleBackend:
    config = RuntimeConfig(distill_backend="openai", distill_model="gpt-test", **cfg)
    target = resolve_target(config)
    return OpenAICompatibleBackend(
        target, consented=consent_granted(target, config), api_key="sk-test-123456", opener=opener
    )


def _chat(text: str, finish: str = "stop") -> dict[str, Any]:
    return {"choices": [{"message": {"content": text}, "finish_reason": finish}]}


def test_cloud_target_without_consent_never_sends() -> None:
    opener = FakeOpener(_chat("[1] ok"))
    backend = _openai(opener)
    with pytest.raises(DistillError) as info:
        backend.complete("rules", "<transcript>\n[1] ok\n</transcript>", max_tokens=100)
    assert info.value.kind == "consent"
    assert opener.requests == []


def test_consent_for_another_host_does_not_count() -> None:
    opener = FakeOpener(_chat("[1] ok"))
    backend = _openai(opener, distill_cloud_consent="openrouter.ai")
    with pytest.raises(DistillError):
        backend.complete("rules", "x", max_tokens=100)
    assert opener.requests == []


def test_openai_request_shape_and_key_header() -> None:
    opener = FakeOpener(_chat("[1] Olá."))
    backend = _openai(opener, distill_cloud_consent="api.openai.com")
    assert backend.complete("rules", "prompt", max_tokens=100) == "[1] Olá."
    req = opener.requests[0]
    assert req.full_url == "https://api.openai.com/v1/chat/completions"
    assert req.get_header("Authorization") == "Bearer sk-test-123456"
    body = opener.body()
    assert body["model"] == "gpt-test"
    assert body["messages"][0] == {"role": "system", "content": "rules"}
    assert body["messages"][1] == {"role": "user", "content": "prompt"}
    assert body["temperature"] == 0


def test_rejected_optional_knobs_fall_back_to_a_bare_request() -> None:
    opener = FakeOpener(
        _http_error(400, "Unsupported value: 'temperature'"), _chat("[1] ok"), _chat("[1] ok")
    )
    backend = _openai(opener, distill_cloud_consent="api.openai.com")
    backend.complete("rules", "p", max_tokens=100)
    assert "temperature" not in opener.body(1)
    backend.complete("rules", "p", max_tokens=100)
    assert "temperature" not in opener.body(2)  # remembered
    assert len(opener.requests) == 3


@pytest.mark.parametrize(
    ("error", "kind"),
    [
        (_http_error(401, "bad key"), "auth"),
        (_http_error(429, "slow down"), "rate_limited"),
        (_http_error(400, "This model's maximum context length is 8192 tokens"), "context"),
        (_http_error(503, "overloaded"), "unavailable"),
        (urllib.error.URLError("connection refused"), "transport"),
        (TimeoutError(), "timeout"),
    ],
)
def test_errors_are_classified(error: Exception, kind: str) -> None:
    backend = _openai(FakeOpener(error), distill_cloud_consent="api.openai.com")
    with pytest.raises(DistillError) as info:
        backend.complete("rules", "p", max_tokens=100)
    assert info.value.kind == kind
    assert "sk-test-123456" not in str(info.value)


def test_truncated_and_refused_replies_are_errors() -> None:
    backend = _openai(
        FakeOpener(_chat("[1] meio", finish="length"), _chat("", finish="content_filter")),
        distill_cloud_consent="api.openai.com",
    )
    with pytest.raises(DistillError) as info:
        backend.complete("rules", "p", max_tokens=100)
    assert info.value.kind == "truncated"
    with pytest.raises(DistillError) as info:
        backend.complete("rules", "p", max_tokens=100)
    assert info.value.kind == "refused"


def test_local_server_needs_no_consent_and_picks_the_first_model() -> None:
    config = RuntimeConfig(distill_backend="openai_compatible", distill_endpoint="http://127.0.0.1:1234")
    target = resolve_target(config)
    assert target.endpoint == "http://127.0.0.1:1234/v1"
    assert not target.leaves_mac
    opener = FakeOpener({"data": [{"id": "qwen-local"}, {"id": "other"}]}, _chat("[1] ok"))
    backend = OpenAICompatibleBackend(target, consented=True, api_key=None, opener=opener)
    backend.complete("rules", "p", max_tokens=99)
    assert opener.requests[0].full_url == "http://127.0.0.1:1234/v1/models"
    assert opener.body(1)["model"] == "qwen-local"
    assert opener.body(1)["max_tokens"] == 99
    assert opener.requests[1].get_header("Authorization") is None


def test_remote_openai_compatible_endpoint_counts_as_leaving_the_mac() -> None:
    config = RuntimeConfig(
        distill_backend="openai_compatible", distill_endpoint="http://studio.local:1234/v1"
    )
    target = resolve_target(config)
    assert target.leaves_mac
    assert not consent_granted(target, config)
    allowed = config.model_copy(update={"distill_cloud_consent": "studio.local"})
    assert consent_granted(target, allowed)


def test_named_cloud_provider_ignores_a_stale_endpoint() -> None:
    config = RuntimeConfig(distill_backend="openai", distill_endpoint="http://127.0.0.1:11434")
    assert resolve_target(config).endpoint == "https://api.openai.com/v1"


def test_anthropic_request_shape_and_text_blocks() -> None:
    config = RuntimeConfig(distill_backend="anthropic", distill_cloud_consent="api.anthropic.com")
    target = resolve_target(config)
    assert target.model == "claude-haiku-5-5"
    reply = {
        "content": [{"type": "thinking", "thinking": ""}, {"type": "text", "text": "[1] Oi."}],
        "stop_reason": "end_turn",
    }
    opener = FakeOpener(reply)
    backend = AnthropicBackend(target, consented=True, api_key="sk-ant-test-123", opener=opener)
    assert backend.complete("rules", "prompt", max_tokens=300) == "[1] Oi."
    req = opener.requests[0]
    assert req.full_url == "https://api.anthropic.com/v1/messages"
    assert req.get_header("X-api-key") == "sk-ant-test-123"
    assert req.get_header("Anthropic-version") == "2023-06-01"
    body = opener.body()
    assert body["system"] == "rules"
    assert body["messages"] == [{"role": "user", "content": "prompt"}]
    assert body["max_tokens"] >= 300 + 2048
    assert "temperature" not in body


@pytest.mark.parametrize(("stop", "kind"), [("max_tokens", "truncated"), ("refusal", "refused")])
def test_anthropic_stop_reasons(stop: str, kind: str) -> None:
    config = RuntimeConfig(distill_backend="anthropic", distill_cloud_consent="api.anthropic.com")
    opener = FakeOpener({"content": [{"type": "text", "text": "[1] x"}], "stop_reason": stop})
    backend = AnthropicBackend(resolve_target(config), consented=True, api_key="k" * 10, opener=opener)
    with pytest.raises(DistillError) as info:
        backend.complete("rules", "p", max_tokens=10)
    assert info.value.kind == kind
