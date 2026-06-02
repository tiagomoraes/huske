"""``huske serve``: receive pushed transcripts, store + index them.

This is the *write* side of the off-device huske server. The *read* side is the
existing loopback ``huske mcp`` daemon, run as a separate process on the same
box (both share the one ``sqlite-vec`` file; WAL handles the concurrent
writer/reader, exactly as in docs/adr/0001). Indexing runs in a single-thread
executor — off the uvicorn event loop and serialized over the one sqlite
connection. A subprocess (the recording path's choice) isn't needed: ADR 0003's
rule protects the audio drainer, which does not exist here.
"""

from __future__ import annotations

import hashlib
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import TYPE_CHECKING

from huske.server.app import IngestApp

if TYPE_CHECKING:
    from huske.config import RuntimeConfig


def _print(msg: str) -> None:
    print(msg, flush=True)


def _print_banner(host: str, port: int, token: str, stats: dict[str, object], cfg: RuntimeConfig) -> None:
    base = f"http://{host}:{port}"
    public = cfg.public_host or "<your-public-host>"
    _print("")
    _print("huske server (ingest)")
    _print(f"  ingest   : {base}/ingest   (bind address — put a TLS reverse proxy in front)")
    _print(f"  health   : {base}/healthz")
    _print(f"  token    : {token}")
    _print(f"  index    : {stats['passages']} passages from {stats['files']} transcripts")
    _print(f"  model    : {stats['embedding_model']} (dim {stats['dim']})")
    _print("")
    _print("On each recording Mac, in ~/.config/huske/config.toml:")
    _print(f'  sync_endpoint = "https://{public}"')
    _print("and write the token above to ~/.config/huske/sync_token (chmod 600).")
    _print("")
    _print("Run the read side alongside this (loopback, for your co-located agent):")
    _print("  huske mcp")
    _print("Press Ctrl+C to stop.\n")


def run(
    cfg: RuntimeConfig,
    *,
    host: str | None = None,
    port: int | None = None,
    token_path: Path | None = None,
) -> int:
    """Serve the ingest endpoint. Returns a process exit code."""
    from huske.mcp.token import ingest_token_path, load_or_create_token
    from huske.paths import index_db_path
    from huske.search.embedder import EmbedderUnavailable, build_embedder
    from huske.search.indexer import Indexer
    from huske.search.store import ModelMismatchError, PassageStore, StoreUnavailable

    host = host or cfg.ingest_host
    port = port or cfg.ingest_port

    try:
        import uvicorn
    except ImportError as exc:
        _print(
            f"[error] the huske server needs the server extra: "
            f"pip install 'huske[server]' ({exc})"
        )
        return 1

    try:
        embedder = build_embedder(cfg.embedding_model)
    except EmbedderUnavailable as exc:
        _print(f"[error] {exc}")
        return 1

    cfg.output_root.mkdir(parents=True, exist_ok=True)
    cfg.index_root.mkdir(parents=True, exist_ok=True)

    try:
        store = PassageStore.open(
            index_db_path(cfg),
            embedding_model=cfg.embedding_model,
            dim=embedder.dim,
            create=True,
        )
    except (ModelMismatchError, StoreUnavailable) as exc:
        _print(f"[error] {exc}")
        return 1

    indexer = Indexer(store, embedder)
    executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="huske-index")

    def _index(path: Path) -> None:
        def _job() -> None:
            try:
                n = indexer.index_file(path)
                if n:
                    _print(f"[huske] indexed {path.name}: {n} passage(s)")
            except Exception as exc:  # best-effort; a later `huske index` reconciles
                _print(f"[warn] indexing {path.name} failed: {str(exc).splitlines()[0]}")

        executor.submit(_job)

    def _startup_backfill() -> None:
        """Index any transcript stored but not yet in the index (e.g. crash recovery).

        Queued before uvicorn starts. Because the executor has max_workers=1, new
        ingest jobs queue behind this naturally — no race between backfill and live
        ingest. The Indexer is idempotent on content hash so overlap is safe.
        """
        try:
            from huske.search.indexer import iter_transcripts

            pending = [
                p for p in iter_transcripts(cfg.output_root)
                if not store.is_indexed(str(p.resolve()), hashlib.sha256(p.read_bytes()).hexdigest())
            ]
            if pending:
                _print(f"[huske] startup backfill: {len(pending)} transcript(s) not yet indexed")
            for path in pending:
                _index(path)
        except Exception as exc:
            _print(f"[warn] startup backfill check failed: {str(exc).splitlines()[0]}")

    executor.submit(_startup_backfill)

    write_token = load_or_create_token(token_path or ingest_token_path())
    app = IngestApp(
        output_root=cfg.output_root,
        write_token=write_token,
        on_stored=_index,
        allowed_host=cfg.public_host,
    )

    _print_banner(host, port, write_token, store.stats(), cfg)

    try:
        uvicorn.run(app, host=host, port=port, log_level=cfg.log_level.lower())
    except KeyboardInterrupt:  # pragma: no cover - interactive
        pass
    finally:
        executor.shutdown(wait=True)
        store.close()
    return 0
