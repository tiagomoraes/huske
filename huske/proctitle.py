"""Best-effort OS process naming.

A pip/uv-installed ``huske`` runs as the Python interpreter, so Activity
Monitor and ``ps`` show it as "Python" (on Homebrew Python, the framework
``Python`` binary) rather than "huske". macOS derives a non-bundled CLI's
displayed name from the executable, not the command word you typed, so the
only way to fix it at runtime is to rewrite the process title.

``setproctitle`` does exactly that: it rewrites the argv/proctitle memory
region (so ``ps``/``top`` update) and, on macOS since setproctitle 1.3.0,
also pushes the name into Activity Monitor via the private LaunchServices
display-name API. It is a base dependency, but the import is kept soft: a
missing dependency — or any platform call that fails — is a silent no-op,
because the process name is cosmetic and must never break recording.
"""

from __future__ import annotations


def set_process_title(title: str) -> bool:
    """Set the OS-visible process title; return ``True`` if it took effect.

    Soft-imports ``setproctitle``; a missing dependency or any runtime error
    is swallowed — naming is cosmetic, so this never raises.
    """
    try:
        from setproctitle import setproctitle
    except ImportError:
        return False
    try:
        setproctitle(title)
        return True
    except Exception:
        return False
