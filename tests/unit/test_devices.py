"""Tests for microphone device resolution."""

from __future__ import annotations

from types import SimpleNamespace

import pytest

from huske.capture import devices as devices_mod


def _patch_sounddevice(
    monkeypatch: pytest.MonkeyPatch,
    raw_devices: list[dict[str, object]],
    default_input: int,
) -> None:
    sd = devices_mod.__dict__["sd"]
    monkeypatch.setattr(
        sd,
        "query_hostapis",
        lambda: [{"name": "Core Audio"}],
    )

    def query_devices(index: int | None = None) -> object:
        if index is None:
            return raw_devices
        return raw_devices[index]

    monkeypatch.setattr(sd, "query_devices", query_devices)
    monkeypatch.setattr(sd, "default", SimpleNamespace(device=[default_input, -1]))


def test_resolve_configured_microphone(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _patch_sounddevice(
        monkeypatch,
        [
            {
                "name": "MacBook Pro Microphone",
                "hostapi": 0,
                "max_input_channels": 1,
                "default_samplerate": 96000.0,
            }
        ],
        default_input=0,
    )

    resolution = devices_mod.resolve_input_device_with_fallback("macbook")

    assert resolution.device is not None
    assert resolution.device.name == "MacBook Pro Microphone"
    assert not resolution.fallback_used
    assert resolution.warning is None


def test_missing_configured_microphone_falls_back_to_default(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _patch_sounddevice(
        monkeypatch,
        [
            {
                "name": "MacBook Pro Microphone",
                "hostapi": 0,
                "max_input_channels": 1,
                "default_samplerate": 96000.0,
            },
            {
                "name": "ZoomAudioDevice",
                "hostapi": 0,
                "max_input_channels": 2,
                "default_samplerate": 48000.0,
            },
        ],
        default_input=0,
    )

    resolution = devices_mod.resolve_input_device_with_fallback("AirPods")

    assert resolution.device is not None
    assert resolution.device.name == "MacBook Pro Microphone"
    assert resolution.fallback_used
    assert resolution.warning is not None
    assert "AirPods" in resolution.warning


def test_missing_configured_microphone_without_devices_returns_none(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _patch_sounddevice(monkeypatch, [], default_input=-1)

    resolution = devices_mod.resolve_input_device_with_fallback("AirPods")

    assert resolution.device is None
    assert not resolution.fallback_used
    assert resolution.warning == "Configured microphone 'AirPods' was not found."
