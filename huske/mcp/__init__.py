"""MCP interface to huske's local transcript search.

`huske mcp` serves the passage index over a loopback HTTP MCP endpoint guarded
by a bearer token + Origin/Host validation (see
docs/adr/0001-http-only-mcp-daemon.md). The official `mcp` SDK and `uvicorn`
are imported lazily inside :mod:`huske.mcp.server`, so importing this package is
safe without the ``huske[mcp]`` extra installed.
"""

from __future__ import annotations
