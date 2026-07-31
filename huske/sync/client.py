"""Dependency-free Git publisher for immutable transcript files.

The recording process never talks to a huske server. It maintains a dedicated
checkout, copies only ``YYYY-MM-DD/*.md`` transcripts into ``transcripts/``,
commits, and pushes through the user's normal Git authentication.

Git itself is the durable outbox: a commit that could not be pushed remains in
the managed checkout and the next reconciliation retries it. This removes the
old HTTP ingest token and SQLite acknowledgement database entirely.
"""

from __future__ import annotations

import hashlib
import os
import re
import shutil
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import TYPE_CHECKING, Protocol

if TYPE_CHECKING:
    from huske.config import RuntimeConfig

_TRANSCRIPT_RE = re.compile(
    r"^\d{4}-\d{2}-\d{2}/[A-Za-z0-9][A-Za-z0-9._-]*\.md$"
)


class SyncError(RuntimeError):
    """A Git sync operation failed without modifying the source transcripts."""

    def __init__(self, message: str, *, retryable: bool = True) -> None:
        super().__init__(message)
        self.retryable = retryable


@dataclass(frozen=True)
class SyncResult:
    changed: int
    commit: str | None
    pushed: bool


class TranscriptPublisher(Protocol):
    """Storage-provider boundary owned by the recording app."""

    def sync(self) -> SyncResult: ...


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(128 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def iter_transcripts(output_root: Path) -> list[Path]:
    """Return only canonical transcript Markdown files, in stable order."""
    if not output_root.exists() or output_root.is_symlink():
        return []
    paths: list[Path] = []
    for day in output_root.iterdir():
        if not day.is_dir() or day.is_symlink():
            continue
        for path in day.glob("*.md"):
            if (
                path.is_file()
                and not path.is_symlink()
                and path.name.lower() != "readme.md"
                and _TRANSCRIPT_RE.fullmatch(
                    path.relative_to(output_root).as_posix()
                )
            ):
                paths.append(path)
    return sorted(paths)


class GitPublisher:
    """Reconcile the authoritative transcript tree into a remote Git branch."""

    def __init__(
        self,
        *,
        output_root: Path,
        checkout_root: Path,
        remote: str,
        branch: str = "main",
        timeout: float = 60.0,
    ) -> None:
        self.output_root = output_root.expanduser().resolve()
        self.checkout_root = checkout_root.expanduser().resolve()
        self.remote = remote.strip()
        self.branch = branch
        self.timeout = timeout
        if not self.remote:
            raise ValueError("sync remote cannot be empty")
        if self.remote.startswith("-") or any(
            character in self.remote for character in ("\n", "\r", "\0")
        ):
            raise ValueError("sync remote is not a safe Git repository location")
        if self.checkout_root == self.output_root or (
            self.checkout_root.is_relative_to(self.output_root)
            or self.output_root.is_relative_to(self.checkout_root)
        ):
            raise ValueError("sync_root and output_root must not overlap")

    def sync(self) -> SyncResult:
        """Pull, copy immutable files, commit, and push.

        The managed checkout is the only directory this class mutates. Existing
        remote content is preserved, and a different file at an established
        transcript path is treated as a conflict instead of overwritten.
        """
        self._ensure_checkout()
        self._configure_identity()
        self._integrate_remote()

        changed = self._copy_new_transcripts()
        if changed:
            self._git("add", "--", "transcripts")
            self._git("commit", "-m", f"sync: add {changed} transcript(s)")

        if not self._has_unpushed_commits():
            return SyncResult(changed=changed, commit=None, pushed=False)

        # A second recording Mac may have won the race after our fetch. Rebase
        # once and retry the push; distinct immutable paths merge cleanly.
        pushed = self._push()
        commit = self._git("rev-parse", "HEAD").stdout.strip()
        return SyncResult(changed=changed, commit=commit, pushed=pushed)

    def _ensure_checkout(self) -> None:
        git_dir = self.checkout_root / ".git"
        if git_dir.is_dir():
            configured = self._git("remote", "get-url", "origin").stdout.strip()
            if configured != self.remote:
                raise SyncError(
                    "sync checkout points at a different remote; remove or move "
                    f"{self.checkout_root} before changing sync_remote",
                    retryable=False,
                )
            return

        if self.checkout_root.exists() and any(self.checkout_root.iterdir()):
            raise SyncError(
                f"sync_root is not empty and is not a Git checkout: {self.checkout_root}",
                retryable=False,
            )
        self.checkout_root.parent.mkdir(parents=True, exist_ok=True)
        result = self._run(
            "git",
            "clone",
            "--origin",
            "origin",
            "--no-checkout",
            "--",
            self.remote,
            str(self.checkout_root),
            cwd=self.checkout_root.parent,
            check=False,
        )
        if result.returncode != 0:
            # `git clone` may leave an incomplete directory. It is safe to
            # remove only when it still lacks .git; never erase a real checkout.
            if self.checkout_root.exists() and not git_dir.exists():
                shutil.rmtree(self.checkout_root)
            raise self._command_error(result)

    def _configure_identity(self) -> None:
        self._git("config", "user.name", "huske")
        self._git("config", "user.email", "sync@huske.local")

    def _integrate_remote(self) -> None:
        self._git("fetch", "--prune", "origin")
        remote_ref = f"refs/remotes/origin/{self.branch}"
        local_ref = f"refs/heads/{self.branch}"
        remote_exists = self._ref_exists(remote_ref)
        local_exists = self._ref_exists(local_ref)

        if local_exists:
            self._git("checkout", self.branch)
            if remote_exists:
                self._rebase_onto(f"origin/{self.branch}")
            return
        if remote_exists:
            self._git("checkout", "-b", self.branch, "--track", f"origin/{self.branch}")
            return
        # Empty repositories have no HEAD. Start the configured branch locally;
        # the first transcript commit will create the remote branch.
        self._git("checkout", "--orphan", self.branch)

    def _copy_new_transcripts(self) -> int:
        changed = 0
        target_root = self.checkout_root / "transcripts"
        for source in iter_transcripts(self.output_root):
            rel = source.relative_to(self.output_root)
            target = target_root / rel
            self._validate_target(target)
            if target.exists():
                if not target.is_file():
                    raise SyncError(
                        f"remote transcript path is not a file: "
                        f"transcripts/{rel.as_posix()}",
                        retryable=False,
                    )
                if sha256_file(source) != sha256_file(target):
                    raise SyncError(
                        f"immutable transcript conflict at transcripts/{rel.as_posix()}",
                        retryable=False,
                    )
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            fd, tmp_name = tempfile.mkstemp(
                dir=target.parent, prefix=".huske-sync-", suffix=".tmp"
            )
            try:
                with os.fdopen(fd, "wb") as stream:
                    stream.write(source.read_bytes())
                os.replace(tmp_name, target)
            except BaseException:
                Path(tmp_name).unlink(missing_ok=True)
                raise
            changed += 1
        return changed

    def _validate_target(self, target: Path) -> None:
        """Refuse remote symlinks before hashing or writing through them."""
        relative = target.relative_to(self.checkout_root)
        current = self.checkout_root
        for part in relative.parts:
            current /= part
            if current.is_symlink():
                raise SyncError(
                    f"remote sync path is a symlink: {relative.as_posix()}",
                    retryable=False,
                )
        if not target.resolve(strict=False).is_relative_to(self.checkout_root):
            raise SyncError(
                f"remote sync path escapes the managed checkout: {relative.as_posix()}",
                retryable=False,
            )

    def _push(self) -> bool:
        first = self._git(
            "push", "--set-upstream", "origin", self.branch, check=False
        )
        if first.returncode == 0:
            return True
        self._git("fetch", "origin", self.branch)
        self._rebase_onto(f"origin/{self.branch}")
        self._git("push", "--set-upstream", "origin", self.branch)
        return True

    def _has_unpushed_commits(self) -> bool:
        if self._git("rev-parse", "--verify", "HEAD", check=False).returncode != 0:
            return False
        remote_ref = f"refs/remotes/origin/{self.branch}"
        if not self._ref_exists(remote_ref):
            return True
        count = self._git(
            "rev-list", "--count", f"origin/{self.branch}..HEAD"
        ).stdout.strip()
        return int(count) > 0

    def _rebase_onto(self, upstream: str) -> None:
        result = self._git("rebase", upstream, check=False)
        if result.returncode == 0:
            return
        # Never strand the managed checkout in an in-progress rebase. The local
        # transcript commit remains the durable retry queue after abort.
        self._git("rebase", "--abort", check=False)
        error = self._command_error(result)
        raise SyncError(
            f"remote transcript conflict while rebasing: {error}",
            retryable=False,
        )

    def _ref_exists(self, ref: str) -> bool:
        return self._git("show-ref", "--verify", "--quiet", ref, check=False).returncode == 0

    def _git(
        self, *args: str, check: bool = True
    ) -> subprocess.CompletedProcess[str]:
        return self._run("git", *args, cwd=self.checkout_root, check=check)

    def _run(
        self, *args: str, cwd: Path, check: bool
    ) -> subprocess.CompletedProcess[str]:
        env = {
            **os.environ,
            "GIT_TERMINAL_PROMPT": "0",
            "LC_ALL": "C",
        }
        try:
            result = subprocess.run(
                args,
                cwd=cwd,
                env=env,
                text=True,
                capture_output=True,
                timeout=self.timeout,
                check=False,
            )
        except FileNotFoundError as exc:
            raise SyncError(
                "Git is not installed; install Xcode Command Line Tools (`xcode-select --install`)",
                retryable=False,
            ) from exc
        except subprocess.TimeoutExpired as exc:
            raise SyncError(f"Git command timed out after {self.timeout:g}s") from exc
        if check and result.returncode != 0:
            raise self._command_error(result)
        return result

    @staticmethod
    def _command_error(result: subprocess.CompletedProcess[str]) -> SyncError:
        detail = (result.stderr or result.stdout).strip().splitlines()
        message = _redact_remote(detail[-1]) if detail else f"Git exited {result.returncode}"
        lower = message.lower()
        retryable = not any(
            marker in lower
            for marker in (
                "authentication failed",
                "permission denied",
                "repository not found",
                "not a git repository",
            )
        )
        return SyncError(message, retryable=retryable)


def redact_remote(remote: str) -> str:
    """Hide HTTP userinfo before displaying a configured remote."""
    return _redact_remote(remote)


def _redact_remote(value: str) -> str:
    return re.sub(r"((?:https?|git)://)[^/@\s]+@", r"\1***@", value)


def build_publisher(config: RuntimeConfig) -> TranscriptPublisher:
    """Build the configured storage publisher without leaking it into callers."""
    if config.sync_provider == "git":
        if not config.sync_remote:
            raise ValueError("sync_remote is required for the Git sync provider")
        return GitPublisher(
            output_root=config.output_root,
            checkout_root=config.sync_root,
            remote=config.sync_remote,
            branch=config.sync_branch,
            timeout=config.sync_push_timeout_seconds,
        )
    raise ValueError(f"unsupported sync provider: {config.sync_provider}")
