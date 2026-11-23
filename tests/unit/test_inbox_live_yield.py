"""A one-shot `huske inbox process` yields to a live `huske run` session.

Contract (inbox.md): the inbox must never load a second ASR model next to a
live one. Huske.app runs a one-shot pass whenever no session is recording; if
the user then starts recording a meeting, the pass must put its item back to
``queued`` (no attempt spent), stop its worker and exit "deferred", so the
live engine takes the inbox lock and transcribes it with its own model.
"""

from __future__ import annotations

import json
import os
import time
from collections.abc import Iterator
from pathlib import Path
from typing import Any

import numpy as np
import pytest
from typer.testing import CliRunner

from huske.cli import app
from huske.inbox import runner as inbox_runner
from huske.inbox.processor import LIVE_SESSION_CHECK_SECONDS

from ._inbox_fakes import FakeEngine, InlineWorker, install_fake_asr, silence, tone, write_wav

STARTED = "2026-11-19T14:03:00-03:00"


class _SessionStartsMidPass(FakeEngine):
    """Starts a "live session" (its lock file) while transcribing piece 1.

    Piece 1 then takes a little longer than the pass's check interval, as a
    real piece does, so the pass notices while it is in flight.
    """

    def __init__(self, session_dir: Path | None) -> None:
        super().__init__()
        self.session_dir = session_dir

    def transcribe(self, audio: np.ndarray) -> Any:
        if self.calls == 0 and self.session_dir is not None:
            self.session_dir.mkdir(parents=True, exist_ok=True)
            (self.session_dir / ".lock").write_text(str(os.getpid()), encoding="utf-8")
            time.sleep(LIVE_SESSION_CHECK_SECONDS + 0.5)
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
    session_dir = tmp_path / "audio" / "20261119T150000_live"
    engine = _SessionStartsMidPass(session_dir)
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
    yield {
        "runner": CliRunner(),
        "config": str(config),
        "tmp": tmp_path,
        "engine": engine,
        "workers": workers,
        "session_dir": session_dir,
        "long": write_wav(tmp_path / "long.wav", np.concatenate(parts)),
        "short": write_wav(tmp_path / "short.wav", tone(3.0)),
    }


def _invoke(env: dict[str, Any], *args: str) -> tuple[int, Any]:
    result = env["runner"].invoke(app, [*args, "--config", env["config"]])
    try:
        payload = json.loads(result.stdout)
    except ValueError:
        payload = result.stdout
    return result.exit_code, payload


def _status(env: dict[str, Any], item_id: str) -> dict[str, Any]:
    _, payload = _invoke(env, "inbox", "status", item_id, "--json")
    item: dict[str, Any] = payload["items"][0]
    return item


def test_one_shot_pass_yields_when_a_live_session_starts(env: dict[str, Any]) -> None:
    _invoke(env, "inbox", "add", str(env["long"]), "--id", "phone-a", "--started-at", STARTED, "--json")
    _invoke(env, "inbox", "add", str(env["short"]), "--id", "phone-b", "--started-at", STARTED, "--json")

    code, payload = _invoke(env, "inbox", "process", "--json")

    assert code == 0
    assert payload["deferred_to_engine"] is True
    # The live engine transcribes both; the pass spent no attempt on either.
    for item_id in ("phone-a", "phone-b"):
        item = _status(env, item_id)
        assert item["state"] == "queued", item
        assert item["attempts"] == 0, item
    assert env["engine"].calls == 1  # stopped after the piece in flight
    assert env["workers"] and all(not w.alive for w in env["workers"])


def test_one_shot_pass_defers_to_a_live_session_without_loading_a_model(
    env: dict[str, Any],
) -> None:
    _invoke(env, "inbox", "add", str(env["short"]), "--id", "phone-b", "--started-at", STARTED, "--json")
    env["session_dir"].mkdir(parents=True)
    (env["session_dir"] / ".lock").write_text(str(os.getpid()), encoding="utf-8")

    code, payload = _invoke(env, "inbox", "process", "--json")

    assert code == 0
    assert payload == {"deferred_to_engine": True, "items": []}
    assert env["workers"] == []
    assert _status(env, "phone-b")["state"] == "queued"


def test_a_stale_session_lock_does_not_block_the_pass(env: dict[str, Any]) -> None:
    _invoke(env, "inbox", "add", str(env["short"]), "--id", "phone-b", "--started-at", STARTED, "--json")
    env["session_dir"].mkdir(parents=True)
    # A crashed session's lock names a process that no longer exists.
    (env["session_dir"] / ".lock").write_text("999999", encoding="utf-8")
    env["engine"].session_dir = None  # nothing starts mid-pass

    code, payload = _invoke(env, "inbox", "process", "--json")

    assert code == 0
    assert payload["deferred_to_engine"] is False
    assert payload["items"][0]["state"] == "done"
