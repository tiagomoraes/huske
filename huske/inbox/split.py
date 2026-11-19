"""Split a decoded recording into ≤ ``chunk_minutes`` pieces at quiet points.

Each piece becomes one ASR job and one transcript, exactly like a live chunk.
A cut is placed at the quietest moment of the last stretch before each
``chunk_minutes`` boundary (smoothed over ~0.5 s so it lands in a pause, not
between two syllables), never past the boundary, so a piece is never longer
than a live chunk can be and words are not split.

Everything streams: one pass computes a tiny energy envelope (one value per
100 ms), a second copies sample ranges into per-piece WAVs.
"""

from __future__ import annotations

import math
import threading
from dataclasses import dataclass
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    import numpy as np
    import numpy.typing as npt

FRAME_SECONDS = 0.1
_BLOCK_FRAMES = 65_536
# How far before each boundary to look for a pause: a minute, or a quarter of
# the piece length for very short `chunk_minutes`.
_MAX_SEARCH_SECONDS = 60.0
_SMOOTH_SECONDS = 0.5


class SplitCancelled(RuntimeError):
    """``cancel`` was set while splitting."""


@dataclass(frozen=True, slots=True)
class Piece:
    seq: int  # 1-based
    start_frame: int  # inclusive sample index in the decoded WAV
    end_frame: int  # exclusive
    sample_rate: int

    @property
    def offset_seconds(self) -> float:
        return self.start_frame / self.sample_rate

    @property
    def duration_seconds(self) -> float:
        return (self.end_frame - self.start_frame) / self.sample_rate


def frame_energies(
    wav: Path,
    *,
    frame_seconds: float = FRAME_SECONDS,
    cancel: threading.Event | None = None,
) -> tuple[npt.NDArray[np.float64], int, int]:
    """Mean-square energy per ``frame_seconds`` frame of a mono WAV.

    Returns ``(energies, sample_rate, total_frames)``. The trailing partial
    frame, if any, is included.
    """
    import numpy as np
    import soundfile as sf

    with sf.SoundFile(str(wav)) as handle:
        sr = int(handle.samplerate)
        total = int(handle.frames)
        hop = max(1, round(sr * frame_seconds))
        block_frames = max(hop, (_BLOCK_FRAMES // hop) * hop)
        energies: list[npt.NDArray[np.float64]] = []
        carry = np.zeros(0, dtype=np.float32)
        while True:
            if cancel is not None and cancel.is_set():
                raise SplitCancelled(str(wav))
            block = handle.read(block_frames, dtype="float32", always_2d=True)
            if len(block) == 0:
                break
            mono = block.mean(axis=1) if block.shape[1] > 1 else block[:, 0]
            data = np.concatenate([carry, mono]) if carry.size else mono
            whole = (len(data) // hop) * hop
            if whole:
                frames = data[:whole].astype(np.float64).reshape(-1, hop)
                energies.append(np.mean(frames * frames, axis=1))
            carry = data[whole:]
        if carry.size:
            tail = carry.astype(np.float64)
            energies.append(np.array([float(np.mean(tail * tail))]))
    if not energies:
        return np.zeros(0, dtype=np.float64), sr, total
    return np.concatenate(energies), sr, total


def plan_pieces(
    energies: npt.NDArray[np.float64],
    *,
    sample_rate: int,
    total_frames: int,
    max_seconds: float,
    frame_seconds: float = FRAME_SECONDS,
    search_seconds: float | None = None,
) -> list[Piece]:
    """Choose piece boundaries. Pure, so it is unit-testable on synthetic data.

    Every piece is at most ``max_seconds`` long (to the sample). Returns ``[]``
    for empty audio.
    """
    import numpy as np

    if total_frames <= 0:
        return []
    max_frames = max(1, math.floor(max_seconds * sample_rate))
    if total_frames <= max_frames:
        return [Piece(1, 0, total_frames, sample_rate)]

    hop = max(1, round(sample_rate * frame_seconds))
    search = search_seconds if search_seconds is not None else min(
        _MAX_SEARCH_SECONDS, max_seconds / 4.0
    )
    search_frames = max(hop, int(search * sample_rate))
    window = max(1, round(_SMOOTH_SECONDS / frame_seconds))
    if energies.size >= window:
        smooth = np.convolve(energies, np.ones(window) / window, mode="same")
    else:
        smooth = energies

    cuts: list[int] = []
    start = 0
    while total_frames - start > max_frames:
        hi = start + max_frames  # latest allowed cut (sample index)
        lo = max(start + hop, hi - search_frames)
        # Candidate cut = centre of an energy frame i: (i + 0.5) * hop.
        i_lo = math.ceil(lo / hop - 0.5)
        i_hi = math.floor(hi / hop - 0.5)
        i_hi = min(i_hi, smooth.size - 1)
        cut = hi
        if smooth.size and i_hi >= i_lo >= 0:
            span = smooth[i_lo : i_hi + 1]
            # Ties (e.g. a long silence) → the latest, so pieces stay long.
            best = i_lo + (span.size - 1 - int(np.argmin(span[::-1])))
            cut = min(hi, max(lo, round((best + 0.5) * hop)))
        cuts.append(cut)
        start = cut

    bounds = [0, *cuts, total_frames]
    return [
        Piece(seq=i + 1, start_frame=bounds[i], end_frame=bounds[i + 1], sample_rate=sample_rate)
        for i in range(len(bounds) - 1)
        if bounds[i + 1] > bounds[i]
    ]


def write_pieces(
    wav: Path,
    pieces: list[Piece],
    out_dir: Path,
    *,
    cancel: threading.Event | None = None,
) -> list[Path]:
    """Copy each piece's sample range into ``out_dir/piece_NNN.wav``."""
    import soundfile as sf

    out_dir.mkdir(parents=True, exist_ok=True)
    written: list[Path] = []
    with sf.SoundFile(str(wav)) as src:
        sr = int(src.samplerate)
        for piece in pieces:
            target = out_dir / f"piece_{piece.seq:03d}.wav"
            src.seek(piece.start_frame)
            remaining = piece.end_frame - piece.start_frame
            with sf.SoundFile(
                str(target), mode="w", samplerate=sr, channels=1, format="WAV", subtype="FLOAT"
            ) as out:
                while remaining > 0:
                    if cancel is not None and cancel.is_set():
                        raise SplitCancelled(str(wav))
                    block = src.read(min(_BLOCK_FRAMES, remaining), dtype="float32")
                    if len(block) == 0:
                        break
                    out.write(block)
                    remaining -= len(block)
            written.append(target)
    return written


def split_wav(
    wav: Path,
    out_dir: Path,
    *,
    max_seconds: float,
    cancel: threading.Event | None = None,
) -> list[tuple[Piece, Path]]:
    """Plan and write the pieces of a decoded mono WAV."""
    energies, sr, total = frame_energies(wav, cancel=cancel)
    pieces = plan_pieces(energies, sample_rate=sr, total_frames=total, max_seconds=max_seconds)
    paths = write_pieces(wav, pieces, out_dir, cancel=cancel)
    return list(zip(pieces, paths, strict=True))
