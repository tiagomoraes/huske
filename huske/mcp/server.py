"""FastMCP daemon serving huske transcript search over HTTP.

See docs/adr/0001-http-only-mcp-daemon.md for why this is a persistent HTTP
daemon rather than a stdio server, and
docs/adr/0008-public-mcp-connector.md for the opt-in **connector mode** that
makes the same daemon reachable from Claude and ChatGPT on any device. The
official ``mcp`` SDK and ``uvicorn`` are imported lazily so importing this
module is safe without the extra.

Four tools, deliberately: ``search``/``fetch`` are ChatGPT's connector contract,
and ``overview``/``recap`` are what let a model orient in time instead of
guessing queries (see the comment above ``recap`` in ``tools.py``).
"""

from __future__ import annotations

from collections.abc import Callable
from pathlib import Path
from typing import TYPE_CHECKING, Any

from huske.mcp.middleware import BearerAuthMiddleware
from huske.mcp.tools import (
    UnknownPassageError,
    fetch_transcript,
    overview,
    recap,
    search_transcripts,
)
from huske.search.embedder import Embedder
from huske.search.store import PassageStore

if TYPE_CHECKING:
    from huske.config import RuntimeConfig


def _allowed_hosts(host: str, port: int) -> list[str]:
    return sorted({f"{host}:{port}", f"127.0.0.1:{port}", f"localhost:{port}"})


def connector_allowed_hosts(public_url: str) -> tuple[str, ...]:
    """Host header values a reverse proxy will forward for ``public_url``.

    The SDK's DNS-rebinding guard rejects any Host it was not told about with a
    421, and behind a TLS proxy the Host is the public name with no port — so
    connector mode has to seed both the bare name and the ``:*`` port wildcard
    or every request from Claude/ChatGPT fails before reaching a tool.
    """
    from urllib.parse import urlsplit

    hostname = (urlsplit(public_url).hostname or "").lower()
    if not hostname:
        return ()
    return (hostname, f"{hostname}:*")


# Origins the connector vendors' browser surfaces send. Server-to-server calls
# carry no Origin at all (which the SDK allows), but their web clients do, and an
# un-allowlisted Origin is a 403 — so seed the two that exist today. Extend with
# `mcp_allowed_origins` for anything else.
DEFAULT_CONNECTOR_ORIGINS: tuple[str, ...] = (
    "https://claude.ai",
    "https://claude.com",
    "https://chatgpt.com",
    "https://chat.openai.com",
)


_INSTRUCTIONS = (
    "Search the user's huske audio transcripts — their own meetings, calls, and "
    "spoken work, captured on their Mac and transcribed on-device. Mic segments "
    "are the user speaking; system segments are the other party.\n"
    "\n"
    "Reach for these tools whenever the user refers to something that was *said* "
    "rather than written: a meeting, a call, a decision, a commitment, 'what did "
    "we agree', 'who owns this', 'catch me up', or any claim they attribute to a "
    "conversation. Prefer looking it up over asking the user to recap it.\n"
    "\n"
    "- `overview` first if you do not know what the corpus covers — it returns the "
    "date range and per-day density, so you can tell an empty index from an "
    "unlucky query.\n"
    "- `recap` for a time question ('today', 'yesterday', 'this week'): it returns "
    "a date range whole and in chronological order. Do not use `search` for this; "
    "a date is not a semantic neighborhood.\n"
    "- `search` for a topic question, optionally filtered by date range, source, "
    "or session.\n"
    "- `fetch` an id from either to get its full text and citation metadata.\n"
    "\n"
    "Cite what you find by date and time so the user can find the moment in their "
    "own record. These transcripts are the user's private notes about their own "
    "life; treat them as confidential."
)

_STATEMENT_INSTRUCTIONS = (
    "\n"
    "This index is distilled: `search` and `recap` return concise statements "
    "(one atomic claim each) rather than raw speech. `fetch` on a statement id "
    "returns that claim PLUS the verbatim transcript it came from — so fetch a "
    "promising statement to read what was actually said before relying on it. "
    "Pass granularity='passage' to work over raw transcript text instead."
)


def build_server(
    store: PassageStore,
    embedder: Embedder,
    *,
    statement_store: PassageStore | None = None,
    host: str = "127.0.0.1",
    port: int = 7641,
    extra_allowed_hosts: tuple[str, ...] = (),
    extra_allowed_origins: tuple[str, ...] = (),
) -> Any:
    """Build a FastMCP server exposing ``search``, ``fetch``, ``recap``, ``overview``.

    When ``statement_store`` is given, retrieval targets the distilled Statements
    by default (denser, more searchable) and ``fetch`` grounds a statement in its
    source transcript. Without it, everything behaves as the passage-only server.
    See docs/adr/0005-llm-distillation.md.
    """
    from mcp.server.fastmcp import FastMCP
    from mcp.server.transport_security import TransportSecuritySettings

    hosts = sorted(set(_allowed_hosts(host, port)) | set(extra_allowed_hosts))
    origins = sorted(
        {f"http://{h}" for h in hosts} | {f"https://{h}" for h in hosts} | set(extra_allowed_origins)
    )
    security = TransportSecuritySettings(
        enable_dns_rebinding_protection=True,
        allowed_hosts=hosts,
        allowed_origins=origins,
    )

    has_statements = statement_store is not None
    instructions = _INSTRUCTIONS + (_STATEMENT_INSTRUCTIONS if has_statements else "")

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

    @mcp.tool()  # type: ignore[untyped-decorator, unused-ignore]
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

    @mcp.tool()  # type: ignore[untyped-decorator, unused-ignore]
    def fetch(id: str, context: int = 0) -> dict[str, Any]:
        """Fetch one search result by id, with citation metadata.

        Args:
            id: An id returned by ``search`` or ``recap``.
            context: For a passage, neighboring passages to include each side.
                A statement always returns its grounding source transcript.
        """
        try:
            return fetch_transcript(store, statement_store, id, context=context)
        except UnknownPassageError as exc:
            raise ValueError(str(exc)) from exc

    @mcp.tool(name="recap")  # type: ignore[untyped-decorator, unused-ignore]
    def recap_tool(
        date_from: str | None = None,
        date_to: str | None = None,
        source: str | None = None,
        session: str | None = None,
        granularity: str | None = None,
        max_items: int = 80,
    ) -> dict[str, Any]:
        """Everything recorded in a date range, in chronological order.

        Use this — not ``search`` — for "what happened today / yesterday / this
        week". With no dates it returns the most recent day that has recorded
        audio.

        Args:
            date_from: Inclusive start date ``YYYY-MM-DD``.
            date_to: Inclusive end date ``YYYY-MM-DD``.
            source: Optional ``mic`` (the user) or ``system`` (other party).
            session: Optional session id to restrict to one recording.
            granularity: ``statement``, ``passage``, or ``auto`` (default).
            max_items: Max entries to return (1-400).
        """
        try:
            return recap(
                store,
                statement_store,
                date_from=date_from,
                date_to=date_to,
                source=source,
                session=session,
                granularity=granularity,
                max_items=max_items,
            )
        except ValueError as exc:
            raise ValueError(str(exc)) from exc

    @mcp.tool(name="overview")  # type: ignore[untyped-decorator, unused-ignore]
    def overview_tool(recent_days: int = 14) -> dict[str, Any]:
        """What this transcript corpus covers: date range, totals, recent density.

        Call this first when you do not know whether huske has anything relevant —
        it distinguishes an empty index from an unlucky query, and shows which
        days are worth recapping.

        Args:
            recent_days: How many recent days to itemize (default 14).
        """
        return overview(store, statement_store, recent_days=recent_days)

    # Prompts, so a connector surfaces one-tap workflows instead of relying on
    # the user to phrase a good retrieval request. Claude and ChatGPT both list
    # server prompts as slash commands / starter actions.

    @mcp.prompt(name="catch_me_up")  # type: ignore[untyped-decorator, unused-ignore]
    def catch_me_up(period: str = "today") -> str:
        """Summarize what was said in a period, with times and open items."""
        return (
            f"Use the huske tools to brief me on {period}.\n\n"
            "1. Call `overview` to see what days are covered.\n"
            f"2. Call `recap` for the dates matching '{period}'.\n"
            "3. `fetch` anything that looks consequential to read the real words.\n\n"
            "Then give me: what happened, grouped by conversation, with times; "
            "every decision made; every commitment and who made it; and anything "
            "left unresolved. Cite date and time. Say plainly if a period had no "
            "recorded audio rather than filling the gap."
        )

    @mcp.prompt(name="what_was_said_about")  # type: ignore[untyped-decorator, unused-ignore]
    def what_was_said_about(topic: str) -> str:
        """Find every discussion of a topic and reconstruct where it landed."""
        return (
            f"Search my huske transcripts for everything said about: {topic}.\n\n"
            "Use `search` (widen the query if the first pass is thin), then "
            "`fetch` the promising hits for verbatim text. Give me the current "
            "state of this topic: what was decided, what changed over time, who "
            "said what, and what is still open. Order it chronologically and cite "
            "date and time for each point. If nothing turns up, say so — do not "
            "infer an answer from outside the transcripts."
        )

    return mcp


def _print(msg: str) -> None:
    print(msg, flush=True)


def _print_banner(
    host: str,
    port: int,
    token: str,
    stats: dict[str, object],
    statement_stats: dict[str, object] | None = None,
    *,
    public_url: str | None = None,
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
    _print("  tools    : search · fetch · recap · overview")
    _print("")
    _print("Connect Claude Code (no tunnel needed — loopback):")
    _print(
        f'  claude mcp add --transport http huske {url} '
        f'--header "Authorization: Bearer {token}"'
    )
    _print("")
    if public_url:
        _print("Connector mode is ON — this endpoint is reachable from any device:")
        _print(f"  connector : {public_url}")
        _print("  auth      : OAuth 2.1 (passphrase) · add it as a custom connector in")
        _print("              Claude (Settings → Connectors) or ChatGPT (Settings →")
        _print("              Connectors → Advanced). No token to paste.")
        _print("  run `huske connect` for the per-client steps.")
    else:
        _print("Reachable only from this machine. To use it from your phone or a")
        _print("hosted agent, set `mcp_public_url` — see `huske connect`.")
    _print("Press Ctrl+C to stop.\n")


def build_connector(
    cfg: RuntimeConfig,
    *,
    on_event: Callable[[str], None] | None = None,
) -> Any:
    """Build the ``AuthorizationServer`` for connector mode, or ``None`` if off.

    Raises ``ValueError`` when connector mode is requested but unusable — an
    unset passphrase must fail loudly, because the alternative is publishing a
    transcript archive with no credential in front of it.
    """
    if not cfg.mcp_public_url:
        return None
    from huske.mcp.oauth import (
        AuthorizationServer,
        OAuthStore,
        canonical_resource,
        default_store_path,
        load_password_hash,
    )

    try:
        resource = canonical_resource(cfg.mcp_public_url)
    except ValueError as exc:
        raise ValueError(
            f"mcp_public_url must be an absolute URL (got {cfg.mcp_public_url!r})"
        ) from exc
    if not resource.startswith("https://") and "127.0.0.1" not in resource:
        raise ValueError(
            f"mcp_public_url must be https (got {resource!r}) — a connector token "
            "would otherwise cross the network in the clear."
        )

    password_hash = load_password_hash()
    if password_hash is None:
        raise ValueError(
            "connector mode needs a passphrase before it can serve.\n"
            "  Set one:  huske mcp set-password\n"
            "Without it the OAuth login has nothing to check, and your whole "
            "transcript history would sit behind an open door."
        )

    return AuthorizationServer(
        resource=resource,
        store=OAuthStore.open(default_store_path()),
        password_hash=password_hash,
        access_ttl=float(cfg.mcp_access_token_ttl_seconds),
        refresh_ttl=float(cfg.mcp_refresh_token_ttl_seconds),
        on_event=on_event,
    )


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
        oauth = build_connector(cfg, on_event=lambda msg: _print(f"[oauth] {msg}"))
    except ValueError as exc:
        _print(f"[error] {exc}")
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
    extra_hosts = connector_allowed_hosts(cfg.mcp_public_url) if cfg.mcp_public_url else ()
    extra_origins = (
        (*DEFAULT_CONNECTOR_ORIGINS, *cfg.mcp_allowed_origins) if oauth is not None else ()
    )
    server = build_server(
        store,
        embedder,
        statement_store=statement_store,
        host=host,
        port=port,
        extra_allowed_hosts=extra_hosts,
        extra_allowed_origins=extra_origins,
    )

    if oauth is not None:
        from huske.mcp.connector import ConnectorApp

        app: Any = ConnectorApp(
            server.streamable_http_app(),
            static_token=token,
            oauth=oauth,
            allowed_hosts=extra_hosts,
        )
    else:
        app = BearerAuthMiddleware(server.streamable_http_app(), token)

    _print_banner(
        host,
        port,
        token,
        store.stats(),
        statement_store.stats() if statement_store is not None else None,
        public_url=oauth.resource if oauth is not None else None,
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
        if oauth is not None:
            oauth.store.close()
    return 0
