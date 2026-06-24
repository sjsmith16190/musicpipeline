from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterable, Iterator


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
TITLE_SUFFIX_RE = re.compile(r"\s?\[(?:MP3|\d+(?:\.\d+)?-\d+(?:\.\d+)?)\]$")
TITLE_CASE_WORD_RE = re.compile(r"[A-Za-z]+(?:'[A-Za-z]+)?")


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


@dataclass(frozen=True)
class ResolutionTitleOutcome:
    path: Path
    status: str
    current_title: str | None = None
    new_title: str | None = None
    reason: str | None = None


def ensure_title_resolution_tools() -> list[str]:
    return [name for name in ("ffprobe", "exiftool") if shutil.which(name) is None]


def default_title_resolution_jobs() -> int:
    return min(16, max(4, os.cpu_count() or 1))


def apply_resolution_titles(
    root: Path,
    *,
    dry_run: bool = False,
    jobs: int | None = None,
) -> ResolutionTitleSummary:
    updated = 0
    skipped = 0
    failed = 0
    selected_jobs = max(1, jobs or default_title_resolution_jobs())
    paths = iter_audio_files(root)

    if dry_run:
        iterator = _map_outcomes(paths, _build_outcome, selected_jobs)
    else:
        iterator = _map_outcomes(paths, _process_write, selected_jobs)

    for outcome in iterator:
        if outcome.status == "failed":
            failed += 1
            print(f"ERROR  {outcome.path}: {outcome.reason}")
            continue

        if outcome.status == "skipped":
            skipped += 1
            print(f"SKIP   {outcome.path}: {outcome.reason}")
            continue

        if dry_run:
            print(f"DRY    {outcome.path}: '{outcome.current_title}' -> '{outcome.new_title}'")
            updated += 1
        else:
            print(f"WRITE  {outcome.path}: '{outcome.current_title}' -> '{outcome.new_title}'")
            updated += 1

    print("")
    print(f"Root:    {root}")
    print(f"Updated: {updated}")
    print(f"Skipped: {skipped}")
    print(f"Failed:  {failed}")
    return ResolutionTitleSummary(updated=updated, skipped=skipped, failed=failed)


def _map_outcomes(
    paths: Iterable[Path],
    worker: Callable[[Path], ResolutionTitleOutcome],
    jobs: int,
) -> Iterator[ResolutionTitleOutcome]:
    if jobs == 1:
        for path in paths:
            yield worker(path)
        return
    with ThreadPoolExecutor(max_workers=jobs) as executor:
        yield from executor.map(worker, paths)


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
    return _build_plan_from_metadata(path, metadata)


def _build_plan_from_metadata(
    path: Path,
    metadata: dict[str, object],
) -> ResolutionTitlePlan | None:
    title = str(metadata["title"])
    bits = metadata["bits_per_sample"]
    sample_rate = metadata["sample_rate"]
    suffix = resolution_suffix(path, bits, sample_rate)
    if suffix is None:
        return None

    trailing_suffix = trailing_title_suffix(title)
    base_title = TITLE_SUFFIX_RE.sub("", title).strip()
    normalized_base_title = title_case_label(base_title)
    if trailing_suffix == suffix:
        separator = "" if normalized_base_title.endswith("]") else " "
        new_title = f"{normalized_base_title}{separator}{suffix}".strip()
    elif suffix in base_title:
        new_title = normalized_base_title
    else:
        separator = "" if normalized_base_title.endswith("]") else " "
        new_title = f"{normalized_base_title}{separator}{suffix}".strip()

    if new_title == title:
        return None

    return ResolutionTitlePlan(path=path, current_title=title, new_title=new_title)


def _build_outcome(path: Path) -> ResolutionTitleOutcome:
    try:
        metadata = probe_resolution_metadata(path)
    except Exception as exc:  # pragma: no cover - defensive logging for ad hoc use
        return ResolutionTitleOutcome(path=path, status="failed", reason=str(exc))

    plan = _build_plan_from_metadata(path, metadata)
    if plan is None:
        title = str(metadata["title"])
        bits = metadata["bits_per_sample"]
        sample_rate = metadata["sample_rate"]
        if not bits or not sample_rate:
            return ResolutionTitleOutcome(
                path=path,
                status="skipped",
                reason="missing bit depth or sample rate",
            )
        return ResolutionTitleOutcome(
            path=path,
            status="skipped",
            reason=f"title already '{title}'",
        )

    return ResolutionTitleOutcome(
        path=path,
        status="updated",
        current_title=plan.current_title,
        new_title=plan.new_title,
    )


def _process_write(path: Path) -> ResolutionTitleOutcome:
    outcome = _build_outcome(path)
    if outcome.status != "updated":
        return outcome

    completed = subprocess.run(
        ["exiftool", "-overwrite_original", f"-title={outcome.new_title}", str(path)],
        check=False,
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        reason = (completed.stderr or completed.stdout or "exiftool failed").strip()
        return ResolutionTitleOutcome(path=path, status="failed", reason=reason)
    return outcome


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


def resolution_suffix(path: Path, bits: object, sample_rate: object) -> str | None:
    if path.suffix.casefold() == ".mp3":
        return "[MP3]"
    if not bits or not sample_rate:
        return None
    return f"[{bits}-{format_sample_rate(int(sample_rate))}]"


def title_case_label(label: str) -> str:
    return TITLE_CASE_WORD_RE.sub(_title_case_match, label)


def trailing_title_suffix(title: str) -> str | None:
    match = TITLE_SUFFIX_RE.search(title)
    if match is None:
        return None
    return match.group().strip()


def _title_case_match(match: re.Match[str]) -> str:
    word = match.group(0)
    return word[:1].upper() + word[1:].lower()


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
