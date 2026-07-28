# Getting huske context into your LLMs

huske records and transcribes on your Mac. This document is about the other half:
making that context reach whichever model you are actually talking to — Claude
Code in a terminal, Claude on your phone, ChatGPT, an always-on agent on a VPS —
including when the Mac that recorded it is asleep.

## Start here

**In Huske.app, open the Connect pane.** It lists what's left and puts a button
on each row — build the index, start the search server, connect your client. No
terminal, and it edits your client's config for you (merging, so any other MCP
servers you have survive). For most people that is the whole of this document.

Prefer a terminal, or on a headless box?

```bash
huske setup      # what's done, what's next, and `--apply` to finish it
huske connect    # per-client wiring, and whether that path works right now
```

Both read the same state the app does. The rest of this document is the reasoning
behind what they tell you, and the one path neither can finish for you: reaching
your transcripts from another device.

## Pick your path in one question

**Does the model run on the same machine as the huske daemon?**

| | Client | Path |
| --- | --- | --- |
| **Yes** | Claude Code, Codex, Cursor, Claude Desktop, an agent on the same box | **Loopback.** Static bearer token, no TLS, no OAuth, nothing exposed. |
| **No** | Claude on iPhone/iPad/web, ChatGPT, a hosted agent, Claude Code on another machine | **Connector mode.** One HTTPS URL, OAuth sign-in, works while the Mac sleeps. |

Loopback is the default and needs no setup beyond `huske mcp`. Connector mode is
opt-in and is the only thing here that puts a read surface on the network — see
[Security posture](#security-posture).

Neither is exclusive: one daemon serves both at once, and a client on the same
machine keeps using loopback even after connector mode is on.

## Topology

```
  Mac (sleeps)                          VPS (always on)
  ────────────                          ───────────────
  huske run                             Caddy (TLS, :443)
    ├─ transcribe on-device               │  /ingest        → write
    ├─ distil → statements                │  /mcp           → read  ◄── NEW
    ├─ embed  → index                     │  /.well-known/* → discovery
    └─ finalize .md ─┐                    │  /oauth/*       → sign-in
       sync outbox   │  POST https        ▼
                     └───────────►  huske serve   (ingest, :7642 loopback)
                                          │  stores .md, indexes with CPU e5
                                          ▼
                                   sqlite-vec (one file, WAL)
                                          ▲
                                   huske mcp     (read, :7641 loopback)
                                     ▲       ▲
                        hermes ──────┘       └────── Claude / ChatGPT / your phone
                     (loopback, static token)        (HTTPS, OAuth)

  huske mcp on the Mac  ◄── Claude Code, Codex, Cursor  (loopback, static token)
```

The replication half (`sync_endpoint` → `huske serve`) is
[docs/server.md](server.md). The read half is what follows.

## What the model can actually do

Four tools, and the last two matter more than they look.

| Tool | Answers | Notes |
| --- | --- | --- |
| `search` | "what was said about X" | Semantic. Filters: date range, source (`mic`/`system`), session. |
| `fetch` | "show me the real words" | Full text + citation metadata. On a statement, returns the grounding transcript too. |
| `recap` | "what happened today / this week" | Chronological, grouped by day and session. No embedding involved. |
| `overview` | "what do you even have?" | Date coverage and per-day density. |

`recap` and `overview` exist because `search` alone makes an agent guess. A date
range is not a semantic neighborhood — embedding the word "yesterday" returns
whatever *sounds* like it — and a model with no map of the corpus cannot tell an
empty index from an unlucky query. In practice this is the difference between
"catch me up on today" working and returning three unrelated fragments.

Two prompts ship with the server, so clients that surface them (Claude, ChatGPT)
get one-tap actions: **`catch_me_up`** and **`what_was_said_about`**.

## Local clients (loopback)

Run the daemon:

```bash
pip install 'huske[mcp]'   # if you haven't
huske index                # backfill your history (incremental)
huske mcp                  # prints the endpoint and token
```

Set `indexing_enabled = true` in `~/.config/huske/config.toml` to keep the index
fresh automatically as you record.

### Claude Code

```bash
claude mcp add --transport http huske http://127.0.0.1:7641/mcp \
  --header "Authorization: Bearer $(cat ~/.config/huske/mcp_token)"
```

### Claude Desktop / Cowork

Claude Desktop cannot attach a bearer header to a loopback URL through the
connectors UI, so bridge it to a local stdio server with `mcp-remote` in
`~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "huske": {
      "command": "npx",
      "args": [
        "-y", "mcp-remote", "http://127.0.0.1:7641/mcp",
        "--allow-http",
        "--header", "Authorization:${HUSKE_MCP_TOKEN}"
      ],
      "env": { "HUSKE_MCP_TOKEN": "Bearer <token from the banner>" }
    }
  }
}
```

Write `Authorization:` with **no space** — Claude Desktop strips spaces in args —
then fully quit and reopen the app. Cowork shares this config.

If connector mode is on, skip the bridge: add the HTTPS URL as a custom connector
exactly as on the phone.

### Codex CLI

```toml
# ~/.codex/config.toml
[mcp_servers.huske]
url = "http://127.0.0.1:7641/mcp"
[mcp_servers.huske.headers]
Authorization = "Bearer <token>"
```

### Cursor

```json
// ~/.cursor/mcp.json
{
  "mcpServers": {
    "huske": {
      "url": "http://127.0.0.1:7641/mcp",
      "headers": { "Authorization": "Bearer <token>" }
    }
  }
}
```

### An agent co-located with the daemon (hermes)

Unchanged from [ADR 0004](adr/0004-off-device-huske-server.md): loopback, static
token, nothing exposed. Turning connector mode on does not alter this path.

```bash
claude mcp add --transport http huske http://127.0.0.1:7641/mcp \
  --header "Authorization: Bearer $(cat ~/.config/huske/mcp_token)"
```

## Connector mode (phone, web, hosted agents)

### Why it needs OAuth and not a token

Neither Claude nor ChatGPT lets you attach a custom header to a remote MCP
server. Both implement the MCP authorization spec and drive it: HTTPS transport,
OAuth 2.1 with PKCE, protected-resource metadata for discovering the
authorization server, and dynamic client registration. "Expose the token endpoint
over TLS" is not a lighter version of this — it is a version that does not
connect.

So `huske mcp` embeds a small single-tenant authorization server. One passphrase,
one read-only scope, no accounts. Rationale and rejected alternatives:
[ADR 0008](adr/0008-public-mcp-connector.md).

### Where to turn it on

**On the VPS, if you replicate there.** That is the point — the index is awake
when your Mac is not. Set up replication first ([docs/server.md](server.md)),
then turn on connector mode on the read side.

**On the Mac,** if you have no VPS and accept that it only answers while the Mac
is awake and reachable (you will need a tunnel — `cloudflared`, Tailscale Funnel,
or similar — terminating TLS at a hostname you control).

### Setup

```bash
# 1. The passphrase that authorizes clients. Stored as a scrypt hash at
#    ~/.config/huske/mcp_password (0600); the plaintext is never written.
huske mcp set-password

# 2. The public URL clients will use, exactly as they see it.
huske config set mcp_public_url https://huske.example.com/mcp

# 3. Serve. The daemon stays bound to loopback; the proxy fronts it.
huske mcp
```

The daemon **refuses to start** if `mcp_public_url` is set without a passphrase,
or if the URL is not HTTPS. That is deliberate — the failure being guarded
against is publishing your transcript history with no credential in front of it.

### Reverse proxy

Forward exactly these paths and nothing else. This allowlist is the security
boundary; a catch-all `reverse_proxy` is the footgun.

```caddyfile
huske.example.com {
    # Write side (transcripts pushed from your Mac).
    @ingest path /ingest /healthz
    handle @ingest {
        reverse_proxy 127.0.0.1:7642
    }

    # Read side: the MCP endpoint plus OAuth discovery and sign-in.
    @mcp path /mcp /mcp/* /.well-known/oauth-* /.well-known/oauth-*/* /oauth/*
    handle @mcp {
        reverse_proxy 127.0.0.1:7641
    }

    handle {
        respond "not found" 404
    }
}
```

Caddy obtains and renews TLS automatically. Verify discovery works before
touching a client:

```bash
curl -s https://huske.example.com/.well-known/oauth-protected-resource/mcp | jq
curl -s https://huske.example.com/.well-known/oauth-authorization-server | jq
```

Both must return JSON. An unauthenticated `POST /mcp` must return `401` with a
`WWW-Authenticate` header naming the metadata URL — that header is how a client
finds its way into the sign-in flow.

### Claude on iPhone, iPad, and web

1. **Settings → Connectors → Add custom connector**
2. URL: `https://huske.example.com/mcp`
3. Claude registers itself, opens huske's sign-in page, and asks for your
   connector passphrase. Once.

It stays connected across your devices. Then ask it anything about what was said,
or use `/catch_me_up`.

### ChatGPT

1. **Settings → Connectors → Advanced → Developer mode** (Plus and above)
2. **Settings → Connectors → Create**, paste `https://huske.example.com/mcp`
3. Authenticate with your connector passphrase.

`search` and `fetch` return exactly the shape ChatGPT's connector contract
expects; `recap` and `overview` are additive.

### Claude Code from another machine

No header needed — it runs the OAuth flow itself and opens a browser once:

```bash
claude mcp add --transport http huske https://huske.example.com/mcp
```

### Managing access

```bash
huske mcp status              # is it configured? how many clients are attached?
huske mcp revoke --all        # cut off every device; each must sign in again
huske mcp revoke --client-id huske-xxxx
huske mcp set-password        # rotate the passphrase (existing tokens survive —
                              # follow with `revoke --all` to force re-auth)
```

Revocation does not touch loopback clients using the static token. To rotate
*that*, delete `~/.config/huske/mcp_token` and restart the daemon.

## Making the agent actually use it

A connected server that never gets called is the same as no server. Two things
help, in order of effect:

**1. Tell your agent it exists.** The MCP server ships instructions telling the
model to reach for huske whenever the user refers to something that was *said* —
a meeting, a call, a decision, "what did we agree", "who owns this" — and to
prefer looking it up over asking you to recap it. Clients that read server
instructions get this for free. For Claude Code, put it in `CLAUDE.md` too, where
it survives context compaction:

```markdown
## huske (spoken context)

My meetings and calls are transcribed into huske. When I reference a
conversation, a decision, or something someone said, query huske before asking me
to repeat it: `overview` to orient, `recap` for a date range, `search` for a
topic, `fetch` for verbatim text. Cite date and time.
```

**2. Use the prompts.** `catch_me_up` and `what_was_said_about` encode the good
retrieval sequence (orient → range → verbatim) so you do not have to phrase it
each time.

## When MCP is not an option: `huske export`

Some destinations read files and will never speak MCP — a Claude Project,
NotebookLM, an Obsidian vault, a folder shared with someone else. huske natively
writes many small files per day (one per chunk), which such a tool cannot rank:
it has thousands of similarly-named documents, no date filter, and no ranking
signal.

`huske export` inverts that — **one Markdown file per day**, distilled key points
first, verbatim conversation below:

```bash
huske export                          # → ~/huske/export/YYYY-MM-DD.md
huske export --statements-only        # key points only, no verbatim text
huske export --since 2026-07-01
huske export --export-root ~/Obsidian/huske
```

It is incremental: a day whose transcripts and statements are unchanged is
skipped, and writes are atomic, so a sync client never uploads a partial file.

**This is a complement, not a substitute.** What you give up going this route:
semantic search over Passages, statement grounding, date/source/session filters,
`recap`, and `overview` — replaced by whatever full-text search the destination
happens to have. If the answer to "what did we decide about pricing last week"
matters, use the connector.

> **Privacy.** Pointing a sync client at the export folder copies plaintext
> transcripts to that provider, under their retention and scanning policy. That
> is a different posture from a VPS you control, and a much different one from
> on-device. Choose it deliberately, and prefer `--statements-only` if you do.

## Security posture

What connector mode adds, and what bounds it:

- **Only an authenticated read is exposed.** The bind stays loopback; the proxy
  allowlist is the boundary. Nothing but `/mcp`, `/.well-known/oauth-*`, and
  `/oauth/*` should reach the read daemon.
- **One passphrase, scrypt-hashed** at `~/.config/huske/mcp_password` (`0600`).
  The plaintext is never written to disk. Failed attempts back off globally —
  not per-IP, since an attacker rotating addresses would walk straight through a
  per-IP counter.
- **Tokens are audience-bound** (RFC 8707) to your exact endpoint, so one minted
  here cannot be replayed elsewhere. Access tokens expire
  (`mcp_access_token_ttl_seconds`, default 12h); refresh tokens **rotate**, so a
  stolen one is usable at most once and only before the real client refreshes.
- **Authorization codes are single-use and PKCE-bound** (S256 required), and
  redirect URIs match exactly — no prefix or wildcard matching.
- **`oauth.db` stores hashes, not tokens.** A stolen copy yields no usable
  credential. Both it and the passphrase file live in `~/.config/huske/`, not
  under `index_root`, so `huske index --rebuild` cannot break connector access.
- **The server holds plaintext.** It has to, in order to embed and serve (ADR
  0004). Enable full-disk encryption on the VPS and treat that box as holding
  everything ever said near your Mac.
- **Answers still go to a model provider.** Retrieval is local; the model reading
  the result is Anthropic's or OpenAI's. A connector sends transcript snippets to
  whichever provider you attached, exactly as if you had pasted them in. That is
  the deal you are opting into, and it is unchanged from the loopback case.

Report anything that looks like a hole privately —
[SECURITY.md](../SECURITY.md).

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| Client says "could not connect" and no sign-in page appears | Discovery is not reachable. `curl` both `.well-known` URLs; the proxy allowlist is usually missing `/.well-known/oauth-*`. |
| `421 Misdirected Request` | The public hostname is not in the DNS-rebinding allowlist. Make sure `mcp_public_url` matches the hostname the proxy serves, then restart. |
| `403 Invalid Origin header` | A browser-based client sending an Origin huske does not know. Add it to `mcp_allowed_origins`. |
| Sign-in page rejects the right passphrase | Locked out after repeated failures (backoff, up to 15 min). Wait it out. |
| `no connector passphrase is set` | `huske mcp set-password`. |
| Connector worked, then stopped | Refresh token expired (`mcp_refresh_token_ttl_seconds`, default 90 days) or was revoked. Re-add the connector. |
| Tools return nothing | The index is empty or in another vector space. `huske mcp status`, then `huske index`. Ask the model to call `overview`. |
| `import mcp` fails after upgrading | The SDK 2.0 line moved `FastMCP`. The extras cap at `mcp<2`; reinstall with `pip install 'huske[mcp]'`. |

## Reference

- [ADR 0001](adr/0001-http-only-mcp-daemon.md) — why an HTTP daemon, not stdio.
- [ADR 0004](adr/0004-off-device-huske-server.md) — the off-device Replica.
- [ADR 0005](adr/0005-llm-distillation.md) — statements and two-stage retrieval.
- [ADR 0008](adr/0008-public-mcp-connector.md) — connector mode, and why it
  amends 0004.
- [docs/server.md](server.md) — replication and VPS setup.
- [docs/distillation.md](distillation.md) — distilling transcripts into
  statements.
