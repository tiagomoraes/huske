"""Structured logging via structlog.

JSON lines to ``~/huske/logs/<session_id>.log`` plus an optional console renderer
when ``--no-ui`` is set or stderr is a terminal at startup.
"""

from __future__ import annotations

import logging
import sys
from pathlib import Path
from typing import Any

import structlog


def configure(
    log_path: Path | None,
    *,
    level: str = "INFO",
    console: bool = False,
) -> None:
    """Configure structlog and the root stdlib logger.

    Idempotent: safe to call multiple times.
    """

    # File handler (JSON lines).
    handlers: list[logging.Handler] = []
    if log_path is not None:
        log_path.parent.mkdir(parents=True, exist_ok=True)
        file_handler = logging.FileHandler(log_path, encoding="utf-8")
        file_handler.setFormatter(logging.Formatter("%(message)s"))
        handlers.append(file_handler)

    if console:
        stream_handler = logging.StreamHandler(sys.stderr)
        stream_handler.setFormatter(logging.Formatter("%(message)s"))
        handlers.append(stream_handler)

    logging.basicConfig(
        level=getattr(logging, level.upper(), logging.INFO),
        handlers=handlers,
        force=True,
    )

    timestamper = structlog.processors.TimeStamper(fmt="iso", utc=False)

    shared: list[Any] = [
        structlog.contextvars.merge_contextvars,
        structlog.stdlib.add_log_level,
        timestamper,
        structlog.processors.StackInfoRenderer(),
    ]

    structlog.configure(
        processors=[
            *shared,
            structlog.processors.format_exc_info,
            structlog.processors.JSONRenderer(),
        ],
        wrapper_class=structlog.make_filtering_bound_logger(
            getattr(logging, level.upper(), logging.INFO)
        ),
        logger_factory=structlog.stdlib.LoggerFactory(),
        cache_logger_on_first_use=True,
    )


def get_logger(name: str | None = None) -> structlog.stdlib.BoundLogger:
    return structlog.get_logger(name)
