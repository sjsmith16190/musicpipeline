from __future__ import annotations

import json
import re
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path


AUDIO_EXTENSIONS = {
    ".aac",
    ".aif",
    ".aiff",
    ".alac",
    ".ape",
    ".dsf",
    ".flac",
    ".m4a",
    ".m4b",
    ".mp3",
    ".mp4",
    ".ogg",
    ".opus",
    ".wav",
    ".wma",
}
TITLE_SUFFIX_RE = re.compile(r"\s\[\d+(?:\.\d+)?-\d+(?:\.\d+)?\]$")


@dataclass(frozen=True)
class ResolutionTitlePlan:
    path: Path
    current_title: str
    new_title: str


@dataclass(frozen=True)
class ResolutionTitleSummary:
    updated: int
    skipped: int
    failed: int


def ensure_title_resolution_tools() -> list[str]:
    return [name for name in ("ffprobe", "exiftool") if shutil.which(name) is None]


def apply_resolution_titles(root: Path, *, dry_run: bool = False) -> ResolutionTitleSummary:
    updated = 0
    skipped = 0
    failed = 0

    for path in iter_audio_files(root):
        try:
            plan = build_resolution_title_plan(path)
        except Exception as exc:  # pragma: no cover - defensive logging for ad hoc use
            failed += 1
            print(f"ERROR  {path}: {exc}")
            continue

        if plan is None:
            skipped += 1
            continue

        if dry_run:
            print(f"DRY    {path}: '{plan.current_title}' -> '{plan.new_title}'")
            updated += 1
            continue

        completed = subprocess.run(
            ["exiftool", "-overwrite_original", f"-title={plan.new_title}", str(path)],
            check=False,
            capture_output=True,
            text=True,
        )
        if completed.returncode != 0:
            failed += 1
            reason = (completed.stderr or completed.stdout or "exiftool failed").strip()
            print(f"ERROR  {path}: {reason}")
            continue
        print(f"WRITE  {path}: '{plan.current_title}' -> '{plan.new_title}'")
        updated += 1

    print("")
    print(f"Root:    {root}")
    print(f"Updated: {updated}")
    print(f"Skipped: {skipped}")
    print(f"Failed:  {failed}")
    return ResolutionTitleSummary(updated=updated, skipped=skipped, failed=failed)


def iter_audio_files(root: Path):
    for path in sorted(root.rglob("*")):
        if not path.is_file():
            continue
        if path.name.startswith("."):
            continue
        if path.name.startswith("._"):
            continue
        if path.suffix.casefold() in AUDIO_EXTENSIONS:
            yield path


def build_resolution_title_plan(path: Path) -> ResolutionTitlePlan | None:
    metadata = probe_resolution_metadata(path)
    title = metadata["title"]
    bits = metadata["bits_per_sample"]
    sample_rate = metadata["sample_rate"]

    if not bits or not sample_rate:
        print(f"SKIP   {path}: missing bit depth or sample rate")
        return None

    suffix = f"[{bits}-{format_sample_rate(sample_rate)}]"
    base_title = TITLE_SUFFIX_RE.sub("", title).strip()
    new_title = f"{base_title} {suffix}".strip()

    if new_title == title:
        print(f"SKIP   {path}: title already '{new_title}'")
        return None

    return ResolutionTitlePlan(path=path, current_title=title, new_title=new_title)


def probe_resolution_metadata(path: Path) -> dict[str, object]:
    completed = subprocess.run(
        [
            "ffprobe",
            "-v",
            "error",
            "-print_format",
            "json",
            "-show_format",
            "-show_streams",
            str(path),
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        raise RuntimeError((completed.stderr or "ffprobe failed").strip())

    payload = json.loads(completed.stdout or "{}")
    streams = payload.get("streams") or []
    audio_stream = next((stream for stream in streams if stream.get("codec_type") == "audio"), None)
    if audio_stream is None:
        raise RuntimeError("no audio stream found")

    tags = {
        str(key).casefold(): str(value)
        for key, value in ((payload.get("format") or {}).get("tags") or {}).items()
    }
    title = (tags.get("title") or path.stem).strip()

    return {
        "title": title,
        "sample_rate": maybe_int(audio_stream.get("sample_rate")),
        "bits_per_sample": best_bits(audio_stream),
    }


def maybe_int(value: object) -> int | None:
    if value in (None, "", "N/A"):
        return None
    try:
        return int(str(value), 10)
    except ValueError:
        return None


def best_bits(stream: dict[str, object]) -> int | None:
    for key in ("bits_per_raw_sample", "bits_per_sample"):
        bits = maybe_int(stream.get(key))
        if bits:
            return bits
    sample_fmt = str(stream.get("sample_fmt") or "")
    digits = "".join(character for character in sample_fmt if character.isdigit())
    return maybe_int(digits)


def format_sample_rate(sample_rate: int) -> str:
    khz = sample_rate / 1000
    if khz.is_integer():
        return str(int(khz))
    return f"{khz:.1f}".rstrip("0").rstrip(".")
