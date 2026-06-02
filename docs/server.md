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
    └─ finalize .md ─┐                     │  proxies ONLY /ingest + /healthz
       sync outbox   │  POST https         ▼
                     └────────────►   huske serve  (write token, :7642 loopback)
                                            │  stores .md, indexes with CPU e5
                                            ▼
                                      sqlite-vec  (one file, WAL)
                                            ▲
                                      huske mcp   (read token, :7641 loopback)
                                            ▲  localhost
                                       hermes (co-located agent)
```

- The Mac **pushes the finalized transcript `.md`** (not audio, not vectors) to
  the server's authenticated ingest endpoint, out-of-band from recording. If the
  Mac is offline the send is retried and reconciled on reconnect.
- The server **re-derives its own index** from the `.md` using a CPU embedder
  (`fastembed`), since a Linux VPS has no Metal.
- The **read MCP stays loopback-only** on the server — it is never exposed to the
  internet. Only a **write-only ingest endpoint** is public. A stolen write token
  lets someone push junk (bounded — transcripts are immutable and ingest is
  idempotent), but **cannot read your history over the network**.

## 1. Server setup (the VPS)

Install the server extra (pulls `fastembed` + `sqlite-vec` + the MCP SDK +
`uvicorn`; no `mlx`):

```bash
pip install 'huske[server]'
```

Configure `~/.config/huske/config.toml` on the server:

```toml
# CPU embedder — no Metal on a Linux VPS. Must be an e5 model.
embedding_model = "fastembed:intfloat/multilingual-e5-base"

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
`/healthz`. Never proxy the MCP read port — it must stay loopback.

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

Because the read endpoint is loopback-only, nothing but a process on the VPS can
query your transcripts.

## Tokens at a glance

| Token | File | Guards | Who holds it |
| --- | --- | --- | --- |
| write | `~/.config/huske/ingest_token` (server) → `~/.config/huske/sync_token` (Mac) | ingest (push) | server + every recording Mac |
| read | `~/.config/huske/mcp_token` (server) | MCP search/fetch | the co-located agent |

To rotate the write token, delete `ingest_token` on the server, restart
`huske serve`, and copy the newly printed value to each Mac's `sync_token`.
