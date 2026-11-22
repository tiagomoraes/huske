"""Minimal ctypes access to Core Audio HAL object properties.

PyObjC's CoreAudio bridge handles the tap/aggregate *creation* calls cleanly,
but ``AudioObjectGetPropertyData`` (in/out size + variable-length payloads)
is incomplete there, so device enumeration and stream layout queries go
through ctypes. Read-only helpers; nothing here changes system state.
"""

from __future__ import annotations

import ctypes
import ctypes.util
import platform
from dataclasses import dataclass
from functools import lru_cache


def fourcc(code: str) -> int:
    return int.from_bytes(code.encode("ascii"), "big")


kAudioObjectSystemObject = 1
kAudioObjectPropertyScopeGlobal = fourcc("glob")
kAudioObjectPropertyScopeInput = fourcc("inpt")
kAudioObjectPropertyElementMain = 0

kAudioHardwarePropertyDevices = fourcc("dev#")
kAudioHardwarePropertyDefaultInputDevice = fourcc("dIn ")
kAudioHardwarePropertyDefaultOutputDevice = fourcc("dOut")
kAudioObjectPropertyName = fourcc("lnam")
kAudioDevicePropertyDeviceUID = fourcc("uid ")
kAudioDevicePropertyStreamConfiguration = fourcc("slay")
kAudioDevicePropertyNominalSampleRate = fourcc("nsrt")
kAudioDevicePropertyTransportType = fourcc("tran")

_kCFStringEncodingUTF8 = 0x08000100


class _PropertyAddress(ctypes.Structure):
    _fields_ = [
        ("mSelector", ctypes.c_uint32),
        ("mScope", ctypes.c_uint32),
        ("mElement", ctypes.c_uint32),
    ]


class _AudioBuffer(ctypes.Structure):
    _fields_ = [
        ("mNumberChannels", ctypes.c_uint32),
        ("mDataByteSize", ctypes.c_uint32),
        ("mData", ctypes.c_void_p),
    ]


@lru_cache(maxsize=1)
def _libs() -> tuple[ctypes.CDLL, ctypes.CDLL]:
    if platform.system() != "Darwin":
        raise OSError("Core Audio is only available on macOS")
    ca_path = ctypes.util.find_library("CoreAudio")
    cf_path = ctypes.util.find_library("CoreFoundation")
    if not ca_path or not cf_path:
        raise OSError("CoreAudio/CoreFoundation not found")
    ca = ctypes.CDLL(ca_path)
    cf = ctypes.CDLL(cf_path)
    ca.AudioObjectGetPropertyDataSize.argtypes = [
        ctypes.c_uint32,
        ctypes.POINTER(_PropertyAddress),
        ctypes.c_uint32,
        ctypes.c_void_p,
        ctypes.POINTER(ctypes.c_uint32),
    ]
    ca.AudioObjectGetPropertyDataSize.restype = ctypes.c_int32
    ca.AudioObjectGetPropertyData.argtypes = [
        ctypes.c_uint32,
        ctypes.POINTER(_PropertyAddress),
        ctypes.c_uint32,
        ctypes.c_void_p,
        ctypes.POINTER(ctypes.c_uint32),
        ctypes.c_void_p,
    ]
    ca.AudioObjectGetPropertyData.restype = ctypes.c_int32
    cf.CFStringGetLength.argtypes = [ctypes.c_void_p]
    cf.CFStringGetLength.restype = ctypes.c_long
    cf.CFStringGetCString.argtypes = [
        ctypes.c_void_p,
        ctypes.c_char_p,
        ctypes.c_long,
        ctypes.c_uint32,
    ]
    cf.CFStringGetCString.restype = ctypes.c_bool
    cf.CFRelease.argtypes = [ctypes.c_void_p]
    cf.CFRelease.restype = None
    return ca, cf


def _address(selector: int, scope: int = kAudioObjectPropertyScopeGlobal) -> _PropertyAddress:
    return _PropertyAddress(selector, scope, kAudioObjectPropertyElementMain)


def _get_bytes(obj: int, selector: int, scope: int = kAudioObjectPropertyScopeGlobal) -> bytes | None:
    ca, _ = _libs()
    addr = _address(selector, scope)
    size = ctypes.c_uint32(0)
    if ca.AudioObjectGetPropertyDataSize(obj, ctypes.byref(addr), 0, None, ctypes.byref(size)) != 0:
        return None
    if size.value == 0:
        return b""
    buf = (ctypes.c_ubyte * size.value)()
    if ca.AudioObjectGetPropertyData(obj, ctypes.byref(addr), 0, None, ctypes.byref(size), buf) != 0:
        return None
    return bytes(buf[: size.value])


def _get_u32(obj: int, selector: int, scope: int = kAudioObjectPropertyScopeGlobal) -> int | None:
    ca, _ = _libs()
    addr = _address(selector, scope)
    value = ctypes.c_uint32(0)
    size = ctypes.c_uint32(ctypes.sizeof(value))
    if ca.AudioObjectGetPropertyData(obj, ctypes.byref(addr), 0, None, ctypes.byref(size), ctypes.byref(value)) != 0:
        return None
    return int(value.value)


def _get_f64(obj: int, selector: int) -> float | None:
    ca, _ = _libs()
    addr = _address(selector)
    value = ctypes.c_double(0.0)
    size = ctypes.c_uint32(ctypes.sizeof(value))
    if ca.AudioObjectGetPropertyData(obj, ctypes.byref(addr), 0, None, ctypes.byref(size), ctypes.byref(value)) != 0:
        return None
    return float(value.value)


def _get_cfstring(obj: int, selector: int) -> str | None:
    ca, cf = _libs()
    addr = _address(selector)
    ref = ctypes.c_void_p(None)
    size = ctypes.c_uint32(ctypes.sizeof(ref))
    if ca.AudioObjectGetPropertyData(obj, ctypes.byref(addr), 0, None, ctypes.byref(size), ctypes.byref(ref)) != 0:
        return None
    if not ref.value:
        return None
    try:
        length = cf.CFStringGetLength(ref)
        cap = length * 4 + 1
        out = ctypes.create_string_buffer(cap)
        if not cf.CFStringGetCString(ref, out, cap, _kCFStringEncodingUTF8):
            return None
        return out.value.decode("utf-8", "replace")
    finally:
        cf.CFRelease(ref)


def device_ids() -> list[int]:
    raw = _get_bytes(kAudioObjectSystemObject, kAudioHardwarePropertyDevices)
    if not raw:
        return []
    count = len(raw) // 4
    return list((ctypes.c_uint32 * count).from_buffer_copy(raw))


def device_uid(device_id: int) -> str | None:
    return _get_cfstring(device_id, kAudioDevicePropertyDeviceUID)


def device_name(device_id: int) -> str | None:
    return _get_cfstring(device_id, kAudioObjectPropertyName)


def nominal_sample_rate(device_id: int) -> float | None:
    return _get_f64(device_id, kAudioDevicePropertyNominalSampleRate)


def default_input_device() -> int | None:
    dev = _get_u32(kAudioObjectSystemObject, kAudioHardwarePropertyDefaultInputDevice)
    return dev or None


def default_output_device() -> int | None:
    dev = _get_u32(kAudioObjectSystemObject, kAudioHardwarePropertyDefaultOutputDevice)
    return dev or None


def stream_channels(device_id: int, scope: int = kAudioObjectPropertyScopeInput) -> list[int]:
    """Channel count of each stream in ``scope`` (one entry per AudioBuffer)."""
    raw = _get_bytes(device_id, kAudioDevicePropertyStreamConfiguration, scope)
    if not raw or len(raw) < 4:
        return []
    n = int.from_bytes(raw[:4], "little")
    # AudioBufferList: UInt32 mNumberBuffers, (pad to 8), then AudioBuffer[n].
    offset = ctypes.sizeof(ctypes.c_void_p)  # 8 on arm64/x86_64
    item = ctypes.sizeof(_AudioBuffer)
    out: list[int] = []
    for i in range(n):
        start = offset + i * item
        chunk = raw[start : start + item]
        if len(chunk) < item:
            break
        out.append(_AudioBuffer.from_buffer_copy(chunk).mNumberChannels)
    return out


@dataclass(frozen=True)
class HalDevice:
    device_id: int
    uid: str
    name: str
    input_channels: int


def input_devices() -> list[HalDevice]:
    """Every HAL device with at least one input channel."""
    out: list[HalDevice] = []
    for dev in device_ids():
        channels = sum(stream_channels(dev))
        if channels <= 0:
            continue
        uid = device_uid(dev)
        if not uid:
            continue
        out.append(HalDevice(dev, uid, device_name(dev) or uid, channels))
    return out


def find_input_device(name: str | None) -> HalDevice | None:
    """Resolve a PortAudio/huske device name to a HAL input device.

    ``None`` means the system default input. Matching is exact first, then
    case-insensitive, then by prefix (PortAudio may truncate long names).
    """
    devices = input_devices()
    if name is None:
        default = default_input_device()
        return next((d for d in devices if d.device_id == default), None)
    for d in devices:
        if d.name == name:
            return d
    lowered = name.casefold()
    for d in devices:
        if d.name.casefold() == lowered:
            return d
    for d in devices:
        if d.name.casefold().startswith(lowered) or lowered.startswith(d.name.casefold()):
            return d
    return None
