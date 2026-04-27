from __future__ import annotations

import os
import shutil
import sys
from pathlib import Path

from .constants import (
    LOSSY_QUALITY_LABELS,
    MISSING_TAG_MANIFEST_NAME,
    NOT_AUDIO_DIR_NAME,
    ORIGINAL_SOURCE_DIR_NAME,
    RUNS_DIR_NAME,
    STATE_DIR_NAME,
    TEMP_DIR_NAMES,
    is_managed_dir_name,
    state_path,
)
from .convert import convert_units
from .executor import RunLogger, delete_tree, execute_plan, remove_empty_dirs
from .models import ProbeResult
from .planner import build_sort_plan
from .probe import probe_file
from .retag import apply_retag_review, build_retag_review
from .scan import iter_scanned_files
from .undo import command_undo as _command_undo


def command_audit(root: Path) -> int:
    scanned = iter_scanned_files(root)
    plan = build_sort_plan(root, scanned)
    logger = RunLogger(root, "audit", dry_run=True)
    execute_plan(root, plan, logger, dry_run=True)
    _log_summary(logger, plan.summary, dry_run=True)
    return 0


def command_sort(root: Path, dry_run: bool = False) -> int:
    scanned = iter_scanned_files(root)
    plan = build_sort_plan(root, scanned)
    logger = RunLogger(root, "sort", dry_run=dry_run)
    execute_plan(root, plan, logger, dry_run=dry_run)
    removed = remove_empty_dirs(root, logger, dry_run=dry_run)
    if removed:
        plan.bump("empty_dirs_removed", removed)
    _log_summary(logger, plan.summary, dry_run=dry_run)
    logger.persist()
    return 0


def command_convert(root: Path, dry_run: bool = False) -> int:
    scanned = iter_scanned_files(root)
    logger = RunLogger(root, "convert", dry_run=dry_run)
    summary = convert_units(root, scanned, logger, dry_run)
    _log_summary(logger, summary, dry_run=dry_run)
    logger.persist()
    return 0


def command_both(root: Path, dry_run: bool = False) -> int:
    convert_code = command_convert(root, dry_run=dry_run)
    if convert_code != 0:
        return convert_code
    return command_sort(root, dry_run=dry_run)


def command_audio_scrape(
    root: Path,
    source: Path,
    move: bool = False,
    dry_run: bool = False,
    bucket_by_format: bool = False,
) -> int:
    root = root.resolve()
    source = source.resolve()
    error = _validate_audio_scrape_paths(root, source)
    if error is not None:
        print(f"error: {error}", file=sys.stderr, flush=True)
        return 1

    logger = RunLogger(root, "audio-scrape", dry_run=dry_run)
    files = list(_iter_audio_scrape_files(source))
    probe_cache: dict[Path, ProbeResult] = {}
    audio_count = 0
    sidecar_count = 0
    sidecar_bucket_roots: dict[Path, set[str]] = {}

    if bucket_by_format:
        for path in files:
            if _is_audio_scrape_sidecar(path):
                continue
            probed = probe_file(path)
            probe_cache[path] = probed
            if probed.status != "audio":
                continue
            bucket_name = _audio_scrape_bucket_name(path, probed)
            parent = path.parent
            while True:
                sidecar_bucket_roots.setdefault(parent, set()).add(bucket_name)
                if parent == source:
                    break
                parent = parent.parent

    reserved_destinations: set[Path] = set()
    for path in files:
        relative = path.relative_to(source)
        if path.suffix.casefold() in {".cue", ".log", ".jpg", ".jpeg", ".png"}:
            destinations = _audio_scrape_sidecar_destinations(
                root=root,
                source=source,
                path=path,
                bucket_by_format=bucket_by_format,
                sidecar_bucket_roots=sidecar_bucket_roots,
                reserved_destinations=reserved_destinations,
            )
            if not destinations:
                continue
            for destination in destinations:
                if _same_resolved_path(path, destination):
                    logger.log(f"[skip] {path} (source and destination resolve to the same path)")
                    continue
                logger.log(f"[{'move' if move else 'copy'}] {path} -> {destination} (related sidecar)")
                if not dry_run:
                    _transfer_audio_scrape_file(path, destination, move=(move and len(destinations) == 1))
                sidecar_count += 1
            if move and len(destinations) > 1 and not dry_run and path.exists():
                path.unlink()
            continue
        probed = probe_cache.get(path)
        if probed is None:
            probed = probe_file(path)
            probe_cache[path] = probed
        if probed.status != "audio":
            continue
        destination = _audio_scrape_audio_destination(
            root=root,
            source=source,
            path=path,
            probe=probed,
            bucket_by_format=bucket_by_format,
            reserved_destinations=reserved_destinations,
        )
        if _same_resolved_path(path, destination):
            logger.log(f"[skip] {path} (source and destination resolve to the same path)")
            continue
        logger.log(f"[{'move' if move else 'copy'}] {path} -> {destination} (audio scrape)")
        if not dry_run:
            _transfer_audio_scrape_file(path, destination, move=move)
        audio_count += 1
    removed = 0
    if move:
        removed = remove_empty_dirs(source, logger, dry_run)
    logger.log(f"audio files {'moved' if move else 'copied'}={audio_count}")
    logger.log(f"sidecars {'moved' if move else 'copied'}={sidecar_count}")
    if move:
        logger.log(f"empty dirs removed={removed}")
    logger.persist()
    return 0


def command_delete_empty_dirs(root: Path, dry_run: bool = False) -> int:
    logger = RunLogger(root, "delete-empty-dirs", dry_run=dry_run)
    removed = remove_empty_dirs(root, logger, dry_run)
    logger.log(f"empty dirs removed={removed}")
    logger.persist()
    return 0


def command_delete_source(root: Path, dry_run: bool = False, yes: bool = False) -> int:
    logger = RunLogger(root, "delete-source", dry_run=dry_run)
    targets = sorted(path for path in root.rglob(ORIGINAL_SOURCE_DIR_NAME) if path.is_dir())
    not_audio = root / NOT_AUDIO_DIR_NAME
    if not_audio.is_dir():
        targets.append(not_audio)
    for target in targets:
        if not yes:
            _log_delete_source_audit(root, target, logger)
        if not yes and not dry_run:
            reply = input(f"Delete {_relative_or_absolute(root, target)}? [y/N]: ").strip().casefold()
            if reply not in {"y", "yes"}:
                logger.log(f"[skip] {_relative_or_absolute(root, target)}")
                continue
        logger.log(f"[delete] {_relative_or_absolute(root, target)}")
        if not dry_run:
            shutil.rmtree(target)
        _remove_empty_ancestor_dirs(root, target.parent, logger, dry_run)
    logger.persist()
    return 0


def command_retag_review(
    root: Path,
    *,
    provider: str = "musicbrainz",
    manifest_path: Path | None = None,
    acoustid_client: str | None = None,
) -> int:
    logger = RunLogger(root, "retag", dry_run=False)
    code = build_retag_review(
        root,
        logger,
        provider=provider,
        manifest_path=manifest_path,
        acoustid_client=acoustid_client,
    )
    logger.persist()
    return code


def command_retag_apply(root: Path, *, manifest_path: Path | None = None, dry_run: bool = False) -> int:
    logger = RunLogger(root, "retag-apply", dry_run=dry_run)
    code = apply_retag_review(root, logger, manifest_path=manifest_path, dry_run=dry_run)
    logger.persist()
    return code


def command_undo(root: Path, *, dry_run: bool = False, run_id: str | None = None) -> int:
    return _command_undo(root, dry_run=dry_run, run_id=run_id)


def _log_summary(logger: RunLogger, summary: dict[str, int], dry_run: bool) -> None:
    logger.log("")
    logger.log("Run summary:")
    for key in sorted(summary):
        logger.log(f"  {key}: {summary[key]}")
    if dry_run:
        logger.log("  dry_run: 1")


def _log_delete_source_audit(root: Path, target: Path, logger: RunLogger) -> None:
    entries = sorted(target.rglob("*"))
    logger.log(f"[audit] {_relative_or_absolute(root, target)}")
    if not entries:
        logger.log("  (empty)")
        return
    for entry in entries:
        suffix = "/" if entry.is_dir() else ""
        logger.log(f"  {entry.relative_to(target)}{suffix}")


def _relative_or_absolute(root: Path, value: Path) -> str:
    try:
        return f"./{value.resolve().relative_to(root.resolve())}"
    except ValueError:
        return str(value)


def _validate_audio_scrape_paths(root: Path, source: Path) -> str | None:
    if not source.exists():
        return f"audio-scrape source does not exist: {source}"
    if not source.is_dir():
        return f"audio-scrape source is not a directory: {source}"
    if root == source or root in source.parents or source in root.parents:
        return "audio-scrape source must not overlap --destination; use a separate source directory"
    return None


def _remove_empty_ancestor_dirs(root: Path, start: Path, logger: RunLogger, dry_run: bool) -> int:
    removed = 0
    root = root.resolve()
    current = start.resolve()
    while current != root:
        try:
            next(current.iterdir())
            break
        except StopIteration:
            logger.log(f"[delete-empty-dirs] {_relative_or_absolute(root, current)}")
            if not dry_run:
                current.rmdir()
            removed += 1
            current = current.parent
    return removed


def _iter_audio_scrape_files(source: Path):
    for current_root, dirnames, filenames in os.walk(source):
        current_path = Path(current_root)
        dirnames[:] = [
            dirname
            for dirname in sorted(dirnames)
            if not _should_prune_audio_scrape_dir(current_path / dirname)
        ]
        for filename in sorted(filenames):
            path = current_path / filename
            if path.is_file():
                yield path


def _should_prune_audio_scrape_dir(path: Path) -> bool:
    name = path.name
    if name == ORIGINAL_SOURCE_DIR_NAME:
        return True
    if is_managed_dir_name(name):
        return True
    if name in TEMP_DIR_NAMES:
        return True
    if name.startswith("."):
        return True
    return False


def _same_resolved_path(left: Path, right: Path) -> bool:
    return left.resolve() == right.resolve()


def _is_audio_scrape_sidecar(path: Path) -> bool:
    return path.suffix.casefold() in {".cue", ".log", ".jpg", ".jpeg", ".png"}


def _audio_scrape_audio_destination(
    *,
    root: Path,
    source: Path,
    path: Path,
    probe: ProbeResult,
    bucket_by_format: bool,
    reserved_destinations: set[Path],
) -> Path:
    if not bucket_by_format:
        destination = root / path.relative_to(source)
    else:
        bucket_name = _audio_scrape_bucket_name(path, probe)
        destination = root / f"_{bucket_name}" / path.name
    return _dedupe_audio_scrape_destination(destination, reserved_destinations)


def _audio_scrape_sidecar_destinations(
    *,
    root: Path,
    source: Path,
    path: Path,
    bucket_by_format: bool,
    sidecar_bucket_roots: dict[Path, set[str]],
    reserved_destinations: set[Path],
) -> list[Path]:
    if not bucket_by_format:
        return [_dedupe_audio_scrape_destination(root / path.relative_to(source), reserved_destinations)]
    bucket_names = sorted(sidecar_bucket_roots.get(path.parent, set()))
    if not bucket_names:
        return [_dedupe_audio_scrape_destination(root / path.name, reserved_destinations)]
    return [
        _dedupe_audio_scrape_destination(root / f"_{bucket_name}" / path.name, reserved_destinations)
        for bucket_name in bucket_names
    ]


def _audio_scrape_bucket_name(path: Path, probe: ProbeResult) -> str:
    codec = (probe.codec or "").casefold()
    if codec == "alac":
        return "alac"
    mapped_lossy = LOSSY_QUALITY_LABELS.get(codec)
    if mapped_lossy:
        return mapped_lossy
    suffix = path.suffix.casefold().lstrip(".")
    if suffix == "aif":
        return "aiff"
    return suffix or codec or "audio"


def _dedupe_audio_scrape_destination(destination: Path, reserved_destinations: set[Path]) -> Path:
    candidate = destination
    index = 2
    while candidate in reserved_destinations or candidate.exists():
        candidate = destination.with_name(f"{destination.stem} ({index}){destination.suffix}")
        index += 1
    reserved_destinations.add(candidate)
    return candidate


def _transfer_audio_scrape_file(path: Path, destination: Path, *, move: bool) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    if move:
        shutil.move(str(path), str(destination))
        return
    shutil.copy2(path, destination)
