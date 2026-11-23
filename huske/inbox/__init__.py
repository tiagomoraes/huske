"""The engine inbox: external recordings in, ordinary transcripts out.

Recordings that did not come from live capture — an iPhone recording handed
over by Huske.app, a voice memo passed to ``huske import`` — are staged as
items under ``inbox_root`` (:mod:`huske.inbox.store`) and transcribed by
whichever process holds ``inbox_root/.lock``: the live ``huske run`` engine,
feeding its existing ASR worker, or a one-shot ``huske inbox process``
(:mod:`huske.inbox.processor`). Contract:
``specs/002-phone-sync/contracts/inbox.md``.
"""

from __future__ import annotations

from huske.inbox.processor import InboxProcessor, is_inbox_job_id
from huske.inbox.store import InboxError, InboxItem, InboxLock, InboxStore

__all__ = [
    "InboxError",
    "InboxItem",
    "InboxLock",
    "InboxProcessor",
    "InboxStore",
    "is_inbox_job_id",
]
