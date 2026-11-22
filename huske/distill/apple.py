"""Apple Intelligence (on-device Foundation Models) through ``huske-apple-llm``.

Foundation Models is a Swift framework. Apple's official Python SDK
(``apple-fm-sdk``) exists but is an alpha that compiles a Swift bridge at
install time and needs a full Xcode, so it can't be a dependency of an engine
installed with ``uv``/``pipx``/Homebrew. Huske.app instead bundles a small
Swift helper (``Contents/Helpers/huske-apple-llm``) and the engine talks to it
with JSON lines over stdin/stdout — ADR 0013. All pipeline logic (chunking,
prompts, validation, fallback) stays here, in the engine (ADR 0006).

The helper is found, in order, at ``$HUSKE_APPLE_LLM_HELPER`` (Huske.app sets
it when it starts the engine), inside ``Huske.app`` in ``/Applications`` or
``~/Applications``, then on ``PATH``.

One helper process serves requests strictly one at a time (the OS queues
concurrent sessions anyway); the worker thread blocks on a pipe read, which
releases the GIL, so the audio drainer never waits on it.
"""

from __future__ import annotations

import json
import os
import select
import shutil
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from huske.distill.client import DistillError, ErrorKind
from huske.distill.providers import APPLE_MODEL_ID

HELPER_NAME = "huske-apple-llm"
HELPER_ENV = "HUSKE_APPLE_LLM_HELPER"
_APP_LOCATIONS = (
    Path("/Applications/Huske.app"),
    Path.home() / "Applications" / "Huske.app",
)
_STATUS_TIMEOUT = 15.0

#: Plain-language explanations, shared by ``huske doctor``, ``huske llm
#: status`` and the app (which shows the engine's words verbatim).
REASON_TEXT: dict[str, tuple[str, str | None]] = {
    "device_not_eligible": (
        "This Mac can't run Apple Intelligence.",
        "It needs a Mac with Apple silicon (M1 or later). Choose another way to clean up "
        "transcripts.",
    ),
    "not_enabled": (
        "Apple Intelligence is turned off.",
        "Turn it on in System Settings → Apple Intelligence & Siri, then try again.",
    ),
    "model_not_ready": (
        "Apple Intelligence is still getting ready.",
        "macOS is downloading the model. Huske will use it once it's ready; raw "
        "transcripts are kept meanwhile.",
    ),
    "os_too_old": (
        "Apple Intelligence needs macOS 26 or later.",
        "Update macOS, or choose another way to clean up transcripts.",
    ),
    "not_built": (
        "This copy of Huske.app was built without Apple Intelligence support.",
        "Install a release of Huske.app built with Xcode 26 or later.",
    ),
    "no_helper": (
        "Apple Intelligence runs through Huske.app, which wasn't found.",
        "Install Huske.app in Applications (it carries the helper), or set "
        "HUSKE_APPLE_LLM_HELPER to the helper's path.",
    ),
    "unknown": (
        "Apple Intelligence is unavailable for a reason this version doesn't know.",
        "Update Huske, or choose another way to clean up transcripts.",
    ),
}

_ERROR_KINDS: dict[str, ErrorKind] = {
    "context": "context",
    "refused": "refused",
    "rate_limited": "rate_limited",
    "unavailable": "unavailable",
    "timeout": "timeout",
    "busy": "unavailable",
    "unsupported_language": "config",
    "bad_request": "config",
}


def find_helper() -> Path | None:
    """Path to an executable ``huske-apple-llm``, or ``None``."""
    override = os.environ.get(HELPER_ENV)
    if override:
        path = Path(override).expanduser()
        return path if path.is_file() and os.access(path, os.X_OK) else None
    for app in _APP_LOCATIONS:
        candidate = app / "Contents" / "Helpers" / HELPER_NAME
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return candidate
    found = shutil.which(HELPER_NAME)
    return Path(found) if found else None


@dataclass(frozen=True)
class AppleStatus:
    available: bool
    reason: str | None
    context_size: int
    locale_supported: bool | None
    helper: Path | None

    @property
    def detail(self) -> str:
        if self.available:
            return "Apple Intelligence is ready on this Mac."
        return REASON_TEXT.get(self.reason or "unknown", REASON_TEXT["unknown"])[0]

    @property
    def hint(self) -> str | None:
        if self.available:
            return None
        return REASON_TEXT.get(self.reason or "unknown", REASON_TEXT["unknown"])[1]


def probe_apple(locale: str | None = None, helper: Path | None = None) -> AppleStatus:
    """Ask the helper whether the on-device model can be used right now."""
    path = helper or find_helper()
    if path is None:
        return AppleStatus(False, "no_helper", 0, None, None)
    args = [str(path), "--status"]
    if locale:
        args += ["--locale", locale]
    try:
        result = subprocess.run(
            args, capture_output=True, text=True, timeout=_STATUS_TIMEOUT, check=False
        )
        data = json.loads(result.stdout.strip().splitlines()[-1])
    except (OSError, subprocess.SubprocessError, ValueError, IndexError):
        return AppleStatus(False, "unknown", 0, None, path)
    return _status_from(data, path)


def _status_from(data: dict[str, Any], path: Path | None) -> AppleStatus:
    supported = data.get("locale_supported")
    return AppleStatus(
        available=bool(data.get("available")),
        reason=str(data["reason"]) if data.get("reason") else None,
        context_size=int(data.get("context_size") or 4096),
        locale_supported=bool(supported) if isinstance(supported, bool) else None,
        helper=path,
    )


class AppleBackend:
    """:class:`~huske.distill.correction.CompletionBackend` over the helper."""

    provider = "apple"
    model_id = APPLE_MODEL_ID

    def __init__(self, helper: Path | None = None, *, timeout: float = 120.0) -> None:
        self._helper = helper or find_helper()
        self._timeout = timeout
        self._proc: subprocess.Popen[bytes] | None = None
        self._buffer = b""
        self._next_id = 0
        self._status: AppleStatus | None = None

    # -- lifecycle -----------------------------------------------------------

    @property
    def pid(self) -> int | None:
        if self._proc is None or self._proc.poll() is not None:
            return None
        return self._proc.pid

    def close(self) -> None:
        proc, self._proc = self._proc, None
        self._buffer = b""
        if proc is None:
            return
        try:
            if proc.stdin is not None:
                proc.stdin.close()
            proc.wait(timeout=3.0)
        except (OSError, subprocess.SubprocessError):
            proc.kill()

    def _ensure(self) -> subprocess.Popen[bytes]:
        if self._proc is not None and self._proc.poll() is None:
            return self._proc
        if self._helper is None:
            detail, hint = REASON_TEXT["no_helper"]
            raise DistillError(f"{detail} {hint}", kind="config")
        try:
            self._proc = subprocess.Popen(
                [str(self._helper)],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
            )
        except OSError as exc:
            raise DistillError(f"could not start {HELPER_NAME}: {exc}", kind="config") from None
        self._buffer = b""
        return self._proc

    # -- protocol --------------------------------------------------------------

    def _call(self, payload: dict[str, Any], timeout: float) -> dict[str, Any]:
        proc = self._ensure()
        self._next_id += 1
        ident = self._next_id
        line = json.dumps({"id": ident, **payload}, ensure_ascii=False) + "\n"
        assert proc.stdin is not None and proc.stdout is not None
        try:
            proc.stdin.write(line.encode("utf-8"))
            proc.stdin.flush()
        except (BrokenPipeError, OSError):
            self.close()
            raise DistillError(f"{HELPER_NAME} exited unexpectedly", kind="unavailable") from None
        deadline = time.monotonic() + timeout
        fd = proc.stdout.fileno()
        while True:
            newline = self._buffer.find(b"\n")
            if newline >= 0:
                raw, self._buffer = self._buffer[:newline], self._buffer[newline + 1 :]
                try:
                    reply = json.loads(raw.decode("utf-8"))
                except (ValueError, UnicodeDecodeError):
                    continue
                if isinstance(reply, dict) and reply.get("id") == ident:
                    return reply
                continue
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                self.close()  # a stuck generation: start over next time
                raise DistillError(
                    f"Apple Intelligence did not answer within {timeout:.0f}s", kind="timeout"
                )
            ready, _, _ = select.select([fd], [], [], remaining)
            if not ready:
                continue
            chunk = os.read(fd, 65536)
            if not chunk:
                self.close()
                raise DistillError(f"{HELPER_NAME} exited unexpectedly", kind="unavailable")
            self._buffer += chunk

    def status(self, locale: str | None = None) -> AppleStatus:
        reply = self._call({"op": "status", "locale": locale}, _STATUS_TIMEOUT)
        self._status = _status_from(reply, self._helper)
        return self._status

    @property
    def context_tokens(self) -> int | None:
        """The model's real context window, once :meth:`status` has run."""
        return self._status.context_size if self._status else None

    def complete(self, instructions: str, prompt: str, *, max_tokens: int) -> str:
        if self._status is None:
            status = self.status()
            if not status.available:
                kind: ErrorKind = "unavailable" if status.reason == "model_not_ready" else "config"
                raise DistillError(f"{status.detail} {status.hint or ''}".strip(), kind=kind)
        reply = self._call(
            {
                "op": "respond",
                "instructions": instructions,
                "prompt": prompt,
                "max_tokens": int(max_tokens),
            },
            self._timeout,
        )
        if reply.get("ok"):
            return str(reply.get("text", ""))
        error = str(reply.get("error", "failed"))
        message = str(reply.get("message", "")) or "Apple Intelligence failed"
        raise DistillError(
            f"Apple Intelligence: {message.splitlines()[0][:200]}",
            kind=_ERROR_KINDS.get(error, "http"),
        )
