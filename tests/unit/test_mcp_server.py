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
    assert {"search", "fetch", "recap", "overview"} <= names


def test_recap_and_overview_are_callable_via_sdk(store: PassageStore) -> None:
    mcp = build_server(store, _EMB)

    async def drive() -> tuple[dict, dict]:  # type: ignore[type-arg]
        r = await mcp.call_tool("recap", {})
        o = await mcp.call_tool("overview", {})
        return (
            r[1] if isinstance(r, tuple) else r,
            o[1] if isinstance(o, tuple) else o,
        )

    recap_result, overview_result = asyncio.run(drive())
    assert recap_result["days"][0]["date"] == "2026-05-07"
    assert overview_result["first_day"] == "2026-05-07"
    assert overview_result["passages"] == 1


def test_prompts_are_registered(store: PassageStore) -> None:
    """Claude and ChatGPT surface server prompts as one-tap actions."""
    mcp = build_server(store, _EMB)
    names = {p.name for p in asyncio.run(mcp.list_prompts())}
    assert {"catch_me_up", "what_was_said_about"} <= names


def test_instructions_tell_the_model_when_to_reach_for_huske(store: PassageStore) -> None:
    mcp = build_server(store, _EMB)
    instructions = mcp.instructions or ""
    # A connector that is never invoked is useless, so the guidance to prefer
    # lookup over asking the user is load-bearing, not decoration.
    assert "recap" in instructions
    assert "overview" in instructions
    assert "not a semantic neighborhood" in instructions


def test_connector_hosts_are_allowlisted(store: PassageStore) -> None:
    """Without the public host, the SDK's rebinding guard 421s every request."""
    from huske.mcp.server import DEFAULT_CONNECTOR_ORIGINS, connector_allowed_hosts

    hosts = connector_allowed_hosts("https://huske.example.com/mcp")
    assert hosts == ("huske.example.com", "huske.example.com:*")

    mcp = build_server(
        store,
        _EMB,
        extra_allowed_hosts=hosts,
        extra_allowed_origins=DEFAULT_CONNECTOR_ORIGINS,
    )
    ts = mcp.settings.transport_security
    assert "huske.example.com" in ts.allowed_hosts
    assert "https://claude.ai" in ts.allowed_origins
    assert "https://chatgpt.com" in ts.allowed_origins


def test_connector_allowed_hosts_ignores_garbage() -> None:
    from huske.mcp.server import connector_allowed_hosts

    assert connector_allowed_hosts("not-a-url") == ()


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
