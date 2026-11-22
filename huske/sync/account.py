"""``huske sync login|logout|status|repos|use`` — the Huske Sync GitHub App.

Each command prints plain sentences for a terminal, or JSON (one object per
line) with ``--json`` for Huske.app, which renders the same flow. Exit codes:
0 success, 1 failure, 2 configuration problem.
"""

from __future__ import annotations

import json
import time
from collections.abc import Callable
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from huske.config import RuntimeConfig, load_config, update_user_config
from huske.sync import credentials as creds
from huske.sync import github
from huske.sync.client import SyncError, exclusive_lock, redact_remote, sync_lock_path
from huske.sync.credentials import CredentialError, GitHubAppCredentials
from huske.sync.github import GitHubError, Repository, TokenSet


class _Output:
    def __init__(self, json_output: bool) -> None:
        self.json_output = json_output

    def emit(self, event: str, human: str | None = None, **data: Any) -> None:
        if self.json_output:
            print(json.dumps({"event": event, **data}), flush=True)
        elif human:
            print(human, flush=True)

    def fail(self, message: str, *, code: int = 1, **data: Any) -> int:
        self.emit("error", f"[error] {message}", message=message, **data)
        return code


def _load(config_path: Path | None, out: _Output) -> RuntimeConfig | None:
    try:
        return load_config(config_path=config_path)
    except ValueError as exc:
        out.fail(f"config: {exc}", code=2)
        return None


def _iso(epoch: float | None) -> str | None:
    if epoch is None:
        return None
    return datetime.fromtimestamp(epoch, tz=UTC).isoformat(timespec="seconds")


def _repo_json(repo: Repository) -> dict[str, Any]:
    return {"full_name": repo.full_name, "private": repo.private, "html_url": repo.html_url}


def _fresh_tokens(cfg: RuntimeConfig) -> TokenSet:
    """Current tokens, renewed under the same lock sync uses."""
    with exclusive_lock(sync_lock_path(cfg.sync_root), cfg.sync_push_timeout_seconds):
        return GitHubAppCredentials(creds.default_token_store()).fresh_tokens()


def _connected_repository(cfg: RuntimeConfig) -> str | None:
    if cfg.sync_auth != "github-app" or not cfg.sync_remote:
        return None
    parsed = github.parse_github_https_remote(cfg.sync_remote)
    return f"{parsed[0]}/{parsed[1]}" if parsed else None


# -- login --------------------------------------------------------------------


def run_login(
    config_path: Path | None = None,
    *,
    json_output: bool = False,
    sleep: Callable[[float], None] = time.sleep,
) -> int:
    out = _Output(json_output)
    cfg = _load(config_path, out)
    if cfg is None:
        return 2
    try:
        code = github.start_device_flow()
        out.emit(
            "code",
            f"Open {code.verification_uri} and enter the code {code.user_code}\n"
            "Waiting for you to approve Huske Sync on GitHub…",
            user_code=code.user_code,
            verification_uri=code.verification_uri,
            expires_in=code.expires_in,
        )
        tokens = github.wait_for_authorization(code, sleep=sleep)
        store = creds.default_token_store()
        lock = sync_lock_path(cfg.sync_root)
        # Keep the sign-in the moment GitHub grants it; the account name is a
        # nicety that a flaky network must not cost the user a second code.
        with exclusive_lock(lock, cfg.sync_push_timeout_seconds):
            store.save(tokens)
        tokens = tokens.with_login(_fetch_login_patiently(tokens.access_token, sleep))
        with exclusive_lock(lock, cfg.sync_push_timeout_seconds):
            store.save(tokens)
    except (GitHubError, CredentialError, SyncError) as exc:
        return out.fail(str(exc))
    out.emit(
        "connected",
        f"[huske] connected to GitHub as @{tokens.login}\n"
        f"[huske] next: share a private repository with Huske Sync at "
        f"{github.install_url()}, then run `huske sync use OWNER/REPO`",
        login=tokens.login,
        install_url=github.install_url(),
    )
    return 0


def _fetch_login_patiently(token: str, sleep: Callable[[float], None]) -> str:
    for attempt in range(5):
        try:
            return github.fetch_login(token)
        except GitHubError as exc:
            if not exc.retryable or attempt == 4:
                raise
            sleep(2.0 * (attempt + 1))
    raise AssertionError("unreachable")


# -- logout -------------------------------------------------------------------


def run_logout(config_path: Path | None = None, *, json_output: bool = False) -> int:
    out = _Output(json_output)
    cfg = _load(config_path, out)
    if cfg is None:
        return 2
    try:
        with exclusive_lock(sync_lock_path(cfg.sync_root), cfg.sync_push_timeout_seconds):
            creds.default_token_store().delete()
        if cfg.sync_auth == "github-app":
            # Without a sign-in, automatic sync could only fail. The remote
            # stays so reconnecting picks up where it left off.
            update_user_config({"sync_enabled": False, "sync_auth": None}, config_path)
    except (CredentialError, SyncError) as exc:
        return out.fail(str(exc))
    out.emit(
        "disconnected",
        "[huske] disconnected from GitHub on this Mac. To revoke Huske Sync on "
        f"GitHub too: {github.authorizations_url()}",
        authorizations_url=github.authorizations_url(),
    )
    return 0


# -- status -------------------------------------------------------------------


def run_status(config_path: Path | None = None, *, json_output: bool = False) -> int:
    """Local state only — no network, so the app can call it freely."""
    out = _Output(json_output)
    cfg = _load(config_path, out)
    if cfg is None:
        return 2
    try:
        tokens = creds.default_token_store().load()
    except CredentialError as exc:
        return out.fail(str(exc))
    now = time.time()
    connected = tokens is not None and (
        not tokens.needs_refresh(now, 0) or tokens.can_refresh(now)
    )
    repository = _connected_repository(cfg)
    payload = {
        "auth": cfg.sync_auth,
        "connected": connected,
        "login": tokens.login if tokens else None,
        "sign_in_renewable_until": _iso(tokens.refresh_expires_at) if tokens else None,
        "repository": repository,
        "remote": redact_remote(cfg.sync_remote) if cfg.sync_remote else None,
        "sync_enabled": cfg.sync_enabled,
        "install_url": github.install_url(),
        "new_repository_url": github.new_repository_url(),
    }
    if json_output:
        print(json.dumps({"event": "status", **payload}), flush=True)
        return 0
    if connected and tokens:
        print(f"[huske] GitHub: connected as @{tokens.login}")
    elif tokens:
        print("[huske] GitHub: sign-in expired — run `huske sync login`")
    else:
        print("[huske] GitHub: not connected — run `huske sync login`")
    if cfg.sync_auth == "github-app":
        print(f"[huske] publishing to: {repository or 'no repository chosen'}")
    elif cfg.sync_remote:
        print(f"[huske] publishing with this Mac's Git sign-in to: {payload['remote']}")
    return 0


# -- repos --------------------------------------------------------------------


def run_repos(config_path: Path | None = None, *, json_output: bool = False) -> int:
    out = _Output(json_output)
    cfg = _load(config_path, out)
    if cfg is None:
        return 2
    try:
        tokens = _fresh_tokens(cfg)
        installation = github.fetch_installation(tokens.access_token)
    except (GitHubError, CredentialError, SyncError) as exc:
        return out.fail(str(exc), reconnect=_needs_reconnect(exc))
    settings_url = (
        github.installation_settings_url(installation.installation_id)
        if installation.installation_id is not None
        else None
    )
    payload = {
        "installed": installation.installed,
        "repository_selection": installation.repository_selection,
        "repositories": [_repo_json(repo) for repo in installation.repositories],
        "install_url": github.install_url(),
        "installation_settings_url": settings_url,
        "new_repository_url": github.new_repository_url(),
        "current": _connected_repository(cfg),
    }
    if json_output:
        print(json.dumps({"event": "repos", **payload}), flush=True)
        return 0
    if not installation.installed:
        print(f"[huske] Huske Sync isn't installed yet. Share a repository: {github.install_url()}")
        return 0
    if installation.repository_selection == "all":
        print(
            "[warn] Huske Sync can see all your repositories. Limit it to the "
            f"transcripts repository: {settings_url}"
        )
    if not installation.repositories:
        print(f"[huske] no repositories shared yet: {github.install_url()}")
    for repo in installation.repositories:
        visibility = "private" if repo.private else "PUBLIC — not usable"
        print(f"  {repo.full_name} ({visibility})")
    return 0


# -- use ----------------------------------------------------------------------


def run_use(
    full_name: str, config_path: Path | None = None, *, json_output: bool = False
) -> int:
    out = _Output(json_output)
    cfg = _load(config_path, out)
    if cfg is None:
        return 2
    try:
        remote = github.github_https_remote(full_name.strip())
    except ValueError as exc:
        return out.fail(str(exc), code=2)
    try:
        tokens = _fresh_tokens(cfg)
        repo = github.fetch_repository(tokens.access_token, full_name.strip())
    except (GitHubError, CredentialError, SyncError) as exc:
        return out.fail(str(exc), reconnect=_needs_reconnect(exc))
    if repo is None:
        return out.fail(
            f"{full_name} isn't shared with Huske Sync, or doesn't exist. "
            f"Share it at {github.install_url()}",
            install_url=github.install_url(),
        )
    if not repo.private:
        return out.fail(
            f"{repo.full_name} is public. Huske only publishes transcripts to a "
            "private repository — make it private on GitHub or choose another."
        )
    try:
        update_user_config({"sync_auth": "github-app", "sync_remote": remote}, config_path)
    except (OSError, ValueError) as exc:
        return out.fail(f"couldn't save the configuration: {exc}")
    out.emit(
        "using",
        f"[huske] publishing to {repo.full_name} (private). Run `huske sync` to "
        "publish now, and `huske config set sync_enabled true` to publish every "
        "new transcript automatically.",
        repository=repo.full_name,
        remote=remote,
    )
    return 0


def _needs_reconnect(exc: Exception) -> bool:
    if isinstance(exc, GitHubError):
        return exc.kind in {"revoked", "expired"}
    if isinstance(exc, CredentialError):
        return not exc.retryable
    return False
