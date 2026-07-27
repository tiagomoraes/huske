#!/usr/bin/env python3
"""Update the Homebrew tap (``tiagomoraes/homebrew-huske``) for a published huske version.

Usage:
    python scripts/update-homebrew-tap.py 0.5.0

What it does:

  1. Locates the tap clone via ``brew --repo tiagomoraes/huske`` (or the
     ``HOMEBREW_HUSKE_TAP_PATH`` env var as override).
  2. Generates a fresh pip dependency report by ``pip install --dry-run
     --report`` for the requested ``huske==X.Y.Z``.
  3. Cross-references that report against the resource blocks already in
     ``Formula/huske.rb`` and rewrites each block's ``url`` + ``sha256``
     (in-place; positions and surrounding code are preserved).
  4. Updates the formula's stable ``url`` + ``sha256`` to the new sdist.
  5. Reports any added/removed dependencies (the script does NOT add or
     remove resource blocks — that requires human judgement about ordering
     and whether the new dep is needed at runtime).
  6. Optionally runs ``brew style`` and ``brew audit --strict --online``.
  7. Stops before committing. The maintainer reviews the diff, runs
     ``brew install --build-from-source`` and ``brew test``, and pushes.

Idempotent: rerunning produces the same diff. Refuses to run if the tap
clone has uncommitted changes.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import NoReturn

PYPI_INDEX = "https://pypi.org/pypi/{name}/{version}/json"

RESOURCE_BLOCK_RE = re.compile(
    r'(resource "(?P<name>[^"]+)" do\s+url ")(?P<url>[^"]+)("\s+sha256 ")(?P<sha256>[^"]+)("\s+end)',
    re.S,
)
STABLE_URL_RE = re.compile(
    r'(url ")(https://files\.pythonhosted\.org/[^"]+huske-[^"]+\.tar\.gz)(")'
)
STABLE_SHA_RE = re.compile(r'(sha256 ")([0-9a-f]{64})(")')


def run(
    *args: str,
    capture: bool = False,
    check: bool = True,
    cwd: Path | None = None,
) -> subprocess.CompletedProcess[str]:
    print(f"$ {' '.join(args)}")
    return subprocess.run(
        list(args),
        check=check,
        text=True,
        capture_output=capture,
        cwd=str(cwd) if cwd else None,
    )


def die(message: str, code: int = 1) -> NoReturn:
    print(f"error: {message}", file=sys.stderr)
    sys.exit(code)


def find_tap() -> Path:
    if env := os.environ.get("HOMEBREW_HUSKE_TAP_PATH"):
        path = Path(env).expanduser()
        if not path.is_dir():
            die(f"HOMEBREW_HUSKE_TAP_PATH points at {path}, which is not a directory")
        return path
    try:
        out = run("brew", "--repo", "tiagomoraes/huske", capture=True).stdout.strip()
    except (FileNotFoundError, subprocess.CalledProcessError):
        die("brew not found and HOMEBREW_HUSKE_TAP_PATH is not set")
    return Path(out)


def fetch_pypi_sdist(name: str, version: str) -> tuple[str, str]:
    """Return (sdist_url, sdist_sha256) for ``name==version`` on PyPI."""
    url = PYPI_INDEX.format(name=name, version=version)
    print(f"$ GET {url}")
    with urllib.request.urlopen(url, timeout=15) as resp:
        data = json.load(resp)
    for entry in data.get("urls", []):
        if entry.get("packagetype") == "sdist":
            return entry["url"], entry["digests"]["sha256"]
    die(f"no sdist found on PyPI for {name}=={version}")
    return "", ""  # unreachable, satisfies mypy


def generate_pip_report(version: str) -> dict[str, tuple[str, str]]:
    """Return ``{normalized_name: (url, sha256)}`` from a pip dry-run report."""
    with tempfile.TemporaryDirectory() as tmp:
        report_path = Path(tmp) / "report.json"
        run(
            sys.executable,
            "-m",
            "pip",
            "install",
            "--no-cache-dir",
            "--dry-run",
            "--ignore-installed",
            "--report",
            str(report_path),
            f"huske=={version}",
        )
        report = json.loads(report_path.read_text())

    pkgs: dict[str, tuple[str, str]] = {}
    for item in report["install"]:
        md = item["metadata"]
        name = md["name"].lower().replace("_", "-")
        dl = item.get("download_info", {})
        url = dl.get("url", "")
        sha = dl.get("archive_info", {}).get("hashes", {}).get("sha256")
        if url and sha:
            pkgs[name] = (url, sha)
    return pkgs


def normalize(name: str) -> str:
    return name.lower().replace("_", "-")


@dataclass
class FormulaResource:
    name: str
    url: str
    sha256: str
    span: tuple[int, int]


def parse_formula_resources(text: str) -> list[FormulaResource]:
    return [
        FormulaResource(
            name=m.group("name"),
            url=m.group("url"),
            sha256=m.group("sha256"),
            span=m.span(),
        )
        for m in RESOURCE_BLOCK_RE.finditer(text)
    ]


def rewrite_formula(
    formula_text: str,
    new_sdist_url: str,
    new_sdist_sha: str,
    pip_pkgs: dict[str, tuple[str, str]],
) -> tuple[str, list[str], list[str]]:
    """Rewrite the formula. Returns (new_text, added, removed) where added /
    removed are dependency names present in only one of the two sources."""

    # 1. Replace the stable url + sha256 (huske itself).
    new_text, n_url = STABLE_URL_RE.subn(
        lambda m: f'{m.group(1)}{new_sdist_url}{m.group(3)}',
        formula_text,
        count=1,
    )
    if n_url != 1:
        die("could not find the stable `url \"...huske-X.Y.Z.tar.gz\"` line")
    new_text, n_sha = STABLE_SHA_RE.subn(
        lambda m: f'{m.group(1)}{new_sdist_sha}{m.group(3)}',
        new_text,
        count=1,
    )
    if n_sha != 1:
        die("could not find the stable `sha256 \"...\"` line for huske")

    # 2. Per-resource: replace url + sha256 in place.
    formula_resource_names = {normalize(r.name) for r in parse_formula_resources(new_text)}
    pip_resource_names = set(pip_pkgs) - {"huske"}

    def _resource_replacer(match: re.Match[str]) -> str:
        name = match.group("name")
        norm = normalize(name)
        if norm not in pip_pkgs:
            return match.group(0)
        new_url, new_sha = pip_pkgs[norm]
        prefix = match.group(1)
        suffix1 = match.group(4)
        suffix2 = match.group(6)
        return f"{prefix}{new_url}{suffix1}{new_sha}{suffix2}"

    new_text = RESOURCE_BLOCK_RE.sub(_resource_replacer, new_text)

    added = sorted(pip_resource_names - formula_resource_names)
    removed = sorted(formula_resource_names - pip_resource_names)
    return new_text, added, removed


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version", help="Semver version of huske on PyPI, e.g. 0.5.0")
    parser.add_argument(
        "--no-audit",
        action="store_true",
        help="Skip `brew style` and `brew audit --strict --online`.",
    )
    args = parser.parse_args()

    version = args.version.lstrip("v")
    tap = find_tap()
    formula = tap / "Formula" / "huske.rb"
    if not formula.exists():
        die(f"formula not found at {formula}")

    # Refuse to clobber uncommitted work.
    status = run(
        "git", "status", "--porcelain", capture=True, cwd=tap
    ).stdout.strip()
    if status:
        die(f"tap working tree at {tap} has uncommitted changes:\n{status}")

    # Sync the tap.
    run("git", "fetch", "--all", "--prune", cwd=tap)
    run("git", "pull", "--ff-only", cwd=tap)

    print(f"\n=== updating {formula} for huske {version} ===\n")

    sdist_url, sdist_sha = fetch_pypi_sdist("huske", version)
    print(f"sdist url:    {sdist_url}")
    print(f"sdist sha256: {sdist_sha}\n")

    pip_pkgs = generate_pip_report(version)
    print(f"\npip report has {len(pip_pkgs)} packages (incl. huske)\n")

    original = formula.read_text(encoding="utf-8")
    rewritten, added, removed = rewrite_formula(original, sdist_url, sdist_sha, pip_pkgs)

    if rewritten == original:
        print("✓ formula already up to date — nothing to write")
    else:
        formula.write_text(rewritten, encoding="utf-8")
        diff = run(
            "git", "diff", "--stat", "Formula/huske.rb", cwd=tap, capture=True
        ).stdout
        print(diff)

    if added:
        print(f"\nWARN: pip report has {len(added)} new dependencies not in formula:")
        for name in added:
            url, sha = pip_pkgs[name]
            print(f"  - {name} {url}#{sha[:12]}")
        print(
            "\nAdd matching `resource \"<name>\" do ... end` blocks to the "
            "formula manually. The script does not auto-insert because the "
            "block ordering matters for readability."
        )
        print(
            "\nNote `brew style` and `brew audit` both PASS with these missing "
            "— only `brew install --build-from-source` catches it, so do not "
            "skip that step. (v0.11.0 shipped needing six: the mlx-lm stack.)"
        )
    if removed:
        print(f"\nWARN: formula has {len(removed)} resources no longer in pip report:")
        for name in removed:
            print(f"  - {name}")
        print("\nDelete or comment those out of the formula manually.")

    if not args.no_audit:
        run("brew", "style", str(formula))
        run("brew", "audit", "--strict", "--online", "tiagomoraes/huske/huske")

    print("\n=== done ===")
    print(
        f"\nReview the diff in {tap}, then:\n\n"
        f"    cd {tap}\n"
        f"    brew install --build-from-source tiagomoraes/huske/huske\n"
        f"    brew test tiagomoraes/huske/huske\n"
        f"    git add Formula/huske.rb\n"
        f"    git commit -m 'Update huske to v{version}'\n"
        f"    git push\n"
    )
    # Non-zero when the formula is knowingly incomplete: the resource list has
    # to be edited by hand, and a green exit reads as "tap is ready to push".
    # The formula is still written — this is "not finished", not "failed".
    if added or removed:
        print(
            "Exiting non-zero: the resource list above still needs hand-editing.\n"
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
