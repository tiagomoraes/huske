"""FastMCP daemon serving huske transcript search over loopback HTTP.

See docs/adr/0001-http-only-mcp-daemon.md for why this is a persistent HTTP
daemon rather than a stdio server. The official ``mcp`` SDK and ``uvicorn`` are
imported lazily so importing this module is safe without the extra.
"""

from __future__ import annotations

from pathlib import Path
from typing import TYPE_CHECKING, Any

from huske.mcp.middleware import BearerAuthMiddleware
from huske.mcp.tools import UnknownPassageError, fetch_transcript, search_transcripts
from huske.search.embedder import Embedder
from huske.search.store import PassageStore

if TYPE_CHECKING:
    from huske.config import RuntimeConfig


def _allowed_hosts(host: str, port: int) -> list[str]:
    return sorted({f"{host}:{port}", f"127.0.0.1:{port}", f"localhost:{port}"})


def build_server(
    store: PassageStore,
    embedder: Embedder,
    *,
    statement_store: PassageStore | None = None,
    host: str = "127.0.0.1",
    port: int = 7641,
    extra_allowed_hosts: tuple[str, ...] = (),
) -> Any:
    """Build a FastMCP server exposing ``search`` and ``fetch``.

    When ``statement_store`` is given, ``search`` targets the distilled
    Statements by default (denser, more searchable) and ``fetch`` grounds a
    statement in its source transcript. Without it, both behave exactly as the
    passage-only server. See docs/adr/0005-llm-distillation.md.
    """
    from mcp.server.fastmcp import FastMCP
    from mcp.server.transport_security import TransportSecuritySettings

    hosts = sorted(set(_allowed_hosts(host, port)) | set(extra_allowed_hosts))
    origins = sorted({f"http://{h}" for h in hosts} | {f"https://{h}" for h in hosts})
    security = TransportSecuritySettings(
        enable_dns_rebinding_protection=True,
        allowed_hosts=hosts,
        allowed_origins=origins,
    )

    has_statements = statement_store is not None
    instructions = (
        "Search the user's local huske audio transcripts (their own meetings "
        "and calls, transcribed on-device). Use `search` to find relevant "
        "material by meaning, optionally filtered by date range, audio source "
        "(mic = the user; system = the other party), or session; then `fetch` "
        "an id for its full text and citation metadata."
    )
    if has_statements:
        instructions += (
            " `search` returns concise distilled statements by default; `fetch` on "
            "a statement id returns that claim PLUS the verbatim source transcript "
            "it came from, so fetch promising statements to read what was actually "
            "said. Pass granularity='passage' to search raw transcript text instead."
        )

    mcp = FastMCP(
        "huske",
        instructions=instructions,
        host=host,
        port=port,
        streamable_http_path="/mcp",
        stateless_http=True,
        json_response=True,
        transport_security=security,
    )

    @mcp.tool()  # type: ignore[untyped-decorator]
    def search(
        query: str,
        date_from: str | None = None,
        date_to: str | None = None,
        source: str | None = None,
        session: str | None = None,
        granularity: str | None = None,
        k: int = 8,
    ) -> dict[str, Any]:
        """Search transcripts by meaning.

        Args:
            query: Natural-language query.
            date_from: Optional inclusive start date ``YYYY-MM-DD``.
            date_to: Optional inclusive end date ``YYYY-MM-DD``.
            source: Optional ``mic`` (the user) or ``system`` (other party).
            session: Optional session id to restrict to one recording.
            granularity: ``statement`` (concise distilled claims), ``passage``
                (raw transcript windows), or ``auto`` (default: statements when
                available, else passages).
            k: Max results (1-50).
        """
        try:
            return search_transcripts(
                store,
                statement_store,
                embedder,
                query,
                granularity=granularity,
                date_from=date_from,
                date_to=date_to,
                source=source,
                session=session,
                k=k,
            )
        except ValueError as exc:
            raise ValueError(str(exc)) from exc

    @mcp.tool()  # type: ignore[untyped-decorator]
    def fetch(id: str, context: int = 0) -> dict[str, Any]:
        """Fetch one search result by id, with citation metadata.

        Args:
            id: An id returned by ``search`` (a statement or a passage).
            context: For a passage, neighboring passages to include each side.
                A statement always returns its grounding source transcript.
        """
        try:
            return fetch_transcript(store, statement_store, id, context=context)
        except UnknownPassageError as exc:
            raise ValueError(str(exc)) from exc

    return mcp


def _print(msg: str) -> None:
    print(msg, flush=True)


def _print_banner(
    host: str,
    port: int,
    token: str,
    stats: dict[str, object],
    statement_stats: dict[str, object] | None = None,
) -> None:
    url = f"http://{host}:{port}/mcp"
    _print("")
    _print("huske MCP server")
    _print(f"  endpoint : {url}")
    _print(f"  token    : {token}")
    _print(f"  index    : {stats['passages']} passages from {stats['files']} transcripts")
    if statement_stats is not None:
        _print(
            f"  statements: {statement_stats['passages']} distilled statements "
            f"from {statement_stats['files']} transcripts (searched first)"
        )
    _print(f"  model    : {stats['embedding_model']} (dim {stats['dim']})")
    _print("")
    _print("Connect Claude Code (no tunnel needed — loopback):")
    _print(
        f'  claude mcp add --transport http huske {url} '
        f'--header "Authorization: Bearer {token}"'
    )
    _print("")
    _print("ChatGPT requires a public HTTPS tunnel to this endpoint (opt-in).")
    _print("Press Ctrl+C to stop.\n")


def run(
    cfg: RuntimeConfig,
    *,
    host: str | None = None,
    port: int | None = None,
    token_path: Path | None = None,
) -> int:
    """Serve the MCP daemon. Returns a process exit code."""
    from huske.mcp.token import load_or_create_token
    from huske.paths import index_db_path, statements_db_path
    from huske.search.embedder import EmbedderUnavailable, build_embedder
    from huske.search.store import ModelMismatchError, StoreUnavailable

    host = host or cfg.mcp_host
    port = port or cfg.mcp_port

    try:
        import mcp  # noqa: F401
        import uvicorn
    except ImportError as exc:
        _print(f"[error] the MCP server needs the search extra: pip install 'huske[mcp]' ({exc})")
        return 1

    try:
        embedder = build_embedder(cfg.embedding_model)
    except EmbedderUnavailable as exc:
        _print(f"[error] {exc}")
        return 1

    try:
        store = PassageStore.open(
            index_db_path(cfg),
            embedding_model=cfg.embedding_model,
            dim=embedder.dim,
            create=False,
        )
    except StoreUnavailable as exc:
        _print(f"[error] {exc}")
        return 1
    except ModelMismatchError as exc:
        _print(f"[error] {exc}")
        return 1

    # Optional statement index — distilled, searched first when present. A
    # missing/mismatched statement store degrades to passage-only search.
    statement_store: PassageStore | None = None
    sdb = statements_db_path(cfg)
    if sdb.exists():
        try:
            statement_store = PassageStore.open(
                sdb, embedding_model=cfg.embedding_model, dim=embedder.dim, create=False
            )
        except (StoreUnavailable, ModelMismatchError) as exc:
            _print(f"[warn] statement index unavailable ({exc}); serving passages only")
            statement_store = None

    token = load_or_create_token(token_path)
    server = build_server(store, embedder, statement_store=statement_store, host=host, port=port)
    app = BearerAuthMiddleware(server.streamable_http_app(), token)
    _print_banner(
        host,
        port,
        token,
        store.stats(),
        statement_store.stats() if statement_store is not None else None,
    )

    import uvicorn

    try:
        uvicorn.run(app, host=host, port=port, log_level=cfg.log_level.lower())
    except KeyboardInterrupt:  # pragma: no cover - interactive
        pass
    finally:
        store.close()
        if statement_store is not None:
            statement_store.close()
    return 0
