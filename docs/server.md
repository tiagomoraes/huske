# Always-on transcript service

Huske's recording app and its MCP service are deliberately separate:

```text
Mac                                  GitHub                 VPS
Huske.app
  record → transcribe → .md
  background Git publisher ──push──> private repo <──pull── huske-mcp
                                                             │
                                              SQLite index ←─┘
                                                             │
                                                   /mcp ─────┴─ agent
```

The Mac is authoritative. GitHub is a durable transport/history layer. The VPS
holds a read replica and can answer while the Mac sleeps. There is no custom
ingest endpoint and no MCP server in the recording process.

## 1. Create the private repository

Create an empty **private** GitHub repository dedicated to transcript data. Do
not reuse the Huske source repository. On the Mac, use an SSH remote when
possible:

```text
git@github.com:you/huske-transcripts.git
```

SSH keeps credentials in the normal macOS ssh-agent/Keychain. Huske does not
store a GitHub token.

## 2. Configure Huske.app

Open **Cloud sync**, paste the repository URL, leave the branch as `main`, and
press **Sync now**. Once the initial push works, enable automatic sync.

Terminal equivalent:

```bash
huske config set sync_remote git@github.com:you/huske-transcripts.git
huske config set sync_branch main
huske config set sync_enabled true
huske sync
```

The managed checkout is `~/huske/sync` by default. Only canonical transcript
Markdown is copied to `transcripts/YYYY-MM-DD/*.md`. Existing remote content is
preserved. If the same path contains different bytes, sync stops with an
immutable-file conflict instead of overwriting either copy.

## 3. Install the VPS service

The independent package is in
[`services/huske_mcp`](../services/huske_mcp/README.md):

```bash
python3 -m venv /opt/huske-mcp/venv
/opt/huske-mcp/venv/bin/pip install ./services/huske_mcp
```

Give the VPS service account a **read-only deploy key** for the private
repository. Configure its environment:

```ini
HUSKE_MCP_REPOSITORY=git@github.com:you/huske-transcripts.git
HUSKE_MCP_BRANCH=main
HUSKE_MCP_DATA_DIR=/var/lib/huske-mcp
HUSKE_MCP_HOST=127.0.0.1
HUSKE_MCP_PORT=7641
HUSKE_MCP_POLL_SECONDS=60
HUSKE_MCP_TOKEN_FILE=/etc/huske-mcp/token
HUSKE_MCP_ALLOWED_HOSTS=huske.example.com
```

Generate the read token:

```bash
openssl rand -hex 32 | sudo tee /etc/huske-mcp/token >/dev/null
sudo chown root:huske /etc/huske-mcp/token
sudo chmod 640 /etc/huske-mcp/token
```

Then validate, perform the initial pull/index, and start:

```bash
huske-mcp doctor
huske-mcp sync
huske-mcp serve
```

Use the provided `services/huske_mcp/deploy/huske-mcp.service` under systemd.

## 4. Polling and webhook

Polling is always the reconciliation path. It heals missed GitHub deliveries,
VPS restarts, and temporary network failures.

For lower latency, also set `HUSKE_MCP_WEBHOOK_SECRET_FILE` and create a GitHub
push webhook targeting:

```text
https://huske.example.com/webhooks/github
```

The handler verifies `X-Hub-Signature-256`, checks the configured branch, and
wakes the poller. It does no Git or index work in the HTTP request.

## 5. Expose MCP safely

Keep the process on loopback and terminate TLS with Caddy, Tailscale, or another
reverse proxy. Agents connect to:

```text
https://huske.example.com/mcp
Authorization: Bearer <contents of /etc/huske-mcp/token>
```

The service refuses to start without a bearer token, including on loopback:
loopback is commonly published by a reverse proxy. It also validates the HTTP
`Host`; list the public proxy hostname in `HUSKE_MCP_ALLOWED_HOSTS`. Prefer a
private overlay network. Clients that require OAuth and cannot attach a bearer
header need an external identity-aware proxy; OAuth is not embedded in the
512 MB service.

## Resource budget

The default `tiny` profile uses one process, one poll thread, SQLite FTS5, an
8 MB SQLite page cache, and a 32 MB mmap ceiling. It has no resident embedding
model and is the supported profile for 1 vCPU / 512 MB.

Set `HUSKE_MCP_SEARCH_PROFILE=semantic` only after installing
`huske-mcp[semantic]`. Hybrid Model2Vec search gives real semantic retrieval but
the default multilingual model needs more memory; provision at least 1 GB or
select a smaller model.
