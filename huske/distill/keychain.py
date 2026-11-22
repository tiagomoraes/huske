"""LLM provider API keys in the macOS Keychain — never in config, logs or snapshots.

Every read and write goes through ``/usr/bin/security``, from the engine and
(via ``huske llm key``) from Huske.app alike. That is deliberate: a Keychain
item's access list trusts the program that created it, so an item written by
``security`` is readable by ``security`` without a prompt, whichever process
runs it. Had the app written the item with the Security framework, the engine
would trip an "allow access?" dialog on every read, from a background daemon.

The secret never appears on a command line (``ps`` shows other processes'
argv): writes are piped to ``security -i``, which reads its command from
stdin. Keys are restricted to the URL-safe characters real provider keys use,
so the quoting of that interactive command is trivially safe.

``HUSKE_KEYCHAIN`` points every call at another keychain file — used by the
tests and by isolated checks so the login keychain is never touched.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
from typing import Any

from huske.distill.providers import PROVIDERS

SERVICE = "cloud.tiagomoraes.huske.llm"
_KEY_RE = re.compile(r"^[A-Za-z0-9._~+/=:-]{8,512}$")
_NOT_FOUND = 44  # errSecItemNotFound, as `security` reports it
_TIMEOUT = 15.0


class KeychainError(RuntimeError):
    """A Keychain operation failed (message is safe to show; it never has the key)."""


def _security_path() -> str | None:
    if os.path.exists("/usr/bin/security"):
        return "/usr/bin/security"
    return shutil.which("security")


def _run(args: list[str], *, input: str | None = None, **kwargs: Any) -> Any:
    return subprocess.run(
        args, input=input, capture_output=True, text=True, timeout=_TIMEOUT, check=False, **kwargs
    )


def _keychain_args() -> list[str]:
    path = os.environ.get("HUSKE_KEYCHAIN")
    return [path] if path else []


def _check_provider(provider: str) -> None:
    prov = PROVIDERS.get(provider)
    if prov is None or not prov.accepts_key:
        raise KeychainError(f"{provider!r} does not use an API key")


def _label(provider: str) -> str:
    return f"Huske — {PROVIDERS[provider].label} API key"


def set_key(provider: str, key: str) -> None:
    """Store (or replace) the API key for ``provider``."""
    _check_provider(provider)
    secret = key.strip()
    if not _KEY_RE.match(secret):
        raise KeychainError(
            "that doesn't look like an API key (expected one line of letters, digits "
            "and - _ . characters)"
        )
    security = _security_path()
    if security is None:
        raise KeychainError("API keys are stored in the macOS Keychain, which isn't available here")
    target = "".join(f' "{p}"' for p in _keychain_args())
    command = (
        f'add-generic-password -U -s "{SERVICE}" -a "{provider}" '
        f'-l "{_label(provider)}" -w "{secret}"{target}\n'
    )
    try:
        result = _run([security, "-i"], input=command)
    except (OSError, subprocess.SubprocessError) as exc:
        raise KeychainError(f"could not reach the Keychain: {type(exc).__name__}") from exc
    if result.returncode != 0:
        raise KeychainError(
            f"the Keychain refused to save the key (security exited {result.returncode})"
        )
    if get_key(provider) != secret:
        raise KeychainError("the Keychain did not keep the key (is the keychain locked?)")


def get_key(provider: str) -> str | None:
    """The stored key for ``provider``, or ``None`` when there is none."""
    if provider not in PROVIDERS or not PROVIDERS[provider].accepts_key:
        return None
    security = _security_path()
    if security is None:
        return None
    try:
        result = _run(
            [security, "find-generic-password", "-s", SERVICE, "-a", provider, "-w",
             *_keychain_args()]
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if result.returncode != 0:
        return None
    secret = str(result.stdout).strip()
    return secret or None


def has_key(provider: str) -> bool:
    """Whether a key exists, without reading the secret."""
    if provider not in PROVIDERS or not PROVIDERS[provider].accepts_key:
        return False
    security = _security_path()
    if security is None:
        return False
    try:
        result = _run(
            [security, "find-generic-password", "-s", SERVICE, "-a", provider,
             *_keychain_args()]
        )
    except (OSError, subprocess.SubprocessError):
        return False
    return bool(result.returncode == 0)


def delete_key(provider: str) -> bool:
    """Remove the key for ``provider``. Returns whether one existed."""
    _check_provider(provider)
    security = _security_path()
    if security is None:
        raise KeychainError("API keys are stored in the macOS Keychain, which isn't available here")
    try:
        result = _run(
            [security, "delete-generic-password", "-s", SERVICE, "-a", provider,
             *_keychain_args()]
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise KeychainError(f"could not reach the Keychain: {type(exc).__name__}") from exc
    if result.returncode == _NOT_FOUND:
        return False
    if result.returncode != 0:
        raise KeychainError(f"the Keychain refused (security exited {result.returncode})")
    return True


def key_status() -> dict[str, bool]:
    """``{provider: has_key}`` for every provider that takes a key."""
    return {name: has_key(name) for name, prov in PROVIDERS.items() if prov.accepts_key}
