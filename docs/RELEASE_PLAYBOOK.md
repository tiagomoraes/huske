# Release playbook (short version)

The complete reference is [`docs/releasing.md`](releasing.md). This document
is the **operational checklist** — what to actually run, in order, with
explicit "stop here" points so a human reviewer (or an LLM agent operating
on the repo) cannot accidentally skip a step.

A release moves through three GitHub PRs and one tag/release event:

```
develop ──► develop ──► main ──► develop
release-prep   promotion   tag+   back-merge
                          PyPI    (auto)
```

Almost everything below is wrapped by one of three scripts:

| Script | Runs when | What it does |
|---|---|---|
| `scripts/release.py X.Y.Z` | from up-to-date `develop` | Bumps version, moves CHANGELOG, updates website, runs tests, opens **release-prep PR** to `develop`. |
| `scripts/release-finalize.py X.Y.Z` | after promotion PR merges | Tags `main`, creates GitHub release (triggers PyPI publish), opens back-merge PR. |
| `scripts/update-homebrew-tap.py X.Y.Z` | after PyPI is live | Refreshes the tap formula's url + sha256 + all 55 resources. |

The auto back-merge PR is also created by `.github/workflows/back-merge.yml`
when a `release: v*` or `hotfix:*` PR merges to `main` — the script's
back-merge step is a fallback in case the workflow is disabled.

---

## 0. Pre-flight (once per release cycle)

Confirm everything intended for this release has merged to `develop`:

```bash
git fetch origin --prune --tags
git switch develop
git pull --ff-only
gh pr list --base develop --state open      # ensure no must-have PRs are still open
```

Pick the next semver: `MAJOR.MINOR.PATCH`. Examples for `v0.5.0`:

```bash
export VERSION=0.5.0
```

---

## 1. Release-prep PR (`develop` → `develop`)

```bash
python scripts/release.py "$VERSION"
```

The script:
- Refuses to run if you're not on `develop`, the working tree is dirty, or
  `develop` is out of sync with origin.
- Bumps `pyproject.toml` (and `huske/__init__.py` reads it dynamically so
  there is **only one source of truth**).
- Moves `## Unreleased` content to `## $VERSION - YYYY-MM-DD` in
  `CHANGELOG.md`.
- Mechanically updates `website/components-shell.jsx` (Nav + Footer) and
  inserts a new `RELEASES` entry in `website/components-sections.jsx` with
  bullets converted from the moved CHANGELOG section.
- Runs unit tests + the smoke integration suite.
- Pushes `release/v$VERSION` and opens the PR via `gh pr create`.

> **Review the website JSX** before merging — the auto-converted bullets
> often read as too long for the site style. Tighten them up in the PR.

### 🛑 STOP

A human reviews and merges the release-prep PR with default settings
("Squash and merge" or "Create a merge commit" — both are acceptable for
this PR; the back-merge cares about the *promotion* PR's merge type, not
this one).

---

## 2. Promotion PR (`develop` → `main`)

```bash
gh pr create --repo tiagomoraes/huske \
  --base main --head develop \
  --title "release: v$VERSION" \
  --body "Promotes develop to main for huske v$VERSION."
```

### 🛑 STOP

A human reviews and merges with **"Create a merge commit"**. Not squash.
Not rebase.

> **Why merge commit specifically:** the back-merge PR (next step) brings
> `main`'s tip back into `develop` as ancestry. If you squash here, `main`'s
> tip is a single-parent commit that doesn't include `main`'s prior
> commits as ancestors — every later `develop -> main` PR will then show
> "out of date" on GitHub until the next promotion. Squash drops history
> we need.

---

## 3. Tag, GitHub release, back-merge

```bash
python scripts/release-finalize.py "$VERSION"
```

The script:
1. Pulls `main`, verifies `pyproject.toml` matches `$VERSION`, and that
   `main` HEAD is a real merge commit (warns if it was squashed).
2. Creates annotated tag `v$VERSION` and pushes it.
3. Extracts `## $VERSION` from `CHANGELOG.md` as release notes.
4. `gh release create v$VERSION --verify-tag …` — this triggers
   `.github/workflows/release.yml`, which builds sdist + wheel and
   publishes to PyPI via trusted publishing.
5. Polls until the workflow finishes (default 180 s).
6. Opens the back-merge PR `chore/sync-main-after-v$VERSION` from a temp
   branch (NOT `head=main` — that would auto-delete `main` because of
   `delete_branch_on_merge: true`).

The back-merge PR is **also** opened automatically by
`.github/workflows/back-merge.yml`. The script's version is the fallback
if Actions are disabled.

### 🛑 STOP

A human reviews and merges the back-merge PR with **"Create a merge
commit"**. Same rule as the promotion PR — squash defeats the point.

---

## 4. Homebrew tap (`tiagomoraes/homebrew-huske`)

```bash
python scripts/update-homebrew-tap.py "$VERSION"
```

The script:
- Locates the tap clone via `brew --repo tiagomoraes/huske`.
- Pulls `huske==$VERSION` metadata from PyPI (sdist url + sha256).
- Runs `pip install --dry-run --report` and updates every existing
  resource block's `url` + `sha256` in place.
- Reports any **added** or **removed** dependencies (does not auto-edit
  blocks — those need human ordering).
- Runs `brew style` and `brew audit --strict --online`.

### 🛑 STOP

A human runs the final three commands the script prints:

```bash
brew install --build-from-source tiagomoraes/huske/huske
brew test tiagomoraes/huske/huske
cd "$(brew --repo tiagomoraes/huske)" && git push
```

The tap repo does not use PRs (it's a personal tap); the maintainer pushes
directly to `master`.

---

## Hotfix flow

Hotfixes start from `main`, not `develop`:

```bash
git fetch origin --prune --tags
git switch main && git pull --ff-only
git switch -c hotfix/<short-fix>
# ...edit, bump version (patch), update CHANGELOG, commit...
gh pr create --base main --head hotfix/<short-fix> --title "hotfix: <short fix>"
```

After merge: same `release-finalize.py` and `update-homebrew-tap.py`
sequence. The auto back-merge workflow recognises both `release: v…` and
`hotfix:…` titles.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `huske --version` shows old version after a bump | Editable install dist-info is stale | Not actually a problem — `huske/__init__.py` reads `pyproject.toml` directly when it's adjacent to the package. If still wrong, run `pip install -e . --no-deps`. |
| `release-finalize.py` says "main HEAD is not a merge commit" | Promotion PR was squashed | The release shipping is unaffected, but the back-merge will not add ancestry. Open the next release from `develop` rebased onto `main` to recover. |
| `release.yml` workflow fails to publish to PyPI | First-time PyPI trusted publisher not configured, or workflow filename changed | See [`docs/releasing.md` → PyPI Trusted Publishing](releasing.md#pypi-trusted-publishing). |
| Back-merge PR says "out of date with the base branch" right after merging promotion | Promotion was squashed — see above | — |
| `update-homebrew-tap.py` reports added/removed deps | The dependency tree changed | Manually edit `Formula/huske.rb` to add/remove the listed `resource` blocks, then re-run the script. |

---

## Why this is structured this way

- **Three PRs, not one.** Release-prep, promotion, and back-merge each
  serve different reviewers and protect different invariants.
  Collapsing them loses the squash-vs-merge guard rail and makes
  hotfix-from-main impossible to express cleanly.
- **Scripts, not aliases.** A bash alias loses the pre-flight checks; the
  scripts validate working-tree state, semver format, branch sync, and
  test results before touching anything.
- **Single source of truth for version.** `huske/__init__.py` reads
  `pyproject.toml` so the two cannot diverge silently — historically that
  was the cause of [#18 hotfix](https://github.com/tiagomoraes/huske/pull/18).
- **Tap automation is offline-friendly.** Updating the Homebrew tap runs
  on the maintainer's Mac (Xcode toolchain, brew, the existing tap
  clone). A GitHub Action would be slower and require cross-repo tokens.
