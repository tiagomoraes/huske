#!/usr/bin/env python3
"""Post-promotion finalize step for huske releases.

Run this AFTER the `release: vX.Y.Z` PR (develop -> main) has merged.

Usage:
    python scripts/release-finalize.py 0.5.0

What it does:

  1. Pre-flight: fetches origin, checks out `main`, verifies HEAD is the
     promotion merge commit and `pyproject.toml` matches the requested
     version.
  2. Creates an annotated tag `vX.Y.Z` on the `main` HEAD and pushes it.
  3. Extracts the matching `## X.Y.Z` section from `CHANGELOG.md` as
     release notes.
  4. Runs `gh release create vX.Y.Z --verify-tag` — this triggers the
     `release.yml` workflow which builds sdist + wheel and publishes to
     PyPI via trusted publishing.
  5. Opens the back-merge PR `chore/sync-main-after-vX.Y.Z` from a
     temporary branch (NOT `head=main`, which would be auto-deleted), or
     reports the PR that `.github/workflows/back-merge.yml` already opened.
     The PR body reminds the reviewer to use "Create a merge commit"
     instead of squash.
  6. Optionally polls until the release workflow succeeds and prints a
     hint to run `python scripts/update-homebrew-tap.py X.Y.Z`.

Idempotent where it can be: rerunning after the tag exists is a no-op for
the tag, the GitHub release is created only once, and the back-merge step
reports an existing PR/branch (including the one `back-merge.yml` opens
automatically) instead of failing.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
import tempfile
import time
import tomllib
from pathlib import Path
from typing import NoReturn

REPO_ROOT = Path(__file__).resolve().parent.parent
PYPROJECT = REPO_ROOT / "pyproject.toml"
CHANGELOG = REPO_ROOT / "CHANGELOG.md"

SEMVER_RE = re.compile(r"^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.\-+]+)?$")


def run(
    *args: str,
    capture: bool = False,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    print(f"$ {' '.join(args)}")
    return subprocess.run(
        list(args),
        check=check,
        text=True,
        capture_output=capture,
    )


def die(message: str, code: int = 1) -> NoReturn:
    print(f"error: {message}", file=sys.stderr)
    sys.exit(code)


def current_pyproject_version() -> str:
    with PYPROJECT.open("rb") as f:
        return str(tomllib.load(f)["project"]["version"])


def extract_changelog_section(version: str) -> str:
    text = CHANGELOG.read_text(encoding="utf-8")
    pattern = re.compile(
        rf"^## {re.escape(version)}\b[^\n]*\n"
        r"(?P<body>.*?)"
        r"(?=^## )",
        re.S | re.M,
    )
    match = pattern.search(text)
    if not match:
        die(f"could not find `## {version}` section in CHANGELOG.md")
    return match.group("body").strip("\n")


def preflight(version: str) -> None:
    run("git", "fetch", "origin", "--prune", "--tags")
    run("git", "switch", "main")
    run("git", "pull", "--ff-only")

    pyproj = current_pyproject_version()
    if pyproj != version:
        die(
            f"pyproject.toml on main is {pyproj!r}, expected {version!r}. "
            f"Did the promotion PR merge yet?"
        )

    head_parents = run(
        "git", "log", "-1", "--format=%P", "HEAD", capture=True
    ).stdout.strip().split()
    if len(head_parents) < 2:
        die(
            "main HEAD is not a merge commit (only one parent). The promotion "
            "PR may have been squashed instead of using \"Create a merge "
            "commit\". The back-merge will not work — fix on GitHub before "
            "continuing."
        )


def tag_main(version: str) -> str:
    tag = f"v{version}"
    existing = run("git", "rev-parse", "--verify", tag, capture=True, check=False)
    if existing.returncode == 0:
        print(f"tag {tag} already exists locally — skipping creation")
    else:
        run("git", "tag", "-a", tag, "-m", f"huske {tag}")

    # Push only if the remote doesn't already have the tag.
    remote_check = run(
        "git", "ls-remote", "--tags", "origin", tag, capture=True
    ).stdout.strip()
    if remote_check:
        print(f"tag {tag} already on origin — skipping push")
    else:
        run("git", "push", "origin", tag)
    return tag


def create_github_release(version: str, repo: str) -> None:
    tag = f"v{version}"
    existing = run(
        "gh",
        "release",
        "view",
        tag,
        "--repo",
        repo,
        capture=True,
        check=False,
    )
    if existing.returncode == 0:
        print(f"GitHub release {tag} already exists — skipping creation")
        return

    notes = extract_changelog_section(version)
    with tempfile.NamedTemporaryFile(
        mode="w", suffix=".md", delete=False, encoding="utf-8"
    ) as f:
        f.write(notes)
        notes_path = f.name

    run(
        "gh",
        "release",
        "create",
        tag,
        "--repo",
        repo,
        "--verify-tag",
        "--title",
        f"huske {tag}",
        "--notes-file",
        notes_path,
    )


def wait_for_release_workflow(version: str, repo: str, timeout_s: int) -> bool:
    """Poll until the release workflow run for this tag succeeds. Returns True
    on success, False on timeout (does NOT die)."""
    tag = f"v{version}"
    deadline = time.time() + timeout_s
    last_status = ""
    while time.time() < deadline:
        result = run(
            "gh",
            "run",
            "list",
            "--repo",
            repo,
            "--workflow=release.yml",
            "--branch",
            tag,
            "--limit=1",
            "--json",
            "status,conclusion",
            capture=True,
            check=False,
        )
        if result.returncode == 0 and result.stdout.strip():
            import json as _json

            entries = _json.loads(result.stdout)
            if entries:
                status = entries[0].get("status") or ""
                conclusion = entries[0].get("conclusion") or ""
                summary = f"{status}/{conclusion or '-'}"
                if summary != last_status:
                    print(f"release workflow: {summary}")
                    last_status = summary
                if status == "completed":
                    return conclusion == "success"
        time.sleep(5)
    print(f"timed out waiting {timeout_s}s for release workflow")
    return False


def open_back_merge_pr(version: str, repo: str) -> str | None:
    branch = f"chore/sync-main-after-v{version}"

    # `.github/workflows/back-merge.yml` opens this PR automatically when the
    # promotion PR merges into `main`. If it already has, report the existing PR
    # instead of racing it: blindly recreating the branch and pushing would fail
    # non-fast-forward against the branch the workflow already pushed.
    existing_pr = run(
        "gh",
        "pr",
        "list",
        "--repo",
        repo,
        "--head",
        branch,
        "--base",
        "develop",
        "--state",
        "open",
        "--json",
        "url",
        "--jq",
        ".[0].url // empty",
        capture=True,
        check=False,
    ).stdout.strip()
    if existing_pr:
        print(f"back-merge PR already open (created by back-merge.yml): {existing_pr}")
        return existing_pr

    # No PR yet. If the workflow pushed the branch but not the PR, open the PR
    # from that remote branch; otherwise (e.g. Actions disabled) build the
    # branch locally and push it ourselves.
    remote_branch = run(
        "git", "ls-remote", "--heads", "origin", branch, capture=True, check=False
    ).stdout.strip()
    if not remote_branch:
        local = run(
            "git",
            "show-ref",
            "--verify",
            "--quiet",
            f"refs/heads/{branch}",
            check=False,
        )
        if local.returncode == 0:
            run("git", "branch", "-D", branch)
        run("git", "switch", "-c", branch, "origin/develop")
        run(
            "git",
            "merge",
            "origin/main",
            "--no-ff",
            "-m",
            f"chore: sync main back into develop after v{version}",
        )
        run("git", "push", "-u", "origin", branch)

    body = (
        f"Brings the v{version} promotion merge commit and tag into `develop`.\n\n"
        f"The file diff against `develop` is empty — the promotion PR put exactly "
        f"this content on `main`. This PR only adds ancestry so future "
        f"`develop -> main` PRs don't show \"out of date\" and the `v{version}` "
        f"tag is reachable from `develop`.\n\n"
        f"## ⚠️ Merge instructions\n\n"
        f"> Use **\"Create a merge commit\"**, not squash. Squashing copies the "
        f"content but drops `main`'s tip as a second parent — `main`'s history "
        f"never lands in `develop`'s ancestry, defeating the whole purpose of "
        f"this PR.\n"
    )
    result = run(
        "gh",
        "pr",
        "create",
        "--repo",
        repo,
        "--base",
        "develop",
        "--head",
        branch,
        "--title",
        f"chore: sync main back into develop after v{version}",
        "--body",
        body,
        capture=True,
        check=False,
    )
    if result.returncode != 0:
        # Likely a PR already exists for this branch.
        print("note: gh pr create returned non-zero — a PR may already exist")
        return None
    return result.stdout.strip()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version", help='Semver version of the merged release, e.g. "0.5.0"')
    parser.add_argument(
        "--repo",
        default="tiagomoraes/huske",
        help="GitHub repo for `gh` invocations.",
    )
    parser.add_argument(
        "--wait",
        type=int,
        default=180,
        help="Seconds to wait for the release workflow to succeed (0 to skip).",
    )
    parser.add_argument(
        "--skip-back-merge",
        action="store_true",
        help="Skip opening the back-merge PR.",
    )
    args = parser.parse_args()

    new_version = args.version.lstrip("v")
    if not SEMVER_RE.match(new_version):
        die(f"version {new_version!r} is not semver (X.Y.Z)")

    print(f"\n=== huske release-finalize for v{new_version} ===\n")

    preflight(new_version)
    tag_main(new_version)
    create_github_release(new_version, args.repo)

    if args.wait > 0:
        wait_for_release_workflow(new_version, args.repo, args.wait)

    pr_url: str | None = None
    if not args.skip_back_merge:
        pr_url = open_back_merge_pr(new_version, args.repo)

    print("\n=== done ===")
    print(f"  tag:           v{new_version} pushed")
    print(f"  release:       https://github.com/{args.repo}/releases/tag/v{new_version}")
    if pr_url:
        print(f"  back-merge PR: {pr_url}")
        print(
            "                 ⚠️  merge with \"Create a merge commit\" "
            "(not squash)"
        )
    print(
        "\nNext: once PyPI confirms v"
        + new_version
        + " is live, run:\n"
        + f"    python scripts/update-homebrew-tap.py {new_version}\n"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
