"""Parakeet (TDT) transcription engine via ``parakeet-mlx``.

Parakeet is a non-autoregressive ASR model. Unlike Whisper it does not invent
repeated filler ("e aí e aí…", "sports sports…") on silence or background
noise — it simply emits nothing — which removes huske's single worst transcript
defect. ``parakeet-tdt-0.6b-v3`` is multilingual (auto-detects across ~25
languages, Portuguese included), fast on Apple-Silicon MLX, and reports a
per-sentence confidence we keep for downstream filtering.

We deliberately bypass ``parakeet_mlx``'s own ``transcribe(path)`` because it
shells out to ffmpeg to decode audio. Instead we load 16 kHz mono via
``soundfile`` + ``soxr`` (see ``base.load_mono_16k``), compute the log-mel, and
call ``model.generate`` directly — re-implementing only the long-audio
overlap-and-merge chunking from the upstream ``transcribe`` so memory stays
bounded on multi-minute chunks.
"""

from __future__ import annotations

from typing import TYPE_CHECKING, Any

from huske.transcribe.engines.base import Segment, TranscriptionEngine, load_mono_16k

if TYPE_CHECKING:
    import mlx.core as mx


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
    """

    def __init__(
        self,
        model_id: str = "mlx-community/parakeet-tdt-0.6b-v3",
        *,
        chunk_duration: float = 120.0,
        overlap_duration: float = 15.0,
    ) -> None:
        self._model_id = model_id
        self._chunk_duration = chunk_duration
        self._overlap_duration = overlap_duration
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

    def transcribe(self, wav_path: str) -> list[Segment]:
        import mlx.core as mx
        from parakeet_mlx.audio import get_logmel

        model = self._ensure_model()
        audio_np = load_mono_16k(wav_path)
        if audio_np.size == 0:
            return []
        sr = int(model.preprocessor_config.sample_rate)
        audio = mx.array(audio_np)

        length_seconds = audio_np.shape[0] / float(sr)
        if length_seconds <= self._chunk_duration:
            mel = get_logmel(audio, model.preprocessor_config)
            result = model.generate(mel)[0]
        else:
            result = self._transcribe_chunked(model, audio, sr)

        return _result_to_segments(result)

    def _transcribe_chunked(self, model: Any, audio: mx.array, sr: int) -> Any:
        """Sliding-window transcription with token-stream merging (long audio)."""
        from parakeet_mlx.alignment import (
            merge_longest_common_subsequence,
            merge_longest_contiguous,
            sentences_to_result,
            tokens_to_sentences,
        )
        from parakeet_mlx.audio import get_logmel
        from parakeet_mlx.parakeet import DecodingConfig

        cfg = model.preprocessor_config
        chunk_samples = int(self._chunk_duration * sr)
        overlap_samples = int(self._overlap_duration * sr)
        stride = max(1, chunk_samples - overlap_samples)
        hop = int(cfg.hop_length)
        decoding = DecodingConfig()

        all_tokens: list[Any] = []
        n = audio.shape[0]
        for start in range(0, n, stride):
            end = min(start + chunk_samples, n)
            if end - start < hop:  # too short to form a single mel frame
                break
            mel = get_logmel(audio[start:end], cfg)
            chunk_result = model.generate(mel, decoding_config=decoding)[0]

            offset = start / float(sr)
            for sentence in chunk_result.sentences:
                for token in sentence.tokens:
                    token.start += offset
                    token.end = token.start + token.duration

            if all_tokens:
                try:
                    all_tokens = merge_longest_contiguous(
                        all_tokens, chunk_result.tokens, overlap_duration=self._overlap_duration
                    )
                except RuntimeError:
                    all_tokens = merge_longest_common_subsequence(
                        all_tokens, chunk_result.tokens, overlap_duration=self._overlap_duration
                    )
            else:
                all_tokens = chunk_result.tokens

        return sentences_to_result(tokens_to_sentences(all_tokens, decoding.sentence))


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
