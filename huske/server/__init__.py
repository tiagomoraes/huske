"""The off-device huske server (the ``huske serve`` ingest side).

Per docs/adr/0004-off-device-huske-server.md this is a single-tenant, always-on
deployment (a VPS) that receives finalized transcripts pushed from a recording
Mac, stores them, and indexes them with a non-Metal (CPU) embedder. The read
side is the existing loopback ``huske mcp`` daemon, run as a second process on
the same box; a co-located agent (e.g. "hermes") queries it over localhost. A
TLS-terminating reverse proxy fronts *only* the ingest endpoint — the only
network-exposed surface.

Everything here needs the ``huske[server]`` extra (fastembed + sqlite-vec + mcp
+ uvicorn). Heavy imports are lazy so importing the package is cheap; the pure
ingest logic in :mod:`huske.server.ingest` has no third-party dependencies and
is unit-testable on its own.
"""

from __future__ import annotations
