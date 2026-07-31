"""Transcript parsing and time-windowing shared by local engine features.

Search serving and indexing live in the independent ``huske-mcp`` service.
This package retains only the stable transcript model, parser, and windowing
logic needed by distillation and export.
"""

from __future__ import annotations
