"""SIGTERM stops a one-shot `huske inbox process` cleanly.

Huske.app's watchdog stops a pass with SIGTERM. Python's default for it ends
the process on the spot — no ``finally`` — so the item in progress stayed
``processing`` (the phone showed "Transcribing · 1 of 3" until the next pass
recovered it, at the cost of an attempt) and the ASR worker was orphaned.

The pass now stops the way it yields to a live session: the item goes back to
``queued`` with its attempt unspent, the worker is shut down, and the exit
status says it was terminated.
"""

from __future__ import annotations

import json
import os
import signal
import time
from collections.abc import Iterator
from pathlib import Path
from typing import Any

import numpy as np
import pytest
from typer.testing import CliRunner

from huske.cli import app
from huske.inbox import runner as inbox_runner

from ._inbox_fakes import FakeEngine, InlineWorker, install_fake_asr, silence, tone, write_wav

STARTED = "2026-11-19T14:03:00-03:00"


class _TerminatedWhileTranscribing(FakeEngine):
    """Sends this process SIGTERM while piece 1 is being transcribed.

    The piece then takes longer than the pass's 0.25 s poll, as a real piece
    (minutes) does, so the pass notices while it is still in flight.
    """

    def __init__(self) -> None:
        super().__init__()
        self.armed = True

    def transcribe(self, audio: np.ndarray) -> Any:
        if self.armed and self.calls == 0:
            os.kill(os.getpid(), signal.SIGTERM)
            time.sleep(0.6)
        return super().transcribe(audio)


@pytest.fixture
def env(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Iterator[dict[str, Any]]:
    monkeypatch.setattr("huske.update_check.notify_if_outdated", lambda: None)
    config = tmp_path / "config.toml"
    config.write_text(
        "\n".join(
            [
                f'output_root = "{tmp_path / "transcripts"}"',
                f'audio_root = "{tmp_path / "audio"}"',
                f'logs_root = "{tmp_path / "logs"}"',
                f'inbox_root = "{tmp_path / "inbox"}"',
                "chunk_minutes = 1.0",
            ]
        )
        + "\n"
    )
    engine = _TerminatedWhileTranscribing()
    install_fake_asr(monkeypatch, engine)
    workers: list[InlineWorker] = []

    def make(_cfg: Any) -> InlineWorker:
        w = InlineWorker()
        workers.append(w)
        return w

    monkeypatch.setattr(inbox_runner, "make_worker", make)
    parts = []
    for i in range(10):  # 150 s of speech → three pieces at chunk_minutes=1
        parts += [tone(13.0, freq=200.0 + 20 * i), silence(2.0)]

    # Safety net: if the pass did not take the signal, it must fail this test,
    # not kill the test runner.
    leaked: list[int] = []

    def fallback(signum: int, _frame: Any) -> None:
        leaked.append(signum)

    original = signal.signal(signal.SIGTERM, fallback)
    try:
        yield {
            "runner": CliRunner(),
            "config": str(config),
            "tmp": tmp_path,
            "engine": engine,
            "workers": workers,
            "leaked": leaked,
            "fallback": fallback,
            "long": write_wav(tmp_path / "long.wav", np.concatenate(parts)),
            "short": write_wav(tmp_path / "short.wav", tone(3.0)),
        }
    finally:
        signal.signal(signal.SIGTERM, original)


def _invoke(env: dict[str, Any], *args: str) -> tuple[int, Any]:
    result = env["runner"].invoke(app, [*args, "--config", env["config"]])
    try:
        payload = json.loads(result.stdout)
    except ValueError:
        payload = result.stdout
    return result.exit_code, payload


def _status_file(env: dict[str, Any], item_id: str) -> dict[str, Any]:
    path = env["tmp"] / "inbox" / item_id / "status.json"
    status: dict[str, Any] = json.loads(path.read_text(encoding="utf-8"))
    return status


def test_sigterm_requeues_the_item_in_progress_without_spending_an_attempt(
    env: dict[str, Any],
) -> None:
    _invoke(env, "inbox", "add", str(env["long"]), "--id", "phone-a", "--started-at", STARTED, "--json")
    _invoke(env, "inbox", "add", str(env["short"]), "--id", "phone-b", "--started-at", STARTED, "--json")

    code, payload = _invoke(env, "inbox", "process", "--json")

    assert code == inbox_runner.EXIT_TERMINATED == 143
    assert payload["interrupted"] is True
    assert payload["deferred_to_engine"] is False
    assert [i["id"] for i in payload["items"]] == ["phone-a"]
    assert payload["items"][0]["state"] == "queued"

    # What Huske.app polls: never left at `processing`, and no attempt spent.
    on_disk = _status_file(env, "phone-a")
    assert on_disk["state"] == "queued", on_disk
    assert on_disk["attempts"] == 0, on_disk
    assert on_disk["chunks_done"] == 0 and on_disk["chunks_total"] == 0, on_disk
    assert on_disk["transcripts"] == [] and on_disk["error"] is None, on_disk
    assert "chunk_progress" not in on_disk
    assert not (env["tmp"] / "inbox" / "phone-a" / "work").exists()
    untouched = _status_file(env, "phone-b")
    assert untouched["state"] == "queued" and untouched["attempts"] == 0, untouched

    assert env["engine"].calls == 1, "stopped after the piece in flight"
    assert env["workers"] and all(not w.alive for w in env["workers"]), "worker left running"
    assert env["leaked"] == [], "the pass did not handle SIGTERM itself"
    assert signal.getsignal(signal.SIGTERM) is env["fallback"], "the caller's handler was not restored"

    # The next pass picks both up as if nothing had happened.
    env["engine"].armed = False
    code, payload = _invoke(env, "inbox", "process", "--json")

    assert code == 0
    assert "interrupted" not in payload
    assert {i["id"]: i["state"] for i in payload["items"]} == {"phone-a": "done", "phone-b": "done"}
    assert _status_file(env, "phone-a")["attempts"] == 1
    assert len(_status_file(env, "phone-a")["transcripts"]) == 3


def test_sigterm_also_stops_huske_import(env: dict[str, Any]) -> None:
    code, payload = _invoke(env, "import", str(env["long"]), "--started-at", STARTED, "--json")

    assert code == inbox_runner.EXIT_TERMINATED
    assert payload["interrupted"] is True
    assert [i["state"] for i in payload["items"]] == ["queued"]
    assert payload["items"][0]["attempts"] == 0
    assert all(not w.alive for w in env["workers"])
    assert env["leaked"] == []


def test_the_termination_watch_restores_the_previous_handler() -> None:
    seen: list[int] = []

    def previous(signum: int, _frame: Any) -> None:
        seen.append(signum)

    original = signal.signal(signal.SIGTERM, previous)
    try:
        with inbox_runner._TerminationWatch() as watch:
            assert watch.requested is False
            os.kill(os.getpid(), signal.SIGTERM)
            deadline = time.monotonic() + 5.0
            while not watch.requested and time.monotonic() < deadline:
                time.sleep(0.01)
            assert watch.requested is True
        assert seen == [], "the signal reached the outer handler while the pass was watching"
        assert signal.getsignal(signal.SIGTERM) is previous
    finally:
        signal.signal(signal.SIGTERM, original)
