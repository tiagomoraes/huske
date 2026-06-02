"""Off-device replication: push finalized transcripts to a huske server.

This package is the *send* side of docs/adr/0004-off-device-huske-server.md. It
ships in the base install and is **dependency-free** (stdlib ``sqlite3`` +
``urllib``) — it pulls in none of the ``huske[mcp]`` / ``huske[server]`` weight.
It stays inert unless ``sync_endpoint`` is configured, so the 99% local case
pays nothing.

- :mod:`huske.sync.outbox` — durable record of what the server has acknowledged.
- :mod:`huske.sync.client` — the HTTPS ``POST /ingest`` call.
- :mod:`huske.sync.worker` — a background thread that pushes off the hot path
  and reconciles after the Mac has been offline.
- :mod:`huske.sync.runner` — ``huske sync`` one-shot backfill.
"""

from __future__ import annotations

# The ingest path appended to ``sync_endpoint`` on the client and served by the
# huske server. Kept here so both sides agree (see huske.server.app).
INGEST_PATH = "/ingest"
