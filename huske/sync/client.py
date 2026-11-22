"""Dependency-free Git publisher for transcript files.

The recording process never talks to a huske server. It maintains a dedicated
checkout, copies only ``YYYY-MM-DD/*.md`` transcripts into ``transcripts/``,
commits, and pushes through the user's normal Git authentication.

Git itself is the durable outbox: a commit that could not be pushed remains in
the managed checkout and the next reconciliation retries it. This removes the
old HTTP ingest token and SQLite acknowledgement database entirely.

Ownership. A transcript can change after it was published — distillation
rewrites the canonical ``.md`` in place. The publisher keeps a ledger, inside
the checkout's ``.git`` directory and never committed, of the content it last
published for each path. A repository copy that matches the ledger (or the raw
``.asr.txt`` snapshot distillation keeps, which heals checkouts that predate
the ledger) is Huske's own and is updated. Anything else at that path was
written by someone else: it is reported as a conflict and never overwritten.
A path Huske published that later disappears from the repository was deleted
there on purpose, so it is not published again.
"""

from __future__ import annotations

import contextlib
import fcntl
import hashlib
import json
import os
import re
import shutil
import subprocess
import tempfile
import time
from collections.abc import Iterable, Iterator
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import TYPE_CHECKING, Protocol

from huske.output_readme import render_agents, render_repo_readme, write_managed
from huske.paths import asr_raw_path

if TYPE_CHECKING:
    from huske.config import RuntimeConfig

_TRANSCRIPT_RE = re.compile(
    r"^\d{4}-\d{2}-\d{2}/[A-Za-z0-9][A-Za-z0-9._-]*\.md$"
)
_LEDGER_NAME = "huske-published.json"
# Repository-root docs Huske keeps current (README for people and chat
# connectors, AGENTS.md for coding agents). Never written over a user's file.
_REPO_DOCS = ("README.md", "AGENTS.md")


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
    #: Of ``changed``, how many replaced a copy Huske published earlier.
    updated: int = 0
    #: Local transcripts considered (contract paths under ``output_root``).
    total: int = 0
    #: Repository paths holding a copy Huske did not publish; left untouched.
    conflicts: tuple[str, ...] = ()
    #: Paths Huske published that were later deleted from the repository.
    removed_remotely: tuple[str, ...] = ()
    #: Human-readable notes about housekeeping done during this run.
    notes: tuple[str, ...] = ()


class TranscriptPublisher(Protocol):
    """Storage-provider boundary owned by the recording app."""

    def sync(self) -> SyncResult: ...


@dataclass
class _Reconciliation:
    added: int = 0
    updated: int = 0
    conflicts: list[str] = field(default_factory=list)
    removed_remotely: list[str] = field(default_factory=list)


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
        republish: Iterable[str] = (),
    ) -> None:
        self.output_root = output_root.expanduser().resolve()
        self.checkout_root = checkout_root.expanduser().resolve()
        self.remote = remote.strip()
        self.branch = branch
        self.timeout = timeout
        # Paths the user explicitly asked to publish again from this Mac, even
        # though the repository copy differs or was deleted there.
        self.republish = frozenset(_transcript_rel(path) for path in republish)
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
        """Pull, copy new or updated transcripts, commit, and push.

        The managed checkout is the only directory this class mutates. Remote
        content Huske did not publish is never overwritten; it is reported.
        One publisher runs at a time per checkout, across processes (the
        engine's worker and ``huske sync`` from the app share the checkout).
        """
        with self._exclusive():
            notes: list[str] = []
            moved = self._ensure_checkout()
            if moved is not None:
                notes.append(
                    "The repository changed, so the previous checkout was moved "
                    f"to {moved}"
                )
            self._clear_stale_index_lock()
            self._configure_identity()
            self._integrate_remote()

            sources = iter_transcripts(self.output_root)
            outcome = self._reconcile_transcripts(sources)
            docs = self._write_repo_docs()
            changed = outcome.added + outcome.updated
            if changed or docs:
                staged = [
                    name
                    for name in ("transcripts", *_REPO_DOCS)
                    if (self.checkout_root / name).exists()
                ]
                self._git("add", "--", *staged)
                self._git("commit", "-m", _commit_message(outcome, docs))

            pushed = False
            commit: str | None = None
            if self._has_unpushed_commits():
                # A second recording Mac may have won the race after our fetch.
                # Rebase once and retry the push; distinct paths merge cleanly.
                pushed = self._push()
                commit = self._git("rev-parse", "HEAD").stdout.strip()
            return SyncResult(
                changed=changed,
                commit=commit,
                pushed=pushed,
                updated=outcome.updated,
                total=len(sources),
                conflicts=tuple(outcome.conflicts),
                removed_remotely=tuple(outcome.removed_remotely),
                notes=tuple(notes),
            )

    # -- checkout lifecycle -------------------------------------------------

    @contextlib.contextmanager
    def _exclusive(self) -> Iterator[None]:
        """Hold a cross-process lock beside the checkout for one sync run."""
        lock_path = self.checkout_root.with_name(f".{self.checkout_root.name}.lock")
        lock_path.parent.mkdir(parents=True, exist_ok=True)
        with lock_path.open("a") as handle:
            deadline = time.monotonic() + self.timeout
            while True:
                try:
                    fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if time.monotonic() >= deadline:
                        raise SyncError(
                            "another Huske sync is already running"
                        ) from None
                    time.sleep(0.1)
            try:
                yield
            finally:
                fcntl.flock(handle.fileno(), fcntl.LOCK_UN)

    def _ensure_checkout(self) -> Path | None:
        """Clone on first use. Returns where an old checkout was moved, if any."""
        git_dir = self.checkout_root / ".git"
        moved: Path | None = None
        if git_dir.is_dir():
            configured = self._git("remote", "get-url", "origin").stdout.strip()
            if configured == self.remote:
                return None
            # The user pointed sync at another repository. The checkout is a
            # cache of the remote (the transcripts live in output_root), so set
            # it aside rather than deleting it, then clone the new remote.
            stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
            moved = self.checkout_root.with_name(
                f"{self.checkout_root.name}.previous-{stamp}"
            )
            self.checkout_root.rename(moved)

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
        return moved

    def _clear_stale_index_lock(self) -> None:
        """Remove an ``index.lock`` left behind by a Git process that died.

        Only Huske uses this checkout and the cross-process lock is held, so a
        lock file older than one Git timeout cannot belong to a live command.
        """
        lock = self.checkout_root / ".git" / "index.lock"
        try:
            age = time.time() - lock.stat().st_mtime
        except FileNotFoundError:
            return
        if age > self.timeout:
            lock.unlink(missing_ok=True)

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

    # -- reconciliation -----------------------------------------------------

    def _reconcile_transcripts(self, sources: list[Path]) -> _Reconciliation:
        """Bring the checkout's ``transcripts/`` in line with ``output_root``.

        Per path, with the ledger recording what Huske last published:

        - absent remotely, never published → add;
        - absent remotely, published before → deleted there; leave it out;
        - identical → nothing (and adopt it into the ledger);
        - remote copy is Huske's own (ledger or ``.asr.txt``) → update;
        - anything else → conflict; never overwritten.

        A path in ``republish`` is the user's explicit decision: it is added or
        overwritten with this Mac's copy regardless of the two exceptions.
        """
        outcome = _Reconciliation()
        ledger = self._load_ledger()
        ledger_dirty = False
        target_root = self.checkout_root / "transcripts"
        for source in sources:
            rel = source.relative_to(self.output_root).as_posix()
            repo_path = f"transcripts/{rel}"
            target = target_root / rel
            self._validate_target(target)
            local_sha = sha256_file(source)

            forced = rel in self.republish

            if not target.exists():
                if rel in ledger and not forced:
                    outcome.removed_remotely.append(repo_path)
                    continue
                self._copy_atomic(source, target)
                ledger[rel] = local_sha
                ledger_dirty = True
                outcome.added += 1
                continue

            if not target.is_file():
                raise SyncError(
                    f"remote transcript path is not a file: {repo_path}",
                    retryable=False,
                )
            remote_sha = sha256_file(target)
            if remote_sha == local_sha:
                if ledger.get(rel) != local_sha:
                    ledger[rel] = local_sha
                    ledger_dirty = True
                continue
            if (
                forced
                or remote_sha == ledger.get(rel)
                or remote_sha == _raw_snapshot_sha(source)
            ):
                self._copy_atomic(source, target)
                ledger[rel] = local_sha
                ledger_dirty = True
                outcome.updated += 1
                continue
            outcome.conflicts.append(repo_path)

        if ledger_dirty:
            self._save_ledger(ledger)
        return outcome

    def _write_repo_docs(self) -> int:
        """Keep README.md and AGENTS.md at the repository root current."""
        written = 0
        for name, content in (
            ("README.md", render_repo_readme()),
            ("AGENTS.md", render_agents(prefix="transcripts/")),
        ):
            target = self.checkout_root / name
            self._validate_target(target)
            if write_managed(target, content):
                written += 1
        return written

    def _copy_atomic(self, source: Path, target: Path) -> None:
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

    def _ledger_path(self) -> Path:
        return self.checkout_root / ".git" / _LEDGER_NAME

    def _load_ledger(self) -> dict[str, str]:
        try:
            raw = json.loads(self._ledger_path().read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return {}
        if not isinstance(raw, dict):
            return {}
        return {
            str(path): str(digest)
            for path, digest in raw.items()
            if isinstance(path, str) and isinstance(digest, str)
        }

    def _save_ledger(self, ledger: dict[str, str]) -> None:
        target = self._ledger_path()
        tmp = target.with_name(f"{target.name}.tmp")
        tmp.write_text(json.dumps(ledger, indent=0, sort_keys=True), encoding="utf-8")
        os.replace(tmp, target)

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

    # -- git plumbing -------------------------------------------------------

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
        return describe_git_failure(result.stderr or result.stdout, result.returncode)


# Known Git/SSH failure lines → (plain-language cause, retryable). Matched
# against every stderr line, because the *last* line of an SSH failure is
# always Git's boilerplate ("and the repository exists.").
_FAILURES: tuple[tuple[str, str, bool], ...] = (
    (
        "permission denied (publickey)",
        "the Git host rejected this Mac's SSH key — add the key to your GitHub "
        "account, or load it with `ssh-add`",
        False,
    ),
    (
        "host key verification failed",
        "this Mac doesn't trust the Git host's SSH key yet — run "
        "`ssh -T git@github.com` once in Terminal and answer yes",
        False,
    ),
    (
        "repository not found",
        "the repository was not found — check the URL, that it still exists, "
        "and that this account can push to it",
        False,
    ),
    (
        "does not appear to be a git repository",
        "the repository was not found — check the URL and that it still exists",
        False,
    ),
    (
        "not a git repository",
        "the managed sync checkout is damaged — move it aside and sync again",
        False,
    ),
    (
        "terminal prompts disabled",
        "Git needs a sign-in for this HTTPS remote and can't ask for one here — "
        "use the SSH URL, or sign in once with `gh auth login`",
        False,
    ),
    (
        "authentication failed",
        "the Git host rejected the saved sign-in — sign in again (for example "
        "`gh auth login`) or use the SSH URL",
        False,
    ),
    (
        "the requested url returned error: 403",
        "this account can't push to the repository",
        False,
    ),
    (
        "denied to",
        "this account can't push to the repository",
        False,
    ),
    (
        "could not resolve host",
        "can't reach the Git host — this Mac looks offline",
        True,
    ),
    (
        "network is unreachable",
        "can't reach the Git host — this Mac looks offline",
        True,
    ),
    (
        "operation timed out",
        "the connection to the Git host timed out",
        True,
    ),
    (
        "connection timed out",
        "the connection to the Git host timed out",
        True,
    ),
    (
        "connection refused",
        "the Git host refused the connection",
        True,
    ),
    (
        "index.lock",
        "another Git process is using the sync checkout",
        True,
    ),
)

# Git's generic tail after an SSH failure; never the informative line.
_BOILERPLATE = (
    "please make sure you have the correct access rights",
    "and the repository exists.",
    "fatal: could not read from remote repository.",
)


def describe_git_failure(output: str, returncode: int = 1) -> SyncError:
    """Turn Git's stderr into one actionable, correctly classified error."""
    lines = [
        _redact_remote(line.strip()) for line in output.splitlines() if line.strip()
    ]
    for line in lines:
        lower = line.lower()
        for marker, cause, retryable in _FAILURES:
            if marker in lower:
                return SyncError(f"{cause} (git: {line})", retryable=retryable)
    informative = [
        line for line in lines if not line.lower().startswith(_BOILERPLATE)
    ]
    for line in informative:
        if line.lower().startswith(("fatal:", "error:")):
            return SyncError(line)
    if informative:
        return SyncError(informative[-1])
    if lines:
        return SyncError(lines[-1])
    return SyncError(f"Git exited {returncode}")


def _transcript_rel(path: str) -> str:
    """Normalise ``transcripts/YYYY-MM-DD/x.md`` or ``YYYY-MM-DD/x.md``."""
    rel = path.strip().lstrip("/")
    if rel.startswith("transcripts/"):
        rel = rel[len("transcripts/") :]
    if not _TRANSCRIPT_RE.fullmatch(rel):
        raise ValueError(f"not a transcript path: {path}")
    return rel


def _raw_snapshot_sha(source: Path) -> str | None:
    """SHA-256 of distillation's raw ``.asr.txt`` snapshot, if there is one.

    Distillation copies the transcript byte-for-byte to ``<name>.asr.txt``
    before rewriting the ``.md``. A repository copy equal to that snapshot is
    the version Huske published before the rewrite.
    """
    raw = asr_raw_path(source)
    if not raw.is_file() or raw.is_symlink():
        return None
    return sha256_file(raw)


def _commit_message(outcome: _Reconciliation, docs: int) -> str:
    parts: list[str] = []
    if outcome.added:
        parts.append(f"add {outcome.added}")
    if outcome.updated:
        parts.append(f"update {outcome.updated}")
    if parts:
        message = f"sync: {', '.join(parts)} transcript(s)"
        return message if not docs else f"{message}; refresh repository docs"
    return "sync: refresh repository docs"


def redact_remote(remote: str) -> str:
    """Hide HTTP userinfo before displaying a configured remote."""
    return _redact_remote(remote)


def _redact_remote(value: str) -> str:
    return re.sub(r"((?:https?|git)://)[^/@\s]+@", r"\1***@", value)


def build_publisher(
    config: RuntimeConfig, *, republish: Iterable[str] = ()
) -> TranscriptPublisher:
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
            republish=republish,
        )
    raise ValueError(f"unsupported sync provider: {config.sync_provider}")
