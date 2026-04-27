from __future__ import annotations

import re
import shutil
import subprocess
from collections import defaultdict
from dataclasses import replace
from pathlib import Path

from .constants import ARTWORK_PRIORITY, ORIGINAL_SOURCE_DIR_NAME, QUARANTINE_DIR_NAME, SIDECAR_EXTENSIONS, STATE_DIR_NAME
from .models import PlannedOperation, ScannedFile
from .normalize import album_quality_suffix, apply_album_group_consensus, build_track_token, codec_quality_tag, normalize_metadata
from .probe import ProbeResult, validate_alac_output, validate_audio_decode

_DISC_DIR_RE = re.compile(r"^(disc|cd)\s*0*\d+$", re.IGNORECASE)


def convert_units(root: Path, scanned_files: list[ScannedFile], logger, dry_run: bool) -> dict[str, int]:
    summary: dict[str, int] = defaultdict(int)
    release_units: dict[Path, list[ScannedFile]] = defaultdict(list)
    loose_units: list[ScannedFile] = []

    for scanned in scanned_files:
        if scanned.probe.status != "audio" or scanned.probe.audio_kind != "lossless":
            continue
        unit_root = _convert_unit_root(root, scanned.path)
        if unit_root == root:
            loose_units.append(scanned)
        else:
            release_units[unit_root].append(scanned)

    for directory in sorted(release_units):
        _convert_release_unit(root, directory, release_units[directory], logger, dry_run, summary)
    for scanned in sorted(loose_units, key=lambda item: str(item.relative_path)):
        _convert_single_file(root, scanned, logger, dry_run, summary)
    return dict(summary)


def _convert_release_unit(root: Path, directory: Path, files: list[ScannedFile], logger, dry_run: bool, summary: dict[str, int]) -> None:
    cue_path = _cue_file_in_dir(directory)
    if cue_path is not None:
        if _convert_cue_release_unit(root, directory, cue_path, files, logger, dry_run, summary):
            return

    release_metadata = _release_metadata_for_unit(directory, files)
    if not release_metadata or any(metadata.album is None or metadata.title is None or (metadata.album_artist is None and metadata.artist is None) for metadata in release_metadata):
        _convert_unresolved_release_unit(root, directory, files, logger, dry_run, summary, reason="insufficient metadata for release conversion")
        return
    first = release_metadata[0]
    if any(
        metadata.album != first.album
        or metadata.routing_artist != first.routing_artist
        or metadata.year != first.year
        or metadata.is_various_artists != first.is_various_artists
        for metadata in release_metadata
    ):
        _convert_unresolved_release_unit(root, directory, files, logger, dry_run, summary, reason="mixed release metadata")
        return
    discs = {metadata.disc_number or 1 for metadata in release_metadata}
    multi_disc = len(discs) > 1 or any(value > 1 for value in discs)
    quality_suffix = album_quality_suffix([codec_quality_tag(scanned.probe) for scanned in files])
    release_destination = _release_destination_root(first, quality_suffix)
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
    disc_total = len({metadata.disc_number for metadata in release_metadata if metadata.disc_number is not None}) or 1
    track_totals_by_disc = _track_totals_by_disc(release_metadata)
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
            success, reason = _run_ffmpeg_convert(
                scanned.path,
                temp_output,
                artwork,
                metadata_overrides=_release_metadata_overrides(
                    metadata,
                    disc_total=disc_total,
                    track_total=track_totals_by_disc.get(metadata.disc_number or 1),
                ),
            )
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


def _convert_unresolved_release_unit(
    root: Path,
    directory: Path,
    files: list[ScannedFile],
    logger,
    dry_run: bool,
    summary: dict[str, int],
    *,
    reason: str,
) -> None:
    logger.log(f"[convert-unresolved] ./{directory.relative_to(root)} ({reason})")
    artwork = _select_artwork(directory)
    archive_dir = directory / ORIGINAL_SOURCE_DIR_NAME
    temp_dir = root / STATE_DIR_NAME / "tmp" / directory.relative_to(root)
    if archive_dir.exists():
        logger.log(f"[convert-skip] ./{directory.relative_to(root)} (source archive already exists at ./{archive_dir.relative_to(root)})")
        summary["convert_skipped"] += 1
        return
    if not dry_run:
        temp_dir.mkdir(parents=True, exist_ok=True)
    converted_outputs: list[tuple[Path, Path]] = []
    try:
        for scanned in sorted(files, key=lambda item: str(item.relative_path)):
            temp_output = temp_dir / f"{scanned.path.stem}.tmp.m4a"
            final_output = scanned.path.with_suffix(".m4a")
            if final_output.exists():
                valid, existing_reason = validate_alac_output(final_output)
                if valid:
                    logger.log(f"[convert-skip] ./{scanned.relative_path} -> ./{final_output.relative_to(root)} (valid ALAC already exists)")
                    summary["convert_skipped"] += 1
                    continue
                _quarantine_file(root, scanned.path, "convert", existing_reason or "existing output invalid", logger, dry_run, summary)
                return
            success, convert_reason = _run_ffmpeg_convert(scanned.path, temp_output, artwork)
            if not success:
                _quarantine_file(root, scanned.path, "convert", convert_reason or "conversion failed", logger, dry_run, summary)
                return
            valid, validate_reason = validate_alac_output(temp_output)
            if not valid:
                _quarantine_file(root, scanned.path, "convert", validate_reason or "converted output failed validation", logger, dry_run, summary)
                if not dry_run and temp_output.exists():
                    temp_output.unlink()
                return
            converted_outputs.append((temp_output, final_output))

        logger.log(f"[preserve-source] ./{directory.relative_to(root)} -> ./{archive_dir.relative_to(root)}")
        if not dry_run:
            archive_dir.mkdir(parents=True, exist_ok=True)
            for scanned in sorted(files, key=lambda item: str(item.relative_path)):
                archived = archive_dir / scanned.path.relative_to(directory)
                archived.parent.mkdir(parents=True, exist_ok=True)
                shutil.move(str(scanned.path), str(archived))
        for temp_output, final_output in converted_outputs:
            logger.log(f"[convert] ./{final_output.with_suffix('.flac').relative_to(root)} -> ./{final_output.relative_to(root)}")
            if not dry_run:
                final_output.parent.mkdir(parents=True, exist_ok=True)
                shutil.move(str(temp_output), str(final_output))
            summary["converted_files"] += 1
        summary["preserved_source_units"] += 1
    finally:
        if not dry_run and temp_dir.exists():
            shutil.rmtree(temp_dir, ignore_errors=True)


def _run_ffmpeg_convert(
    source: Path,
    destination: Path,
    artwork: Path | None,
    metadata_overrides: dict[str, str] | None = None,
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
    command.extend(["-map", "0:a:0", "-map_metadata", "0"])
    for key, value in (metadata_overrides or {}).items():
        command.extend(["-metadata", f"{key}={value}"])
    if artwork:
        command.extend(["-map", "1:v:0", "-disposition:v:0", "attached_pic"])
    else:
        command.extend(["-map", "0:v?", "-disposition:v:0", "attached_pic"])
    command.extend(["-c:a", "alac", "-c:v", "mjpeg", str(destination)])
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
    command.extend(["-c:a", "alac", "-c:v", "mjpeg", str(destination)])
    completed = subprocess.run(command, check=False, capture_output=True, text=True)
    if completed.returncode == 0:
        return True, None
    return False, (completed.stderr or "ffmpeg segment conversion failed").strip()


def _release_destination_root(metadata, quality_suffix: str) -> Path:
    year_prefix = f"[{metadata.year}] " if metadata.year else ""
    if metadata.is_various_artists:
        return Path(f"{year_prefix}VA - {metadata.album} {quality_suffix}")
    return Path(metadata.routing_artist or "Unknown Artist", f"{year_prefix}{metadata.album} {quality_suffix}")


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
    files: list[ScannedFile],
    logger,
    dry_run: bool,
    summary: dict[str, int],
) -> bool:
    album_meta, track_entries = _parse_cue_file(cue_path)
    if not track_entries:
        logger.log(f"[cue-fail] ./{cue_path.relative_to(root)} (no track entries found)")
        summary["cue_split_failures"] += 1
        return True
    source_files = {scanned.path.name.casefold(): scanned for scanned in files}
    fallback_tags = files[0].probe.metadata if files else {}
    normalized_tracks = apply_album_group_consensus([
        normalize_metadata(
            {
                "artist": track.get("artist") or source_files.get(str(track.get("source_file") or "").casefold(), files[0]).probe.metadata.get("artist", "") if files else fallback_tags.get("artist", ""),
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
    ])
    routable = not any(metadata.album is None or metadata.title is None or (metadata.album_artist is None and metadata.artist is None) for metadata in normalized_tracks)
    first_source = source_files.get(str(track_entries[0].get("source_file") or "").casefold()) if track_entries else None
    if first_source is None and files:
        first_source = files[0]
    if first_source is None:
        logger.log(f"[cue-fail] ./{cue_path.relative_to(root)} (no source audio matched cue entries)")
        summary["cue_split_failures"] += 1
        return True
    first = normalized_tracks[0]
    quality_suffix = album_quality_suffix([codec_quality_tag(source.probe) for source in files])
    target_dir = root / _release_destination_root(first, quality_suffix) if routable else directory
    archive_dir = (root / (first.routing_artist or "Unknown Artist") / ORIGINAL_SOURCE_DIR_NAME / _archive_release_dir_name(first)) if routable else (directory / ORIGINAL_SOURCE_DIR_NAME)
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
            source_file = source_files.get(str(track.get("source_file") or "").casefold())
            if source_file is None:
                logger.log(f"[cue-fail] ./{cue_path.relative_to(root)} (missing source file {track.get('source_file')})")
                summary["cue_split_failures"] += 1
                return True
            start = float(track["index_seconds"])
            duration = None
            if index + 1 < total_tracks and track_entries[index + 1].get("source_file") == track.get("source_file"):
                duration = float(track_entries[index + 1]["index_seconds"]) - start
            inferred_disc = _disc_number_from_path(directory, source_file.path) or metadata.disc_number
            effective_metadata = replace(metadata, disc_number=inferred_disc)
            output_name = _release_output_name(
                effective_metadata,
                source_file.probe,
                source_file.path.suffix,
                inferred_disc is not None and inferred_disc > 1 or len({(_disc_number_from_path(directory, source.path) or 1) for source in files}) > 1,
            ) if routable else _cue_unresolved_output_name(track, metadata)
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
            archive_dir.mkdir(parents=True, exist_ok=True)
            for source_file in sorted(files, key=lambda item: str(item.relative_path)):
                archived = archive_dir / source_file.path.relative_to(directory)
                archived.parent.mkdir(parents=True, exist_ok=True)
                shutil.move(str(source_file.path), str(archived))
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
    current_file = ""
    for raw_line in cue_path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw_line.strip()
        if not line:
            continue
        file_match = re.match(r'^FILE\s+"(.+)"\s+\S+$', line, re.IGNORECASE)
        if file_match:
            current_file = file_match.group(1)
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
            current_track = {"track_number": int(track_match.group(1)), "source_file": current_file}
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


def _cue_unresolved_output_name(track: dict[str, object], metadata) -> str:
    track_number = str(track.get("track_number") or metadata.track_number or "0")
    title = metadata.title or f"Track {track_number}"
    return f"[{track_number}] {title}.m4a"


def _convert_unit_root(root: Path, path: Path) -> Path:
    parent = path.parent
    if parent == root:
        return root
    if _DISC_DIR_RE.match(parent.name) and parent.parent != root:
        return parent.parent
    return parent


def _release_metadata_for_unit(directory: Path, files: list[ScannedFile]):
    metadata_list = []
    for scanned in files:
        metadata = normalize_metadata(scanned.probe.metadata)
        inferred_disc = _disc_number_from_path(directory, scanned.path)
        if inferred_disc is not None and metadata.disc_number is None:
            metadata = replace(metadata, disc_number=inferred_disc)
        metadata_list.append(metadata)
    return apply_album_group_consensus(metadata_list)


def _disc_number_from_path(directory: Path, path: Path) -> int | None:
    try:
        relative = path.relative_to(directory)
    except ValueError:
        return None
    if not relative.parts:
        return None
    first_part = relative.parts[0]
    if not _DISC_DIR_RE.match(first_part):
        return None
    digits = "".join(character for character in first_part if character.isdigit())
    return int(digits, 10) if digits else None


def _track_totals_by_disc(metadata_list) -> dict[int, int]:
    totals: dict[int, int] = defaultdict(int)
    for metadata in metadata_list:
        totals[metadata.disc_number or 1] += 1
    return dict(totals)


def _release_metadata_overrides(metadata, *, disc_total: int, track_total: int | None) -> dict[str, str]:
    overrides: dict[str, str] = {}
    if metadata.artist:
        overrides["artist"] = metadata.artist
    if metadata.album_artist:
        overrides["album_artist"] = metadata.album_artist
    if metadata.album:
        overrides["album"] = metadata.album
    if metadata.title:
        overrides["title"] = metadata.title
    if metadata.year:
        overrides["date"] = metadata.year
    if metadata.genre:
        overrides["genre"] = metadata.genre
    if metadata.track_number is not None:
        overrides["track"] = f"{metadata.track_number}/{track_total}" if track_total else str(metadata.track_number)
    if metadata.disc_number is not None:
        overrides["disc"] = f"{metadata.disc_number}/{disc_total}" if disc_total > 1 else str(metadata.disc_number)
    return overrides
