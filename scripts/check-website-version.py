#!/usr/bin/env python3
"""Confirm the website's version copy is in sync with ``pyproject.toml``.

A standalone wrapper around the drift guard in ``scripts/release.py`` — run it
any time, not just at release, to confirm no page still mentions a previous
version:

    python scripts/check-website-version.py

It exits non-zero and prints every offending ``file:line`` if any version other
than the current ``pyproject.toml`` version appears outside the historical
``RELEASES`` timeline (hero eyebrow, live-demo header, footer, sample transcript
frontmatter, the "supported target" FAQ, the docs facts list, and the README
install-pin).

Pass an explicit version to check against something other than pyproject (e.g.
the version you are *about* to release):

    python scripts/check-website-version.py 0.8.0
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path
from types import ModuleType

_HERE = Path(__file__).resolve().parent


def _load_release_module() -> ModuleType:
    """Load the hyphen-free ``release.py`` as a module so we can reuse its
    scanner without duplicating the rules."""
    spec = importlib.util.spec_from_file_location("huske_release", _HERE / "release.py")
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main(argv: list[str]) -> int:
    release = _load_release_module()
    expected = argv[0].lstrip("v") if argv else release.current_pyproject_version()
    problems = release.scan_stale_website_versions(expected)
    if problems:
        print(f"✗ website version drift (expected {expected}):", file=sys.stderr)
        for p in problems:
            print(f"    {p}", file=sys.stderr)
        print(
            "\nFix each line to read the current version — dynamic spots should go "
            "through HUSKE_VERSION / HUSKE_PYTHONS in website/version.js.",
            file=sys.stderr,
        )
        return 1
    print(f"✓ website version copy is in sync ({expected})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
