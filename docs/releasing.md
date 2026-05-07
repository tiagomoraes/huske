# Releasing

huske does not have a public release process yet. Use this checklist when the
first release is ready.

## Pre-release

1. Confirm `CHANGELOG.md` has entries for the release.
2. Confirm `README.md`, `examples/config.toml`, and `specs/` match behavior.
3. Run the standard checks from [development.md](development.md).
4. Run at least one manual `huske doctor` on a supported macOS machine.
5. Verify no audio, transcripts, logs, model files, or private config are
   included in the tree.

## Release

1. Update the version in `pyproject.toml`.
2. Move `CHANGELOG.md` entries from `Unreleased` to the new version.
3. Commit with `chore: release vX.Y.Z`.
4. Tag the commit with `vX.Y.Z`.
5. Publish GitHub release notes from the changelog.

PyPI publishing can be added later once package ownership and release
automation are decided.
