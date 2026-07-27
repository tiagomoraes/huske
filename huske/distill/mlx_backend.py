"""Built-in MLX distillation backend — huske's own local LLM, no daemon.

Distillation used to require a separately installed Ollama daemon. This
backend removes that: the model is a Hugging Face repo loaded with ``mlx-lm``
on the same MLX/Metal stack as transcription, downloaded automatically on
first use exactly like the Parakeet weights. Nothing to install, start, or
babysit.

Isolation rule (ADR 0003/0005): model load and token generation hold the GIL,
and the :class:`~huske.distill.worker.DistillWorker` is a *thread* inside
``huske run`` — so the LLM runs in a private **spawn subprocess**, and the
worker thread blocks on a pipe read (GIL-releasing) just as it used to block
on Ollama's HTTP socket. The audio drainer never stalls.

Footprint rule: the child drops the model after ``_IDLE_UNLOAD_SECONDS``
without work and reloads from the local HF cache on the next passage — same
trade as the transcribe worker's idle unload (huske idles far more than it
distills).

Tests set ``HUSKE_DISTILL_MLX_FAKE=1`` to exercise the subprocess protocol
without model weights.
"""

from __future__ import annotations

import multiprocessing as mp
import os
import re
from multiprocessing.connection import Connection
from typing import Any

from huske.distill.client import DistillError
from huske.distill.distiller import build_prompt, parse_statements

DEFAULT_MLX_MODEL = "mlx-community/Qwen3.5-0.8B-4bit"

_FAKE_ENV = "HUSKE_DISTILL_MLX_FAKE"
_IDLE_UNLOAD_SECONDS = 120.0
_THINK_RE = re.compile(r"<think>.*?</think>", re.DOTALL)
_JSON_RE = re.compile(r"\{.*\}", re.DOTALL)

# Configs written for the old Ollama-only default keep working: the known
# tags map onto the equivalent 4-bit MLX community builds.
_OLLAMA_TAG_TO_MLX = {
    "qwen3.5:0.8b": "mlx-community/Qwen3.5-0.8B-4bit",
    "qwen3.5:0.8b-mlx": "mlx-community/Qwen3.5-0.8B-4bit",
    "qwen3.5:2b": "mlx-community/Qwen3.5-2B-4bit",
    "qwen3.5:2b-mlx": "mlx-community/Qwen3.5-2B-4bit",
    "qwen3.5:4b": "mlx-community/Qwen3.5-4B-4bit",
}


def resolve_mlx_model(model: str) -> str:
    """HF repo id for ``model``: repos pass through, known Ollama tags map."""
    if "/" in model:
        return model
    return _OLLAMA_TAG_TO_MLX.get(model.lower(), model)


def mlx_runtime_available() -> bool:
    """True when the ``mlx-lm`` runtime is importable (Apple Silicon installs)."""
    try:
        from importlib.util import find_spec

        return find_spec("mlx_lm") is not None
    except (ImportError, ValueError):
        return False


def model_is_cached(repo: str) -> bool:
    """True when the model is already in the local HF cache (no download)."""
    try:
        from huggingface_hub import snapshot_download

        snapshot_download(repo, local_files_only=True)
        return True
    except Exception:
        return False


def _clean_reply(raw: str) -> str:
    """Strip thinking blocks and markdown fences; isolate the JSON object."""
    text = _THINK_RE.sub("", raw).strip()
    if text.startswith("```"):
        text = text.strip("`").strip()
        if text.lower().startswith("json"):
            text = text[4:].strip()
    match = _JSON_RE.search(text)
    return match.group(0) if match else text


def _child_main(conn: Connection, model_id: str) -> None:  # pragma: no cover — subprocess
    """LLM loop: recv prompt → generate → send reply. ``None`` stops it."""
    try:
        from huske.proctitle import set_process_title

        set_process_title("huske-distill-llm")
    except Exception:
        pass

    fake = bool(os.environ.get(_FAKE_ENV))
    model: Any = None
    tokenizer: Any = None

    while True:
        # Idle unload: free the resident weights after a quiet stretch; the
        # next passage pays a local-cache reload (a few seconds, no network).
        if model is not None and not conn.poll(_IDLE_UNLOAD_SECONDS):
            model = None
            tokenizer = None
            try:
                import mlx.core as mx

                mx.clear_cache()
            except Exception:
                pass
            continue
        try:
            msg = conn.recv()
        except (EOFError, OSError):
            return
        if msg is None:
            return
        prompt = str(msg.get("prompt", ""))
        try:
            if fake:
                raw = '{"statements": ["fake statement"]}'
            else:
                from mlx_lm import generate, load

                if model is None:
                    # `load` is typed as returning (model, tokenizer) *or*
                    # (model, tokenizer, config) depending on `return_config`,
                    # and it is not overloaded — so a two-value unpack cannot be
                    # narrowed and mypy rejects it. We never pass
                    # `return_config`, so the pair is what comes back; index
                    # instead of unpacking to stay correct for either arity.
                    loaded = load(model_id)
                    model, tokenizer = loaded[0], loaded[1]
                chat = [{"role": "user", "content": prompt}]
                try:
                    templated = tokenizer.apply_chat_template(
                        chat, add_generation_prompt=True, tokenize=False,
                        enable_thinking=False,
                    )
                except TypeError:
                    templated = tokenizer.apply_chat_template(
                        chat, add_generation_prompt=True, tokenize=False
                    )
                kwargs: dict[str, Any] = {"max_tokens": 512}
                try:
                    from mlx_lm.sample_utils import make_sampler

                    kwargs["sampler"] = make_sampler(temp=0.0)
                except Exception:
                    pass
                raw = generate(model, tokenizer, prompt=templated, **kwargs)
            conn.send({"ok": True, "raw": raw})
        except Exception as exc:
            conn.send({"ok": False, "error": f"{type(exc).__name__}: {exc}"})


class MLXDistiller:
    """Drop-in :class:`~huske.distill.distiller.Distiller` backed by mlx-lm."""

    def __init__(self, model: str, *, max_statements: int = 8, timeout: float = 120.0) -> None:
        self.model_id = resolve_mlx_model(model)
        self.backend = "mlx"
        self._max = max_statements
        self._timeout = timeout
        self._ctx = mp.get_context("spawn")
        self._proc: Any = None
        self._conn: Connection | None = None
        self._warmed = False

    def distill_passage(self, text: str, *, sources: list[str], language: str) -> list[str]:
        prompt = build_prompt(
            text, sources=sources, language=language, max_statements=self._max
        )
        self._ensure_process()
        assert self._conn is not None

        deadline = self._timeout
        if not self._warmed and not os.environ.get(_FAKE_ENV):
            # First call may download the weights from HF and load them onto
            # the GPU; give it real room instead of failing a fresh install.
            deadline = max(self._timeout, 900.0 if not model_is_cached(self.model_id) else 240.0)

        try:
            self._conn.send({"prompt": prompt})
            if not self._conn.poll(deadline):
                self._terminate()
                raise DistillError(
                    f"built-in model {self.model_id!r} timed out after {deadline:.0f}s "
                    "(the first run downloads and loads the model)"
                )
            reply = self._conn.recv()
        except DistillError:
            raise
        except (BrokenPipeError, EOFError, OSError) as exc:
            self._terminate()
            raise DistillError(f"built-in LLM process died: {exc}") from exc

        self._warmed = True
        if not reply.get("ok"):
            raise DistillError(str(reply.get("error", "unknown built-in LLM error")))
        return parse_statements(_clean_reply(str(reply.get("raw", ""))), self._max)

    def close(self) -> None:
        """Stop the LLM subprocess. Idempotent."""
        conn, proc = self._conn, self._proc
        self._conn = None
        self._proc = None
        if conn is not None:
            try:
                conn.send(None)
            except (BrokenPipeError, OSError):
                pass
            try:
                conn.close()
            except OSError:
                pass
        if proc is not None:
            proc.join(timeout=5.0)
            if proc.is_alive():
                proc.terminate()
                proc.join(timeout=2.0)

    # ------------------------------------------------------------------

    def _ensure_process(self) -> None:
        if self._proc is not None and self._proc.is_alive():
            return
        parent_conn, child_conn = self._ctx.Pipe()
        proc = self._ctx.Process(
            target=_child_main,
            args=(child_conn, self.model_id),
            name="huske-distill-llm",
            daemon=True,
        )
        proc.start()
        child_conn.close()
        self._proc = proc
        self._conn = parent_conn
        self._warmed = False

    def _terminate(self) -> None:
        conn, proc = self._conn, self._proc
        self._conn = None
        self._proc = None
        if conn is not None:
            try:
                conn.close()
            except OSError:
                pass
        if proc is not None and proc.is_alive():
            proc.terminate()
            proc.join(timeout=2.0)
