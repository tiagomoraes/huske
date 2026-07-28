# Off-device huske server

By default huske is local-first: capture, transcription, and (optionally) search
all run on your Mac. If you want an always-on agent — say a personal "hermes"
agent — to query your huske context **even while your Mac is asleep**, you can
run a single-tenant **huske server** on a box you control (a VPS), push your
finalized transcripts to it, and serve search from there.

This is an opt-in power feature. 99% of users never need it; the local
`huske mcp` daemon already covers querying your own machine. The design and its
trade-offs are recorded in
[docs/adr/0004-off-device-huske-server.md](adr/0004-off-device-huske-server.md).

## How it fits together

```
  Mac (ephemeral)                       VPS (always-on, single user)
  ──────────────                        ────────────────────────────
  huske run                             Caddy (TLS, public :443)
    └─ finalize .md ─┐                     │  /ingest /healthz  → write, always
       sync outbox   │  POST https         │  /mcp /oauth/* …   → read, only in
                     └────────────►        │                      connector mode
                                           ▼
                                      huske serve  (write token, :7642 loopback)
                                            │  stores .md, indexes with CPU e5
                                            ▼
                                      sqlite-vec  (one file, WAL)
                                            ▲
                                      huske mcp   (:7641 loopback)
                                        ▲                    ▲
                                   hermes                Claude / ChatGPT / phone
                              (co-located agent,         (HTTPS + OAuth, only in
                               static token)              connector mode)
```

- The Mac **pushes the finalized transcript `.md`** (not audio, not vectors) to
  the server's authenticated ingest endpoint, out-of-band from recording. If the
  Mac is offline the send is retried and reconciled on reconnect.
- The server **re-derives its own index** from the `.md` using a CPU embedder
  (`fastembed`), since a Linux VPS has no Metal.
- The **read MCP is loopback-only by default** — a co-located agent on the VPS
  queries it directly, and only the **write-only ingest endpoint** is public. A
  stolen write token lets someone push junk (bounded — transcripts are immutable
  and ingest is idempotent) but cannot read your history.
- **If you also want to reach it from your phone**, turn on opt-in
  [connector mode](#5-connector-mode-reach-it-from-your-phone-opt-in): the same
  read daemon additionally serves an OAuth 2.1 sign-in, so Claude and ChatGPT can
  attach it as a custom connector from any device. That is the one thing here
  that puts a read surface on the network — see
  [ADR 0008](adr/0008-public-mcp-connector.md).

## 1. Server setup (the VPS)

Install the server extra (pulls `fastembed` + `sqlite-vec` + the MCP SDK +
`uvicorn`; no `mlx`):

```bash
pip install 'huske[server]'
```

Configure `~/.config/huske/config.toml` on the server:

```toml
# CPU embedder — no Metal on a Linux VPS. Must be an e5 model.
embedding_model = "fastembed:intfloat/multilingual-e5-large"

output_root = "/var/lib/huske/transcripts"
index_root  = "/var/lib/huske/index"

ingest_host = "127.0.0.1"   # behind the reverse proxy
ingest_port = 7642
public_host = "huske.example.com"   # validates the Host header
```

Run the two processes (single responsibility each; they share one `sqlite-vec`
file via WAL):

```bash
huske serve   # ingest + indexing (the write side; behind Caddy)
huske mcp     # search/fetch over loopback (the read side; for hermes)
```

`huske serve` prints — and persists to `~/.config/huske/ingest_token` — the
**write token**. You'll copy that to each recording Mac.

### systemd units

```ini
# /etc/systemd/system/huske-serve.service
[Unit]
Description=huske ingest server
After=network.target

[Service]
User=huske
ExecStart=/usr/local/bin/huske serve
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

```ini
# /etc/systemd/system/huske-mcp.service
[Unit]
Description=huske MCP (loopback read)
After=huske-serve.service

[Service]
User=huske
ExecStart=/usr/local/bin/huske mcp
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl enable --now huske-serve huske-mcp
```

### Reverse proxy (Caddy) — only the ingest path is public

This is the load-bearing security boundary: proxy **only** `/ingest` and
`/healthz`. Leave the MCP read port off the proxy entirely unless you are
deliberately turning on connector mode (next section), which adds a specific,
short allowlist of read paths — never a catch-all.

```caddyfile
huske.example.com {
    @ingest path /ingest /healthz
    handle @ingest {
        reverse_proxy 127.0.0.1:7642
    }
    handle {
        respond "not found" 404
    }
}
```

Caddy obtains and renews the TLS certificate automatically. Also recommended:
enable **full-disk encryption** on the VPS — the server holds your full
plaintext transcript history (huske does not add app-level encryption at rest,
because the server must read plaintext to embed and serve; see ADR 0004).

## 2. Client setup (each recording Mac)

No extra to install — the send side ships in base huske. In
`~/.config/huske/config.toml`:

```toml
sync_endpoint = "https://huske.example.com"
# sync_verify_tls = false   # ONLY for local testing against a self-signed cert
```

Write the server's token into `~/.config/huske/sync_token` (mode `600`):

```bash
umask 077 && printf '%s\n' '<token from huske serve>' > ~/.config/huske/sync_token
```

Now:

- `huske run` replicates each finalized transcript live, in the background. It
  never blocks recording; if the network drops it retries and catches up.
- `huske sync` pushes everything not yet acknowledged and exits — use it to
  backfill an existing corpus, or to flush after a long offline stretch.

## 3. The co-located agent (hermes)

hermes runs **on the VPS** and connects to the loopback MCP — exactly like
Claude connects to a local huske on your Mac:

```bash
claude mcp add --transport http huske http://127.0.0.1:7641/mcp \
  --header "Authorization: Bearer $(cat ~/.config/huske/mcp_token)"
```

With connector mode off, nothing but a process on the VPS can query your
transcripts.

## 5. Connector mode: reach it from your phone (opt-in)

A co-located agent covers hermes and nothing else. Claude on your iPhone and
ChatGPT are not co-located with anything, and cannot be — you do not control
where they run. Reaching them means the read endpoint has to answer over the
network, authenticated.

Neither client can send a custom bearer header to a remote MCP server, so a
widened static token would not work; both drive the MCP authorization spec
(OAuth 2.1 + PKCE + discovery metadata + dynamic client registration). `huske mcp`
therefore embeds a small single-tenant authorization server: one passphrase, one
read-only scope, no accounts.

```bash
huske mcp set-password                                            # scrypt hash, 0600
huske config set mcp_public_url https://huske.example.com/mcp     # as clients see it
sudo systemctl restart huske-mcp
```

The daemon refuses to start if the URL is set without a passphrase, or if it is
not HTTPS.

Then extend the Caddy allowlist with the read paths — and *only* these:

```caddyfile
huske.example.com {
    @ingest path /ingest /healthz
    handle @ingest {
        reverse_proxy 127.0.0.1:7642
    }

    @mcp path /mcp /mcp/* /.well-known/oauth-* /.well-known/oauth-*/* /oauth/*
    handle @mcp {
        reverse_proxy 127.0.0.1:7641
    }

    handle {
        respond "not found" 404
    }
}
```

Verify discovery before touching a client — if these two do not return JSON, no
client will get as far as a sign-in page:

```bash
curl -s https://huske.example.com/.well-known/oauth-protected-resource/mcp | jq
curl -s https://huske.example.com/.well-known/oauth-authorization-server | jq
```

Now add `https://huske.example.com/mcp` as a custom connector in Claude
(Settings → Connectors) or ChatGPT (Settings → Connectors → Advanced →
Developer mode) and sign in with your passphrase. hermes keeps using loopback
with the static token, unchanged.

Manage it with `huske mcp status`, `huske mcp revoke --all`, and
`huske connect claude-app`. Full client-by-client guide:
**[docs/integrations.md](integrations.md)**.

## Tokens at a glance

| Credential | File | Guards | Who holds it |
| --- | --- | --- | --- |
| write token | `~/.config/huske/ingest_token` (server) → `~/.config/huske/sync_token` (Mac) | ingest (push) | server + every recording Mac |
| read token | `~/.config/huske/mcp_token` (server) | MCP search/fetch over loopback | the co-located agent |
| connector passphrase | `~/.config/huske/mcp_password` (server, scrypt hash) | OAuth sign-in, connector mode only | you, in a browser |
| issued OAuth tokens | `~/.config/huske/oauth.db` (server, hashed) | one per connected device | huske, on your behalf |

All are mode `0600`. To rotate the write token, delete `ingest_token` on the
server, restart `huske serve`, and copy the newly printed value to each Mac's
`sync_token`. To rotate connector access, `huske mcp set-password` then
`huske mcp revoke --all`.
