"""MCP server build: tools registered, callable end-to-end via the SDK."""

from __future__ import annotations

import asyncio
from datetime import datetime, timedelta
from pathlib import Path

import pytest

pytest.importorskip("sqlite_vec")
pytest.importorskip("mcp")

from huske.mcp.server import build_server
from huske.search.embedder import HashingEmbedder
from huske.search.models import Passage
from huske.search.store import PassageStore

_BASE = datetime(2026, 5, 7, 9, 30, 0).astimezone()
_EMB = HashingEmbedder(dim=64)


@pytest.fixture
def store(tmp_path: Path) -> PassageStore:
    s = PassageStore.open(tmp_path / "p.db", embedding_model="hashing", dim=_EMB.dim)
    ps = [
        Passage(
            uid="/t/a#0",
            text="revisão do plano de marketing trimestral",
            start=_BASE,
            end=_BASE + timedelta(seconds=10),
            sources=["system"],
            session_id="s1",
            day=20260507,
            path="/t/a",
            title="2026-05-07 09:30 · system",
        )
    ]
    s.upsert("/t/a", "h", ps, _EMB.embed_passages([p.text for p in ps]))
    return s


def test_tools_are_registered_with_chatgpt_names(store: PassageStore) -> None:
    mcp = build_server(store, _EMB, host="127.0.0.1", port=7641)
    names = {t.name for t in asyncio.run(mcp.list_tools())}
    assert {"search", "fetch"} <= names


def test_call_search_and_fetch_via_sdk(store: PassageStore) -> None:
    mcp = build_server(store, _EMB)

    async def drive() -> tuple[object, object]:
        s = await mcp.call_tool("search", {"query": "plano de marketing", "k": 3})
        # FastMCP returns (content, structured) — structured holds our dict.
        results = s[1]["results"] if isinstance(s, tuple) else s["results"]
        first_id = results[0]["id"]
        f = await mcp.call_tool("fetch", {"id": first_id})
        fetched = f[1] if isinstance(f, tuple) else f
        return first_id, fetched

    first_id, fetched = asyncio.run(drive())
    assert first_id == "/t/a#0"
    assert "marketing" in fetched["text"]
    assert fetched["metadata"]["session"] == "s1"


def test_transport_security_allows_loopback(store: PassageStore) -> None:
    mcp = build_server(store, _EMB, host="127.0.0.1", port=7641)
    ts = mcp.settings.transport_security
    assert ts.enable_dns_rebinding_protection is True
    assert "127.0.0.1:7641" in ts.allowed_hosts
    assert "http://127.0.0.1:7641" in ts.allowed_origins
