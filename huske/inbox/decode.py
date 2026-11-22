"""Decode any supported recording to a 16 kHz mono float32 WAV on disk.

``soundfile`` reads WAV/FLAC/OGG/MP3/AIFF/CAF(PCM); those stream through
:func:`huske.transcribe.engines.base.iter_mono_16k` — the same downmix and
``soxr`` resampling the ASR worker uses — block by block straight into the
output file, so even a multi-hour recording never sits in RAM. Anything
``soundfile`` cannot open (AAC in ``.m4a``/``.caf``, which is what the iPhone
records) goes through macOS's built-in ``/usr/bin/afconvert``. No ffmpeg.

The live engine runs this on a background thread; ``cancel`` lets it stop
promptly on shutdown (an ``afconvert`` child is terminated).
"""

from __future__ import annotations

import contextlib
import os
import subprocess
import threading
from pathlib import Path

AFCONVERT = Path("/usr/bin/afconvert")
TARGET_SAMPLE_RATE = 16000


class DecodeError(RuntimeError):
    """The recording could not be decoded."""


class DecodeCancelled(RuntimeError):
    """``cancel`` was set while decoding."""


def soundfile_can_read(path: Path) -> bool:
    try:
        import soundfile as sf

        sf.info(str(path))
    except Exception:
        return False
    return True


def decode_to_wav16k(
    source: Path,
    dest: Path,
    *,
    cancel: threading.Event | None = None,
    afconvert: Path = AFCONVERT,
) -> float:
    """Decode ``source`` into a 16 kHz mono float32 WAV at ``dest``.

    Returns the decoded duration in seconds. Writes through a temporary
    sibling and renames, so ``dest`` is either complete or absent.
    """
    import soundfile as sf

    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_name(f".{dest.name}.part.wav")
    tmp.unlink(missing_ok=True)
    try:
        if soundfile_can_read(source):
            _decode_with_soundfile(source, tmp, cancel)
        else:
            _decode_with_afconvert(source, tmp, cancel, afconvert)
        os.replace(tmp, dest)
    finally:
        tmp.unlink(missing_ok=True)
    info = sf.info(str(dest))
    if info.samplerate <= 0:
        return 0.0
    return float(info.frames) / float(info.samplerate)


def _decode_with_soundfile(
    source: Path, dest: Path, cancel: threading.Event | None
) -> None:
    import soundfile as sf

    from huske.transcribe.engines.base import iter_mono_16k

    try:
        with sf.SoundFile(
            str(dest),
            mode="w",
            samplerate=TARGET_SAMPLE_RATE,
            channels=1,
            format="WAV",
            subtype="FLOAT",
        ) as out:
            for block in iter_mono_16k(str(source)):
                if cancel is not None and cancel.is_set():
                    raise DecodeCancelled(str(source))
                out.write(block)
    except DecodeCancelled:
        raise
    except Exception as exc:
        raise DecodeError(f"could not decode {source.name}: {exc}") from exc


def _decode_with_afconvert(
    source: Path, dest: Path, cancel: threading.Event | None, afconvert: Path
) -> None:
    if not afconvert.exists():
        raise DecodeError(
            f"cannot decode {source.name}: soundfile does not support this format "
            f"and {afconvert} is not available"
        )
    argv = [
        str(afconvert),
        "-f", "WAVE",
        "-d", f"LEF32@{TARGET_SAMPLE_RATE}",
        "-c", "1",
        "--mix",
        str(source),
        str(dest),
    ]
    proc = subprocess.Popen(
        argv,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    while True:
        try:
            _, stderr = proc.communicate(timeout=0.25)
            break
        except subprocess.TimeoutExpired:
            if cancel is not None and cancel.is_set():
                proc.terminate()
                with contextlib.suppress(subprocess.TimeoutExpired):
                    proc.wait(timeout=2.0)
                if proc.poll() is None:
                    proc.kill()
                    proc.wait()
                raise DecodeCancelled(str(source)) from None
    if proc.returncode != 0 or not dest.exists():
        detail = (stderr or "").strip().splitlines()
        tail = detail[-1] if detail else f"exit status {proc.returncode}"
        raise DecodeError(f"afconvert could not decode {source.name}: {tail}")
