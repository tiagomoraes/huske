from __future__ import annotations

import hashlib
import hmac
import json
import threading
from pathlib import Path

import pytest

pytest.importorskip("mcp")
pytest.importorskip("starlette")

from starlette.testclient import TestClient

from huske_mcp.config import Settings
from huske_mcp.index import TranscriptIndex
from huske_mcp.server import ServiceStatus, build_app


class FakeWatcher:
    def __init__(self) -> None:
        self.wakes = 0

    def start(self) -> None:
        pass

    def stop(self) -> None:
        pass

    def wake(self) -> None:
        self.wakes += 1


def settings(tmp_path: Path) -> Settings:
    return Settings(
        repository="git@example.invalid:private/transcripts.git",
        branch="main",
        data_dir=tmp_path,
        host="127.0.0.1",
        port=7641,
        poll_seconds=60,
        access_token="test-token-that-is-at-least-32-chars",
        webhook_secret="webhook-secret",
        allowed_hosts=("testserver",),
        allowed_origins=(),
        search_profile="tiny",
        embedding_model="unused",
    )


def test_exact_mcp_route_requires_bearer_and_health_waits_for_sync(
    tmp_path: Path,
) -> None:
    index = TranscriptIndex(tmp_path / "index.sqlite3")
    status = ServiceStatus(threading.Lock())
    app = build_app(settings(tmp_path), index, FakeWatcher(), status)  # type: ignore[arg-type]
    with TestClient(app, follow_redirects=False) as client:
        assert client.get("/healthz").status_code == 503
        assert client.post("/mcp").status_code == 401

        response = client.post(
            "/mcp",
            headers={
                "Authorization": "Bearer test-token-that-is-at-least-32-chars",
                "Accept": "application/json, text/event-stream",
            },
            json={
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "protocolVersion": "2025-06-18",
                    "capabilities": {},
                    "clientInfo": {"name": "test", "version": "1"},
                },
            },
        )
        assert response.status_code == 200
        assert response.json()["result"]["serverInfo"]["name"] == "huske"

        with status.lock:
            status.commit = "abc123"
        assert client.get("/healthz").status_code == 200


def test_signed_push_webhook_only_wakes_matching_branch(tmp_path: Path) -> None:
    index = TranscriptIndex(tmp_path / "index.sqlite3")
    status = ServiceStatus(threading.Lock())
    watcher = FakeWatcher()
    app = build_app(settings(tmp_path), index, watcher, status)  # type: ignore[arg-type]
    body = json.dumps({"ref": "refs/heads/main"}).encode()
    signature = "sha256=" + hmac.new(
        b"webhook-secret", body, hashlib.sha256
    ).hexdigest()

    with TestClient(app) as client:
        response = client.post(
            "/webhooks/github",
            content=body,
            headers={
                "content-type": "application/json",
                "x-github-event": "push",
                "x-hub-signature-256": signature,
            },
        )
        assert response.status_code == 202
        assert watcher.wakes == 1

        rejected = client.post(
            "/webhooks/github",
            content=body,
            headers={
                "content-type": "application/json",
                "x-github-event": "push",
                "x-hub-signature-256": "sha256=wrong",
            },
        )
        assert rejected.status_code == 401
        assert watcher.wakes == 1

        invalid_payload = b"[]"
        invalid_signature = "sha256=" + hmac.new(
            b"webhook-secret", invalid_payload, hashlib.sha256
        ).hexdigest()
        rejected = client.post(
            "/webhooks/github",
            content=invalid_payload,
            headers={
                "content-type": "application/json",
                "x-github-event": "push",
                "x-hub-signature-256": invalid_signature,
            },
        )
        assert rejected.status_code == 400
        assert watcher.wakes == 1
