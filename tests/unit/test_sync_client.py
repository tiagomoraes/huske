"""GitPublisher: immutable copy, commit/push, idempotence, and conflicts."""

from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

from huske.sync.client import GitPublisher, SyncError, iter_transcripts, redact_remote


def _git(cwd: Path, *args: str) -> str:
    return subprocess.run(
        ("git", *args), cwd=cwd, text=True, capture_output=True, check=True
    ).stdout.strip()


def _write(root: Path, name: str, text: str) -> Path:
    path = root / "2026-07-30" / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    return path


def test_publish_to_empty_remote_and_repeat_is_idempotent(tmp_path: Path) -> None:
    remote = tmp_path / "remote.git"
    output = tmp_path / "transcripts"
    checkout = tmp_path / "sync"
    _git(tmp_path, "init", "--bare", str(remote))
    _write(output, "090000_abcd1234_001.md", "hello")
    (output / "README.md").write_text("not synced")

    publisher = GitPublisher(
        output_root=output,
        checkout_root=checkout,
        remote=str(remote),
    )
    first = publisher.sync()
    assert first.changed == 1
    assert first.pushed
    assert (checkout / "transcripts/2026-07-30/090000_abcd1234_001.md").read_text() == "hello"
    assert not (checkout / "transcripts/README.md").exists()

    second = publisher.sync()
    assert second.changed == 0
    assert second.pushed is False

    verify = tmp_path / "verify"
    _git(tmp_path, "clone", "--branch", "main", str(remote), str(verify))
    assert (verify / "transcripts/2026-07-30/090000_abcd1234_001.md").read_text() == "hello"


def test_remote_conflict_never_overwrites(tmp_path: Path) -> None:
    remote = tmp_path / "remote.git"
    output = tmp_path / "transcripts"
    checkout = tmp_path / "sync"
    _git(tmp_path, "init", "--bare", str(remote))
    path = _write(output, "090000_abcd1234_001.md", "original")
    publisher = GitPublisher(
        output_root=output,
        checkout_root=checkout,
        remote=str(remote),
    )
    publisher.sync()
    path.write_text("changed locally", encoding="utf-8")

    with pytest.raises(SyncError, match="immutable transcript conflict"):
        publisher.sync()
    assert (checkout / "transcripts/2026-07-30/090000_abcd1234_001.md").read_text() == "original"


def test_iter_transcripts_accepts_only_contract_paths(tmp_path: Path) -> None:
    _write(tmp_path, "090000_abcd1234_001.md", "yes")
    (tmp_path / "misc").mkdir()
    (tmp_path / "misc/note.md").write_text("no")
    assert len(iter_transcripts(tmp_path)) == 1


def test_publisher_never_writes_through_remote_symlink(tmp_path: Path) -> None:
    output = tmp_path / "transcripts"
    checkout = tmp_path / "sync"
    outside = tmp_path / "outside"
    outside.mkdir()
    _write(output, "090000_abcd1234_001.md", "private")
    checkout.mkdir()
    (checkout / "transcripts").symlink_to(outside, target_is_directory=True)
    publisher = GitPublisher(
        output_root=output,
        checkout_root=checkout,
        remote="git@example.invalid:private/transcripts.git",
    )

    with pytest.raises(SyncError, match="symlink"):
        publisher._copy_new_transcripts()
    assert not list(outside.rglob("*"))


def test_source_and_managed_checkout_must_not_overlap(tmp_path: Path) -> None:
    with pytest.raises(ValueError, match="must not overlap"):
        GitPublisher(
            output_root=tmp_path,
            checkout_root=tmp_path / "sync",
            remote="git@example.invalid:private/transcripts.git",
        )


def test_remote_rejects_option_injection_and_redacts_http_credentials(
    tmp_path: Path,
) -> None:
    with pytest.raises(ValueError, match="safe Git repository"):
        GitPublisher(
            output_root=tmp_path / "transcripts",
            checkout_root=tmp_path / "sync",
            remote="--upload-pack=malicious",
        )
    assert (
        redact_remote("https://secret-token@github.com/example/private.git")
        == "https://***@github.com/example/private.git"
    )
