from __future__ import annotations

import json
import subprocess
from pathlib import Path

from .constants import FFPROBE_METADATA_FIELDS, KNOWN_AUDIO_EXTENSIONS, LOSSLESS_CODECS, LOSSLESS_PCM_PREFIXES, LOSSY_CODECS
from .models import ProbeResult


class ProbeError(RuntimeError):
    pass


def run_command(command: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        check=False,
        capture_output=True,
        text=True,
    )


def classify_codec(codec: str | None) -> str | None:
    if not codec:
        return None
    lowered = codec.casefold()
    if lowered in LOSSLESS_CODECS or lowered.startswith(LOSSLESS_PCM_PREFIXES):
        return "lossless"
    if lowered in LOSSY_CODECS:
        return "lossy"
    return None


def probe_file(path: Path) -> ProbeResult:
    command = [
        "ffprobe",
        "-v",
        "error",
        "-print_format",
        "json",
        "-show_format",
        "-show_streams",
        str(path),
    ]
    completed = run_command(command)
    if completed.returncode != 0:
        if path.suffix.casefold() in KNOWN_AUDIO_EXTENSIONS:
            return ProbeResult(
                status="broken_audio",
                failure_stage="probe",
                failure_reason=(completed.stderr or "ffprobe failed").strip(),
            )
        return ProbeResult(status="not_audio")
    try:
        payload = json.loads(completed.stdout or "{}")
    except json.JSONDecodeError:
        if path.suffix.casefold() in KNOWN_AUDIO_EXTENSIONS:
            return ProbeResult(
                status="broken_audio",
                failure_stage="probe",
                failure_reason="invalid ffprobe json",
            )
        return ProbeResult(status="not_audio")

    streams = payload.get("streams") or []
    audio_stream = next((stream for stream in streams if stream.get("codec_type") == "audio"), None)
    if audio_stream is None:
        if path.suffix.casefold() in KNOWN_AUDIO_EXTENSIONS:
            return ProbeResult(
                status="broken_audio",
                failure_stage="probe",
                failure_reason="no audio stream detected",
            )
        return ProbeResult(status="not_audio")

    codec = audio_stream.get("codec_name")
    audio_kind = classify_codec(codec)
    if audio_kind is None:
        return ProbeResult(
            status="broken_audio",
            codec=codec,
            failure_stage="probe",
            failure_reason="unsupported or unknown audio codec",
        )

    format_info = payload.get("format") or {}
    tags = {key.casefold(): str(value) for key, value in (format_info.get("tags") or {}).items()}
    metadata = {field: tags.get(field, "") for field in FFPROBE_METADATA_FIELDS}
    sample_rate = _maybe_int(audio_stream.get("sample_rate"))
    bits_per_sample = _best_bits(audio_stream)
    return ProbeResult(
        status="audio",
        codec=(codec or "").casefold() or None,
        container=str(format_info.get("format_name") or "").casefold() or None,
        audio_kind=audio_kind,
        sample_rate=sample_rate,
        bits_per_sample=bits_per_sample,
        metadata=metadata,
    )


def validate_audio_decode(path: Path) -> tuple[bool, str | None]:
    command = [
        "ffmpeg",
        "-v",
        "error",
        "-i",
        str(path),
        "-f",
        "null",
        "-",
    ]
    completed = run_command(command)
    if completed.returncode == 0:
        return True, None
    return False, (completed.stderr or "decode validation failed").strip()


def validate_alac_output(path: Path) -> tuple[bool, str | None]:
    probed = probe_file(path)
    if probed.status != "audio":
        return False, probed.failure_reason or "unable to probe ALAC output"
    if probed.codec != "alac":
        return False, f"expected ALAC output, found {probed.codec or 'unknown'}"
    return validate_audio_decode(path)


def _maybe_int(value: object) -> int | None:
    if value in (None, "", "N/A"):
        return None
    try:
        return int(str(value), 10)
    except ValueError:
        return None


def _best_bits(stream: dict[str, object]) -> int | None:
    for key in ("bits_per_raw_sample", "bits_per_sample"):
        bits = _maybe_int(stream.get(key))
        if bits:
            return bits
    sample_fmt = str(stream.get("sample_fmt") or "")
    digits = "".join(character for character in sample_fmt if character.isdigit())
    return _maybe_int(digits)

