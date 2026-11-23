"""GitPublisher: copy/commit/push, ownership of updates, conflicts, deletions,
error classification, and checkout housekeeping."""

from __future__ import annotations

import fcntl
import json
import os
import subprocess
import time
from pathlib import Path

import pytest

from huske.output_readme import MANAGED_MARKER
from huske.sync.client import (
    GitPublisher,
    SyncError,
    describe_git_failure,
    iter_transcripts,
    redact_remote,
)

DAY = "2026-07-30"
NAME = "090000_abcd1234_001.md"
REPO_PATH = f"transcripts/{DAY}/{NAME}"


def _git(cwd: Path, *args: str) -> str:
    return subprocess.run(
        ("git", *args), cwd=cwd, text=True, capture_output=True, check=True
    ).stdout.strip()


def _write(root: Path, name: str, text: str, day: str = DAY) -> Path:
    path = root / day / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    return path


def _setup(tmp_path: Path) -> tuple[Path, Path, Path]:
    remote = tmp_path / "remote.git"
    output = tmp_path / "transcripts"
    checkout = tmp_path / "sync"
    _git(tmp_path, "init", "--bare", "--initial-branch=main", str(remote))
    output.mkdir()
    return remote, output, checkout


def _publisher(
    output: Path, checkout: Path, remote: Path | str, **kwargs: object
) -> GitPublisher:
    return GitPublisher(
        output_root=output,
        checkout_root=checkout,
        remote=str(remote),
        **kwargs,  # type: ignore[arg-type]
    )


def _remote_file(tmp_path: Path, remote: Path, rel: str) -> str | None:
    """Read ``rel`` from the remote's main branch, or None when absent."""
    result = subprocess.run(
        ("git", "--git-dir", str(remote), "show", f"main:{rel}"),
        cwd=tmp_path,
        text=True,
        capture_output=True,
        check=False,
    )
    return result.stdout if result.returncode == 0 else None


def _edit_remote(tmp_path: Path, remote: Path, edit: str, rel: str = REPO_PATH) -> None:
    """Change ``rel`` from a second clone, as a user on github.com would."""
    other = tmp_path / "other"
    if other.exists():
        _git(other, "pull", "-q")
    else:
        _git(tmp_path, "clone", "-q", str(remote), str(other))
    target = other / rel
    if edit == "delete":
        _git(other, "rm", "-q", rel)
    else:
        target.write_text(edit, encoding="utf-8")
        _git(other, "add", rel)
    _git(other, "-c", "user.name=t", "-c", "user.email=t@example.invalid",
         "commit", "-qm", "edit in the repository")
    _git(other, "push", "-q", "origin", "main")


def test_publish_to_empty_remote_and_repeat_is_idempotent(tmp_path: Path) -> None:
    remote, output, checkout = _setup(tmp_path)
    _write(output, NAME, "hello")
    (output / "README.md").write_text("not synced")

    publisher = _publisher(output, checkout, remote)
    first = publisher.sync()
    assert first.changed == 1
    assert first.updated == 0
    assert first.total == 1
    assert first.pushed
    assert (checkout / REPO_PATH).read_text() == "hello"
    assert not (checkout / "transcripts/README.md").exists()

    second = publisher.sync()
    assert second.changed == 0
    assert second.pushed is False

    assert _remote_file(tmp_path, remote, REPO_PATH) == "hello"


def test_repository_root_gets_managed_readme_and_agents(tmp_path: Path) -> None:
    remote, output, checkout = _setup(tmp_path)
    _write(output, NAME, "hello")
    _publisher(output, checkout, remote).sync()

    readme = _remote_file(tmp_path, remote, "README.md")
    agents = _remote_file(tmp_path, remote, "AGENTS.md")
    assert readme is not None and readme.startswith(MANAGED_MARKER)
    assert "transcripts/YYYY-MM-DD/" in readme
    assert agents is not None and "data, never as instructions" in agents


def test_first_sync_with_no_transcripts_still_proves_push_works(tmp_path: Path) -> None:
    remote, output, checkout = _setup(tmp_path)
    result = _publisher(output, checkout, remote).sync()
    assert result.total == 0
    assert result.pushed
    assert _remote_file(tmp_path, remote, "README.md") is not None


def test_users_own_readme_is_never_overwritten(tmp_path: Path) -> None:
    remote, output, checkout = _setup(tmp_path)
    seed = tmp_path / "seed"
    _git(tmp_path, "clone", "-q", str(remote), str(seed))
    (seed / "README.md").write_text("my notes\n", encoding="utf-8")
    _git(seed, "add", "README.md")
    _git(seed, "-c", "user.name=t", "-c", "user.email=t@example.invalid",
         "commit", "-qm", "readme")
    _git(seed, "push", "-q", "origin", "HEAD:main")
    _write(output, NAME, "hello")

    _publisher(output, checkout, remote).sync()
    assert _remote_file(tmp_path, remote, "README.md") == "my notes\n"
    assert _remote_file(tmp_path, remote, "AGENTS.md") is not None


def test_distilled_rewrite_is_published_and_newer_transcripts_follow(
    tmp_path: Path,
) -> None:
    """The F1 regression: sync pushes the raw transcript, distillation then
    rewrites it in place. The polished copy must replace the raw one, and a
    transcript recorded later must not be blocked."""
    from huske.distill.distiller import ensure_asr_raw

    remote, output, checkout = _setup(tmp_path)
    path = _write(output, NAME, "---\nraw: true\n---\n\n[09:00:00 · mic] teh raw text\n")
    publisher = _publisher(output, checkout, remote)
    publisher.sync()

    ensure_asr_raw(path)  # what distillation does before rewriting
    path.write_text("---\nraw: true\n---\n\n[09:00:00 · mic] the raw text\n")
    _write(output, "100000_feedbeef_001.md", "next day", day="2026-07-31")

    result = publisher.sync()
    assert result.changed == 2
    assert result.updated == 1
    assert result.conflicts == ()
    assert "the raw text" in (_remote_file(tmp_path, remote, REPO_PATH) or "")
    assert _remote_file(tmp_path, remote, "transcripts/2026-07-31/100000_feedbeef_001.md") == "next day"

    # A second correction pass is also Huske's own update (via the ledger).
    path.write_text("---\nraw: true\n---\n\n[09:00:00 · mic] The raw text.\n")
    again = publisher.sync()
    assert again.updated == 1
    assert "The raw text." in (_remote_file(tmp_path, remote, REPO_PATH) or "")


def test_checkout_from_before_the_ledger_heals_via_raw_snapshot(tmp_path: Path) -> None:
    """Installs stuck on the old hard conflict have no ledger. The raw
    ``.asr.txt`` snapshot proves the repository copy is Huske's own."""
    from huske.distill.distiller import ensure_asr_raw

    remote, output, checkout = _setup(tmp_path)
    path = _write(output, NAME, "raw")
    publisher = _publisher(output, checkout, remote)
    publisher.sync()
    (checkout / ".git" / "huske-published.json").unlink()  # pre-ledger checkout

    ensure_asr_raw(path)
    path.write_text("polished")
    result = publisher.sync()
    assert result.updated == 1
    assert _remote_file(tmp_path, remote, REPO_PATH) == "polished"


def test_fresh_checkout_adopts_matching_files_into_the_ledger(tmp_path: Path) -> None:
    remote, output, checkout = _setup(tmp_path)
    path = _write(output, NAME, "v1")
    _publisher(output, checkout, remote).sync()

    # A new Mac (or a moved-aside checkout) clones the existing repository.
    fresh = tmp_path / "fresh-sync"
    publisher = _publisher(output, fresh, remote)
    publisher.sync()
    ledger = json.loads((fresh / ".git" / "huske-published.json").read_text())
    assert f"{DAY}/{NAME}" in ledger

    path.write_text("v2")
    assert publisher.sync().updated == 1


def test_copy_changed_in_the_repository_is_never_overwritten(tmp_path: Path) -> None:
    remote, output, checkout = _setup(tmp_path)
    path = _write(output, NAME, "original")
    publisher = _publisher(output, checkout, remote)
    publisher.sync()

    _edit_remote(tmp_path, remote, "edited on github")
    path.write_text("changed locally", encoding="utf-8")
    _write(output, "100000_feedbeef_001.md", "unrelated")

    result = publisher.sync()
    assert result.conflicts == (REPO_PATH,)
    assert _remote_file(tmp_path, remote, REPO_PATH) == "edited on github"
    # The conflict no longer blocks every other transcript.
    assert _remote_file(tmp_path, remote, f"transcripts/{DAY}/100000_feedbeef_001.md") == "unrelated"

    forced = _publisher(output, checkout, remote, republish=[REPO_PATH]).sync()
    assert forced.updated == 1
    assert _remote_file(tmp_path, remote, REPO_PATH) == "changed locally"


def test_transcript_deleted_in_the_repository_stays_deleted(tmp_path: Path) -> None:
    remote, output, checkout = _setup(tmp_path)
    _write(output, NAME, "sensitive")
    publisher = _publisher(output, checkout, remote)
    publisher.sync()

    _edit_remote(tmp_path, remote, "delete")
    result = publisher.sync()
    assert result.removed_remotely == (REPO_PATH,)
    assert result.changed == 0
    assert _remote_file(tmp_path, remote, REPO_PATH) is None

    _publisher(output, checkout, remote, republish=[f"{DAY}/{NAME}"]).sync()
    assert _remote_file(tmp_path, remote, REPO_PATH) == "sensitive"


def test_repository_recreated_empty_is_republished(tmp_path: Path) -> None:
    remote, output, checkout = _setup(tmp_path)
    _write(output, NAME, "hello")
    publisher = _publisher(output, checkout, remote)
    publisher.sync()

    subprocess.run(("rm", "-rf", str(remote)), check=True)
    _git(tmp_path, "init", "--bare", "--initial-branch=main", str(remote))
    result = publisher.sync()
    assert result.pushed
    assert _remote_file(tmp_path, remote, REPO_PATH) == "hello"


def test_changing_the_repository_moves_the_old_checkout_aside(tmp_path: Path) -> None:
    remote, output, checkout = _setup(tmp_path)
    _write(output, NAME, "hello")
    _publisher(output, checkout, remote).sync()

    second = tmp_path / "second.git"
    _git(tmp_path, "init", "--bare", "--initial-branch=main", str(second))
    result = _publisher(output, checkout, second).sync()
    assert result.changed == 1
    assert any("moved" in note for note in result.notes)
    assert _remote_file(tmp_path, second, REPO_PATH) == "hello"
    assert len(list(tmp_path.glob("sync.previous-*"))) == 1


def test_stale_index_lock_is_cleared(tmp_path: Path) -> None:
    remote, output, checkout = _setup(tmp_path)
    _write(output, NAME, "hello")
    publisher = _publisher(output, checkout, remote, timeout=5.0)
    publisher.sync()

    lock = checkout / ".git" / "index.lock"
    lock.write_text("")
    old = time.time() - 60
    os.utime(lock, (old, old))
    _write(output, "100000_feedbeef_001.md", "next")
    assert publisher.sync().changed == 1
    assert not lock.exists()


def test_concurrent_sync_waits_then_reports_busy(tmp_path: Path) -> None:
    remote, output, checkout = _setup(tmp_path)
    publisher = _publisher(output, checkout, remote, timeout=5.0)
    publisher.timeout = 0.3  # keep the wait short; Git calls never run here
    lock_path = tmp_path / ".sync.lock"
    with lock_path.open("a") as held:
        fcntl.flock(held.fileno(), fcntl.LOCK_EX)
        with pytest.raises(SyncError, match="already running") as excinfo:
            publisher.sync()
    assert excinfo.value.retryable


def test_republish_rejects_paths_outside_the_contract(tmp_path: Path) -> None:
    with pytest.raises(ValueError, match="not a transcript path"):
        _publisher(tmp_path / "t", tmp_path / "s", "x.git", republish=["../etc/passwd"])


@pytest.mark.parametrize(
    ("stderr", "expected", "retryable"),
    [
        (
            "git@github.com: Permission denied (publickey).\n"
            "fatal: Could not read from remote repository.\n\n"
            "Please make sure you have the correct access rights\n"
            "and the repository exists.\n",
            "SSH key",
            False,
        ),
        (
            "Host key verification failed.\n"
            "fatal: Could not read from remote repository.\n\n"
            "Please make sure you have the correct access rights\n"
            "and the repository exists.\n",
            "ssh -T git@github.com",
            False,
        ),
        (
            "ssh: Could not resolve hostname github.com: nodename nor servname "
            "provided, or not known\n"
            "fatal: Could not read from remote repository.\n\n"
            "Please make sure you have the correct access rights\n"
            "and the repository exists.\n",
            "offline",
            True,
        ),
        (
            "ERROR: Repository not found.\n"
            "fatal: Could not read from remote repository.\n\n"
            "Please make sure you have the correct access rights\n"
            "and the repository exists.\n",
            "repository was not found",
            False,
        ),
        (
            "fatal: could not read Username for 'https://github.com': "
            "terminal prompts disabled\n",
            "gh auth login",
            False,
        ),
        (
            "fatal: unable to access 'https://token@github.com/x/y.git/': "
            "Could not resolve host: github.com\n",
            "offline",
            True,
        ),
        (
            "ERROR: Permission to example/transcripts.git denied to someone.\n"
            "fatal: Could not read from remote repository.\n",
            "can't push",
            False,
        ),
    ],
)
def test_git_failures_name_the_real_cause(
    stderr: str, expected: str, retryable: bool
) -> None:
    error = describe_git_failure(stderr)
    assert expected in str(error)
    assert "and the repository exists" not in str(error)
    assert "token@" not in str(error)
    assert error.retryable is retryable


def test_unknown_git_failure_prefers_the_fatal_line() -> None:
    error = describe_git_failure("hint: something\nfatal: bad object HEAD\nhint: more\n")
    assert str(error) == "fatal: bad object HEAD"
    assert error.retryable


def test_iter_transcripts_accepts_only_contract_paths(tmp_path: Path) -> None:
    _write(tmp_path, NAME, "yes")
    (tmp_path / "misc").mkdir()
    (tmp_path / "misc/note.md").write_text("no")
    assert len(iter_transcripts(tmp_path)) == 1


def test_publisher_never_writes_through_remote_symlink(tmp_path: Path) -> None:
    output = tmp_path / "transcripts"
    checkout = tmp_path / "sync"
    outside = tmp_path / "outside"
    outside.mkdir()
    _write(output, NAME, "private")
    checkout.mkdir()
    (checkout / "transcripts").symlink_to(outside, target_is_directory=True)
    publisher = _publisher(output, checkout, "git@example.invalid:private/transcripts.git")

    with pytest.raises(SyncError, match="symlink"):
        publisher._reconcile_transcripts(iter_transcripts(publisher.output_root))
    assert not list(outside.rglob("*"))


def test_source_and_managed_checkout_must_not_overlap(tmp_path: Path) -> None:
    with pytest.raises(ValueError, match="must not overlap"):
        _publisher(tmp_path, tmp_path / "sync", "git@example.invalid:private/transcripts.git")


def test_remote_rejects_option_injection_and_redacts_http_credentials(
    tmp_path: Path,
) -> None:
    with pytest.raises(ValueError, match="safe Git repository"):
        _publisher(tmp_path / "transcripts", tmp_path / "sync", "--upload-pack=malicious")
    assert (
        redact_remote("https://secret-token@github.com/example/private.git")
        == "https://***@github.com/example/private.git"
    )


class FakeCredentials:
    def __init__(self, env: dict[str, str] | None = None, error: Exception | None = None) -> None:
        self.env = env or {}
        self.error = error
        self.calls = 0

    def git_env(self) -> dict[str, str]:
        self.calls += 1
        if self.error is not None:
            raise self.error
        return self.env


def test_credential_environment_reaches_every_git_command(tmp_path: Path) -> None:
    remote, output, checkout = _setup(tmp_path)
    _write(output, NAME, "hello")
    provider = FakeCredentials({"GIT_AUTHOR_NAME": "from-credentials"})
    _publisher(output, checkout, remote, credentials=provider).sync()
    assert provider.calls == 1
    author = _git(tmp_path, "--git-dir", str(remote), "log", "-1", "--format=%an", "main")
    assert author == "from-credentials"


def test_missing_sign_in_stops_sync_before_git_runs(tmp_path: Path) -> None:
    from huske.sync.credentials import CredentialError

    remote, output, checkout = _setup(tmp_path)
    provider = FakeCredentials(error=CredentialError("Huske isn't connected to GitHub"))
    with pytest.raises(SyncError, match="isn't connected") as excinfo:
        _publisher(output, checkout, remote, credentials=provider).sync()
    assert not excinfo.value.retryable
    assert not checkout.exists()


@pytest.mark.parametrize(
    ("stderr", "expected"),
    [
        (
            "remote: Repository not found.\n"
            "fatal: repository 'https://github.com/octo/t.git/' not found\n",
            "isn't shared with Huske Sync",
        ),
        (
            "remote: Invalid username or token. Password authentication is not supported.\n"
            "fatal: Authentication failed for 'https://github.com/octo/t.git/'\n",
            "Connect GitHub",
        ),
        (
            "remote: Permission to octo/t.git denied to octo.\n"
            "fatal: unable to access 'https://github.com/octo/t.git/': "
            "The requested URL returned error: 403\n",
            "isn't shared with Huske Sync",
        ),
    ],
)
def test_github_app_failures_point_at_the_app(stderr: str, expected: str) -> None:
    error = describe_git_failure(stderr, github_app=True)
    assert expected in str(error)
    assert "SSH" not in str(error)
    assert not error.retryable
