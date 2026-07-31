# Connect agents to Huske

The recording Mac no longer runs an MCP server. It publishes immutable
transcripts to a private Git repository; the independent `huske-mcp` service on
your VPS pulls, indexes, and serves them permanently.

Set up the topology first: [Always-on transcript service](server.md).

## MCP endpoint

Agents that accept custom HTTP headers use:

```text
URL: https://huske.example.com/mcp
Authorization: Bearer <your VPS read token>
```

For a co-located agent, keep traffic on loopback:

```text
URL: http://127.0.0.1:7641/mcp
Authorization: Bearer <token>
```

Available tools:

| Tool | Purpose |
| --- | --- |
| `overview` | Corpus coverage, density, current replica commit/status |
| `recap` | Chronological content for a day or date range |
| `search` | Topic search with date/source/session filters |
| `fetch` | Verbatim passage plus nearby context |
| `sync_status` | Git/index health without credentials |

The recommended agent sequence is overview → search/recap → fetch before
quoting.

## Search profiles

The default `tiny` profile is designed for a 512 MB VPS. It uses Unicode FTS5
and reports `mode: "fts5"` honestly. Date, source, and session queries do not
need embeddings and remain exact.

The optional `semantic` profile uses Model2Vec dense embeddings and reciprocal
rank fusion with FTS5. It reports `mode: "hybrid"`. The default multilingual
model is not appropriate for a 512 MB box; use at least 1 GB or configure a
smaller language-specific model.

## Clients without bearer headers

Some hosted consumer connectors insist on OAuth and cannot send a pre-shared
header. The small Huske service does not embed an OAuth authorization server.
Put an identity-aware OAuth proxy in front, or use an agent/client that supports
authenticated custom MCP endpoints. This keeps account management and browser
login code out of the transcript service.

## File-only destinations

`huske export` still produces one Markdown digest per day for destinations that
cannot speak MCP:

```bash
huske export
huske export --statements-only
```

Exports are derived and regenerable. Cloud sync publishes canonical transcript
files, not the export directory.
