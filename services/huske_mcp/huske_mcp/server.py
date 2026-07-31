"""Authenticated Streamable-HTTP MCP service plus GitHub webhook wakeup."""

from __future__ import annotations

import contextlib
import hashlib
import hmac
import json
import logging
import threading
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from typing import Any, cast

from huske_mcp.config import Settings
from huske_mcp.index import TranscriptIndex
from huske_mcp.replica import GitReplica, PullResult, ReplicaWatcher

log = logging.getLogger("huske_mcp")

Scope = dict[str, Any]
Message = dict[str, Any]
Receive = Callable[[], Awaitable[Message]]
Send = Callable[[Message], Awaitable[None]]


@dataclass
class ServiceStatus:
    lock: threading.Lock
    commit: str | None = None
    last_error: str | None = None
    indexed_files: int = 0
    indexed_passages: int = 0
    failed_files: int = 0

    def snapshot(self) -> dict[str, Any]:
        with self.lock:
            return {
                "commit": self.commit,
                "last_error": self.last_error,
                "indexed_files": self.indexed_files,
                "indexed_passages": self.indexed_passages,
                "failed_files": self.failed_files,
            }


class BearerAuthApp:
    def __init__(self, app: Any, token: str | None) -> None:
        self.app = app
        self.expected = f"Bearer {token}" if token else None

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope.get("type") == "http" and self.expected is not None:
            provided = _header(scope, b"authorization")
            if not hmac.compare_digest(provided, self.expected):
                await _json(
                    send,
                    401,
                    {"error": "unauthorized"},
                    headers=[(b"www-authenticate", b"Bearer")],
                )
                return
        await self.app(scope, receive, send)


def build_app(
    settings: Settings,
    index: TranscriptIndex,
    watcher: ReplicaWatcher,
    status: ServiceStatus,
) -> Any:
    settings.validate()
    try:
        from mcp.server.fastmcp import FastMCP
        from mcp.server.transport_security import TransportSecuritySettings
        from starlette.applications import Starlette
        from starlette.requests import Request
        from starlette.responses import JSONResponse, Response
        from starlette.routing import Mount, Route
    except ImportError as exc:  # pragma: no cover - packaging/preflight
        raise RuntimeError("install the huske-mcp service dependencies") from exc

    allowed_hosts = list(
        dict.fromkeys(
            [
                "127.0.0.1:*",
                "localhost:*",
                "[::1]:*",
                *settings.allowed_hosts,
            ]
        )
    )
    allowed_origins = list(
        dict.fromkeys(
            [
                "http://127.0.0.1:*",
                "http://localhost:*",
                "http://[::1]:*",
                *settings.allowed_origins,
            ]
        )
    )
    mcp = FastMCP(
        "huske",
        instructions=(
            "Huske contains spoken meeting and call context. Use overview to orient, "
            "recap for time ranges, search for topics, and fetch before quoting."
        ),
        stateless_http=True,
        json_response=True,
        host=settings.host,
        port=settings.port,
        streamable_http_path="/mcp",
        max_request_body_size=1024 * 1024,
        transport_security=TransportSecuritySettings(
            enable_dns_rebinding_protection=True,
            allowed_hosts=allowed_hosts,
            allowed_origins=allowed_origins,
        ),
    )

    @mcp.tool()
    def search(
        query: str,
        date_from: str | None = None,
        date_to: str | None = None,
        source: str | None = None,
        session: str | None = None,
        limit: int = 8,
    ) -> dict[str, Any]:
        """Search transcript passages, optionally filtered by date/source/session."""
        return index.search(
            query,
            date_from=date_from,
            date_to=date_to,
            source=source,
            session=session,
            limit=limit,
        )

    @mcp.tool()
    def fetch(id: str, context: int = 1) -> dict[str, Any]:
        """Fetch a passage and nearby passages for verbatim context."""
        try:
            passage_id = int(id)
        except ValueError as exc:
            raise ValueError("id must be the numeric value returned by search/recap") from exc
        return index.fetch(passage_id, context=context)

    @mcp.tool()
    def recap(
        date_from: str | None = None,
        date_to: str | None = None,
        limit: int = 100,
    ) -> dict[str, Any]:
        """Return passages chronologically for a day or date range."""
        return index.recap(date_from=date_from, date_to=date_to, limit=limit)

    @mcp.tool()
    def overview(recent_days: int = 14) -> dict[str, Any]:
        """Describe corpus coverage and recent transcript density."""
        result = index.overview(recent_days=recent_days)
        result["replica"] = status.snapshot()
        return result

    @mcp.tool()
    def sync_status() -> dict[str, Any]:
        """Report the Git replica/index state without exposing credentials."""
        return status.snapshot()

    async def health(_: Request) -> JSONResponse:
        snapshot = status.snapshot()
        code = (
            200
            if snapshot["commit"] is not None
            and snapshot["last_error"] is None
            and snapshot["failed_files"] == 0
            else 503
        )
        public = {key: value for key, value in snapshot.items() if key != "last_error"}
        return JSONResponse({"status": "ok" if code == 200 else "degraded", **public}, code)

    async def webhook(request: Request) -> Response:
        if settings.webhook_secret is None:
            return Response(status_code=404)
        declared = request.headers.get("content-length")
        if declared:
            try:
                if int(declared) > 1024 * 1024:
                    return JSONResponse({"error": "payload too large"}, 413)
            except ValueError:
                return JSONResponse({"error": "invalid content length"}, 400)
        chunks: list[bytes] = []
        size = 0
        async for chunk in request.stream():
            size += len(chunk)
            if size > 1024 * 1024:
                return JSONResponse({"error": "payload too large"}, 413)
            chunks.append(chunk)
        body = b"".join(chunks)
        signature = request.headers.get("x-hub-signature-256", "")
        expected = "sha256=" + hmac.new(
            settings.webhook_secret.encode(), body, hashlib.sha256
        ).hexdigest()
        if not hmac.compare_digest(signature, expected):
            return JSONResponse({"error": "invalid signature"}, 401)
        if request.headers.get("x-github-event") == "ping":
            return JSONResponse({"status": "pong"})
        if request.headers.get("x-github-event") != "push":
            return Response(status_code=202)
        try:
            payload = json.loads(body)
        except ValueError:
            return JSONResponse({"error": "invalid JSON"}, 400)
        if not isinstance(payload, dict):
            return JSONResponse({"error": "invalid JSON payload"}, 400)
        if payload.get("ref") != f"refs/heads/{settings.branch}":
            return Response(status_code=202)
        watcher.wake()
        return JSONResponse({"status": "scheduled"}, 202)

    @contextlib.asynccontextmanager
    async def lifespan(_: Any) -> Any:
        watcher.start()
        async with mcp.session_manager.run():
            yield
        watcher.stop()
        index.close()

    return Starlette(
        routes=[
            Route("/healthz", endpoint=health, methods=["GET"]),
            Route("/webhooks/github", endpoint=webhook, methods=["POST"]),
            Mount(
                "/",
                app=cast(
                    Any,
                    BearerAuthApp(mcp.streamable_http_app(), settings.access_token),
                ),
            ),
        ],
        lifespan=lifespan,
    )


def create_runtime(
    settings: Settings,
) -> tuple[TranscriptIndex, ReplicaWatcher, ServiceStatus]:
    settings.validate()
    embedder = None
    if settings.search_profile == "semantic":
        from huske_mcp.embeddings import Model2VecEmbedder

        embedder = Model2VecEmbedder(settings.embedding_model)
    index = TranscriptIndex(settings.database_path, embedder=embedder)
    status = ServiceStatus(lock=threading.Lock())
    replica = GitReplica(
        settings.repository,
        settings.checkout_dir,
        branch=settings.branch,
    )

    def on_pull(result: PullResult) -> None:
        summary = index.refresh(settings.transcript_root)
        overview = index.overview(recent_days=1)
        with status.lock:
            status.commit = result.after
            status.last_error = (
                f"{summary.failed} transcript(s) could not be indexed"
                if summary.failed
                else None
            )
            status.indexed_files = int(overview["transcripts"])
            status.indexed_passages = int(overview["passages"])
            status.failed_files = summary.failed
        log.info(
            "replica current commit=%s indexed=%d removed=%d passages=%d failed=%d",
            result.after[:10],
            summary.indexed,
            summary.removed,
            summary.passages,
            summary.failed,
        )

    def on_error(exc: Exception) -> None:
        with status.lock:
            status.last_error = str(exc).splitlines()[0]
        log.error("replica sync failed: %s", exc)

    watcher = ReplicaWatcher(
        replica,
        on_pull,
        poll_seconds=settings.poll_seconds,
        on_error=on_error,
    )
    return index, watcher, status


def _header(scope: Scope, name: bytes) -> str:
    for key, value in scope.get("headers", []):
        if (
            isinstance(key, bytes)
            and isinstance(value, bytes)
            and key.lower() == name
        ):
            return value.decode("latin-1")
    return ""


async def _json(
    send: Send,
    status: int,
    payload: dict[str, Any],
    *,
    headers: list[tuple[bytes, bytes]] | None = None,
) -> None:
    body = json.dumps(payload).encode()
    all_headers = [
        (b"content-type", b"application/json"),
        (b"content-length", str(len(body)).encode()),
        *(headers or []),
    ]
    await send({"type": "http.response.start", "status": status, "headers": all_headers})
    await send({"type": "http.response.body", "body": body})
