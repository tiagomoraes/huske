from __future__ import annotations

import subprocess
from pathlib import Path

from huske_mcp.replica import GitReplica


def git(cwd: Path, *args: str) -> str:
    return subprocess.run(
        ("git", *args), cwd=cwd, text=True, capture_output=True, check=True
    ).stdout.strip()


def test_clone_and_fast_forward_pull(tmp_path: Path) -> None:
    remote = tmp_path / "remote.git"
    source = tmp_path / "source"
    checkout = tmp_path / "replica"
    git(tmp_path, "init", "--bare", str(remote))
    git(tmp_path, "init", "-b", "main", str(source))
    git(source, "config", "user.name", "test")
    git(source, "config", "user.email", "test@example.invalid")
    (source / "transcripts").mkdir()
    (source / "transcripts" / "a.md").write_text("one")
    git(source, "add", ".")
    git(source, "commit", "-m", "one")
    git(source, "remote", "add", "origin", str(remote))
    git(source, "push", "-u", "origin", "main")

    replica = GitReplica(str(remote), checkout)
    first = replica.pull()
    assert first.after
    assert (checkout / "transcripts" / "a.md").read_text() == "one"

    (source / "transcripts" / "b.md").write_text("two")
    git(source, "add", ".")
    git(source, "commit", "-m", "two")
    git(source, "push")

    second = replica.pull()
    assert second.changed
    assert (checkout / "transcripts" / "b.md").read_text() == "two"
