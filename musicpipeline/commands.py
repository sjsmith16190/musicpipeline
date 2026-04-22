from __future__ import annotations

import shutil
from pathlib import Path

from .constants import MISSING_TAG_MANIFEST_NAME, ORIGINAL_SOURCE_DIR_NAME, RUNS_DIR_NAME, STATE_DIR_NAME, state_path
from .convert import convert_units
from .executor import RunLogger, delete_tree, execute_plan, remove_empty_dirs
from .planner import build_sort_plan
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


def command_audio_scrape(root: Path, source: Path, move: bool = False, dry_run: bool = False) -> int:
    logger = RunLogger(root, "audio-scrape", dry_run=dry_run)
    audio_count = 0
    sidecar_count = 0
    for path in sorted(source.rglob("*")):
        if not path.is_file():
            continue
        relative = path.relative_to(source)
        if path.suffix.casefold() in {".cue", ".log", ".jpg", ".jpeg", ".png"}:
            destination = root / relative
            logger.log(f"[{'move' if move else 'copy'}] {path} -> {destination} (related sidecar)")
            if not dry_run:
                destination.parent.mkdir(parents=True, exist_ok=True)
                if move:
                    shutil.move(str(path), str(destination))
                else:
                    shutil.copy2(path, destination)
            sidecar_count += 1
            continue
        scanned = iter_scanned_files(path.parent)
        matching = next((item for item in scanned if item.path == path), None)
        if matching is None or matching.probe.status != "audio":
            continue
        destination = root / relative
        logger.log(f"[{'move' if move else 'copy'}] {path} -> {destination} (audio scrape)")
        if not dry_run:
            destination.parent.mkdir(parents=True, exist_ok=True)
            if move:
                shutil.move(str(path), str(destination))
            else:
                shutil.copy2(path, destination)
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
    for target in targets:
        if not yes and not dry_run:
            reply = input(f"Delete {target}? [y/N]: ").strip().casefold()
            if reply not in {"y", "yes"}:
                logger.log(f"[skip] {target}")
                continue
        logger.log(f"[delete] {target}")
        if not dry_run:
            shutil.rmtree(target)
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
