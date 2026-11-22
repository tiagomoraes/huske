"""`huske sync` output: what the user reads in the terminal and in Huske.app."""

from __future__ import annotations

import pytest

from huske.sync.client import SyncResult
from huske.sync.runner import _report


def test_first_connection_with_nothing_to_publish(capsys: pytest.CaptureFixture[str]) -> None:
    assert _report(SyncResult(changed=0, commit=None, pushed=False, total=0)) == 0
    assert "no transcripts to publish yet" in capsys.readouterr().out


def test_published_counts_split_new_and_updated(capsys: pytest.CaptureFixture[str]) -> None:
    result = SyncResult(changed=3, commit="0123456789abcdef", pushed=True, updated=1, total=9)
    assert _report(result) == 0
    assert "published 2 new and 1 updated transcript(s) in 0123456789" in capsys.readouterr().out


def test_conflicts_exit_non_zero_and_say_how_to_resolve(
    capsys: pytest.CaptureFixture[str],
) -> None:
    result = SyncResult(
        changed=1,
        commit="abc",
        pushed=True,
        total=2,
        conflicts=("transcripts/2026-07-30/090000_abcd1234_001.md",),
    )
    assert _report(result) == 1
    out = capsys.readouterr().out
    assert "transcripts/2026-07-30/090000_abcd1234_001.md" in out
    assert "huske sync --republish" in out


def test_remote_deletions_are_reported_but_not_an_error(
    capsys: pytest.CaptureFixture[str],
) -> None:
    paths = tuple(f"transcripts/2026-07-30/0{i}0000_abcd1234_001.md" for i in range(7))
    result = SyncResult(changed=0, commit=None, pushed=False, total=7, removed_remotely=paths)
    assert _report(result) == 0
    out = capsys.readouterr().out
    assert "7 transcript(s) were deleted from the repository" in out
    assert "… and 2 more" in out
