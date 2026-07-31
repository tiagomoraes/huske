"""Read-only Git replica with polling and webhook wakeups."""

from __future__ import annotations

import os
import queue
import re
import shutil
import subprocess
import threading
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path


class ReplicaError(RuntimeError):
    pass


@dataclass(frozen=True)
class PullResult:
    before: str | None
    after: str

    @property
    def changed(self) -> bool:
        return self.before != self.after


class GitReplica:
    def __init__(
        self,
        repository: str,
        checkout_dir: Path,
        *,
        branch: str = "main",
        timeout: float = 60.0,
    ) -> None:
        self.repository = repository
        self.checkout_dir = checkout_dir
        self.branch = branch
        self.timeout = timeout

    def pull(self) -> PullResult:
        self.checkout_dir.parent.mkdir(parents=True, exist_ok=True)
        if not (self.checkout_dir / ".git").is_dir():
            self._clone()
        configured = self._git("remote", "get-url", "origin").stdout.strip()
        if configured != self.repository:
            raise ReplicaError(
                "managed checkout points at a different repository; move or remove "
                f"{self.checkout_dir} before changing HUSKE_MCP_REPOSITORY"
            )
        if self._git("status", "--porcelain").stdout.strip():
            raise ReplicaError("managed checkout is dirty; refusing to discard local files")

        before = self._head()
        self._git("fetch", "--prune", "origin", self.branch)
        self._git("checkout", self.branch)
        self._git("merge", "--ff-only", f"origin/{self.branch}")
        after = self._head()
        if after is None:
            raise ReplicaError("repository branch has no commit")
        return PullResult(before=before, after=after)

    def _clone(self) -> None:
        if self.checkout_dir.exists() and any(self.checkout_dir.iterdir()):
            raise ReplicaError(
                f"checkout path is non-empty and not a Git repository: {self.checkout_dir}"
            )
        result = self._run(
            "git",
            "clone",
            "--branch",
            self.branch,
            "--single-branch",
            "--filter=blob:none",
            "--",
            self.repository,
            str(self.checkout_dir),
            cwd=self.checkout_dir.parent,
            check=False,
        )
        if result.returncode != 0:
            if self.checkout_dir.exists() and not (self.checkout_dir / ".git").exists():
                shutil.rmtree(self.checkout_dir)
            raise self._error(result)

    def _head(self) -> str | None:
        result = self._git("rev-parse", "--verify", "HEAD", check=False)
        return result.stdout.strip() if result.returncode == 0 else None

    def _git(
        self, *args: str, check: bool = True
    ) -> subprocess.CompletedProcess[str]:
        return self._run("git", *args, cwd=self.checkout_dir, check=check)

    def _run(
        self, *args: str, cwd: Path, check: bool
    ) -> subprocess.CompletedProcess[str]:
        try:
            result = subprocess.run(
                args,
                cwd=cwd,
                env={**os.environ, "GIT_TERMINAL_PROMPT": "0", "LC_ALL": "C"},
                text=True,
                capture_output=True,
                timeout=self.timeout,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise ReplicaError(str(exc)) from exc
        if check and result.returncode != 0:
            raise self._error(result)
        return result

    @staticmethod
    def _error(result: subprocess.CompletedProcess[str]) -> ReplicaError:
        lines = (result.stderr or result.stdout).strip().splitlines()
        detail = lines[-1] if lines else f"Git exited {result.returncode}"
        return ReplicaError(
            re.sub(r"((?:https?|git)://)[^/@\s]+@", r"\1***@", detail)
        )


class ReplicaWatcher:
    """Single polling thread; webhook deliveries only wake it early."""

    def __init__(
        self,
        replica: GitReplica,
        on_pull: Callable[[PullResult], None],
        *,
        poll_seconds: int,
        on_error: Callable[[Exception], None] | None = None,
    ) -> None:
        self.replica = replica
        self.on_pull = on_pull
        self.poll_seconds = poll_seconds
        self.on_error = on_error or (lambda exc: None)
        self._wake: queue.Queue[None] = queue.Queue(maxsize=1)
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    def start(self) -> None:
        if self._thread and self._thread.is_alive():
            return
        self._thread = threading.Thread(target=self._loop, name="huske-mcp-sync", daemon=True)
        self._thread.start()

    def wake(self) -> None:
        try:
            self._wake.put_nowait(None)
        except queue.Full:
            pass

    def stop(self, timeout: float | None = None) -> None:
        self._stop.set()
        self.wake()
        if self._thread:
            # Git has its own timeout. Wait long enough that the callback cannot
            # race with index shutdown after this method returns.
            self._thread.join(timeout if timeout is not None else self.replica.timeout + 5)
            if self._thread.is_alive():
                raise ReplicaError("replica thread did not stop before its Git timeout")
        self._thread = None

    def sync_now(self) -> PullResult:
        result = self.replica.pull()
        self.on_pull(result)
        return result

    def _loop(self) -> None:
        while not self._stop.is_set():
            try:
                self.sync_now()
            except Exception as exc:
                self.on_error(exc)
            try:
                self._wake.get(timeout=self.poll_seconds)
            except queue.Empty:
                pass
