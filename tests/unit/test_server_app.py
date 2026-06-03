"""IngestApp ASGI behavior, driven directly (no uvicorn / no extras)."""

from __future__ import annotations

import asyncio
import json
from pathlib import Path
from typing import Any

from huske.server.app import IngestApp
from huske.server.ingest import content_sha256

_TOKEN = "write-secret"
_REL = "2026-06-02/120000_abcd1234_001.md"


def _make_app(tmp_path: Path, stored: list[Path], *, public_host: str | None = None) -> IngestApp:
    return IngestApp(
        output_root=tmp_path,
        write_token=_TOKEN,
        on_stored=stored.append,
        allowed_host=public_host,
    )


async def _call(
    app: IngestApp,
    *,
    method: str = "GET",
    path: str = "/",
    headers: list[tuple[bytes, bytes]] | None = None,
    body: bytes = b"",
) -> tuple[int, dict[str, Any]]:
    served = {"sent_body": False}

    async def receive() -> dict[str, Any]:
        if served["sent_body"]:
            return {"type": "http.disconnect"}
        served["sent_body"] = True
        return {"type": "http.request", "body": body, "more_body": False}

    sent: list[dict[str, Any]] = []

    async def send(message: dict[str, Any]) -> None:
        sent.append(message)

    scope = {"type": "http", "method": method, "path": path, "headers": headers or []}
    await app(scope, receive, send)
    start = next(m for m in sent if m["type"] == "http.response.start")
    body_msg = next((m for m in sent if m["type"] == "http.response.body"), {"body": b""})
    payload = json.loads(body_msg["body"].decode("utf-8")) if body_msg["body"] else {}
    return start["status"], payload


def _auth() -> list[tuple[bytes, bytes]]:
    return [(b"authorization", f"Bearer {_TOKEN}".encode())]


def _ingest_body(content: str, *, rel: str = _REL, sha: str | None = None) -> bytes:
    return json.dumps(
        {"rel_path": rel, "sha256": sha or content_sha256(content), "content": content}
    ).encode("utf-8")


def test_healthz_is_unauthenticated(tmp_path: Path) -> None:
    status, payload = asyncio.run(_call(_make_app(tmp_path, []), method="GET", path="/healthz"))
    assert status == 200
    assert payload["status"] == "ok"


def test_ingest_requires_auth(tmp_path: Path) -> None:
    app = _make_app(tmp_path, [])
    status, _ = asyncio.run(_call(app, method="POST", path="/ingest", body=_ingest_body("hi")))
    assert status == 401
    status, _ = asyncio.run(
        _call(
            app,
            method="POST",
            path="/ingest",
            headers=[(b"authorization", b"Bearer nope")],
            body=_ingest_body("hi"),
        )
    )
    assert status == 401


def test_ingest_stores_and_indexes(tmp_path: Path) -> None:
    stored: list[Path] = []
    app = _make_app(tmp_path, stored)
    content = "# transcript\n\nhello world\n"
    status, payload = asyncio.run(
        _call(app, method="POST", path="/ingest", headers=_auth(), body=_ingest_body(content))
    )
    assert status == 200, payload
    assert payload == {"status": "stored", "rel_path": _REL}
    written = tmp_path / _REL
    assert written.read_text(encoding="utf-8") == content
    assert stored == [written]  # on_stored fired with the stored path


def test_ingest_idempotent_unchanged(tmp_path: Path) -> None:
    stored: list[Path] = []
    app = _make_app(tmp_path, stored)
    content = "stable content"
    asyncio.run(_call(app, method="POST", path="/ingest", headers=_auth(), body=_ingest_body(content)))
    status, payload = asyncio.run(
        _call(app, method="POST", path="/ingest", headers=_auth(), body=_ingest_body(content))
    )
    assert status == 200
    assert payload["status"] == "unchanged"
    # on_stored fires both times (closes the wrote-but-crashed-before-index gap).
    assert len(stored) == 2


def test_ingest_rejects_bad_rel_path(tmp_path: Path) -> None:
    app = _make_app(tmp_path, [])
    status, payload = asyncio.run(
        _call(
            app,
            method="POST",
            path="/ingest",
            headers=_auth(),
            body=_ingest_body("x", rel="../escape.md"),
        )
    )
    assert status == 400
    assert "error" in payload


def test_ingest_conflict_on_different_content(tmp_path: Path) -> None:
    app = _make_app(tmp_path, [])
    asyncio.run(
        _call(app, method="POST", path="/ingest", headers=_auth(), body=_ingest_body("original"))
    )
    # Second push with different content → 409; original untouched.
    status, payload = asyncio.run(
        _call(app, method="POST", path="/ingest", headers=_auth(), body=_ingest_body("tampered"))
    )
    assert status == 409
    assert "error" in payload
    written = tmp_path / _REL
    assert written.read_text(encoding="utf-8") == "original"


def test_ingest_rejects_hash_mismatch(tmp_path: Path) -> None:
    app = _make_app(tmp_path, [])
    status, _ = asyncio.run(
        _call(
            app,
            method="POST",
            path="/ingest",
            headers=_auth(),
            body=_ingest_body("real", sha=content_sha256("tampered")),
        )
    )
    assert status == 422


def test_ingest_rejects_bad_json(tmp_path: Path) -> None:
    app = _make_app(tmp_path, [])
    status, _ = asyncio.run(
        _call(app, method="POST", path="/ingest", headers=_auth(), body=b"not json")
    )
    assert status == 400


def test_unknown_path_and_method(tmp_path: Path) -> None:
    app = _make_app(tmp_path, [])
    status, _ = asyncio.run(_call(app, method="POST", path="/nope", headers=_auth()))
    assert status == 404
    status, _ = asyncio.run(_call(app, method="GET", path="/ingest", headers=_auth()))
    assert status == 405


def test_host_validation_when_configured(tmp_path: Path) -> None:
    app = _make_app(tmp_path, [], public_host="huske.example.com")
    # Wrong Host → rejected even with a valid token.
    status, _ = asyncio.run(
        _call(
            app,
            method="POST",
            path="/ingest",
            headers=[*_auth(), (b"host", b"evil.example.com")],
            body=_ingest_body("x"),
        )
    )
    assert status == 400
    # Correct Host → accepted.
    status, _ = asyncio.run(
        _call(
            app,
            method="POST",
            path="/ingest",
            headers=[*_auth(), (b"host", b"huske.example.com")],
            body=_ingest_body("x"),
        )
    )
    assert status == 200
