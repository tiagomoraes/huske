"""Lightweight voice-activity detection for speech-gated segmentation.

This is intentionally a *coarse* gate, not a precise phoneme-level VAD. Its only
jobs are (1) decide when a chunk may open (speech started) and (2) feed the
"how long since speech" timer that splits files on a real pause. Because the
downstream Parakeet engine emits nothing on silence, a false positive only
means a little extra silent audio gets written (and transcribed to nothing) —
never a hallucinated word — so the gate is biased toward *catching* speech.

Pure numpy, no model download, runs on the mixer thread per ~50 ms block:

* RMS in dBFS against an **adaptive noise floor** (fast attack down, slow rise),
  so it tracks the room's true noise level and flags energy a margin above it.
* A short **hangover** holds the speech verdict across the micro-gaps between
  words so a sentence isn't chopped into flapping on/off frames.

The research brief confirms an adaptive energy gate is sufficient here: the
multi-second "continuous silence" requirement for a split washes out per-frame
errors.
"""

from __future__ import annotations

import math

import numpy as np
import numpy.typing as npt

NDArrayF32 = npt.NDArray[np.float32]

_EPS = 1e-9


def _to_db(x: float) -> float:
    return 20.0 * math.log10(max(x, _EPS))


class EnergyVAD:
    """Adaptive-threshold speech/non-speech classifier over mono float32 blocks."""

    def __init__(
        self,
        *,
        margin_db: float = 9.0,
        absolute_gate_db: float = -55.0,
        attack_seconds: float = 0.15,
        hangover_seconds: float = 0.5,
        block_seconds: float = 0.05,
        floor_attack: float = 0.5,
        floor_release: float = 0.0015,
    ) -> None:
        # Gate is max(absolute floor, noise floor + margin) — the absolute floor
        # keeps near-digital-silence from ever counting as speech.
        self._margin_db = margin_db
        self._absolute_gate_db = absolute_gate_db
        # Onset debounce: speech must clear the gate for this many consecutive
        # blocks before it counts. A lone transient (keyboard click, fan tick,
        # a chair creak) is rejected, so it can't keep resetting the
        # silence-split timer and stop a real pause from ever being detected.
        self._attack_blocks = max(1, round(attack_seconds / block_seconds))
        self._hangover_blocks = max(1, round(hangover_seconds / block_seconds))
        # Asymmetric floor tracker: drop quickly toward a new (lower) quiet
        # level, rise slowly so sustained speech doesn't drag the floor up with
        # it (which would desensitize the gate mid-sentence).
        self._floor_attack = floor_attack
        self._floor_release = floor_release
        self._floor = 10 ** (absolute_gate_db / 20.0)
        self._above = 0
        self._hang = 0

    def is_speech(self, block: NDArrayF32) -> bool:
        if block.size == 0:
            # No samples this tick: treat as continuation of the prior verdict
            # via hangover, else silence.
            self._above = 0
            if self._hang > 0:
                self._hang -= 1
                return True
            return False

        rms = float(np.sqrt(np.mean(np.square(block, dtype=np.float64))))

        # Update the adaptive noise floor before thresholding.
        if rms < self._floor:
            self._floor += (rms - self._floor) * self._floor_attack
        else:
            self._floor += (rms - self._floor) * self._floor_release

        gate_db = max(self._absolute_gate_db, _to_db(self._floor) + self._margin_db)
        above = _to_db(rms) >= gate_db

        self._above = self._above + 1 if above else 0
        if self._above >= self._attack_blocks:
            self._hang = self._hangover_blocks
            return True
        if self._hang > 0:
            self._hang -= 1
            return True
        return False
