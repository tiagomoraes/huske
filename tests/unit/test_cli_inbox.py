"""`huske inbox add|process|status` and `huske import` through the Typer app."""

from __future__ import annotations

import json
from collections.abc import Iterator
from pathlib import Path
from typing import Any

import pytest
from typer.testing import CliRunner

from huske.cli import app
from huske.inbox import runner as inbox_runner
from huske.inbox.store import InboxLock

from ._inbox_fakes import FakeEngine, InlineWorker, install_fake_asr, tone, write_wav

STARTED = "2026-11-19T14:03:00-03:00"


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
    engine = FakeEngine()
    install_fake_asr(monkeypatch, engine)
    workers: list[InlineWorker] = []

    def make(_cfg: Any) -> InlineWorker:
        w = InlineWorker()
        workers.append(w)
        return w

    monkeypatch.setattr(inbox_runner, "make_worker", make)
    yield {
        "runner": CliRunner(),
        "config": str(config),
        "tmp": tmp_path,
        "engine": engine,
        "workers": workers,
        "clip": write_wav(tmp_path / "Reunião.wav", tone(3.0)),
    }


def _invoke(env: dict[str, Any], *args: str) -> tuple[int, Any]:
    result = env["runner"].invoke(app, [*args, "--config", env["config"]])
    try:
        payload = json.loads(result.stdout)
    except ValueError:
        payload = result.stdout
    return result.exit_code, payload


def test_add_json_is_idempotent(env: dict[str, Any]) -> None:
    code, first = _invoke(
        env, "inbox", "add", str(env["clip"]), "--id", "4E1C0A5B", "--origin", "phone",
        "--title", "Reunião com a Ana", "--device", "iPhone", "--started-at", STARTED,
        "--duration", "3", "--json",
    )
    assert code == 0
    assert first["created"] is True
    assert first["state"] == "queued"
    assert first["title"] == "Reunião com a Ana"
    assert first["origin"] == "phone"
    assert first["started_at"] == STARTED
    assert first["audio_file"] == "audio.wav"

    code, again = _invoke(env, "inbox", "add", str(env["clip"]), "--id", "4E1C0A5B", "--json")
    assert code == 0
    assert again["created"] is False
    assert again["added_at"] == first["added_at"]


def test_add_move(env: dict[str, Any]) -> None:
    code, payload = _invoke(env, "inbox", "add", str(env["clip"]), "--id", "m", "--move", "--json")
    assert code == 0 and payload["created"] is True
    assert not env["clip"].exists()


@pytest.mark.parametrize(
    "args",
    [
        ["--id", "../escape"],
        ["--origin", "cloud"],
        ["--started-at", "not-a-date"],
    ],
)
def test_add_validation_errors_exit_1(env: dict[str, Any], args: list[str]) -> None:
    code, payload = _invoke(env, "inbox", "add", str(env["clip"]), *args, "--json")
    assert code == 1
    assert "error" in payload


def test_add_missing_file_exits_1(env: dict[str, Any]) -> None:
    code, payload = _invoke(env, "inbox", "add", str(env["tmp"] / "nope.m4a"), "--json")
    assert code == 1 and "no such file" in payload["error"]


def test_status_lists_items_and_reports_unknown_ids(env: dict[str, Any]) -> None:
    _invoke(env, "inbox", "add", str(env["clip"]), "--id", "a", "--json")
    code, payload = _invoke(env, "inbox", "status", "--json")
    assert code == 0 and [i["id"] for i in payload["items"]] == ["a"]

    code, payload = _invoke(env, "inbox", "status", "a", "ghost", "--json")
    assert code == 0
    assert [(i["id"], i["state"]) for i in payload["items"]] == [("a", "queued"), ("ghost", "unknown")]

    code, text = _invoke(env, "inbox", "status")
    assert code == 0 and "queued" in text and "a" in text


def test_process_transcribes_and_reports(env: dict[str, Any]) -> None:
    _invoke(env, "inbox", "add", str(env["clip"]), "--id", "rec", "--started-at", STARTED, "--json")

    code, payload = _invoke(env, "inbox", "process", "--json")

    assert code == 0
    assert payload["deferred_to_engine"] is False
    [item] = payload["items"]
    assert item["id"] == "rec" and item["state"] == "done"
    assert len(item["transcripts"]) == 1 and Path(item["transcripts"][0]).exists()
    assert (env["tmp"] / "transcripts" / "README.md").exists()
    assert all(not w.alive for w in env["workers"])


def test_process_with_nothing_queued(env: dict[str, Any]) -> None:
    code, payload = _invoke(env, "inbox", "process", "--json")
    assert code == 0
    assert payload == {"deferred_to_engine": False, "items": []}
    assert env["workers"] == []


def test_process_defers_to_a_live_engine_holding_the_lock(env: dict[str, Any]) -> None:
    _invoke(env, "inbox", "add", str(env["clip"]), "--id", "rec", "--json")
    engine_lock = InboxLock(env["tmp"] / "inbox")
    assert engine_lock.try_acquire()
    try:
        code, payload = _invoke(env, "inbox", "process", "--json")
    finally:
        engine_lock.release()
    assert code == 0
    assert payload == {"deferred_to_engine": True, "items": []}
    assert env["workers"] == []
    code, status = _invoke(env, "inbox", "status", "rec", "--json")
    assert status["items"][0]["state"] == "queued"


def test_process_exits_2_when_an_item_fails(env: dict[str, Any]) -> None:
    env["engine"].fail_times = 99
    _invoke(env, "inbox", "add", str(env["clip"]), "--id", "rec", "--json")
    code, payload = _invoke(env, "inbox", "process", "--json")
    assert code == 2
    assert payload["items"][0]["state"] == "failed"
    assert payload["items"][0]["attempts"] == 1


def test_import_adds_and_processes(env: dict[str, Any]) -> None:
    other = write_wav(env["tmp"] / "second.wav", tone(2.0, freq=330.0))
    code, payload = _invoke(
        env, "import", str(env["clip"]), str(other), "--title", "Voice memo",
        "--started-at", STARTED, "--json",
    )
    assert code == 0
    assert payload["deferred_to_engine"] is False
    assert [i["state"] for i in payload["items"]] == ["done", "done"]
    assert all(i["origin"] == "file" and i["title"] == "Voice memo" for i in payload["items"])

    # Re-importing the same bytes is a no-op: no new transcripts.
    before = sorted((env["tmp"] / "transcripts").rglob("*.md"))
    code, again = _invoke(env, "import", str(env["clip"]), "--json")
    assert code == 0 and again["items"][0]["state"] == "done"
    assert sorted((env["tmp"] / "transcripts").rglob("*.md")) == before


def test_import_reports_bad_files_with_exit_1(env: dict[str, Any]) -> None:
    code, payload = _invoke(env, "import", str(env["clip"]), str(env["tmp"] / "nope.wav"), "--json")
    assert code == 1
    assert payload["items"][0]["state"] == "done"
    assert payload["errors"][0]["file"].endswith("nope.wav")


def test_config_set_and_show_inbox_root(env: dict[str, Any], tmp_path: Path) -> None:
    runner: CliRunner = env["runner"]
    result = runner.invoke(app, ["config", "set", "inbox_root", "~/somewhere/inbox", "--config", env["config"]])
    assert result.exit_code == 0, result.stdout
    result = runner.invoke(app, ["config", "show", "--json", "--config", env["config"]])
    effective = json.loads(result.stdout)["effective"]
    assert effective["inbox_root"] == str(Path("~/somewhere/inbox").expanduser())


def test_retry_requeues_a_failed_item(env: dict[str, Any]) -> None:
    env["engine"].fail_times = 99
    _invoke(env, "inbox", "add", str(env["clip"]), "--id", "rec", "--json")
    code, payload = _invoke(env, "inbox", "process", "--json")
    assert code == 2 and payload["items"][0]["state"] == "failed"

    code, payload = _invoke(env, "inbox", "retry", "rec", "nope", "--json")
    assert code == 1  # "nope" is unknown
    by_id = {i["id"]: i for i in payload["items"]}
    assert by_id["rec"]["retried"] is True
    assert by_id["rec"]["state"] == "queued" and by_id["rec"]["attempts"] == 0
    assert by_id["nope"]["state"] == "unknown"

    env["engine"].fail_times = 0
    code, payload = _invoke(env, "inbox", "process", "--json")
    assert code == 0 and payload["items"][0]["state"] == "done"

    # A done item is not retried.
    code, payload = _invoke(env, "inbox", "retry", "rec", "--json")
    assert code == 1 and payload["items"][0]["retried"] is False
