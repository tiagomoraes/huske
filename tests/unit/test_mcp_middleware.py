"""BearerAuthMiddleware: stdlib-only, no extra deps required."""

from __future__ import annotations

import asyncio

from huske.mcp.middleware import BearerAuthMiddleware


class _Recorder:
    def __init__(self) -> None:
        self.calls: list[dict] = []
        self.downstream_called = False

    async def app(self, scope, receive, send) -> None:  # type: ignore[no-untyped-def]
        self.downstream_called = True
        await send({"type": "http.response.start", "status": 200, "headers": []})
        await send({"type": "http.response.body", "body": b"ok"})


async def _drive(mw: BearerAuthMiddleware, headers: list[tuple[bytes, bytes]]) -> list[dict]:
    sent: list[dict] = []

    async def receive() -> dict:
        return {"type": "http.request", "body": b"", "more_body": False}

    async def send(message: dict) -> None:
        sent.append(message)

    await mw({"type": "http", "headers": headers}, receive, send)
    return sent


def test_rejects_without_token() -> None:
    rec = _Recorder()
    mw = BearerAuthMiddleware(rec.app, "s3cret")
    sent = asyncio.run(_drive(mw, headers=[]))
    assert sent[0]["status"] == 401
    assert rec.downstream_called is False


def test_rejects_wrong_token() -> None:
    rec = _Recorder()
    mw = BearerAuthMiddleware(rec.app, "s3cret")
    sent = asyncio.run(_drive(mw, headers=[(b"authorization", b"Bearer nope")]))
    assert sent[0]["status"] == 401
    assert rec.downstream_called is False


def test_passes_with_correct_token() -> None:
    rec = _Recorder()
    mw = BearerAuthMiddleware(rec.app, "s3cret")
    sent = asyncio.run(_drive(mw, headers=[(b"authorization", b"Bearer s3cret")]))
    assert sent[0]["status"] == 200
    assert rec.downstream_called is True


def test_lifespan_passes_through() -> None:
    rec = _Recorder()
    mw = BearerAuthMiddleware(rec.app, "s3cret")

    async def run() -> bool:
        seen = {"v": False}

        async def receive() -> dict:
            return {"type": "lifespan.startup"}

        async def send(message: dict) -> None:
            seen["v"] = True

        # Non-http scope must pass straight through (no auth on lifespan).
        await mw({"type": "lifespan"}, receive, send)
        return rec.downstream_called

    assert asyncio.run(run()) is True
