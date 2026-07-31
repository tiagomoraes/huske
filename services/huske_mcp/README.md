# huske-mcp

`huske-mcp` is the always-on, Linux-oriented half of Huske. It is a separate
package and process from the recording app:

```text
Huske.app ── git push ──> private GitHub repository
                                  │
                   webhook wakeup │ + polling reconciliation
                                  ▼
                        huske-mcp on a VPS
                    git pull → SQLite → MCP
```

The repository is the durable handoff. The Mac owns capture and transcription;
the VPS only reads a replica. There is no ingest API and the recording app never
hosts an MCP endpoint.

## Resource profiles

- `tiny` (default): SQLite FTS5, one worker, 8 MB SQLite cache, 32 MB mmap
  ceiling, no resident model. This is the supported profile for 1 vCPU / 512 MB.
- `semantic`: hybrid FTS5 + Model2Vec dense retrieval. Install
  `huske-mcp[semantic]`. The default multilingual model is substantially larger;
  use at least 1 GB RAM or choose a smaller language-specific model.

`tiny` still provides fast full-text topic search, exact date/source/session
filters, chronological recap, overview, and contextual fetch. It is the honest
low-memory tradeoff; it does not label lexical results as semantic.

## Install on a VPS

```bash
python3 -m venv /opt/huske-mcp/venv
/opt/huske-mcp/venv/bin/pip install ./services/huske_mcp
sudo install -d -o huske -g huske /var/lib/huske-mcp /etc/huske-mcp
openssl rand -hex 32 | sudo tee /etc/huske-mcp/token >/dev/null
sudo chown root:huske /etc/huske-mcp/token
sudo chmod 640 /etc/huske-mcp/token
```

Environment:

```ini
HUSKE_MCP_REPOSITORY=git@github.com:you/huske-transcripts.git
HUSKE_MCP_BRANCH=main
HUSKE_MCP_DATA_DIR=/var/lib/huske-mcp
HUSKE_MCP_HOST=127.0.0.1
HUSKE_MCP_PORT=7641
HUSKE_MCP_POLL_SECONDS=60
HUSKE_MCP_TOKEN_FILE=/etc/huske-mcp/token
# Required when a reverse proxy preserves this public Host header:
HUSKE_MCP_ALLOWED_HOSTS=your-host.example
# Only needed for browser-originated MCP traffic:
# HUSKE_MCP_ALLOWED_ORIGINS=https://your-host.example
# Optional; enables POST /webhooks/github:
HUSKE_MCP_WEBHOOK_SECRET_FILE=/etc/huske-mcp/webhook-secret
```

The service account needs read access to the private repository. Use a
read-only GitHub deploy key on the VPS, store it under
`/var/lib/huske-mcp/.ssh`, and pin GitHub's SSH host key in that account's
`known_hosts`. The Mac uses its own write-capable SSH key or Git credential
helper.

Run one reconciliation before starting the daemon:

```bash
huske-mcp doctor
huske-mcp sync
huske-mcp serve
```

Use the example unit at `deploy/huske-mcp.service`. Put Caddy/Tailscale in front
of loopback for TLS. A bearer token is mandatory even on loopback, because a
reverse proxy can make a loopback service public. MCP transport also validates
the `Host` header against `HUSKE_MCP_ALLOWED_HOSTS`.

## GitHub webhook

Create a repository webhook:

- Payload URL: `https://your-host.example/webhooks/github`
- Content type: `application/json`
- Secret: the contents of `HUSKE_MCP_WEBHOOK_SECRET_FILE`
- Event: push only

The handler validates `X-Hub-Signature-256` and merely wakes the sync thread.
Polling remains enabled because webhook delivery is best-effort and can be
missed during restarts or network outages.

## Agent connection

Agents that support a custom bearer header connect to:

```text
https://your-host.example/mcp
Authorization: Bearer <token>
```

The tools are `overview`, `recap`, `search`, `fetch`, and `sync_status`.
Keep the endpoint behind a private network when possible. OAuth-based consumer
connectors are intentionally not embedded in this small single-user service;
put a standards-compliant identity-aware proxy in front if a client cannot send
a bearer header.
