# Issue Triage

This guide keeps issues actionable once the project is public.

## Labels

- `bug`: confirmed or likely defect.
- `feature`: new or changed behavior.
- `docs`: documentation-only work.
- `privacy`: behavior involving audio, transcripts, logs, consent, or local data.
- `good first issue`: small, well-scoped, low-context task.
- `help wanted`: scoped work where outside contribution is welcome.
- `needs reproduction`: report needs a minimal repro.
- `needs decision`: maintainer needs to choose product or architecture direction.
- `blocked`: cannot progress until an external condition changes.

## Bug reports

A bug is actionable when it has:

- Version or commit.
- Platform and Python version.
- Command or workflow that failed.
- Expected behavior.
- Actual behavior.
- Minimal reproduction with synthetic or redacted data.

If a report depends on private audio or transcripts, ask for a synthetic repro
instead of requesting the private material.

## Feature requests

A feature request is actionable when it describes:

- The workflow or user problem.
- Why existing behavior is insufficient.
- Proposed behavior.
- Privacy or consent implications.
- Acceptance criteria or examples.

## Closing issues

Close issues that are duplicates, unsupported by a reproduction after follow-up,
outside project scope, or unsafe to handle publicly. Link to the relevant issue,
PR, or documentation when closing.
