"""Local semantic search over transcripts.

The retrieval unit is the **Passage** (see CONTEXT.md): a time-windowed,
multi-source slice of a transcript, embedded into one vector and stored in a
``sqlite-vec`` passage store. This package is the engine; ``huske.mcp`` is the
MCP interface that serves it to chat models.

Heavy/optional dependencies (``mlx-embeddings``, ``sqlite-vec``) are imported
lazily inside the modules that need them, so importing ``huske.search`` is
cheap and safe without the ``huske[mcp]`` extra installed.
"""

from __future__ import annotations
