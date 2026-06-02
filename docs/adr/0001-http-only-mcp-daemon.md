---
status: accepted
---

# HTTP-only persistent daemon for the MCP server

## Context

huske exposes its transcripts to local chat models (Claude Code, Claude
Desktop, ChatGPT) through an MCP server. The near-universal convention for a
*local* MCP server is **stdio**: the client launches the server as a
subprocess and talks JSON-RPC over stdin/stdout. A future reader will see a
long-running HTTP daemon with a bearer token and reasonably ask "why didn't
this just use stdio like every other local MCP server?"

## Decision

`huske mcp` runs a single **always-on Streamable-HTTP daemon** bound to
`127.0.0.1`, guarded by an auto-generated **bearer token** and **Origin/Host
validation** (DNS-rebinding defense). It is **not** launched per-client over
stdio. Clients connect to `http://127.0.0.1:<port>/mcp`; ChatGPT reaches it via
a user-provided tunnel (documented, not built-in for v1).

## Why (the trade-off)

- **Load the embedding model once.** Under stdio every client spawns its own
  server and reloads `multilingual-e5-base` on each launch. A persistent daemon
  loads it once and serves all clients.
- **Search is decoupled from recording.** The daemon answers queries about your
  whole history even when `huske run` is not active.
- **ChatGPT requires HTTP regardless.** The ChatGPT desktop app cannot launch a
  local stdio server — it only connects to a remote HTTPS MCP endpoint. Any
  design that includes ChatGPT must serve HTTP anyway.

## Consequences

- A listening socket holding all transcripts now exists, so auth + binding +
  anti-rebind are mandatory, not optional. This is the cost we accept versus
  stdio's zero-config locality. See the security posture in the spec.
- The daemon and `huske run` share the one `sqlite-vec` file; SQLite WAL mode
  handles the concurrent reader (daemon) / writer (recorder) case.

## Considered and rejected

- **stdio (the convention).** Simplest, no auth surface, fully local — but
  reloads the model per launch, ties nothing together, and cannot serve
  ChatGPT.
- **HTTP-only with a tunnel for *all* clients.** Forces a needless network hop
  and tunnel/auth even for the local Claude case that localhost HTTP already
  covers for free.
