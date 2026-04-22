from __future__ import annotations

import re
import shutil
import subprocess
from collections import defaultdict
from pathlib import Path

from .constants import ARTWORK_PRIORITY, ORIGINAL_SOURCE_DIR_NAME, QUARANTINE_DIR_NAME, SIDECAR_EXTENSIONS, STATE_DIR_NAME
from .models import PlannedOperation, ScannedFile
from .normalize import build_track_token, codec_quality_tag, normalize_metadata
from .probe import ProbeResult, validate_alac_output, validate_audio_decode


def convert_units(root: Path, scanned_files: list[ScannedFile], logger, dry_run: bool) -> dict[str, int]:
    summary: dict[str, int] = defaultdict(int)
    release_units: dict[Path, list[ScannedFile]] = defaultdict(list)
    loose_units: list[ScannedFile] = []

    for scanned in scanned_files:
        if scanned.probe.status != "audio" or scanned.probe.audio_kind != "lossless":
            continue
        if scanned.path.parent == root:
            loose_units.append(scanned)
        else:
            release_units[scanned.path.parent].append(scanned)

    for directory in sorted(release_units):
        _convert_release_unit(root, directory, release_units[directory], logger, dry_run, summary)
    for scanned in sorted(loose_units, key=lambda item: str(item.relative_path)):
        _convert_single_file(root, scanned, logger, dry_run, summary)
    return dict(summary)


def _convert_release_unit(root: Path, directory: Path, files: list[ScannedFile], logger, dry_run: bool, summary: dict[str, int]) -> None:
    cue_path = _cue_file_in_dir(directory)
    if cue_path is not None and len(files) == 1:
        if _convert_cue_release_unit(root, directory, cue_path, files[0], logger, dry_run, summary):
            return
        return

    release_metadata = [normalize_metadata(scanned.probe.metadata) for scanned in files]
    if not release_metadata or any(metadata.album is None or metadata.title is None or (metadata.album_artist is None and metadata.artist is None) for metadata in release_metadata):
        logger.log(f"[convert-skip] ./{directory.relative_to(root)} (insufficient metadata for release conversion)")
        summary["convert_skipped"] += 1
        return
    first = release_metadata[0]
    if any(
        metadata.album != first.album
        or metadata.routing_artist != first.routing_artist
        or metadata.year != first.year
        or metadata.is_various_artists != first.is_various_artists
        for metadata in release_metadata
    ):
        logger.log(f"[convert-skip] ./{directory.relative_to(root)} (mixed release metadata)")
        summary["convert_skipped"] += 1
        return
    discs = {metadata.disc_number or 1 for metadata in release_metadata}
    multi_disc = len(discs) > 1 or any(value > 1 for value in discs)
    quality_tag = codec_quality_tag(files[0].probe)
    release_destination = _release_destination_root(first, quality_tag)
    target_dir = root / release_destination
    archive_dir = root / (first.routing_artist or "Unknown Artist") / ORIGINAL_SOURCE_DIR_NAME / _archive_release_dir_name(first)
    artwork = _select_artwork(directory)
    temp_dir = root / STATE_DIR_NAME / "tmp" / directory.relative_to(root)

    if not dry_run:
        temp_dir.mkdir(parents=True, exist_ok=True)

    if archive_dir.exists():
        logger.log(f"[convert-skip] ./{directory.relative_to(root)} (source archive already exists at ./{archive_dir.relative_to(root)})")
        summary["convert_skipped"] += 1
        return

    converted_outputs: list[tuple[Path, Path]] = []
    try:
        for scanned, metadata in sorted(zip(files, release_metadata, strict=True), key=lambda pair: str(pair[0].relative_path)):
            if metadata.track_number is None:
                logger.log(f"[convert-skip] ./{scanned.relative_path} (missing track number)")
                summary["convert_skipped"] += 1
                return
            output_name = _release_output_name(metadata, scanned.probe, scanned.path.suffix, multi_disc)
            temp_output = temp_dir / f"{Path(output_name).stem}.tmp.m4a"
            final_output = target_dir / output_name
            if final_output.exists():
                valid, reason = validate_alac_output(final_output)
                if valid:
                    logger.log(f"[convert-skip] ./{scanned.relative_path} -> ./{final_output.relative_to(root)} (valid ALAC already exists)")
                    summary["convert_skipped"] += 1
                    continue
                logger.log(f"[convert-fail] ./{scanned.relative_path} (existing output invalid: {reason})")
                _quarantine_file(root, scanned.path, "convert", reason or "existing output invalid", logger, dry_run, summary)
                return
            success, reason = _run_ffmpeg_convert(scanned.path, temp_output, artwork)
            if not success:
                _quarantine_file(root, scanned.path, "convert", reason or "conversion failed", logger, dry_run, summary)
                return
            valid, reason = validate_alac_output(temp_output)
            if not valid:
                _quarantine_file(root, scanned.path, "convert", reason or "converted output failed validation", logger, dry_run, summary)
                if not dry_run and temp_output.exists():
                    temp_output.unlink()
                return
            converted_outputs.append((temp_output, final_output))

        logger.log(f"[preserve-source] ./{directory.relative_to(root)} -> ./{archive_dir.relative_to(root)}")
        if not dry_run:
            archive_dir.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(directory), str(archive_dir))
        for temp_output, final_output in converted_outputs:
            logger.log(f"[convert] ./{directory.relative_to(root)} -> ./{final_output.relative_to(root)}")
            if not dry_run:
                final_output.parent.mkdir(parents=True, exist_ok=True)
                shutil.move(str(temp_output), str(final_output))
            summary["converted_files"] += 1
        summary["preserved_source_units"] += 1
    finally:
        if not dry_run and temp_dir.exists():
            shutil.rmtree(temp_dir, ignore_errors=True)


def _convert_single_file(root: Path, scanned: ScannedFile, logger, dry_run: bool, summary: dict[str, int]) -> None:
    metadata = normalize_metadata(scanned.probe.metadata)
    if not metadata.artist or not metadata.title:
        logger.log(f"[convert-skip] ./{scanned.relative_path} (insufficient metadata for single conversion)")
        summary["convert_skipped"] += 1
        return
    quality_tag = codec_quality_tag(scanned.probe)
    year_prefix = f"[{metadata.year}] " if metadata.year else ""
    output_name = f"{year_prefix}{metadata.artist} - {metadata.title} [{quality_tag}].m4a"
    target = root / metadata.artist / output_name
    archive_target = root / metadata.artist / ORIGINAL_SOURCE_DIR_NAME / scanned.path.name
    temp_output = root / STATE_DIR_NAME / "tmp" / f"{scanned.path.stem}.tmp.m4a"
    artwork = _select_artwork(scanned.path.parent)
    if archive_target.exists():
        logger.log(f"[convert-skip] ./{scanned.relative_path} (source archive already exists at ./{archive_target.relative_to(root)})")
        summary["convert_skipped"] += 1
        return
    if target.exists():
        valid, reason = validate_alac_output(target)
        if valid:
            logger.log(f"[convert-skip] ./{scanned.relative_path} -> ./{target.relative_to(root)} (valid ALAC already exists)")
            summary["convert_skipped"] += 1
            return
        _quarantine_file(root, scanned.path, "convert", reason or "existing output invalid", logger, dry_run, summary)
        return
    success, reason = _run_ffmpeg_convert(scanned.path, temp_output, artwork)
    if not success:
        _quarantine_file(root, scanned.path, "convert", reason or "conversion failed", logger, dry_run, summary)
        return
    valid, reason = validate_alac_output(temp_output)
    if not valid:
        _quarantine_file(root, scanned.path, "convert", reason or "converted output failed validation", logger, dry_run, summary)
        if not dry_run and temp_output.exists():
            temp_output.unlink()
        return
    logger.log(f"[convert] ./{scanned.relative_path} -> ./{target.relative_to(root)}")
    logger.log(f"[preserve-source] ./{scanned.relative_path} -> ./{archive_target.relative_to(root)}")
    if not dry_run:
        target.parent.mkdir(parents=True, exist_ok=True)
        archive_target.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(temp_output), str(target))
        shutil.move(str(scanned.path), str(archive_target))
    summary["converted_files"] += 1
    summary["preserved_source_units"] += 1


def _run_ffmpeg_convert(source: Path, destination: Path, artwork: Path | None) -> tuple[bool, str | None]:
    destination.parent.mkdir(parents=True, exist_ok=True)
    command = [
        "ffmpeg",
        "-hide_banner",
        "-loglevel",
        "error",
        "-y",
        "-i",
        str(source),
    ]
    if artwork:
        command.extend(["-i", str(artwork)])
    command.extend(["-map", "0:a:0", "-map_metadata", "0"])
    if artwork:
        command.extend(["-map", "1:v:0", "-disposition:v:0", "attached_pic"])
    else:
        command.extend(["-map", "0:v?", "-disposition:v:0", "attached_pic"])
    command.extend(["-c:a", "alac", str(destination)])
    completed = subprocess.run(command, check=False, capture_output=True, text=True)
    if completed.returncode == 0:
        return True, None
    return False, (completed.stderr or "ffmpeg conversion failed").strip()


def _run_ffmpeg_segment_convert(
    source: Path,
    destination: Path,
    artwork: Path | None,
    start_seconds: float,
    duration_seconds: float | None,
    metadata_map: dict[str, str],
) -> tuple[bool, str | None]:
    destination.parent.mkdir(parents=True, exist_ok=True)
    command = [
        "ffmpeg",
        "-hide_banner",
        "-loglevel",
        "error",
        "-y",
        "-i",
        str(source),
    ]
    if artwork:
        command.extend(["-i", str(artwork)])
    command.extend(["-ss", _format_seconds(start_seconds)])
    if duration_seconds is not None:
        command.extend(["-t", _format_seconds(duration_seconds)])
    command.extend(["-map", "0:a:0", "-map_metadata", "-1"])
    for key, value in metadata_map.items():
        command.extend(["-metadata", f"{key}={value}"])
    if artwork:
        command.extend(["-map", "1:v:0", "-disposition:v:0", "attached_pic"])
    else:
        command.extend(["-map", "0:v?", "-disposition:v:0", "attached_pic"])
    command.extend(["-c:a", "alac", str(destination)])
    completed = subprocess.run(command, check=False, capture_output=True, text=True)
    if completed.returncode == 0:
        return True, None
    return False, (completed.stderr or "ffmpeg segment conversion failed").strip()


def _release_destination_root(metadata, quality_tag: str) -> Path:
    year_prefix = f"[{metadata.year}] " if metadata.year else ""
    if metadata.is_various_artists:
        return Path(f"{year_prefix}VA - {metadata.album} [{quality_tag}]")
    return Path(metadata.routing_artist or "Unknown Artist", f"{year_prefix}{metadata.album} [{quality_tag}]")


def _archive_release_dir_name(metadata) -> str:
    year_prefix = f"[{metadata.year}] " if metadata.year else ""
    return f"{year_prefix}{metadata.album}"


def _release_output_name(metadata, probe: ProbeResult, original_suffix: str, multi_disc: bool) -> str:
    token = build_track_token(metadata.track_number or 0, metadata.disc_number, multi_disc)
    title_prefix = f"{metadata.artist} - " if metadata.is_various_artists and metadata.artist else ""
    quality = codec_quality_tag(probe)
    return f"{token} {title_prefix}{metadata.title} [{quality}].m4a"


def _select_artwork(directory: Path) -> Path | None:
    for candidate in ARTWORK_PRIORITY:
        path = directory / candidate
        if path.exists():
            return path
    return None


def _quarantine_file(
    root: Path,
    source: Path,
    stage: str,
    reason: str,
    logger,
    dry_run: bool,
    summary: dict[str, int],
) -> None:
    destination = root / QUARANTINE_DIR_NAME / source.relative_to(root)
    logger.log(f"[quarantine] ./{source.relative_to(root)} -> ./{destination.relative_to(root)} ({stage}: {reason})")
    if not dry_run:
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(source), str(destination))
    summary["quarantined_files"] += 1


def _cue_file_in_dir(directory: Path) -> Path | None:
    matches = sorted(directory.glob("*.cue"))
    return matches[0] if matches else None


def _convert_cue_release_unit(
    root: Path,
    directory: Path,
    cue_path: Path,
    source_file: ScannedFile,
    logger,
    dry_run: bool,
    summary: dict[str, int],
) -> bool:
    album_meta, track_entries = _parse_cue_file(cue_path)
    if not track_entries:
        logger.log(f"[cue-fail] ./{cue_path.relative_to(root)} (no track entries found)")
        summary["cue_split_failures"] += 1
        return True
    fallback_tags = source_file.probe.metadata
    normalized_tracks = [
        normalize_metadata(
            {
                "artist": track.get("artist") or fallback_tags.get("artist", ""),
                "album_artist": album_meta.get("album_artist") or fallback_tags.get("album_artist", ""),
                "albumartist": album_meta.get("album_artist") or fallback_tags.get("albumartist", ""),
                "album": album_meta.get("album") or fallback_tags.get("album", ""),
                "title": track.get("title", ""),
                "date": album_meta.get("date") or fallback_tags.get("date", ""),
                "year": album_meta.get("date") or fallback_tags.get("year", ""),
                "genre": fallback_tags.get("genre", ""),
                "track": str(track.get("track_number", "")),
                "disc": "1",
            }
        )
        for track in track_entries
    ]
    if any(metadata.album is None or metadata.title is None or (metadata.album_artist is None and metadata.artist is None) for metadata in normalized_tracks):
        logger.log(f"[cue-fail] ./{cue_path.relative_to(root)} (insufficient cue metadata for routing)")
        summary["cue_split_failures"] += 1
        return True

    first = normalized_tracks[0]
    quality_tag = codec_quality_tag(source_file.probe)
    target_dir = root / _release_destination_root(first, quality_tag)
    archive_dir = root / (first.routing_artist or "Unknown Artist") / ORIGINAL_SOURCE_DIR_NAME / _archive_release_dir_name(first)
    artwork = _select_artwork(directory)
    temp_dir = root / STATE_DIR_NAME / "tmp" / directory.relative_to(root)
    if archive_dir.exists():
        logger.log(f"[convert-skip] ./{directory.relative_to(root)} (source archive already exists at ./{archive_dir.relative_to(root)})")
        summary["convert_skipped"] += 1
        return True
    if not dry_run:
        temp_dir.mkdir(parents=True, exist_ok=True)
    converted_outputs: list[tuple[Path, Path]] = []
    try:
        total_tracks = len(track_entries)
        for index, (track, metadata) in enumerate(zip(track_entries, normalized_tracks, strict=True)):
            start = float(track["index_seconds"])
            duration = None
            if index + 1 < total_tracks:
                duration = float(track_entries[index + 1]["index_seconds"]) - start
            output_name = _release_output_name(metadata, source_file.probe, source_file.path.suffix, False)
            temp_output = temp_dir / f"{Path(output_name).stem}.tmp.m4a"
            final_output = target_dir / output_name
            if final_output.exists():
                valid, reason = validate_alac_output(final_output)
                if valid:
                    logger.log(f"[convert-skip] ./{cue_path.relative_to(root)} -> ./{final_output.relative_to(root)} (valid ALAC already exists)")
                    summary["convert_skipped"] += 1
                    continue
                logger.log(f"[cue-fail] ./{cue_path.relative_to(root)} (existing output invalid: {reason})")
                summary["cue_split_failures"] += 1
                return True
            metadata_map = {
                "artist": metadata.artist or "",
                "album_artist": metadata.album_artist or metadata.artist or "",
                "album": metadata.album or "",
                "title": metadata.title or "",
                "track": f"{metadata.track_number or track['track_number']}/{total_tracks}",
                "disc": "1/1",
                "date": metadata.year or "",
            }
            success, reason = _run_ffmpeg_segment_convert(
                source_file.path,
                temp_output,
                artwork,
                start,
                duration,
                metadata_map,
            )
            if not success:
                logger.log(f"[cue-fail] ./{cue_path.relative_to(root)} ({reason or 'cue split conversion failed'})")
                summary["cue_split_failures"] += 1
                return True
            valid, reason = validate_alac_output(temp_output)
            if not valid:
                logger.log(f"[cue-fail] ./{cue_path.relative_to(root)} ({reason or 'cue split output failed validation'})")
                summary["cue_split_failures"] += 1
                if not dry_run and temp_output.exists():
                    temp_output.unlink()
                return True
            converted_outputs.append((temp_output, final_output))

        logger.log(f"[preserve-source] ./{directory.relative_to(root)} -> ./{archive_dir.relative_to(root)}")
        if not dry_run:
            archive_dir.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(directory), str(archive_dir))
        for temp_output, final_output in converted_outputs:
            logger.log(f"[convert] ./{cue_path.relative_to(root)} -> ./{final_output.relative_to(root)}")
            if not dry_run:
                final_output.parent.mkdir(parents=True, exist_ok=True)
                shutil.move(str(temp_output), str(final_output))
            summary["converted_files"] += 1
        summary["preserved_source_units"] += 1
    finally:
        if not dry_run and temp_dir.exists():
            shutil.rmtree(temp_dir, ignore_errors=True)
    return True


def _parse_cue_file(cue_path: Path) -> tuple[dict[str, str], list[dict[str, object]]]:
    album_artist = ""
    album_title = ""
    album_date = ""
    tracks: list[dict[str, object]] = []
    current_track: dict[str, object] | None = None
    for raw_line in cue_path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw_line.strip()
        if not line:
            continue
        if line.upper().startswith("REM DATE "):
            album_date = _cue_unquote(line[9:])
            continue
        match = re.match(r"^(PERFORMER|TITLE)\s+(.+)$", line, re.IGNORECASE)
        if current_track is None and match:
            key = match.group(1).upper()
            value = _cue_unquote(match.group(2))
            if key == "PERFORMER":
                album_artist = value
            else:
                album_title = value
            continue
        track_match = re.match(r"^TRACK\s+(\d+)\s+AUDIO$", line, re.IGNORECASE)
        if track_match:
            current_track = {"track_number": int(track_match.group(1))}
            tracks.append(current_track)
            continue
        if current_track is None:
            continue
        field_match = re.match(r"^(TITLE|PERFORMER)\s+(.+)$", line, re.IGNORECASE)
        if field_match:
            current_track[field_match.group(1).lower()] = _cue_unquote(field_match.group(2))
            continue
        index_match = re.match(r"^INDEX\s+01\s+(\d{2}:\d{2}:\d{2})$", line, re.IGNORECASE)
        if index_match:
            current_track["index_seconds"] = _cue_time_to_seconds(index_match.group(1))
    return {"album_artist": album_artist, "album": album_title, "date": album_date}, [track for track in tracks if "index_seconds" in track]


def _cue_unquote(value: str) -> str:
    stripped = value.strip()
    if stripped.startswith('"') and stripped.endswith('"') and len(stripped) >= 2:
        return stripped[1:-1]
    return stripped


def _cue_time_to_seconds(value: str) -> float:
    minutes_str, seconds_str, frames_str = value.split(":")
    minutes = int(minutes_str, 10)
    seconds = int(seconds_str, 10)
    frames = int(frames_str, 10)
    return (minutes * 60) + seconds + (frames / 75.0)


def _format_seconds(value: float) -> str:
    return f"{value:.3f}"
