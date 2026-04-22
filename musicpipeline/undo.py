from __future__ import annotations

import json
from pathlib import Path

from .constants import RUNS_DIR_NAME, state_path
from .executor import RunLogger, remove_empty_dirs

_IRREVERSIBLE_OPS = {"remove_duplicate", "delete_tree"}


def command_undo(root: Path, *, dry_run: bool = False, run_id: str | None = None) -> int:
    logger = RunLogger(root, "undo", dry_run=dry_run)
    manifest_path = _select_run_manifest(root, run_id=run_id)
    if manifest_path is None:
        logger.log("no reversible run manifest found")
        logger.persist()
        return 1
    logger.log(f"[undo-run] {manifest_path.name}")
    events = _load_events(manifest_path)
    reversed_any = False
    skipped_irreversible = 0
    skipped_missing = 0

    for event in reversed(events):
        op = str(event.get("op") or "")
        source = _to_path(event.get("source"))
        destination = _to_path(event.get("destination"))
        if op in _IRREVERSIBLE_OPS:
            skipped_irreversible += 1
            logger.log(f"[undo-skip] {op} is irreversible")
            continue
        if op not in {"move", "move_tree"}:
            continue
        if source is None or destination is None:
            continue
        if not destination.exists():
            skipped_missing += 1
            logger.log(f"[undo-skip] missing destination ./{_relative(root, destination)}")
            continue
        logger.log(f"[undo] ./{_relative(root, destination)} -> ./{_relative(root, source)}")
        if not dry_run:
            source.parent.mkdir(parents=True, exist_ok=True)
            destination.replace(source)
        reversed_any = True

    removed = remove_empty_dirs(root, logger, dry_run=dry_run)
    logger.log("")
    logger.log("Undo summary:")
    logger.log(f"  empty_dirs_removed: {removed}")
    logger.log(f"  irreversible_skips: {skipped_irreversible}")
    logger.log(f"  missing_destination_skips: {skipped_missing}")
    logger.log(f"  reversed_any: {1 if reversed_any else 0}")
    if dry_run:
        logger.log("  dry_run: 1")
    logger.persist()
    return 0 if reversed_any else 1


def _select_run_manifest(root: Path, *, run_id: str | None = None) -> Path | None:
    runs_dir = state_path(root) / RUNS_DIR_NAME
    if not runs_dir.exists():
        return None
    manifests = sorted(runs_dir.glob("*.jsonl"), reverse=True)
    if run_id:
        manifests = [path for path in manifests if path.name.startswith(f"{run_id}.")]
    for manifest in manifests:
        if ".undo." in manifest.name:
            continue
        events = _load_events(manifest)
        if any(str(event.get("op") or "") in {"move", "move_tree"} for event in events):
            return manifest
    return None


def _load_events(path: Path) -> list[dict[str, object]]:
    events: list[dict[str, object]] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        events.append(json.loads(line))
    return events


def _to_path(value: object) -> Path | None:
    text = str(value or "").strip()
    return Path(text) if text else None


def _relative(root: Path, path: Path) -> str:
    try:
        return str(path.resolve().relative_to(root.resolve()))
    except ValueError:
        return str(path)
