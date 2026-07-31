# Domain Docs

How the engineering skills should consume this repo's domain documentation when
exploring the codebase.

## Before exploring, read these

- **`CONTEXT.md`** at the repo root — a single glossary covering all three
  surfaces (recording engine, macOS app, `huske-mcp` service).
- **`docs/adr/`** — read ADRs that touch the area you're about to work in.
  All ADRs here are system-wide; there are no context-scoped ADR directories.

If any of these files don't exist, **proceed silently**. Don't flag their
absence; don't suggest creating them upfront. The producer skill
(`/grill-with-docs`) creates them lazily when terms or decisions actually get
resolved.

## File structure

This is a single-context repo:

```
/
├── CONTEXT.md              ← one glossary, all surfaces
├── docs/adr/               ← 0001..0009, system-wide
│   ├── 0006-native-macos-app.md
│   └── 0009-git-replica-and-isolated-mcp-service.md
├── huske/                  ← Python recording engine
├── macos/                  ← SwiftPM app + HuskeKit
└── services/huske_mcp/     ← independent Linux/VPS distribution
```

The three source trees are separate distributions with separate dependency
boundaries, but they share one domain language — `CONTEXT.md`'s
`## Relationships` section is the cross-surface glue. If you ever split the
glossary per surface, add a root `CONTEXT-MAP.md` and update this file.

## Use the glossary's vocabulary

When your output names a domain concept (in an issue title, a refactor
proposal, a hypothesis, a test name), use the term as defined in `CONTEXT.md`.
Don't drift to synonyms the glossary explicitly avoids — it is specific about
this: don't say "chunk" for a retrieval unit (that's a **Passage**), don't say
"segment" for the retrieval unit either, and don't revive the retired terms
**huske server**, **Ingest**, or **Connector** when you mean **GitPublisher**,
**ReplicaRepository**, or the **huske-mcp service**.

If the concept you need isn't in the glossary yet, that's a signal — either
you're inventing language the project doesn't use (reconsider) or there's a
real gap (note it for `/grill-with-docs`).

## Flag ADR conflicts

If your output contradicts an existing ADR, surface it explicitly rather than
silently overriding:

> _Contradicts ADR-0009 (git replica and isolated MCP service) — but worth
> reopening because…_
