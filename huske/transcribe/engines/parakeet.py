"""Parakeet (TDT) transcription engine via ``parakeet-mlx``.

Parakeet is a non-autoregressive ASR model. Unlike Whisper it does not invent
repeated filler ("e aí e aí…", "sports sports…") on silence or background
noise — it simply emits nothing — which removes huske's single worst transcript
defect. ``parakeet-tdt-0.6b-v3`` is multilingual (~25 languages, Portuguese
included), fast on Apple-Silicon MLX, and reports a per-sentence confidence we
keep for downstream filtering.

It has one sharp edge: **the language is not an input.** Parakeet infers it
implicitly, once per decode window, from the audio alone, and on speech that
code-switches — Portuguese carrying English technical jargon, say — that
inference is unstable. When it lands on English the model transcribes the whole
window phonetically into English words ("dos três hubs" -> "of the three hubs").
The flip is a knife edge: on real meeting audio, moving a window boundary by
0.2 s flipped two minutes of Portuguese into English. The model's vocabulary
does carry ``<|pt|>``-style language tags inherited from the NeMo/Canary
tokenizer, but the TDT decoder was never trained to condition on them — priming
the prediction network with one provably changes nothing — so there is no way to
pin the language here. ``huske.transcribe.langdrift`` therefore detects a window
that collapsed into English and we re-decode it (see ``_decode_window``); a
caller that needs a *guaranteed* language wants ``asr_engine = "whisper"``,
whose decoder takes a real language token.

We deliberately bypass ``parakeet_mlx``'s own ``transcribe(path)`` because it
shells out to ffmpeg to decode audio. Instead we load 16 kHz mono via
``soundfile`` + ``soxr`` (see ``base.load_mono_16k``), compute the log-mel, and
call ``model.generate`` directly — re-implementing only the long-audio
overlap-and-merge chunking from the upstream ``transcribe`` so memory stays
bounded on multi-minute chunks.
"""

from __future__ import annotations

from typing import TYPE_CHECKING, Any

from huske.transcribe.engines.base import Segment, TranscriptionEngine

if TYPE_CHECKING:
    import numpy as np
    import numpy.typing as npt


#: A drifted window is re-decoded as two halves overlapping by this much, so the
#: split costs no coverage and the halves can be stitched with the same
#: longest-common-subsequence merge used between sliding windows.
_GUARD_SPLIT_OVERLAP_SECONDS = 2.0
#: Never split below this — a window this short carries too little text to score
#: (and too little context to transcribe well).
_GUARD_MIN_WINDOW_SECONDS = 20.0
#: Bounds the extra decodes a pathological window can trigger: depth 2 means one
#: 120 s window costs at most 1 + 2 + 4 = 7 decodes instead of 1.
_GUARD_MAX_DEPTH = 2


def _short_model_name(model_id: str) -> str:
    """``mlx-community/parakeet-tdt-0.6b-v3`` -> ``tdt-0.6b-v3``."""
    tail = model_id.rsplit("/", 1)[-1]
    return tail.removeprefix("parakeet-")


class ParakeetEngine(TranscriptionEngine):
    """Transcribe with a Parakeet model loaded through ``parakeet-mlx``.

    For audio longer than ``chunk_duration`` seconds we slide a window with
    ``overlap_duration`` of overlap and stitch the token streams — the same
    strategy ``parakeet_mlx.transcribe`` uses, so peak Metal memory tracks one
    window rather than the whole chunk.

    ``language`` does not condition the model (it cannot — see the module
    docstring); it is the *expected* language, used only to notice a window that
    collapsed into English and re-decode it.
    """

    def __init__(
        self,
        model_id: str = "mlx-community/parakeet-tdt-0.6b-v3",
        *,
        chunk_duration: float = 120.0,
        overlap_duration: float = 15.0,
        language: str | None = None,
    ) -> None:
        self._model_id = model_id
        self._chunk_duration = chunk_duration
        self._overlap_duration = overlap_duration
        self._language = language
        self.model_label = f"parakeet:{_short_model_name(model_id)}"
        self._model: Any = None

    # -- model lifecycle ----------------------------------------------------

    def _ensure_model(self) -> Any:
        if self._model is None:
            from parakeet_mlx import from_pretrained

            self._model = from_pretrained(self._model_id)
        return self._model

    def unload(self) -> None:
        self._model = None
        try:
            import mlx.core as mx

            mx.clear_cache()
        except Exception:
            pass

    # -- transcription ------------------------------------------------------

    def transcribe(self, audio_np: npt.NDArray[np.float32]) -> list[Segment]:
        import numpy as np
        from parakeet_mlx.alignment import sentences_to_result, tokens_to_sentences
        from parakeet_mlx.parakeet import DecodingConfig

        if audio_np.size == 0:
            return []
        model = self._ensure_model()
        sr = int(model.preprocessor_config.sample_rate)
        audio_np = np.ascontiguousarray(audio_np, dtype=np.float32)

        length_seconds = audio_np.shape[0] / float(sr)
        if length_seconds <= self._chunk_duration:
            decoding = DecodingConfig()
            tokens = self._decode_window(model, audio_np, 0, audio_np.shape[0], sr, decoding)
            result = sentences_to_result(tokens_to_sentences(tokens, decoding.sentence))
        else:
            result = self._transcribe_chunked(model, audio_np, sr)

        return _result_to_segments(result)

    # -- windowed decoding --------------------------------------------------

    def _decode_window(
        self,
        model: Any,
        audio_np: npt.NDArray[np.float32],
        start: int,
        end: int,
        sr: int,
        decoding: Any,
        depth: int = 0,
    ) -> list[Any]:
        """Decode ``audio[start:end]`` into absolutely-timed tokens.

        If the window came back in the wrong language (see the module docstring —
        Parakeet decides that per window and can get it wrong on code-switched
        speech), split it into two overlapping halves and decode each. Each half
        is an independent inference, so it re-rolls the language decision on a
        smaller span; the halves overlap, so nothing is dropped. Recursion is
        bounded by ``_GUARD_MAX_DEPTH`` / ``_GUARD_MIN_WINDOW_SECONDS``, and a
        window that is fine — the overwhelming majority — costs one decode, as
        before.
        """
        import mlx.core as mx
        from parakeet_mlx.audio import get_logmel

        from huske.transcribe import langdrift

        # Convert only this window — a 30 min mx.array of the whole chunk
        # would pin ~115 MB of Metal on top of the weights.
        mel = get_logmel(mx.array(audio_np[start:end]), model.preprocessor_config)
        result = model.generate(mel, decoding_config=decoding)[0]

        offset = start / float(sr)
        for sentence in result.sentences:
            for token in sentence.tokens:
                token.start += offset
                token.end = token.start + token.duration
        tokens: list[Any] = result.tokens

        splittable = (
            depth < _GUARD_MAX_DEPTH
            and (end - start) >= 2 * int(_GUARD_MIN_WINDOW_SECONDS * sr)
        )
        if not splittable or not langdrift.drifted(result.text, self._language):
            return tokens

        overlap = int(_GUARD_SPLIT_OVERLAP_SECONDS * sr)
        mid = start + (end - start) // 2
        first = self._decode_window(
            model, audio_np, start, min(mid + overlap, end), sr, decoding, depth + 1
        )
        second = self._decode_window(
            model, audio_np, max(mid - overlap, start), end, sr, decoding, depth + 1
        )
        merged = _merge_tokens(first, second, _GUARD_SPLIT_OVERLAP_SECONDS)
        # Only keep the re-decode if it actually recovered the language; a split
        # that drifted just as badly would trade a coherent window for a seam.
        retry_text = "".join(t.text for t in merged)
        if langdrift.drifted(retry_text, self._language) and not langdrift.drifted(
            result.text, self._language
        ):
            return tokens
        return merged

    def _transcribe_chunked(
        self, model: Any, audio_np: npt.NDArray[np.float32], sr: int
    ) -> Any:
        """Sliding-window transcription with token-stream merging (long audio)."""
        from parakeet_mlx.alignment import sentences_to_result, tokens_to_sentences
        from parakeet_mlx.parakeet import DecodingConfig

        cfg = model.preprocessor_config
        chunk_samples = int(self._chunk_duration * sr)
        overlap_samples = int(self._overlap_duration * sr)
        stride = max(1, chunk_samples - overlap_samples)
        hop = int(cfg.hop_length)
        decoding = DecodingConfig()

        all_tokens: list[Any] = []
        n = audio_np.shape[0]
        for start in range(0, n, stride):
            end = min(start + chunk_samples, n)
            if end - start < hop:  # too short to form a single mel frame
                break
            tokens = self._decode_window(model, audio_np, start, end, sr, decoding)
            if all_tokens:
                all_tokens = _merge_tokens(all_tokens, tokens, self._overlap_duration)
            else:
                all_tokens = tokens

        return sentences_to_result(tokens_to_sentences(all_tokens, decoding.sentence))


def _merge_tokens(a: list[Any], b: list[Any], overlap_duration: float) -> list[Any]:
    """Stitch two overlapping, absolutely-timed token streams (upstream's rule)."""
    from parakeet_mlx.alignment import (
        merge_longest_common_subsequence,
        merge_longest_contiguous,
    )

    if not a:
        return b
    if not b:
        return a
    merged: list[Any]
    try:
        merged = merge_longest_contiguous(a, b, overlap_duration=overlap_duration)
    except RuntimeError:
        merged = merge_longest_common_subsequence(a, b, overlap_duration=overlap_duration)
    return merged


def _result_to_segments(result: Any) -> list[Segment]:
    """Flatten an ``AlignedResult`` into non-empty, time-ordered ``Segment``s."""
    segments: list[Segment] = []
    for sentence in getattr(result, "sentences", None) or []:
        text = (getattr(sentence, "text", "") or "").strip()
        if not text:
            continue
        start = float(getattr(sentence, "start", 0.0) or 0.0)
        end = float(getattr(sentence, "end", start) or start)
        conf = getattr(sentence, "confidence", None)
        segments.append(
            Segment(
                start=start,
                end=max(end, start),
                text=text,
                confidence=float(conf) if conf is not None else None,
            )
        )
    segments.sort(key=lambda s: s.start)
    return segments
