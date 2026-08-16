"""MetalGate serialization and footprint helpers."""

from __future__ import annotations

import threading
import time

from huske.mlx_runtime import GatedDistiller, MetalGate, rss_mb


def test_asr_waits_while_llm_holds() -> None:
    gate = MetalGate()
    gate.acquire_llm()
    assert gate.try_begin_asr(True) is False
    assert gate.llm_held is True
    gate.release_llm()
    assert gate.try_begin_asr(True) is True
    assert gate.asr_inflight == 1
    gate.finish_asr()
    assert gate.asr_inflight == 0


def test_llm_waits_for_asr_then_runs() -> None:
    gate = MetalGate()
    assert gate.try_begin_asr(True) is True
    started = threading.Event()
    done = threading.Event()

    def _llm() -> None:
        started.set()
        gate.acquire_llm()
        done.set()
        gate.release_llm()

    thread = threading.Thread(target=_llm)
    thread.start()
    assert started.wait(1.0)
    time.sleep(0.05)
    assert done.is_set() is False
    gate.finish_asr()
    assert done.wait(1.0)
    thread.join(timeout=1.0)


def test_waiting_asr_preempts_next_llm_passage() -> None:
    gate = MetalGate()
    gate.acquire_llm()
    assert gate.try_begin_asr(True) is False  # records the waiter
    started = threading.Event()
    acquired = threading.Event()

    def _next_passage() -> None:
        started.set()
        gate.acquire_llm()
        acquired.set()
        gate.release_llm()

    thread = threading.Thread(target=_next_passage)
    thread.start()
    assert started.wait(1.0)
    gate.release_llm()
    # ASR waiter is preferred over the next LLM passage.
    time.sleep(0.05)
    assert acquired.is_set() is False
    assert gate.try_begin_asr(True) is True
    gate.finish_asr()
    assert acquired.wait(1.0)
    thread.join(timeout=1.0)


def test_gated_distiller_releases_on_error() -> None:
    gate = MetalGate()

    class Boom:
        model_id = "x"
        backend = "fake"

        def distill_passage(self, text: str, *, sources: list[str], language: str) -> list[str]:
            raise RuntimeError("nope")

    wrapped = GatedDistiller(Boom(), gate)  # type: ignore[arg-type]
    try:
        wrapped.distill_passage("hi", sources=["mic"], language="en")
    except RuntimeError:
        pass
    assert gate.llm_held is False
    assert gate.try_begin_asr(True) is True
    gate.finish_asr()


def test_rss_mb_of_self_is_nonnegative() -> None:
    assert rss_mb() >= 0.0
