# Releasing

This document is the maintainer release playbook for huske. Releases are manual
for now: changes land on `develop`, stable release snapshots are promoted to
`main`, and GitHub releases are created from annotated version tags on `main`.

## Branch Model

- `develop` is the default integration branch. Feature, fix, docs, and
  dependency PRs target `develop`.
- `main` is the stable release branch. Only release promotion PRs should target
  `main`.
- Release tags use `vX.Y.Z`, for example `v0.2.0`.
- Never tag `develop` for a public release. The tag must point at the released
  `main` commit.

Recommended repository settings:

- Require pull requests before merging into `develop` and `main`.
- Require the CI workflow to pass before merging.
- Disallow force pushes and branch deletion on `develop` and `main`.
- Keep `main` stricter than `develop`: only release promotion PRs should merge
  there.

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

## Post-release

1. Confirm the GitHub release points at the `vX.Y.Z` tag.
2. Confirm the tag commit is contained in `origin/main`.
3. Confirm `develop` contains the release commit.
4. Announce the release wherever relevant.
5. Open follow-up issues for anything intentionally deferred.

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

PyPI publishing and fully automated releases can be added later. Until then,
keep release operations explicit, reviewed, and tied to `main` tags.

## References

- GitHub release management:
  <https://docs.github.com/github/administering-a-repository/creating-releases>
- GitHub CLI `gh release create`:
  <https://cli.github.com/manual/gh_release_create>
- GitHub branch protection:
  <https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches>
- GitHub generated release notes:
  <https://docs.github.com/en/repositories/releasing-projects-on-github/automatically-generated-release-notes>
