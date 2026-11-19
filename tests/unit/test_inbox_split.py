"""Inbox decoding (soundfile + afconvert) and quiet-point splitting."""

from __future__ import annotations

import itertools
import subprocess
import threading
from pathlib import Path

import numpy as np
import pytest
import soundfile as sf

from huske.inbox.decode import AFCONVERT, DecodeCancelled, DecodeError, decode_to_wav16k
from huske.inbox.split import frame_energies, plan_pieces, split_wav, write_pieces

from ._inbox_fakes import SR, silence, tone, write_wav

needs_afconvert = pytest.mark.skipif(
    not AFCONVERT.exists(), reason="/usr/bin/afconvert is macOS-only"
)


# ---------------------------------------------------------------------------
# plan_pieces (pure)
# ---------------------------------------------------------------------------


def test_short_recording_is_one_piece() -> None:
    pieces = plan_pieces(np.ones(50), sample_rate=SR, total_frames=5 * SR, max_seconds=60.0)
    assert [(p.start_frame, p.end_frame) for p in pieces] == [(0, 5 * SR)]
    assert pieces[0].seq == 1


def test_empty_recording_has_no_pieces() -> None:
    assert plan_pieces(np.zeros(0), sample_rate=SR, total_frames=0, max_seconds=60.0) == []


def test_cut_lands_in_the_pause_before_the_boundary() -> None:
    # 100 s of speech-level energy with one 1 s pause at 50-51 s; 60 s cap.
    energies = np.ones(1000)
    energies[500:510] = 0.0
    pieces = plan_pieces(
        energies, sample_rate=SR, total_frames=100 * SR, max_seconds=60.0, search_seconds=20.0
    )
    assert len(pieces) == 2
    cut = pieces[0].end_frame / SR
    assert 50.0 <= cut <= 51.0
    assert pieces[1].start_frame == pieces[0].end_frame  # contiguous


def test_pieces_never_exceed_the_cap_and_cover_everything() -> None:
    rng = np.random.default_rng(7)
    total = 1000 * SR + 123
    energies = rng.random(int(np.ceil(total / (SR * 0.1))))
    pieces = plan_pieces(energies, sample_rate=SR, total_frames=total, max_seconds=60.0)
    assert pieces[0].start_frame == 0 and pieces[-1].end_frame == total
    for a, b in itertools.pairwise(pieces):
        assert a.end_frame == b.start_frame
    assert all(p.end_frame - p.start_frame <= 60 * SR for p in pieces)
    assert [p.seq for p in pieces] == list(range(1, len(pieces) + 1))
    # Searching only the last 15 s (60/4) keeps pieces long: no more than one
    # extra piece over the theoretical minimum.
    assert len(pieces) <= int(np.ceil(total / (45 * SR))) + 1


def test_uniform_silence_cuts_as_late_as_allowed() -> None:
    pieces = plan_pieces(
        np.zeros(1500), sample_rate=SR, total_frames=150 * SR, max_seconds=60.0
    )
    lengths = [(p.end_frame - p.start_frame) / SR for p in pieces]
    assert lengths[0] == pytest.approx(60.0, abs=0.1)
    assert lengths[1] == pytest.approx(60.0, abs=0.1)
    assert sum(lengths) == pytest.approx(150.0)


# ---------------------------------------------------------------------------
# frame_energies + write_pieces (streamed I/O)
# ---------------------------------------------------------------------------


def test_split_wav_cuts_at_the_silent_gap_and_preserves_samples(tmp_path: Path) -> None:
    # 50 s tone | 2 s silence | 30 s tone → with a 60 s cap (searched over its
    # last 15 s), the cut must fall inside the silent gap (50-52 s).
    audio = np.concatenate([tone(50.0), silence(2.0), tone(30.0, freq=330.0)])
    wav = tmp_path / "decoded.wav"
    sf.write(str(wav), audio, SR, subtype="FLOAT")

    result = split_wav(wav, tmp_path / "work", max_seconds=60.0)

    assert len(result) == 2
    (p1, f1), (_, f2) = result
    assert 50.0 <= p1.end_frame / SR <= 52.0
    assert f1.name == "piece_001.wav" and f2.name == "piece_002.wav"
    a, _ = sf.read(str(f1), dtype="float32")
    b, _ = sf.read(str(f2), dtype="float32")
    np.testing.assert_array_equal(np.concatenate([a, b]), audio)


def test_frame_energies_reflect_loudness(tmp_path: Path) -> None:
    wav = tmp_path / "x.wav"
    sf.write(str(wav), np.concatenate([silence(1.0), tone(1.0, amp=0.5)]), SR, subtype="FLOAT")
    energies, sr, total = frame_energies(wav)
    assert sr == SR and total == 2 * SR
    assert len(energies) == 20
    assert energies[:10].max() == 0.0
    assert energies[10:].min() > 0.1


def test_write_pieces_honours_cancel(tmp_path: Path) -> None:
    wav = tmp_path / "x.wav"
    sf.write(str(wav), tone(5.0), SR, subtype="FLOAT")
    pieces = plan_pieces(np.ones(50), sample_rate=SR, total_frames=5 * SR, max_seconds=60.0)
    cancel = threading.Event()
    cancel.set()
    from huske.inbox.split import SplitCancelled

    with pytest.raises(SplitCancelled):
        write_pieces(wav, pieces, tmp_path / "out", cancel=cancel)


# ---------------------------------------------------------------------------
# decode_to_wav16k
# ---------------------------------------------------------------------------


def test_decode_soundfile_format_to_16k_mono(tmp_path: Path) -> None:
    sr = 48_000
    stereo = np.stack([tone(3.0, sr=sr), tone(3.0, sr=sr, freq=330.0)], axis=1)
    src = tmp_path / "in.flac"
    sf.write(str(src), stereo, sr, format="FLAC")

    seconds = decode_to_wav16k(src, tmp_path / "out.wav")

    info = sf.info(str(tmp_path / "out.wav"))
    assert (info.samplerate, info.channels, info.subtype) == (16_000, 1, "FLOAT")
    assert seconds == pytest.approx(3.0, abs=0.01)
    assert not list(tmp_path.glob(".*part*"))


@needs_afconvert
def test_decode_aac_m4a_through_afconvert(tmp_path: Path) -> None:
    wav = write_wav(tmp_path / "src.wav", np.concatenate([tone(2.0, sr=44_100), silence(1.0, sr=44_100)]), sr=44_100)
    m4a = tmp_path / "phone.m4a"
    subprocess.run(
        [str(AFCONVERT), "-f", "m4af", "-d", "aac", str(wav), str(m4a)], check=True
    )
    with pytest.raises(sf.LibsndfileError):
        sf.info(str(m4a))  # proves this path really needs afconvert

    seconds = decode_to_wav16k(m4a, tmp_path / "out.wav")

    data, sr = sf.read(str(tmp_path / "out.wav"), dtype="float32")
    assert sr == 16_000 and data.ndim == 1
    assert seconds == pytest.approx(3.0, abs=0.1)
    assert float(np.sqrt(np.mean(data[: SR] ** 2))) > 0.05  # the tone survived


@needs_afconvert
def test_decode_garbage_fails_cleanly(tmp_path: Path) -> None:
    bad = tmp_path / "garbage.m4a"
    bad.write_bytes(b"this is not audio" * 100)
    with pytest.raises(DecodeError):
        decode_to_wav16k(bad, tmp_path / "out.wav")
    assert not (tmp_path / "out.wav").exists()


def test_decode_without_afconvert_reports_it(tmp_path: Path) -> None:
    bad = tmp_path / "garbage.m4a"
    bad.write_bytes(b"\x00" * 64)
    with pytest.raises(DecodeError, match="not available"):
        decode_to_wav16k(bad, tmp_path / "out.wav", afconvert=tmp_path / "no-afconvert")


def test_decode_honours_cancel(tmp_path: Path) -> None:
    src = write_wav(tmp_path / "in.wav", tone(2.0), sr=48_000)
    cancel = threading.Event()
    cancel.set()
    with pytest.raises(DecodeCancelled):
        decode_to_wav16k(src, tmp_path / "out.wav", cancel=cancel)
    assert not (tmp_path / "out.wav").exists()
