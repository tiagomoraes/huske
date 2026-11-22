"""The engine side of the Apple Intelligence bridge, against a fake helper.

The fake is a tiny Python script speaking the same JSON-line protocol as
``macos/Sources/HuskeAppleLLM``; no Foundation Models, no real model.
"""

from __future__ import annotations

import os
import stat
import sys
import textwrap
from pathlib import Path

import pytest

from huske.distill.apple import AppleBackend, find_helper, probe_apple
from huske.distill.client import DistillError

_FAKE = textwrap.dedent(
    """\
    #!{python}
    import json, sys, time
    MODE = {mode!r}
    def status():
        if MODE == "off":
            return {{"available": False, "reason": "not_enabled", "context_size": 4096}}
        return {{"available": True, "context_size": 8192, "locale_supported": True}}
    if "--status" in sys.argv:
        print(json.dumps({{"id": 0, "ok": True, **status()}}))
        sys.exit(0)
    for line in sys.stdin:
        req = json.loads(line)
        if req["op"] == "status":
            out = {{"id": req["id"], "ok": True, **status()}}
        elif MODE == "slow":
            time.sleep(5)
            continue
        elif MODE == "context":
            out = {{"id": req["id"], "ok": False, "error": "context", "message": "too long"}}
        elif MODE == "die":
            sys.exit(3)
        else:
            text = req["prompt"].replace("<transcript>", "").replace("</transcript>", "").strip()
            out = {{"id": req["id"], "ok": True, "text": text.upper()}}
        print(json.dumps(out), flush=True)
    """
)


def _helper(tmp_path: Path, mode: str = "ok") -> Path:
    path = tmp_path / f"huske-apple-llm-{mode}"
    path.write_text(_FAKE.format(python=sys.executable, mode=mode), encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)
    return path


def test_find_helper_prefers_the_env_override(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    helper = _helper(tmp_path)
    monkeypatch.setenv("HUSKE_APPLE_LLM_HELPER", str(helper))
    assert find_helper() == helper
    monkeypatch.setenv("HUSKE_APPLE_LLM_HELPER", str(tmp_path / "missing"))
    assert find_helper() is None


def test_probe_reports_availability_and_context(tmp_path: Path) -> None:
    status = probe_apple("pt", helper=_helper(tmp_path))
    assert status.available and status.context_size == 8192 and status.locale_supported


def test_probe_explains_unavailability_in_plain_words(tmp_path: Path) -> None:
    status = probe_apple(helper=_helper(tmp_path, "off"))
    assert not status.available
    assert status.reason == "not_enabled"
    assert "turned off" in status.detail
    assert status.hint and "System Settings" in status.hint


def test_probe_without_helper_says_where_it_lives(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    monkeypatch.setenv("HUSKE_APPLE_LLM_HELPER", str(tmp_path / "nope"))
    status = probe_apple()
    assert status.reason == "no_helper"
    assert "Huske.app" in status.detail


def test_backend_round_trip_and_reuses_one_process(tmp_path: Path) -> None:
    backend = AppleBackend(_helper(tmp_path))
    try:
        assert backend.complete("rules", "<transcript>\n[1] olá\n</transcript>", max_tokens=50) == "[1] OLÁ"
        pid = backend.pid
        assert backend.context_tokens == 8192
        assert backend.complete("rules", "[1] de novo", max_tokens=50) == "[1] DE NOVO"
        assert backend.pid == pid
    finally:
        backend.close()
    assert backend.pid is None


def test_backend_unavailable_model_is_a_setup_error(tmp_path: Path) -> None:
    backend = AppleBackend(_helper(tmp_path, "off"))
    try:
        with pytest.raises(DistillError) as info:
            backend.complete("rules", "x", max_tokens=10)
        assert info.value.kind == "config"
    finally:
        backend.close()


def test_backend_maps_helper_errors(tmp_path: Path) -> None:
    backend = AppleBackend(_helper(tmp_path, "context"))
    try:
        with pytest.raises(DistillError) as info:
            backend.complete("rules", "x", max_tokens=10)
        assert info.value.kind == "context"
    finally:
        backend.close()


def test_backend_times_out_and_recovers(tmp_path: Path) -> None:
    backend = AppleBackend(_helper(tmp_path, "slow"), timeout=0.5)
    try:
        with pytest.raises(DistillError) as info:
            backend.complete("rules", "x", max_tokens=10)
        assert info.value.kind == "timeout"
        assert backend.pid is None  # the stuck helper was stopped
    finally:
        backend.close()


def test_backend_survives_a_crashed_helper(tmp_path: Path) -> None:
    backend = AppleBackend(_helper(tmp_path, "die"))
    try:
        with pytest.raises(DistillError) as info:
            backend.complete("rules", "x", max_tokens=10)
        assert info.value.retryable
    finally:
        backend.close()


@pytest.mark.skipif(
    not os.environ.get("HUSKE_TEST_APPLE_HELPER"),
    reason="set HUSKE_TEST_APPLE_HELPER to a built huske-apple-llm to run against the real model",
)
def test_real_helper_cleans_up_synthetic_text() -> None:
    backend = AppleBackend(Path(os.environ["HUSKE_TEST_APPLE_HELPER"]))
    try:
        if not backend.status("pt").available:
            pytest.skip("Apple Intelligence unavailable on this Mac")
        out = backend.complete(
            "Fix punctuation and capitalization. Answer with the same [n] line.",
            "<transcript>\n[1] bom dia hoje a gente fala do kubernetes\n</transcript>",
            max_tokens=100,
        )
        assert "ubernetes" in out
    finally:
        backend.close()
