"""`huske-mcp`: deploy, reconcile, index, and inspect the isolated service."""

from __future__ import annotations

import argparse
import json
import logging
from collections.abc import Sequence
from urllib.parse import urlsplit, urlunsplit

from huske_mcp.config import Settings
from huske_mcp.server import create_runtime


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="huske-mcp")
    parser.add_argument(
        "command",
        choices=("serve", "sync", "doctor"),
        nargs="?",
        default="serve",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        settings = Settings.from_env()
    except (ValueError, OSError) as exc:
        print(f"[error] configuration: {exc}", flush=True)
        return 2

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    index, watcher, status = create_runtime(settings)

    if args.command == "doctor":
        payload = {
            "repository": _redact_remote(settings.repository),
            "branch": settings.branch,
            "data_dir": str(settings.data_dir),
            "bind": f"{settings.host}:{settings.port}",
            "authenticated": settings.access_token is not None,
            "webhook": settings.webhook_secret is not None,
            "allowed_hosts": settings.allowed_hosts,
            "allowed_origins": settings.allowed_origins,
            "search_profile": settings.search_profile,
        }
        print(json.dumps(payload, indent=2), flush=True)
        index.close()
        return 0

    if args.command == "sync":
        try:
            result = watcher.sync_now()
        except Exception as exc:
            print(f"[error] {exc}", flush=True)
            index.close()
            return 1
        print(
            json.dumps(
                {"commit": result.after, "changed": result.changed, **status.snapshot()},
                indent=2,
            ),
            flush=True,
        )
        index.close()
        return 0

    try:
        import uvicorn
    except ImportError as exc:
        print(f"[error] install service dependencies: {exc}", flush=True)
        index.close()
        return 1

    from huske_mcp.server import build_app

    app = build_app(settings, index, watcher, status)
    print(
        f"huske-mcp listening on http://{settings.host}:{settings.port}/mcp "
        f"({settings.search_profile}, poll {settings.poll_seconds}s)",
        flush=True,
    )
    uvicorn.run(
        app,
        host=settings.host,
        port=settings.port,
        workers=1,
        log_level="info",
        access_log=False,
    )
    return 0


def _redact_remote(remote: str) -> str:
    """Keep doctor useful without printing HTTPS credentials."""
    parsed = urlsplit(remote)
    if not parsed.scheme or "@" not in parsed.netloc:
        return remote
    host = parsed.netloc.rsplit("@", 1)[1]
    return urlunsplit((parsed.scheme, host, parsed.path, parsed.query, parsed.fragment))


if __name__ == "__main__":
    raise SystemExit(main())
