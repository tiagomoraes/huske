# Releasing

This document is the maintainer release playbook for huske. Releases are manual
for now: changes land on `develop`, stable release snapshots are promoted to
`main`, and GitHub releases are created from annotated version tags on `main`.

## Branch Model

- `develop` is the default integration branch. Feature, fix, docs, and
  dependency PRs target `develop`.
- `main` is the stable release branch. Only release promotion PRs should target
  `main`.
- Work branches are created from `develop` unless they are release or hotfix
  branches.
- Release branches are created from `develop`.
- Hotfix branches are created from `main`, released from `main`, and then
  merged back into `develop`.
- Release tags use `vX.Y.Z`, for example `v0.2.0`.
- Never tag `develop` for a public release. The tag must point at the released
  `main` commit.

Recommended repository settings:

- Require pull requests before merging into `develop` and `main`.
- Require the CI workflow to pass before merging.
- Disallow force pushes and branch deletion on `develop` and `main`.
- Keep `main` stricter than `develop`: only release promotion PRs should merge
  there.

## Branch Naming

Branch names must be lowercase ASCII, use `/` after the type prefix, and use
kebab-case for the descriptive slug. Do not use spaces, underscores, personal
names, or vague slugs like `changes` or `updates`.

Use these prefixes:

| Prefix | Use for | Base branch | PR target |
| --- | --- | --- | --- |
| `feat/<name>` | New user-facing behavior | `develop` | `develop` |
| `fix/<name>` | Bug fixes for unreleased/current development work | `develop` | `develop` |
| `hotfix/<name>` | Urgent fixes for the released `main` line | `main` | `main`, then back to `develop` |
| `chore/<name>` | Maintenance tasks | `develop` | `develop` |
| `docs/<name>` | Documentation-only changes | `develop` | `develop` |
| `test/<name>` | Test-only changes | `develop` | `develop` |
| `refactor/<name>` | Behavior-preserving code changes | `develop` | `develop` |
| `perf/<name>` | Performance improvements | `develop` | `develop` |
| `ci/<name>` | CI and GitHub Actions changes | `develop` | `develop` |
| `release/vX.Y.Z` | Release preparation | `develop` | `develop` |

Examples:

```text
feat/configurable-audio-retention
fix/recovery-empty-session-cleanup
hotfix/transcript-write-crash
chore/update-dependencies
docs/release-process
test/chunker-boundary-cases
refactor/transcription-worker-queue
perf/audio-buffer-drain
ci/cache-python-deps
release/v0.2.0
```

Automation-owned prefixes such as `dependabot/...` are allowed for their tools.
Human and agent-created branches should use the Gitflow prefixes above.

## Versioning

huske follows semantic versioning once public releases begin:

- `MAJOR` for incompatible user-facing or API/format changes.
- `MINOR` for backwards-compatible features.
- `PATCH` for backwards-compatible fixes and docs-only release corrections.

While the project is `0.x`, minor releases may still include sharper changes.
Call those out clearly in `CHANGELOG.md` and GitHub release notes.

## Pre-release Checklist

Run this from an up-to-date `develop`.

```bash
git fetch origin --prune
git switch develop
git pull --ff-only
```

Before creating a release branch:

1. Confirm all intended PRs have merged to `develop`.
2. Confirm no generated audio, transcripts, logs, local config, model caches, or
   private files are in the tree.
3. Confirm `README.md`, `examples/config.toml`, and `specs/` match behavior.
4. Run the current CI baseline locally:

   ```bash
   pytest tests/unit
   pytest tests/integration/test_pipeline_no_whisper.py tests/integration/test_smoke.py
   ```

5. Run at least one manual `huske doctor` on supported macOS hardware.
6. Decide the next version, for example `0.2.0`.

## Prepare the Release Commit on `develop`

Create a release-prep branch from `develop`:

```bash
VERSION=0.2.0
git switch -c release/v$VERSION
```

Update release metadata:

1. Set `version = "$VERSION"` in `pyproject.toml`.
2. Move `CHANGELOG.md` content from `Unreleased` into `## $VERSION - YYYY-MM-DD`.
3. Leave a fresh `## Unreleased` section at the top.
4. If behavior changed, update `README.md`, `examples/config.toml`, and `specs/`.

Validate:

```bash
git diff --check
pytest tests/unit
pytest tests/integration/test_pipeline_no_whisper.py tests/integration/test_smoke.py
```

Commit and open a PR to `develop`:

```bash
git add pyproject.toml CHANGELOG.md README.md examples specs
git commit -m "chore: release v$VERSION"
git push -u origin release/v$VERSION
gh pr create --base develop --head release/v$VERSION \
  --title "chore: release v$VERSION" \
  --body "Prepares huske v$VERSION for release."
```

Merge this PR only after review and CI pass.

## Hotfix Releases

Use a hotfix only when the current `main` branch needs an urgent patch before
the normal `develop` release train.

Create the hotfix from `main`:

```bash
git fetch origin --prune --tags
git switch main
git pull --ff-only
git switch -c hotfix/<short-critical-fix>
```

Make the minimal fix, update `pyproject.toml` and `CHANGELOG.md` for the patch
version, and validate:

```bash
git diff --check
pytest tests/unit
pytest tests/integration/test_pipeline_no_whisper.py tests/integration/test_smoke.py
```

Open the hotfix PR to `main`:

```bash
gh pr create --repo tiagomoraes/huske \
  --base main \
  --head hotfix/<short-critical-fix> \
  --title "hotfix: <short critical fix>" \
  --body "Fixes an urgent issue for the released main line."
```

After the hotfix PR merges to `main`, tag and publish it using the same
`main`-tagged GitHub release flow below. Then bring the fix back to `develop`
immediately — same pattern as
[Sync `main` Back to `develop`](#sync-main-back-to-develop) after a normal
release, with a hotfix-specific branch and title:

```bash
git fetch origin --prune --tags
git switch -c chore/sync-main-hotfix-after-v$VERSION origin/develop
git merge origin/main --no-ff \
  -m "chore: sync main hotfix back into develop"
git push -u origin chore/sync-main-hotfix-after-v$VERSION
gh pr create --repo tiagomoraes/huske \
  --base develop \
  --head chore/sync-main-hotfix-after-v$VERSION \
  --title "chore: sync main hotfix back to develop" \
  --body "Brings the released hotfix into develop. MERGE WITH 'Create a merge commit' — squash drops the second parent."
```

If `main` contains release-only metadata that should not be merged wholesale,
create a `fix/<same-short-fix>` branch from `develop` and cherry-pick the
hotfix commit instead.

## Promote `develop` to `main`

After the release-prep PR has merged to `develop`, create a promotion PR from
`develop` to `main`:

```bash
gh pr create --repo tiagomoraes/huske \
  --base main \
  --head develop \
  --title "release: v$VERSION" \
  --body "Promotes develop to main for huske v$VERSION."
```

Review the PR carefully:

```bash
gh pr diff --repo tiagomoraes/huske <PR_NUMBER> --name-only
gh pr checks --repo tiagomoraes/huske <PR_NUMBER>
```

Merge the promotion PR only after approval and green CI. Prefer a regular merge
commit for the promotion PR so `main` clearly records the release promotion.

## Sync `main` Back to `develop`

Immediately after the promotion PR merges, back-merge `main` into `develop`
so `main`'s new merge commit (and the soon-to-be tag) are reachable from
`develop`. Without this step, every subsequent `develop -> main` PR will be
flagged "out of date with the base branch" and the new release tag will not
be reachable from `develop`.

There are two non-obvious traps; the recipe below sidesteps both:

1. **Do not use `head=main` for the PR.** This repo has
   `delete_branch_on_merge: true`, so a PR with `head=main` causes GitHub to
   auto-delete `main` after merge. Create a throwaway branch from `develop`
   and merge `main` into it locally instead.
2. **Do not "Squash and merge" this PR.** Squashing copies the content but
   drops `main`'s tip as a second parent — `main`'s history never lands in
   `develop`'s ancestry, so the "out of date" warning persists on every
   subsequent `develop -> main` PR. Use **"Create a merge commit"** for
   this PR specifically.

```bash
VERSION=0.2.0
git fetch origin --prune --tags
git switch -c chore/sync-main-after-v$VERSION origin/develop
git merge origin/main --no-ff \
  -m "chore: sync main back into develop after v$VERSION"
git push -u origin chore/sync-main-after-v$VERSION
gh pr create --repo tiagomoraes/huske \
  --base develop \
  --head chore/sync-main-after-v$VERSION \
  --title "chore: sync main back into develop after v$VERSION" \
  --body "Brings the v$VERSION promotion merge commit and tag into develop. MERGE WITH 'Create a merge commit' — squash drops the second parent."
```

The file diff against `develop` is empty — the promotion PR put exactly this
content on `main`. This PR only adds ancestry. Merge it (with **Create a
merge commit**) before opening any new `develop -> main` PR.

The same pattern applies after a hotfix lands on `main`; see
[Hotfix Releases](#hotfix-releases) for the hotfix-specific PR title.

## Tag the Released `main` Commit

After the promotion PR is merged:

```bash
git fetch origin --prune --tags
git switch main
git pull --ff-only
git status --short
```

Confirm `pyproject.toml` contains the intended version and `CHANGELOG.md` has
the matching release section.

Create and push an annotated tag from `main`:

```bash
VERSION=0.2.0
git tag -a "v$VERSION" -m "huske v$VERSION"
git push origin "v$VERSION"
```

Do not move a published release tag. If a release is wrong after publication,
make a new patch release.

## Create the GitHub Release

Create the release from the tag that already exists on GitHub. Use the
corresponding `CHANGELOG.md` release section as the release notes:

```bash
${EDITOR:-vi} /tmp/huske-release-notes.md
gh release create "v$VERSION" \
  --repo tiagomoraes/huske \
  --verify-tag \
  --title "huske v$VERSION" \
  --notes-file /tmp/huske-release-notes.md
```

If you use GitHub-generated release notes, still use `--verify-tag`:

```bash
gh release create "v$VERSION" \
  --repo tiagomoraes/huske \
  --verify-tag \
  --title "huske v$VERSION" \
  --generate-notes
```

`--verify-tag` is important because this repository's default branch is
`develop`; without an existing tag, GitHub CLI can create a release tag from the
default branch instead of the intended `main` commit.

Publishing the GitHub release triggers `.github/workflows/release.yml`. That
workflow builds the sdist and wheel, attaches both distributions to the GitHub
release, and publishes them to PyPI through trusted publishing.

## PyPI Trusted Publishing

PyPI publishing uses GitHub Actions trusted publishing, so no PyPI API token is
stored in GitHub. The `huske` PyPI project was created during the `v0.1.0`
release and is configured for the `release.yml` workflow in the GitHub
environment named `pypi`.

If the PyPI project ever has to be recreated, add a pending publisher in PyPI
before publishing:

- PyPI project name: `huske`
- Owner: `tiagomoraes`
- Repository name: `huske`
- Workflow filename: `release.yml`
- Environment name: `pypi`

If the PyPI publisher is configured after the GitHub release is created, rerun
the failed `Publish to PyPI` job or manually run the `Release` workflow with
`publish_pypi` enabled from the `vX.Y.Z` tag.

After the workflow publishes, verify the package before updating Homebrew:

```bash
python -m venv /tmp/huske-pypi-check
/tmp/huske-pypi-check/bin/python -m pip install --upgrade pip
/tmp/huske-pypi-check/bin/python -m pip install "huske==$VERSION"
/tmp/huske-pypi-check/bin/huske --version
```

## Homebrew

Homebrew releases are maintained from the `tiagomoraes/homebrew-huske` tap after
the matching PyPI release exists. Users install it with:

```bash
brew tap tiagomoraes/huske
brew install huske
```

Homebrew maps the tap name `tiagomoraes/huske` to the repository
`tiagomoraes/homebrew-huske`.

Update the tap after PyPI verification:

```bash
VERSION=0.2.0
brew tap tiagomoraes/huske
cd "$(brew --repo tiagomoraes/huske)"
git pull --ff-only
```

Update `Formula/huske.rb`:

1. Change the stable `url` to the new PyPI sdist URL.
2. Change `sha256` to the new sdist hash.
3. Refresh Python `resource` blocks from the exact PyPI dependency set.
4. Preserve the custom `install` method. Do not replace it with plain
   `virtualenv_install_with_resources`.

The formula intentionally installs most Python dependencies from pinned wheels
because several transitive packages publish macOS platform wheels. The `av`
resource is intentionally an sdist and is built against Homebrew `ffmpeg`; the
PyAV wheels vendor dynamic libraries that do not relocate cleanly in Homebrew.
Keep the `pkgconf`, `ffmpeg`, `cython`, and `build_isolation: false` behavior
unless the formula has been retested without it.

A structured pip report is the easiest source for resource URLs and hashes:

```bash
python -m pip install --upgrade pip
python -m pip install --dry-run --ignore-installed \
  --report /tmp/huske-pip-report.json "huske==$VERSION"
```

Validate the tap locally:

```bash
brew style Formula/huske.rb
brew audit --strict --online tiagomoraes/huske/huske
brew install --build-from-source tiagomoraes/huske/huske
brew test tiagomoraes/huske/huske
huske --version
```

Commit and push the tap:

```bash
git add Formula/huske.rb README.md
git commit -m "Update huske to v$VERSION"
git push
```

## Post-release

1. Confirm the GitHub release points at the `vX.Y.Z` tag.
2. Confirm the tag commit is contained in `origin/main`.
3. Confirm `develop` contains the release commit and the new tag is reachable
   from `develop` (the back-merge PR has landed).
4. Confirm the release workflow succeeded or record the failed publishing step.
5. Confirm the PyPI project page is live and `huske==$VERSION` installs.
6. Confirm the Homebrew tap points at the released version and passes
   `brew test`.
7. Confirm the public install commands in `README.md` are still correct.
8. Announce the release wherever relevant.
9. Open follow-up issues for anything intentionally deferred.

Helpful checks:

```bash
gh release view "v$VERSION" --repo tiagomoraes/huske
git branch --remote --contains "v$VERSION"
```

## Rollback and Corrections

- Before publication: delete the draft release or local tag if needed, fix the
  issue, and recreate the tag from the corrected `main` commit.
- After publication: do not rewrite the tag. Fix forward with a new patch
  release.
- If the GitHub release notes are wrong but the tag is correct, edit the release
  notes without moving the tag.

## Future Automation

The release workflow automates package builds, GitHub release assets, and PyPI
publishing. The release promotion, tag creation, GitHub release publication, and
Homebrew tap updates remain explicit maintainer steps tied to `main` tags.

## References

- GitHub release management:
  <https://docs.github.com/github/administering-a-repository/creating-releases>
- GitHub CLI `gh release create`:
  <https://cli.github.com/manual/gh_release_create>
- GitHub branch protection:
  <https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches>
- GitHub generated release notes:
  <https://docs.github.com/en/repositories/releasing-projects-on-github/automatically-generated-release-notes>
- PyPI trusted publishing:
  <https://docs.pypi.org/trusted-publishers/>
- Homebrew taps:
  <https://docs.brew.sh/Taps>
