# Issue tracker: GitHub

Issues and PRDs for this repo live as GitHub issues on `tiagomoraes/huske`.
Use the `gh` CLI for all operations; it infers the repo from `git remote -v`
when run inside a clone.

## Conventions

- **Create an issue**: `gh issue create --title "..." --body "..."`. Use a
  heredoc for multi-line bodies.
- **Read an issue**: `gh issue view <number> --comments`.
- **List issues**: `gh issue list --state open --json number,title,body,labels,comments
  --jq '[.[] | {number, title, body, labels: [.labels[].name], comments: [.comments[].body]}]'`
  with appropriate `--label` and `--state` filters.
- **Comment**: `gh issue comment <number> --body "..."`
- **Apply / remove labels**: `gh issue edit <number> --add-label "..."` /
  `--remove-label "..."`
- **Close**: `gh issue close <number> --comment "..."`

## When a skill says "publish to the issue tracker"

Create a GitHub issue.

## When a skill says "fetch the relevant ticket"

Run `gh issue view <number> --comments`.

## Privacy

This repo's issues are public, and the `## Privacy Rules` in `CLAUDE.md` apply
to them exactly as they apply to commits. Never paste real transcript text,
audio paths, `huske doctor` output, local config, or credentials into an issue
body, title, or comment. Use synthetic audio and redacted paths in
reproductions — if a report depends on private material, ask for a synthetic
repro instead of the material itself.

## Related

`docs/issue-triage.md` is the human-facing triage guide: what makes a bug
report or feature request actionable, and when to close. Read it before
writing issue bodies. `docs/agents/triage-labels.md` covers the label state
machine.
