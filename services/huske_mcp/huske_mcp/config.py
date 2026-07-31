"""Environment-first service configuration with conservative resource defaults."""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


def _env(name: str, default: str = "") -> str:
    return os.environ.get(name, default).strip()


def _env_int(
    name: str, default: int, *, minimum: int, maximum: int | None = None
) -> int:
    raw = _env(name)
    value = int(raw) if raw else default
    if value < minimum:
        raise ValueError(f"{name} must be >= {minimum}")
    if maximum is not None and value > maximum:
        raise ValueError(f"{name} must be <= {maximum}")
    return value


def _env_list(name: str) -> tuple[str, ...]:
    return tuple(item.strip() for item in _env(name).split(",") if item.strip())


@dataclass(frozen=True)
class Settings:
    repository: str
    branch: str
    data_dir: Path
    host: str
    port: int
    poll_seconds: int
    access_token: str | None
    webhook_secret: str | None
    allowed_hosts: tuple[str, ...]
    allowed_origins: tuple[str, ...]
    search_profile: str
    embedding_model: str

    @property
    def checkout_dir(self) -> Path:
        return self.data_dir / "repository"

    @property
    def database_path(self) -> Path:
        return self.data_dir / "index.sqlite3"

    @property
    def transcript_root(self) -> Path:
        return self.checkout_dir / "transcripts"

    def validate(self) -> None:
        if not self.repository:
            raise ValueError("HUSKE_MCP_REPOSITORY is required")
        if self.repository.startswith("-") or any(
            character in self.repository for character in ("\n", "\r", "\0")
        ):
            raise ValueError("HUSKE_MCP_REPOSITORY is not a safe Git repository location")
        if not _valid_branch(self.branch):
            raise ValueError("HUSKE_MCP_BRANCH is not a safe Git branch name")
        if self.search_profile not in {"tiny", "semantic"}:
            raise ValueError("HUSKE_MCP_SEARCH_PROFILE must be tiny or semantic")
        if not self.access_token:
            raise ValueError("HUSKE_MCP_TOKEN or HUSKE_MCP_TOKEN_FILE is required")
        if len(self.access_token) < 32:
            raise ValueError("HUSKE_MCP_TOKEN must contain at least 32 characters")

    @classmethod
    def from_env(cls) -> Settings:
        token = _env("HUSKE_MCP_TOKEN") or _read_secret(_env("HUSKE_MCP_TOKEN_FILE"))
        webhook = _env("HUSKE_MCP_WEBHOOK_SECRET") or _read_secret(
            _env("HUSKE_MCP_WEBHOOK_SECRET_FILE")
        )
        settings = cls(
            repository=_env("HUSKE_MCP_REPOSITORY"),
            branch=_env("HUSKE_MCP_BRANCH", "main"),
            data_dir=Path(_env("HUSKE_MCP_DATA_DIR", "/var/lib/huske-mcp")).expanduser(),
            host=_env("HUSKE_MCP_HOST", "127.0.0.1"),
            port=_env_int("HUSKE_MCP_PORT", 7641, minimum=1, maximum=65535),
            poll_seconds=_env_int(
                "HUSKE_MCP_POLL_SECONDS", 60, minimum=10, maximum=86400
            ),
            access_token=token or None,
            webhook_secret=webhook or None,
            allowed_hosts=_env_list("HUSKE_MCP_ALLOWED_HOSTS"),
            allowed_origins=_env_list("HUSKE_MCP_ALLOWED_ORIGINS"),
            search_profile=_env("HUSKE_MCP_SEARCH_PROFILE", "tiny").lower(),
            embedding_model=_env(
                "HUSKE_MCP_EMBEDDING_MODEL",
                "minishlab/potion-multilingual-128M",
            ),
        )
        settings.validate()
        return settings


def _read_secret(path: str) -> str:
    if not path:
        return ""
    try:
        return Path(path).read_text(encoding="utf-8").strip()
    except OSError as exc:
        raise ValueError(f"cannot read secret file {path}: {exc}") from exc


def _valid_branch(branch: str) -> bool:
    if (
        not branch
        or branch == "@"
        or branch.startswith(("-", ".", "/"))
        or branch.endswith(("/", "."))
        or ".." in branch
        or "//" in branch
        or "@{" in branch
        or any(
            ch.isspace()
            or ord(ch) < 32
            or ord(ch) == 127
            or ch in "~^:?*[\\\\"
            for ch in branch
        )
    ):
        return False
    return not any(
        part.startswith(".") or part.endswith(".lock") for part in branch.split("/")
    )
