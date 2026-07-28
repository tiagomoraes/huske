"""``huske connect``: the exact wiring for each LLM client, and whether it works.

Every integration failure this command exists to prevent is a *setup* failure,
not a capability one. The endpoint, the token, and the client all exist; what is
missing is knowing that Claude Code takes a header, Claude Desktop needs an
stdio bridge, the phone apps need OAuth, and ChatGPT needs developer mode. That
knowledge lived in prose across three documents, so it was easier to give up
than to finish.

So this command answers one question per client — "what do I paste, and will it
work from here?" — reading the live config and token files to say which paths are
actually reachable right now rather than describing all of them equally.

Stdlib-only and side-effect free: it prints, it never writes config or contacts
a network. Importable without the ``huske[mcp]`` extra.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from huske.config import RuntimeConfig

# Reach describes *where the client runs*, which is the only thing that decides
# which endpoint it can use.
LOCAL = "local"  # same Mac as the daemon → loopback works
REMOTE = "remote"  # another device or a vendor's backend → needs connector mode


@dataclass(frozen=True, slots=True)
class Client:
    key: str
    label: str
    reach: str
    note: str


CLIENTS: tuple[Client, ...] = (
    Client("claude-code", "Claude Code", LOCAL, "CLI on this Mac (also works remote)"),
    Client("claude-desktop", "Claude Desktop / Cowork", LOCAL, "needs an stdio bridge on loopback"),
    Client("claude-app", "Claude on iPhone / web", REMOTE, "custom connector, OAuth"),
    Client("chatgpt", "ChatGPT (app / web)", REMOTE, "custom connector, developer mode"),
    Client("codex", "Codex CLI", LOCAL, "loopback, bearer header"),
    Client("cursor", "Cursor", LOCAL, "loopback, bearer header"),
    Client("hermes", "Co-located agent on the server", LOCAL, "loopback on the VPS itself"),
)

CLIENT_KEYS = tuple(c.key for c in CLIENTS)


@dataclass(frozen=True, slots=True)
class Wiring:
    """Everything the renderers need, resolved once from config + disk."""

    loopback_url: str
    connector_url: str | None
    token: str | None
    has_password: bool
    token_path: str

    @property
    def token_display(self) -> str:
        return self.token or "<token from the `huske mcp` banner>"

    @property
    def connector_ready(self) -> bool:
        return bool(self.connector_url) and self.has_password


def resolve_wiring(cfg: RuntimeConfig) -> Wiring:
    """Read the effective endpoints and credentials without creating anything."""
    from huske.mcp.oauth import load_password_hash
    from huske.mcp.token import default_token_path, load_token

    # load_token, not load_or_create_token: `huske connect` must never mint a
    # credential as a side effect of being asked a question.
    token_path = default_token_path()
    connector = cfg.mcp_public_url.rstrip("/") if cfg.mcp_public_url else None
    return Wiring(
        loopback_url=f"http://{cfg.mcp_host}:{cfg.mcp_port}/mcp",
        connector_url=connector,
        token=load_token(token_path),
        has_password=load_password_hash() is not None,
        token_path=str(token_path),
    )


# --- per-client instructions -------------------------------------------------


def _claude_code(w: Wiring) -> list[str]:
    out = [
        "On this Mac (loopback — no tunnel, no OAuth):",
        "",
        f'  claude mcp add --transport http huske {w.loopback_url} \\',
        f'    --header "Authorization: Bearer {w.token_display}"',
    ]
    if w.connector_ready:
        out += [
            "",
            "From anywhere else (another machine, a CI box, your VPS) — Claude Code",
            "runs the OAuth flow itself and opens a browser once:",
            "",
            f"  claude mcp add --transport http huske {w.connector_url}",
        ]
    return out


def _claude_desktop(w: Wiring) -> list[str]:
    out: list[str] = []
    if w.connector_ready:
        out += [
            "Simplest path — add it as a custom connector (same as the phone):",
            "",
            "  Settings → Connectors → Add custom connector",
            f"  URL: {w.connector_url}",
            "  Sign in with your huske connector passphrase.",
            "",
            "Or keep it on loopback with an stdio bridge:",
            "",
        ]
    else:
        out += [
            "Claude Desktop cannot attach a bearer header to a loopback URL through",
            "the connectors UI, so bridge it to a local stdio server with mcp-remote.",
            "",
            "~/Library/Application Support/Claude/claude_desktop_config.json:",
            "",
        ]
    out += [
        "  {",
        '    "mcpServers": {',
        '      "huske": {',
        '        "command": "npx",',
        '        "args": [',
        f'          "-y", "mcp-remote", "{w.loopback_url}",',
        '          "--allow-http",',
        '          "--header", "Authorization:${HUSKE_MCP_TOKEN}"',
        "        ],",
        '        "env": { "HUSKE_MCP_TOKEN": "Bearer <token>" }',
        "      }",
        "    }",
        "  }",
        "",
        "Write `Authorization:` with no space — Claude Desktop strips spaces in args —",
        "then fully quit and reopen the app. Cowork shares this config.",
    ]
    return out


def _claude_app(w: Wiring) -> list[str]:
    if not w.connector_url:
        return _needs_connector("Claude on iPhone / web")
    return [
        "Claude on iPhone, iPad, and claude.ai reach your transcripts through a",
        "custom connector — one URL, no token to paste, no tunnel to your Mac.",
        "",
        "  Settings → Connectors → Add custom connector",
        f"  URL: {w.connector_url}",
        "",
        "Claude registers itself, opens huske's sign-in page, and you enter your",
        "connector passphrase once. It stays connected across devices.",
        "",
        "Then ask it anything about what was said — or use the built-in prompts:",
        "  /catch_me_up · /what_was_said_about",
    ]


def _chatgpt(w: Wiring) -> list[str]:
    if not w.connector_url:
        return _needs_connector("ChatGPT")
    return [
        "ChatGPT accepts a remote MCP server over HTTPS with OAuth — which is",
        "exactly what connector mode serves.",
        "",
        "  Settings → Connectors → Advanced → Developer mode (Plus and above)",
        "  Settings → Connectors → Create → paste the URL",
        f"  URL: {w.connector_url}",
        "",
        "Authenticate with your connector passphrase when prompted.",
        "",
        "huske exposes `search` and `fetch` in exactly the shape ChatGPT's",
        "connector contract expects, plus `recap` and `overview`.",
    ]


def _codex(w: Wiring) -> list[str]:
    return [
        "~/.codex/config.toml:",
        "",
        "  [mcp_servers.huske]",
        '  url = "' + w.loopback_url + '"',
        "  [mcp_servers.huske.headers]",
        f'  Authorization = "Bearer {w.token_display}"',
    ]


def _cursor(w: Wiring) -> list[str]:
    return [
        "~/.cursor/mcp.json (or .cursor/mcp.json in a project):",
        "",
        "  {",
        '    "mcpServers": {',
        '      "huske": {',
        f'        "url": "{w.loopback_url}",',
        '        "headers": { "Authorization": "Bearer <token>" }',
        "      }",
        "    }",
        "  }",
    ]


def _hermes(w: Wiring) -> list[str]:
    return [
        "An agent running on the same host as the daemon uses loopback directly —",
        "no OAuth, no TLS, nothing exposed. This is the co-located path from",
        "ADR 0004 and it is unchanged by connector mode.",
        "",
        f'  claude mcp add --transport http huske {w.loopback_url} \\',
        '    --header "Authorization: Bearer $(cat ~/.config/huske/mcp_token)"',
        "",
        "For any other agent framework: streamable HTTP, the URL above, and the",
        "token as a bearer header.",
    ]


def _needs_connector(label: str) -> list[str]:
    return [
        f"{label} can only reach a public HTTPS endpoint, so it needs connector",
        "mode. It is off right now.",
        "",
        "Turn it on where your always-on index lives (your VPS if you replicate",
        "there, otherwise this Mac behind a tunnel):",
        "",
        "  1. huske config set mcp_public_url https://huske.example.com/mcp",
        "  2. huske mcp set-password",
        "  3. point a TLS reverse proxy at the daemon (see docs/server.md)",
        "  4. huske mcp",
        "",
        "Then run `huske connect` again — this section will print the URL to paste.",
    ]


_RENDERERS = {
    "claude-code": _claude_code,
    "claude-desktop": _claude_desktop,
    "claude-app": _claude_app,
    "chatgpt": _chatgpt,
    "codex": _codex,
    "cursor": _cursor,
    "hermes": _hermes,
}


# --- rendering ---------------------------------------------------------------


def render_client(client: Client, wiring: Wiring) -> str:
    lines = [f"huske → {client.label}", ""]
    lines += _RENDERERS[client.key](wiring)
    if client.reach == LOCAL and wiring.token is None:
        lines += [
            "",
            f"No token yet at {wiring.token_path} — `huske mcp` writes one on first run.",
        ]
    return "\n".join(lines)


def render_summary(wiring: Wiring) -> str:
    """The overview: what each client would use, and whether it works today."""
    lines = [
        "huske → your LLMs",
        "",
        f"  loopback   {wiring.loopback_url}",
    ]
    if wiring.connector_url:
        state = "ready" if wiring.has_password else "no passphrase set"
        lines.append(f"  connector  {wiring.connector_url}  ({state})")
    else:
        lines.append("  connector  off — set `mcp_public_url` to reach huske from other devices")
    lines += ["", "  client                            reach     status"]

    for client in CLIENTS:
        if client.reach == REMOTE:
            status = "ready" if wiring.connector_ready else "needs connector mode"
        else:
            status = "ready" if wiring.token else "run `huske mcp` once"
        lines.append(f"  {client.label:<33} {client.reach:<9} {status}")

    lines += [
        "",
        "  huske connect <client>   exact steps for one client",
        f"  clients: {', '.join(CLIENT_KEYS)}",
    ]
    if not wiring.connector_ready:
        lines += [
            "",
            "Your Mac sleeps; a connector does not. To query your transcripts from",
            "your phone or a hosted agent, replicate to a server you control and",
            "turn on connector mode there — see docs/integrations.md.",
        ]
    return "\n".join(lines)


def run_connect(client: str | None = None, *, config_path: object = None) -> int:
    """Print wiring for ``client`` (or the summary). Returns an exit code."""
    from pathlib import Path

    from huske.config import load_config

    path = config_path if isinstance(config_path, Path) else None
    try:
        cfg = load_config(config_path=path)
    except ValueError as exc:
        print(f"config: {exc}")
        return 2

    wiring = resolve_wiring(cfg)
    if client is None:
        print(render_summary(wiring))
        return 0

    key = client.strip().lower()
    # Accept the obvious aliases people actually type rather than making them
    # read the key list back.
    key = {
        "claude": "claude-app",
        "claude-ios": "claude-app",
        "claude-mobile": "claude-app",
        "claude-web": "claude-app",
        "desktop": "claude-desktop",
        "cowork": "claude-desktop",
        "code": "claude-code",
        "openai": "chatgpt",
        "gpt": "chatgpt",
        "vps": "hermes",
        "server": "hermes",
    }.get(key, key)

    match = next((c for c in CLIENTS if c.key == key), None)
    if match is None:
        print(f"unknown client: {client!r}\nknown: {', '.join(CLIENT_KEYS)}")
        return 2
    print(render_client(match, wiring))
    return 0
