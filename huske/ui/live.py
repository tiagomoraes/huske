"""Rich Live status panel for `huske run`.

Renders a non-scrolling layout (header / main / footer) at ~8 Hz from a
shared RenderState. The render thread is owned by Rich's Live; we just
update the state, and Rich's auto_refresh polls it.
"""

from __future__ import annotations

import threading
from datetime import datetime

from rich.align import Align
from rich.console import Group
from rich.layout import Layout
from rich.live import Live
from rich.panel import Panel
from rich.table import Table
from rich.text import Text

from huske import __version__
from huske.models import RenderState


def _fmt_duration(seconds: float) -> str:
    seconds = max(0.0, seconds)
    m, s = divmod(int(seconds), 60)
    h, m = divmod(m, 60)
    if h:
        return f"{h:d}:{m:02d}:{s:02d}"
    return f"{m:02d}:{s:02d}"


def _level_bar(db: float, width: int = 24) -> Text:
    # -60 dB → 0 cells, 0 dB → full.
    pct = max(0.0, min(1.0, (db + 60.0) / 60.0))
    cells = int(round(pct * width))
    bar = "█" * cells + "░" * (width - cells)
    if db > -6:
        color = "red"
    elif db > -18:
        color = "yellow"
    else:
        color = "green"
    return Text(bar, style=color)


def _render_running(state: RenderState) -> Panel:
    now = datetime.now().astimezone()
    elapsed = (
        (now - state.chunk_started_at).total_seconds()
        if state.chunk_started_at
        else 0.0
    )
    countdown = (
        (state.next_rotation_at - now).total_seconds()
        if state.next_rotation_at
        else 0.0
    )
    indicator = (
        Text("● RECORDING", style="bold red")
        if state.recording
        else Text("○ idle", style="dim")
    )
    main_table = Table.grid(padding=(0, 2))
    main_table.add_column(justify="left", no_wrap=True)
    main_table.add_column(justify="left")
    main_table.add_row(indicator, Text(""))
    main_table.add_row(
        Text(f"chunk {state.current_chunk_seq:03d}", style="bold"),
        Text(
            f"{_fmt_duration(elapsed)} / {_fmt_duration(elapsed + max(0, countdown))}",
            style="white",
        ),
    )
    main_table.add_row(
        Text("next rotation", style="dim"),
        Text(f"in {_fmt_duration(countdown)}", style="white"),
    )

    if len(state.peak_levels) >= 1:
        main_table.add_row(
            Text("mic level", style="dim"),
            Text.assemble(
                _level_bar(state.peak_levels[0]),
                Text(f"  {state.peak_levels[0]:6.1f} dB", style="dim"),
            ),
        )
    if len(state.peak_levels) >= 2:
        main_table.add_row(
            Text("sys level", style="dim"),
            Text.assemble(
                _level_bar(state.peak_levels[1]),
                Text(f"  {state.peak_levels[1]:6.1f} dB", style="dim"),
            ),
        )

    main_table.add_row(
        Text("queue", style="dim"),
        Text(f"{state.queue_depth} transcription(s) pending", style="white"),
    )
    last_saved = (
        Text(str(state.last_saved), style="green")
        if state.last_saved
        else Text("(none yet)", style="dim")
    )
    main_table.add_row(Text("last saved", style="dim"), last_saved)

    warnings_block: list[Text] = []
    for _key, msg in state.warnings.items():
        warnings_block.append(Text(f"⚠  {msg}", style="yellow"))

    parts: list[object] = [main_table]
    if warnings_block:
        parts.append(Text(""))
        parts.extend(warnings_block)

    return Panel(Group(*parts), title="status", border_style="white", padding=(1, 2))


def _render_stopping(state: RenderState) -> Panel:
    indicator = Text("◐ STOPPING", style="bold yellow")
    if state.queue_depth > 0:
        sub = Text(
            f"transcribing {state.queue_depth} chunk(s)…", style="yellow"
        )
    else:
        sub = Text("finalizing…", style="yellow")

    main_table = Table.grid(padding=(0, 2))
    main_table.add_column(justify="left", no_wrap=True)
    main_table.add_column(justify="left")
    main_table.add_row(indicator, sub)
    main_table.add_row(
        Text("queue", style="dim"),
        Text(f"{state.queue_depth} pending", style="yellow"),
    )
    last_saved = (
        Text(str(state.last_saved), style="green")
        if state.last_saved
        else Text("(none yet)", style="dim")
    )
    main_table.add_row(Text("last saved", style="dim"), last_saved)

    hints = [
        Text(""),
        Text(
            "Wait for drain to finish — Ctrl+C again has no effect.",
            style="dim",
        ),
        Text(
            "If you must kill: `kill -9` then `huske recover` reclaims orphans.",
            style="dim",
        ),
    ]

    warnings_block: list[Text] = []
    for _key, msg in state.warnings.items():
        warnings_block.append(Text(f"⚠  {msg}", style="yellow"))

    parts: list[object] = [main_table, *hints]
    if warnings_block:
        parts.append(Text(""))
        parts.extend(warnings_block)

    return Panel(
        Group(*parts), title="stopping", border_style="yellow", padding=(1, 2)
    )


def _render(state: RenderState) -> Layout:
    layout = Layout()
    layout.split_column(
        Layout(name="header", size=3),
        Layout(name="main"),
        Layout(name="footer", size=8),
    )

    # Header.
    header_text = Text()
    header_text.append("huske ", style="bold cyan")
    header_text.append(f"{__version__}  ", style="cyan")
    header_text.append(f"session {state.session_id[-12:]}  ", style="dim")
    header_text.append(
        f"→ {state.output_root}" if state.output_root else "",
        style="dim",
    )
    layout["header"].update(Panel(Align.left(header_text), border_style="cyan"))

    # Main.
    if state.stopping:
        layout["main"].update(_render_stopping(state))
    else:
        layout["main"].update(_render_running(state))

    # Footer — events.
    events_table = Table.grid(padding=(0, 1))
    events_table.add_column(no_wrap=True, style="dim")
    events_table.add_column(no_wrap=True)
    events_table.add_column()
    color_for = {"info": "white", "warn": "yellow", "error": "red"}
    for ev in list(state.events)[-5:]:
        ts = ev.timestamp.strftime("%H:%M:%S")
        sev = Text(ev.severity.upper().ljust(5), style=color_for.get(ev.severity, "white"))
        msg = Text(ev.message, style=color_for.get(ev.severity, "white"))
        events_table.add_row(Text(ts), sev, msg)
    layout["footer"].update(Panel(events_table, title="events", border_style="dim"))

    return layout


class LiveUI:
    """Wraps Rich Live + a tick loop. Use as a context manager."""

    def __init__(self, state: RenderState, refresh_per_second: int = 8) -> None:
        self._state = state
        self._live: Live | None = None
        self._refresh = refresh_per_second
        self._stop = threading.Event()

    def __enter__(self) -> "LiveUI":
        self._live = Live(
            _render(self._state),
            refresh_per_second=self._refresh,
            screen=False,
            transient=False,
        )
        self._live.__enter__()
        return self

    def update(self) -> None:
        if self._live is None:
            return
        self._live.update(_render(self._state))

    def __exit__(self, *exc_info: object) -> None:
        if self._live is not None:
            self._live.__exit__(*exc_info)
            self._live = None
