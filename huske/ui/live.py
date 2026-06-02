"""Rich Live status panel for `huske run`.

Renders a non-scrolling layout (header / main / footer) at ~8 Hz from a
shared RenderState. The render thread is owned by Rich's Live; we just
update the state, and Rich's auto_refresh polls it.
"""

from __future__ import annotations

import threading
from datetime import datetime
from types import TracebackType

from rich.align import Align
from rich.console import Group, RenderableType
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
    cells = round(pct * width)
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
    if state.paused:
        indicator = Text("|| PAUSED", style="bold yellow")
    elif state.recording:
        indicator = Text("● RECORDING", style="bold red")
    else:
        indicator = Text("○ idle", style="dim")
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
    if state.screenshots_enabled:
        screenshot_text = f"on ({state.screenshots_count} captured"
        if state.last_screenshot_at is not None:
            screenshot_text += f", last {state.last_screenshot_at.strftime('%H:%M:%S')}"
        screenshot_text += ")"
        screenshot_status = Text(screenshot_text, style="cyan")
    else:
        screenshot_status = Text("off", style="dim")
    main_table.add_row(Text("screenshots", style="dim"), screenshot_status)
    last_saved = (
        Text(str(state.last_saved), style="green")
        if state.last_saved
        else Text("(none yet)", style="dim")
    )
    main_table.add_row(Text("last saved", style="dim"), last_saved)

    warnings_block: list[Text] = []
    for _key, msg in state.warnings.items():
        warnings_block.append(Text(f"⚠  {msg}", style="yellow"))

    parts: list[RenderableType] = [main_table]
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

    parts: list[RenderableType] = [main_table, *hints]
    if warnings_block:
        parts.append(Text(""))
        parts.extend(warnings_block)

    return Panel(
        Group(*parts), title="stopping", border_style="yellow", padding=(1, 2)
    )


def _render_help() -> Panel:
    table = Table.grid(padding=(0, 2))
    table.add_column(justify="left", no_wrap=True, style="bold cyan")
    table.add_column(justify="left")
    table.add_row("p", "pause or resume audio recording")
    table.add_row("s", "toggle periodic screenshots")
    table.add_row("i", "choose microphone input device")
    table.add_row("?", "show or hide this help")
    table.add_row("q", "graceful stop")
    table.add_row("Esc", "close controls")
    table.add_row("Ctrl+C", "graceful stop")
    return Panel(table, title="controls", border_style="cyan", padding=(1, 2))


def _render_input_picker(state: RenderState) -> Panel:
    table = Table.grid(padding=(0, 2))
    table.add_column(justify="left", no_wrap=True)
    table.add_column(justify="left")
    if not state.picker_devices:
        table.add_row(Text(""), Text("no input devices found", style="yellow"))
    for i, (dev_index, dev_name) in enumerate(state.picker_devices):
        is_cursor = i == state.picker_cursor
        is_current = dev_index == state.picker_current_index
        marker = "▶" if is_cursor else " "
        suffix = " (current)" if is_current else ""
        if is_cursor:
            row_style = "bold cyan"
        elif is_current:
            row_style = "green"
        else:
            row_style = "white"
        table.add_row(
            Text(marker, style="bold cyan"),
            Text(f"{dev_name}{suffix}", style=row_style),
        )

    hint = Text(
        "j/k or ↓/↑ move   Enter switch   Esc cancel",
        style="dim",
    )
    note = Text(
        "Tip: Bluetooth headsets (AirPods) drop output quality when used as mic.",
        style="yellow",
    )
    return Panel(
        Group(table, Text(""), hint, note),
        title="microphone input",
        border_style="cyan",
        padding=(1, 2),
    )


def _render(state: RenderState) -> Layout:
    layout = Layout()
    layout.split_column(
        Layout(name="header", size=3),
        Layout(name="main"),
        Layout(name="footer", size=9),
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
    if state.picker_visible and not state.stopping:
        layout["main"].update(_render_input_picker(state))
    elif state.help_visible and not state.stopping:
        layout["main"].update(_render_help())
    elif state.stopping:
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
    keys = Text("? controls | Ctrl+C stop", style="dim")
    layout["footer"].update(
        Panel(Group(events_table, Text(""), keys), title="events", border_style="dim")
    )

    return layout


class LiveUI:
    """Wraps Rich Live + a tick loop. Use as a context manager."""

    def __init__(self, state: RenderState, refresh_per_second: int = 8) -> None:
        self._state = state
        self._live: Live | None = None
        self._refresh = refresh_per_second
        self._stop = threading.Event()

    def __enter__(self) -> LiveUI:
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

    def __exit__(
        self,
        exc_type: type[BaseException] | None,
        exc: BaseException | None,
        tb: TracebackType | None,
    ) -> None:
        if self._live is not None:
            self._live.__exit__(exc_type, exc, tb)
            self._live = None
