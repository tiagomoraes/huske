"""Tests for the internal command channel."""

from __future__ import annotations

import threading

from huske.control import Command, CommandChannel


def test_drain_returns_commands_in_send_order() -> None:
    ch = CommandChannel()
    ch.send(Command.PAUSE_RESUME)
    ch.send(Command.TOGGLE_SCREENSHOTS)
    ch.send(Command.STOP)

    assert ch.drain() == [
        (Command.PAUSE_RESUME, None),
        (Command.TOGGLE_SCREENSHOTS, None),
        (Command.STOP, None),
    ]


def test_send_carries_an_argument() -> None:
    ch = CommandChannel()
    ch.send(Command.SET_INPUT_DEVICE, "MacBook Pro Microphone")
    ch.send(Command.SET_INPUT_DEVICE, 3)

    assert ch.drain() == [
        (Command.SET_INPUT_DEVICE, "MacBook Pro Microphone"),
        (Command.SET_INPUT_DEVICE, 3),
    ]


def test_drain_on_empty_channel_returns_empty_list() -> None:
    assert CommandChannel().drain() == []


def test_drain_empties_the_channel() -> None:
    ch = CommandChannel()
    ch.send(Command.STOP)
    ch.drain()
    assert ch.drain() == []


def test_concurrent_producers_do_not_lose_commands() -> None:
    ch = CommandChannel()
    n_threads = 8
    per_thread = 50

    def produce() -> None:
        for _ in range(per_thread):
            ch.send(Command.PAUSE_RESUME)

    threads = [threading.Thread(target=produce) for _ in range(n_threads)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    drained = ch.drain()
    assert len(drained) == n_threads * per_thread
    assert all(c == (Command.PAUSE_RESUME, None) for c in drained)
