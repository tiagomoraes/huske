---
status: accepted
---

# Opt-in public MCP connector (OAuth 2.1) for off-device agents

_Amends ADR 0004, which rejected "exposing the read/MCP endpoint publicly." That
rejection was correct for the requirement it was written against; this ADR
records the requirement that changed and the guardrails that make the reversal
defensible._

## Context

ADR 0001 bound `huske mcp` to `127.0.0.1` behind a static bearer token. ADR 0004
kept that posture on the VPS and made the write-only Ingest endpoint the *sole*
network-exposed surface, reasoning that a **co-located agent** ("hermes", running
on the VPS itself) covers off-device querying without ever putting the read path
on the internet. Its rejection list is explicit: "**Exposing the read/MCP
endpoint publicly:** rejected for the write-only surface above."

A future reader will therefore find this ADR contradicting a decision made
deliberately three releases earlier, and should know exactly which premise broke.

**The premise that broke: "the consuming agent is co-located."** That holds for
hermes and for nothing else the author actually uses. The real consumption
pattern is:

- Claude Code on the Mac — loopback, fine.
- hermes on the VPS — loopback there, fine.
- **Claude on an iPhone, Claude on the web, ChatGPT on an iPhone** — a vendor's
  backend talking to an HTTPS URL. Not co-located with anything. Cannot be made
  co-located: the author does not control where claude.ai runs.

So there are two distinct devices the transcripts must be reachable *from*, and
the topology in ADR 0004 serves neither. The corpus already lives on an always-on
box, already indexed. The only thing missing is a door.

**Why a tunnel to the Mac is not that door** — ADR 0004 already ruled it out
(the Mac is asleep most of the time), and nothing about phone clients changes
that.

**Why a static token is not that door either.** This is the constraint that
forces real OAuth rather than a wider bearer check. Neither Claude nor ChatGPT
lets a user attach a custom header to a remote MCP server through its connector
UI. Both implement the MCP authorization spec and drive it: HTTPS transport,
OAuth 2.1 with PKCE, Protected Resource Metadata (RFC 9728) for authorization
server discovery, and a client registration mechanism — Dynamic Client
Registration (RFC 7591) being the one both support. "Expose the existing token
endpoint over TLS" is not a smaller version of this design; it is a design that
does not connect.

## Decision

An **opt-in connector mode** on the existing `huske mcp` daemon, enabled by
setting `mcp_public_url`. Unset — the default, and the only state 99% of users
are ever in — behavior is byte-identical to before: loopback bind, static token,
no OAuth endpoints served at all.

- **One process, one endpoint, both credentials.** Connector mode wraps the same
  MCP app in `ConnectorApp`, which accepts *either* the static bearer token
  (loopback clients: Claude Code, hermes — unchanged, no migration) *or* an OAuth
  access token (connector clients). There is no second daemon and no second set
  of tools to keep in sync.
- **huske embeds its own single-tenant authorization server** (`huske/mcp/oauth.py`,
  stdlib-only): RFC 8414 metadata, RFC 7591 DCR, PKCE S256 (mandatory),
  authorization code + rotating refresh, RFC 8707 audience binding, RFC 9207
  `iss`, RFC 7009 revocation. The credential is **one scrypt-hashed passphrase**
  and the scope set is **one read-only scope** (`transcripts:read`).
- **The daemon refuses to start in connector mode without a passphrase**, and
  refuses a non-HTTPS `mcp_public_url`. Failing loudly is the point: the failure
  mode being guarded against is a transcript archive published with no credential
  in front of it.
- **Retrieval gains `recap` and `overview`** alongside `search`/`fetch`. Not a
  security matter — a reachability fix that no one uses is the same as no fix,
  and a connector offering only vector search cannot answer "catch me up on
  today" (see the rationale comment above `recap` in `huske/mcp/tools.py`).
- **`huske export`** writes one Markdown file per day for destinations that will
  never speak MCP (a Claude Project, NotebookLM, Obsidian, a synced folder). It
  is a complement, not a path to this one — see the trade-off below.

## Why (the trade-off)

- **Reachability was the whole point of ADR 0004, and it fell one hop short.**
  Replicating transcripts to an always-on box so an agent can query them 24/7,
  then allowing exactly one agent that must run on that box, solves the author's
  hermes case and no other. The Replica was already the hard part; this is the
  door onto it.
- **The public surface grows from write-only to write + authenticated-read.**
  That is a real, permanent widening and the honest cost of this ADR. What bounds
  it: read requires a passphrase-derived token, tokens are audience-bound to one
  resource, refresh tokens rotate, every code is single-use and PKCE-bound,
  failed logins back off globally (not per-IP — an attacker rotating addresses
  would walk through a per-IP counter), and `huske mcp revoke --all` cuts every
  device off in one command.
- **An embedded AS beats requiring an IdP.** Keycloak or Auth0 next to a
  200-line ingest daemon inverts the weight of the thing being protected, and
  adds an operational dependency to a project whose distillation feature was
  built specifically to avoid adding one. Single-tenant with one passphrase and
  one scope is what makes ~600 stdlib lines sufficient; this reasoning does not
  survive a multi-user requirement, and multi-tenant remains out of scope
  (ADR 0004).
- **Opt-in keeps ADR 0001's posture the default.** Nobody pays for this unless
  they set `mcp_public_url`. The loopback deployment serves no OAuth routes, so
  the new surface does not exist on the machines that do not want it.

## Consequences

- The VPS reverse proxy must now forward the read paths as well as `/ingest`:
  `/mcp`, `/.well-known/oauth-*`, and `/oauth/*`. `docs/server.md` and the Caddy
  example are updated. **The proxy is now the boundary that must not leak** — a
  misconfiguration that forwards more than these paths is the new footgun, so the
  documented config is an allowlist, never a catch-all `reverse_proxy`.
- The VPS holds the full plaintext transcript history *and* now answers read
  queries for it over the internet. Full-disk encryption and a correct proxy
  config move from "recommended" to load-bearing.
- Credential material grows by two files, both `0600`:
  `~/.config/huske/mcp_password` (scrypt hash) and `~/.config/huske/oauth.db`
  (issued clients and *hashed* tokens — a stolen copy yields no usable
  credential). Neither lives under `index_root`, so `huske index --rebuild`
  cannot destroy connector access.
- The `mcp`/`server` extras are capped at `mcp>=1.12,<2`. The SDK's 2.0 line
  renamed `mcp.server.fastmcp.FastMCP` to `mcp.server.mcpserver.MCPServer`, so an
  uncapped install resolved to an SDK `huske mcp` could not import — and because
  CI installs only `.[dev]`, no test covered it. Lift the cap with the 2.0 port.
- The SDK's DNS-rebinding guard rejects any unlisted `Host` with a 421, so
  connector mode must seed the public hostname (`connector_allowed_hosts`) and
  the known vendor browser Origins (`DEFAULT_CONNECTOR_ORIGINS`). This was
  anticipated in ADR 0004's consequences ("`_allowed_hosts` only seeds loopback
  today") and is now wired.
- `CONTEXT.md` gains **Connector** and **Recap**; "the huske server's search is
  never queried across the network" in the **Co-located agent** entry is no
  longer unconditional and is amended.

## Considered and rejected

- **Widen the static bearer token to the public interface.** One config line, no
  new code — and it does not work: neither Claude nor ChatGPT can send a custom
  header to a remote MCP server. It would serve `curl` and no client the author
  actually uses.
- **Require an external identity provider (Auth0, Keycloak, Pocket ID).** No
  crypto code in huske, at the cost of an operational dependency heavier than
  huske itself for a single user, and a setup story that ends most self-hosters'
  attempt. Reconsider if huske ever needs multiple users.
- **Cloudflare Access / `oauth2-proxy` in front of the endpoint.** Both
  authenticate a *browser session*; an MCP client is not a browser and cannot
  complete an interactive challenge per request. Service tokens fix that only for
  clients that can set headers — the case that already fails.
- **Client ID Metadata Documents instead of DCR.** The direction the MCP spec now
  prefers (DCR is marked deprecated-for-compat), and both vendors support it. It
  requires the AS to fetch and validate an attacker-supplied URL — an SSRF
  surface — for no gain here, since both clients also support DCR. Worth adding
  when a client appears that requires it.
- **Replace the connector with a synced folder (Google Drive / GitHub).** Zero
  infrastructure, and both vendors already ship Drive connectors, so it is a
  genuinely tempting shortcut. Rejected as the *primary* path on two grounds:
  it discards the retrieval stack (keyword search over concatenated speech in
  place of embedding search over Passages, with no date filter, no source
  filter, and no statement grounding — ADRs 0002 and 0005 become dead weight),
  and it inverts the privacy architecture by handing the full plaintext corpus to
  a third party under their retention and scanning policy, where a self-hosted
  VPS keeps custody with the user. Kept as a deliberate complement in
  `huske export`, which emits a per-day digest rather than the raw corpus, and
  documents the trade-off at the point of use.
- **A separate `huske gateway` command.** A clean split on paper; in practice two
  processes serving the same four tools, with two banners, two configs, and a
  standing risk of drift. Connector mode is a flag on one daemon instead.
