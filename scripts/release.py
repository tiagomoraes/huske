#!/usr/bin/env python3
"""Release-prep automation for huske.

Usage:
    python scripts/release.py 0.5.0

What it does (one command, mechanical only):

  1. Pre-flight: on `develop`, working tree clean, in sync with origin.
  2. Bumps `version =` in `pyproject.toml`.
  3. Moves the `## Unreleased` section in `CHANGELOG.md` into
     `## X.Y.Z - YYYY-MM-DD` and leaves a fresh `## Unreleased` on top.
  4. Updates the website: bumps the single `window.HUSKE_VERSION` in
     `website/version.js` (every JSX component reads it, so the whole site
     updates at once), bumps the README install-pin, and inserts a new
     `website/components-sections.jsx` RELEASES entry with `tag: "latest"`
     (demoted from the previous top entry; bullets from the moved CHANGELOG
     section). Then scans the site and fails if any copy still mentions the
     previous version.
  5. Runs `pytest tests/unit` and the smoke integration tests.
  6. Creates branch `release/vX.Y.Z`, commits, pushes, opens the PR
     `chore: release vX.Y.Z` to `develop`.
  7. Stops there. The maintainer reviews and merges the PR.

Exits non-zero on any failure. Idempotent up to the branch creation step;
re-running after a partial failure is safe as long as the branch doesn't
exist yet (otherwise pass `--force` to overwrite).
"""

from __future__ import annotations

import argparse
import datetime as _dt
import re
import subprocess
import sys
import tomllib
from pathlib import Path
from typing import NoReturn

REPO_ROOT = Path(__file__).resolve().parent.parent
PYPROJECT = REPO_ROOT / "pyproject.toml"
CHANGELOG = REPO_ROOT / "CHANGELOG.md"
README = REPO_ROOT / "README.md"
WEBSITE_DIR = REPO_ROOT / "website"
WEBSITE_VERSION_JS = WEBSITE_DIR / "version.js"
WEBSITE_SECTIONS = WEBSITE_DIR / "components-sections.jsx"

SEMVER_RE = re.compile(r"^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.\-+]+)?$")


# ---------------------------------------------------------------------------
# Shell helpers
# ---------------------------------------------------------------------------


def run(
    *args: str,
    capture: bool = False,
    check: bool = True,
    cwd: Path | None = None,
) -> subprocess.CompletedProcess[str]:
    """Run a subprocess with sensible defaults. Echoes the command for visibility."""
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


# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------


def current_pyproject_version() -> str:
    with PYPROJECT.open("rb") as f:
        return str(tomllib.load(f)["project"]["version"])


def validate_version(new_version: str, current: str) -> None:
    if not SEMVER_RE.match(new_version):
        die(f"version {new_version!r} is not semver (X.Y.Z)")
    if new_version == current:
        die(f"version {new_version} is already in pyproject.toml")


def preflight() -> None:
    # On develop?
    branch = run("git", "rev-parse", "--abbrev-ref", "HEAD", capture=True).stdout.strip()
    if branch != "develop":
        die(f"must run from `develop`; current branch is {branch!r}")

    # Working tree clean?
    status = run("git", "status", "--porcelain", capture=True).stdout
    if status.strip():
        die("working tree is not clean:\n" + status)

    # Up to date with origin?
    run("git", "fetch", "origin", "--prune", "--tags")
    local = run("git", "rev-parse", "HEAD", capture=True).stdout.strip()
    remote = run("git", "rev-parse", "origin/develop", capture=True).stdout.strip()
    if local != remote:
        die("local develop is not in sync with origin/develop — pull or push first")


# ---------------------------------------------------------------------------
# Mechanical edits
# ---------------------------------------------------------------------------


def bump_pyproject(new_version: str) -> None:
    text = PYPROJECT.read_text(encoding="utf-8")
    new_text, n = re.subn(
        r'(?m)^version\s*=\s*"[^"]+"',
        f'version = "{new_version}"',
        text,
        count=1,
    )
    if n != 1:
        die("failed to bump version in pyproject.toml (no `version = \"...\"` line found)")
    PYPROJECT.write_text(new_text, encoding="utf-8")


def move_changelog_unreleased(new_version: str, today: str) -> str:
    """Move `## Unreleased` content to `## X.Y.Z - <today>`. Returns the moved
    section text (header excluded) so the website updater can reuse it."""
    text = CHANGELOG.read_text(encoding="utf-8")
    pattern = re.compile(
        r"(?P<head>^## Unreleased\s*\n)"
        r"(?P<body>.*?)"
        r"(?=^## )",
        re.S | re.M,
    )
    match = pattern.search(text)
    if not match:
        die("could not locate `## Unreleased` section in CHANGELOG.md")

    body = match.group("body").strip("\n")
    if not body.strip():
        die("`## Unreleased` is empty — nothing to release")

    new_section = (
        f"## Unreleased\n\n"
        f"## {new_version} - {today}\n\n"
        f"{body}\n\n"
    )
    new_text = text[: match.start()] + new_section + text[match.end() :]
    CHANGELOG.write_text(new_text, encoding="utf-8")
    return body


# ---------------------------------------------------------------------------
# Website rewriting
# ---------------------------------------------------------------------------


def update_version_js(new_version: str) -> None:
    """Patch the single source of truth for the site's version string.

    ``website/version.js`` defines ``window.HUSKE_VERSION``; every JSX component
    reads it as a global, so this one edit updates the version everywhere on the
    site at once (Nav, Footer, hero eyebrow, live-demo header, sample
    transcript frontmatter, the "supported target" FAQ). The historical
    ``RELEASES`` timeline is updated separately, in ``update_sections_releases``.
    """
    text = WEBSITE_VERSION_JS.read_text(encoding="utf-8")
    new_text, n = re.subn(
        r'(window\.HUSKE_VERSION\s*=\s*")[^"]+(")',
        rf"\g<1>{new_version}\g<2>",
        text,
        count=1,
    )
    if n != 1:
        die('failed to patch website/version.js (no `window.HUSKE_VERSION = "..."` line found)')
    WEBSITE_VERSION_JS.write_text(new_text, encoding="utf-8")


def update_readme_pin(new_version: str) -> None:
    """Bump the example ``git+...@vX.Y.Z`` install-pin in the README to the new tag.

    Soft: not every README revision keeps the pinned-install example, so a
    missing pin is a warning, not a failure."""
    text = README.read_text(encoding="utf-8")
    new_text, n = re.subn(
        r"(github\.com/tiagomoraes/huske\.git@v)\d+\.\d+\.\d+",
        rf"\g<1>{new_version}",
        text,
    )
    if n == 0:
        print("warn: no README install-pin (git+...@vX.Y.Z) to bump (skipping)")
        return
    README.write_text(new_text, encoding="utf-8")


def _markdown_text_to_jsx(line: str) -> str:
    """Convert a single CHANGELOG line (markdown) into a JSX expression body
    suitable to drop inside ``<>...</>``.

    Handles:
      - backtick code spans → ``<code>...</code>``
      - ``**bold**`` → ``<strong>...</strong>``, ``*italic*`` → ``<em>...</em>``
        (every CHANGELOG bullet opens with a bold lede, and leaving the
        asterisks in renders them literally on the site — the bug 0.9.1's
        release notes had to apologize for)
      - curly braces → entity-escape (so JSX doesn't read them as expressions)
    Other characters pass through. ``<``/``>`` outside backticks are left
    alone — none appear in our CHANGELOG text in practice.
    """
    out: list[str] = []
    i = 0
    while i < len(line):
        ch = line[i]
        if ch == "`":
            end = line.find("`", i + 1)
            if end == -1:
                out.append(ch)
                i += 1
                continue
            code = line[i + 1 : end]
            # Inside <code>, escape braces too (JSX still parses).
            code_escaped = code.replace("{", "&#123;").replace("}", "&#125;")
            out.append(f"<code>{code_escaped}</code>")
            i = end + 1
        elif ch == "*":
            # Emphasis spans may themselves contain code, so recurse on the
            # inner text. An unclosed marker is passed through as a literal.
            wide = line.startswith("**", i)
            marker = "**" if wide else "*"
            end = line.find(marker, i + len(marker))
            if end == -1:
                out.append(ch)
                i += 1
                continue
            inner = _markdown_text_to_jsx(line[i + len(marker) : end])
            tag = "strong" if wide else "em"
            out.append(f"<{tag}>{inner}</{tag}>")
            i = end + len(marker)
        elif ch == "{":
            out.append("&#123;")
            i += 1
        elif ch == "}":
            out.append("&#125;")
            i += 1
        else:
            out.append(ch)
            i += 1
    return "".join(out)


def _changelog_to_jsx_items(body: str) -> str:
    """Convert a moved CHANGELOG body into the JSX ``items: [...]`` payload.

    The body looks like::

        ### Added

        - bullet one with optional `code` and **bold-as-text**
          continuation indented two spaces
        - bullet two

        ### Fixed

        - ...

    Returns a string ready to drop into the ``items: [ ... ]`` array (no
    surrounding brackets).
    """
    kind: str | None = None
    bullets: list[tuple[str, str]] = []  # (kind, joined-bullet-text)
    current: list[str] = []

    def flush() -> None:
        if current and kind is not None:
            text = " ".join(s.strip() for s in current).strip()
            if text:
                bullets.append((kind, text))
        current.clear()

    for raw in body.splitlines():
        line = raw.rstrip()
        if line.startswith("### "):
            flush()
            kind = line[4:].strip().lower()
            continue
        if line.startswith("- "):
            flush()
            current.append(line[2:])
        elif line.startswith("  ") and current:
            current.append(line.strip())
        elif not line.strip():
            flush()
        else:
            # Stray text — append as continuation of the last bullet.
            if current:
                current.append(line.strip())
    flush()

    if not bullets:
        die("could not parse any bullets out of the CHANGELOG section")

    parts = []
    for k, txt in bullets:
        jsx = _markdown_text_to_jsx(txt)
        parts.append(f'      {{ kind: "{k}", text: <>{jsx}</> }},')
    return "\n".join(parts)


def update_sections_releases(new_version: str, today: str, body: str) -> None:
    text = WEBSITE_SECTIONS.read_text(encoding="utf-8")

    # Demote `tag: "latest"` from the current top entry.
    new_text, demoted = re.subn(
        r',\s*tag:\s*"latest"',
        "",
        text,
        count=1,
    )
    if demoted == 0:
        # Soft warning only — could be the first release with no prior latest.
        print('warn: no `tag: "latest"` to demote (skipping)')

    # Insert the new entry right after `const RELEASES = [`.
    items_jsx = _changelog_to_jsx_items(body)
    new_entry = (
        f"  {{\n"
        f'    ver: "{new_version}", date: "{today}", tag: "latest",\n'
        f"    items: [\n"
        f"{items_jsx}\n"
        f"    ],\n"
        f"  }},\n"
    )

    inserted_text, n = re.subn(
        r"(const RELEASES = \[\s*\n)",
        r"\1" + new_entry,
        new_text,
        count=1,
    )
    if n != 1:
        die("could not locate `const RELEASES = [` in components-sections.jsx")

    WEBSITE_SECTIONS.write_text(inserted_text, encoding="utf-8")


# ---------------------------------------------------------------------------
# Version-drift guard
# ---------------------------------------------------------------------------

# A semver token (optionally ``v``-prefixed). The lookbehind/lookahead keep it
# from matching inside an IPv4 literal (``127.0.0.1``) or a 4+-component version.
# Group 1 is the bare ``X.Y.Z``. Two-component numbers like Python ``3.14`` do
# not match, so the supported-Python list never trips this.
_SEMVER_RE = re.compile(r"(?<![\w.])v?(\d+\.\d+\.\d+)(?!\.?\d)")


def _releases_block_span(text: str) -> tuple[int, int] | None:
    """Character span of the ``const RELEASES = [ ... ]`` array in
    components-sections.jsx, or None if absent. Versions inside this span are
    the intentional historical timeline and are exempt from the drift check."""
    start = text.find("const RELEASES = [")
    if start == -1:
        return None
    i = text.index("[", start)
    depth = 0
    for j in range(i, len(text)):
        if text[j] == "[":
            depth += 1
        elif text[j] == "]":
            depth -= 1
            if depth == 0:
                return (start, j + 1)
    return (start, len(text))


def _rel(path: Path) -> str:
    """Repo-relative path for messages, tolerant of paths outside the repo
    (e.g. a tmp tree under test)."""
    try:
        return str(path.relative_to(REPO_ROOT))
    except ValueError:
        return str(path)


def _release_versions(sections_text: str) -> list[str]:
    """The ``ver: "X.Y.Z"`` values inside the RELEASES block, newest first."""
    span = _releases_block_span(sections_text)
    if span is None:
        return []
    return re.findall(r'ver:\s*"(\d+\.\d+\.\d+)"', sections_text[span[0] : span[1]])


def scan_stale_website_versions(
    new_version: str, prev_version: str | None = None
) -> list[str]:
    """Confirm the site reads ``new_version`` and no longer mentions the version
    it replaced anywhere a reader would see it.

    Two kinds of check:

    * **Positive** — the single source of truth (``website/version.js``), the
      newest ``RELEASES`` entry, and the README install-pin must all equal
      ``new_version``.
    * **Negative** — ``prev_version`` (the version being replaced) must not
      appear outside the historical ``RELEASES`` timeline. This is the "sweep
      for the previous version everywhere" guard the release process needs.
      Searching for the *specific* prior version (not a generic semver) means
      CDN dependency versions, SVG path data, and version-policy prose never
      trip it. When ``prev_version`` is omitted (e.g. the standalone checker),
      it is taken from the second-newest ``RELEASES`` entry.

    Returns human-readable ``file:line`` problems; an empty list means in sync."""
    problems: list[str] = []

    sections_text = (
        WEBSITE_SECTIONS.read_text(encoding="utf-8") if WEBSITE_SECTIONS.exists() else ""
    )
    span = _releases_block_span(sections_text)
    releases = _release_versions(sections_text)

    # --- Positive: version.js is the bumped source of truth. ---
    vjs = WEBSITE_DIR / "version.js"
    if vjs.exists():
        m = re.search(r'window\.HUSKE_VERSION\s*=\s*"([^"]+)"', vjs.read_text(encoding="utf-8"))
        if m is None:
            problems.append('website/version.js: no `window.HUSKE_VERSION = "..."` line')
        elif m.group(1) != new_version:
            problems.append(
                f"website/version.js: HUSKE_VERSION is {m.group(1)}, expected {new_version}"
            )

    # --- Positive: the newest RELEASES entry is the released version. ---
    if releases and releases[0] != new_version:
        problems.append(
            f"website/components-sections.jsx: newest RELEASES entry is "
            f"{releases[0]}, expected {new_version}"
        )

    # --- Positive: the README install-pin points at the new tag. ---
    if README.exists():
        for i, line in enumerate(README.read_text(encoding="utf-8").splitlines(), start=1):
            if "github.com/tiagomoraes/huske.git@" in line:
                for m in _SEMVER_RE.finditer(line):
                    if m.group(1) != new_version:
                        problems.append(
                            f"README.md:{i}: install-pin {m.group(0)!r}, expected {new_version}"
                        )

    # --- Negative: the replaced version must not linger outside RELEASES. ---
    prev = prev_version or (releases[1] if len(releases) > 1 else None)
    if prev and prev != new_version:
        needle = re.compile(rf"(?<![\w.]){re.escape(prev)}(?![\w.])")
        targets = [
            WEBSITE_DIR / "version.js",
            WEBSITE_DIR / "components-shell.jsx",
            WEBSITE_DIR / "components-hero.jsx",
            WEBSITE_DIR / "components-docs.jsx",
            WEBSITE_SECTIONS,
            WEBSITE_DIR / "index.html",
            WEBSITE_DIR / "docs" / "index.html",
            README,
        ]
        for path in targets:
            if not path.exists():
                continue
            text = path.read_text(encoding="utf-8")
            is_sections = path.name == "components-sections.jsx"
            for m in needle.finditer(text):
                if is_sections and span and span[0] <= m.start() < span[1]:
                    continue  # historical RELEASES entry — allowed
                line = text.count("\n", 0, m.start()) + 1
                problems.append(
                    f"{_rel(path)}:{line}: still mentions previous version {prev}"
                )

    return problems


# ---------------------------------------------------------------------------
# Tests + git + PR
# ---------------------------------------------------------------------------


def run_tests() -> None:
    run(sys.executable, "-m", "pytest", "tests/unit", "-q")
    run(
        sys.executable,
        "-m",
        "pytest",
        "tests/integration/test_pipeline_no_whisper.py",
        "tests/integration/test_smoke.py",
        "-q",
    )


def commit_and_push(branch: str, new_version: str, force: bool) -> None:
    # Create / reset branch.
    existing = run(
        "git",
        "show-ref",
        "--verify",
        "--quiet",
        f"refs/heads/{branch}",
        check=False,
    )
    if existing.returncode == 0:
        if not force:
            die(f"branch {branch!r} already exists; pass --force to overwrite")
        run("git", "branch", "-D", branch)
    run("git", "switch", "-c", branch)

    run(
        "git",
        "add",
        "pyproject.toml",
        "CHANGELOG.md",
        "README.md",
        "website/version.js",
        "website/components-sections.jsx",
    )
    run("git", "commit", "-m", f"chore: release v{new_version}")
    run("git", "push", "-u", "origin", branch, *(["--force-with-lease"] if force else []))


def open_pr(branch: str, new_version: str) -> str:
    body = (
        f"Prepares huske v{new_version} for release.\n\n"
        f"- Bumps `pyproject.toml` (and `huske/__init__.py` reads it dynamically).\n"
        f"- Moves the autostart entry from `CHANGELOG.md` `Unreleased` into `## {new_version}`.\n"
        f"- Updates the website RELEASES timeline, the single `website/version.js` "
        f"version source (Nav, Footer, hero, sample transcript all read it), and the "
        f"README install-pin.\n\n"
        f"## Test plan\n\n"
        f"- [x] `pytest tests/unit` + smoke integration suite pass\n"
        f"- [x] `git diff --check` clean\n\n"
        f"## Next steps\n\n"
        f"After this merges, run `python scripts/release-finalize.py {new_version}` to:\n"
        f"open the promotion PR `develop -> main`, then (once merged) tag the\n"
        f"main commit, create the GitHub release, and open the back-merge PR.\n"
    )
    result = run(
        "gh",
        "pr",
        "create",
        "--base",
        "develop",
        "--head",
        branch,
        "--title",
        f"chore: release v{new_version}",
        "--body",
        body,
        capture=True,
    )
    return result.stdout.strip()


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version", help='New semver version, e.g. "0.5.0"')
    parser.add_argument(
        "--skip-tests",
        action="store_true",
        help="Skip running pytest (use only when tests are already green).",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Overwrite an existing release branch.",
    )
    parser.add_argument(
        "--no-push",
        action="store_true",
        help="Stop after committing locally; do not push or open PR.",
    )
    args = parser.parse_args()

    new_version = args.version.lstrip("v")
    today = _dt.date.today().isoformat()

    print(f"\n=== huske release-prep for v{new_version} ({today}) ===\n")

    current = current_pyproject_version()
    validate_version(new_version, current)
    print(f"Bumping {current} → {new_version}")

    preflight()
    bump_pyproject(new_version)
    body = move_changelog_unreleased(new_version, today)
    update_version_js(new_version)
    update_sections_releases(new_version, today, body)
    update_readme_pin(new_version)

    # Confirm the bump landed everywhere and nothing still points at the previous version.
    stale = scan_stale_website_versions(new_version, prev_version=current)
    if stale:
        die(
            "stale version references remain after the bump — the site still "
            "mentions another version:\n  " + "\n  ".join(stale)
        )

    if not args.skip_tests:
        run_tests()
    else:
        print("(skipping tests per --skip-tests)")

    branch = f"release/v{new_version}"
    if args.no_push:
        run("git", "switch", "-c", branch)
        run(
            "git",
            "add",
            "pyproject.toml",
            "CHANGELOG.md",
            "website/components-shell.jsx",
            "website/components-sections.jsx",
        )
        run("git", "commit", "-m", f"chore: release v{new_version}")
        print(f"\n✓ Branch {branch} ready locally. Push and open PR manually.")
        return 0

    commit_and_push(branch, new_version, args.force)
    pr_url = open_pr(branch, new_version)

    print(f"\n✓ Release-prep PR opened: {pr_url}")
    print(
        f"\nReview the website JSX entry — the script's CHANGELOG-to-JSX conversion\n"
        f"is mechanical and you may want to shorten the bullets to match the\n"
        f"existing site style. After review, merge the PR and run:\n\n"
        f"    python scripts/release-finalize.py {new_version}\n"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
