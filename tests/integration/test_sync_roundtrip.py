"""End-to-end server path: push a transcript → stored → indexed → searchable.

Exercises the real IngestApp + Indexer + PassageStore with the dependency-free
HashingEmbedder (no whisper, no mlx, no fastembed), mirroring the project's
"test the pipeline without the heavy model" approach. The client push protocol
is covered by the unit tests; here we drive the ingest ASGI app directly.
"""

from __future__ import annotations

import asyncio
import json
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any

import pytest

pytest.importorskip("sqlite_vec")

from huske.search.embedder import HashingEmbedder
from huske.search.indexer import Indexer
from huske.search.store import PassageStore
from huske.server.app import IngestApp
from huske.server.ingest import content_sha256
from huske.transcribe.writer import (
    body_from_source_segments,
    build_transcript_from_segments,
    write_transcript,
)

_REL = "2026-05-07/093000_8a3f2c19_001.md"


def _transcript_text(tmp_path: Path, phrase: str) -> str:
    start = datetime(2026, 5, 7, 9, 30, 0).astimezone()
    segs = [
        {"start": 0.0, "end": 2.0, "text": phrase, "source": "system"},
        {"start": 3.0, "end": 4.0, "text": "entendido, obrigado.", "source": "microphone"},
    ]
    body = body_from_source_segments(start, segs)
    doc = build_transcript_from_segments(
        session_id="20260507T093000_8a3f2c19",
        chunk_seq=1,
        start_time=start,
        end_time=start + timedelta(minutes=15),
        expected_duration_seconds=900,
        actual_duration_seconds=900.0,
        gap_seconds=0.0,
        audio_sources=["microphone", "system"],
        model="mlx-whisper:base",
        language="pt",
        incomplete=False,
        text=body,
        segments=segs,
    )
    client_dir = tmp_path / "client" / "2026-05-07"
    client_dir.mkdir(parents=True, exist_ok=True)
    written = write_transcript(doc, client_dir / "093000_8a3f2c19_001.md")
    return written.read_text(encoding="utf-8")


async def _post(app: IngestApp, rel: str, content: str) -> tuple[int, dict[str, Any]]:
    body = json.dumps(
        {"rel_path": rel, "sha256": content_sha256(content), "content": content}
    ).encode("utf-8")
    served = {"done": False}

    async def receive() -> dict[str, Any]:
        if served["done"]:
            return {"type": "http.disconnect"}
        served["done"] = True
        return {"type": "http.request", "body": body, "more_body": False}

    sent: list[dict[str, Any]] = []

    async def send(message: dict[str, Any]) -> None:
        sent.append(message)

    scope = {
        "type": "http",
        "method": "POST",
        "path": "/ingest",
        "headers": [(b"authorization", b"Bearer t")],
    }
    await app(scope, receive, send)
    start = next(m for m in sent if m["type"] == "http.response.start")
    body_msg = next(m for m in sent if m["type"] == "http.response.body")
    return start["status"], json.loads(body_msg["body"].decode("utf-8"))


@pytest.mark.integration
def test_push_stores_indexes_and_searches(tmp_path: Path) -> None:
    server_out = tmp_path / "server"
    emb = HashingEmbedder(dim=64)
    store = PassageStore.open(
        tmp_path / "index" / "passages.db", embedding_model="hashing", dim=emb.dim
    )
    indexer = Indexer(store, emb)
    indexed: list[int] = []

    app = IngestApp(
        output_root=server_out,
        write_token="t",
        on_stored=lambda p: indexed.append(indexer.index_file(p)),
    )

    content = _transcript_text(tmp_path, "vamos falar sobre o orçamento de marketing")

    status, payload = asyncio.run(_post(app, _REL, content))
    assert status == 200, payload
    assert payload["status"] == "stored"
    assert (server_out / _REL).read_text(encoding="utf-8") == content
    assert indexed and indexed[0] >= 1

    hits = store.search(emb.embed_query("orçamento de marketing"), k=3)
    assert hits and "orçamento" in hits[0].text

    # Re-push identical content → idempotent no-op, still indexed.
    status2, payload2 = asyncio.run(_post(app, _REL, content))
    assert status2 == 200
    assert payload2["status"] == "unchanged"
    assert store.stats()["files"] == 1
    store.close()
