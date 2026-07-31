# Triage Labels

The skills speak in terms of five canonical triage roles. This file maps those
roles to the actual label strings used in this repo's issue tracker.

| Label in mattpocock/skills | Label in our tracker | Meaning                                  |
| -------------------------- | -------------------- | ---------------------------------------- |
| `needs-triage`             | `needs-triage`       | Maintainer needs to evaluate this issue  |
| `needs-info`               | `needs-info`         | Waiting on reporter for more information |
| `ready-for-agent`          | `ready-for-agent`    | Fully specified, ready for an AFK agent  |
| `ready-for-human`          | `ready-for-human`    | Requires human implementation            |
| `wontfix`                  | `wontfix`            | Will not be actioned                     |

When a skill mentions a role (e.g. "apply the AFK-ready triage label"), use the
corresponding label string from this table.

## These are workflow state, not topic

This vocabulary is orthogonal to the topical labels documented in
`docs/issue-triage.md` (`bug`, `feature`, `docs`, `privacy`, `good first
issue`, `help wanted`, `blocked`, …). An issue carries one triage-state label
from the table above *and* whatever topical labels apply. Don't substitute one
for the other.

Two topical labels overlap in spirit but are **not** aliases: `needs
reproduction` narrows "we need something from you" to a repro specifically,
while `needs-info` is the general waiting-on-reporter state; `needs decision`
means a maintainer must choose a direction, while `needs-triage` only means
nobody has looked yet.

Edit the right-hand column to match whatever vocabulary you actually use.
