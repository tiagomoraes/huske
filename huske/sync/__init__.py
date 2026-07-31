"""Cloud transcript publication (recording-app side).

Only immutable Markdown transcripts cross this boundary. The implementation is
dependency-free and shells out to Git, reusing the user's SSH agent or Git
credential helper; no cloud credential is persisted by huske.
"""

from __future__ import annotations
