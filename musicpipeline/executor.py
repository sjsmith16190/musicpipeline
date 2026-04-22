from __future__ import annotations

import json
import shutil
from dataclasses import asdict
from datetime import datetime, timezone
from pathlib import Path

from .constants import MISSING_TAG_MANIFEST_NAME, RUNS_DIR_NAME, STATE_DIR_NAME, state_path
from .models import Plan, PlannedOperation


class RunLogger:
    def __init__(self, root: Path, mode: str, dry_run: bool) -> None:
        self.root = root.resolve()
        self.mode = mode
        self.dry_run = dry_run
        self.lines: list[str] = []
        self.manifest_events: list[dict[str, str]] = []
        self.run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")

    def log(self, message: str) -> None:
        self.lines.append(message)
        print(message, flush=True)

    def record(self, operation: PlannedOperation) -> None:
        event = {
            "op": operation.op,
            "stage": operation.stage,
            "reason": operation.reason,
            "source": str(operation.source) if operation.source else "",
            "destination": str(operation.destination) if operation.destination else "",
        }
        event.update(operation.details)
        self.manifest_events.append(event)

    def persist(self) -> None:
        if self.dry_run:
            return
        runs_dir = state_path(self.root) / RUNS_DIR_NAME
        runs_dir.mkdir(parents=True, exist_ok=True)
        log_path = runs_dir / f"{self.run_id}.{self.mode}.log"
        manifest_path = runs_dir / f"{self.run_id}.{self.mode}.jsonl"
        log_path.write_text("\n".join(self.lines) + ("\n" if self.lines else ""), encoding="utf-8")
        manifest_path.write_text(
            "\n".join(json.dumps(event, sort_keys=True) for event in self.manifest_events) + ("\n" if self.manifest_events else ""),
            encoding="utf-8",
        )


def execute_plan(root: Path, plan: Plan, logger: RunLogger, dry_run: bool) -> None:
    for operation in plan.operations:
        logger.record(operation)
        logger.log(_render_operation(root, operation))
        if dry_run:
            continue
        _apply_operation(operation)
    if plan.missing_manifest and not dry_run:
        manifest_path = state_path(root) / MISSING_TAG_MANIFEST_NAME
        manifest_path.parent.mkdir(parents=True, exist_ok=True)
        manifest_path.write_text(json.dumps(plan.missing_manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    logger.persist()


def remove_empty_dirs(root: Path, logger: RunLogger, dry_run: bool) -> int:
    removed = 0
    for directory in sorted((path for path in root.rglob("*") if path.is_dir()), key=lambda path: len(path.parts), reverse=True):
        if directory == root:
            continue
        try:
            next(directory.iterdir())
            continue
        except StopIteration:
            logger.log(f"[delete-empty-dirs] {directory.relative_to(root)}")
            if not dry_run:
                directory.rmdir()
            removed += 1
    logger.persist()
    return removed


def delete_tree(target: Path, logger: RunLogger, dry_run: bool) -> None:
    logger.log(f"[delete] {target}")
    if dry_run:
        return
    shutil.rmtree(target)


def _apply_operation(operation: PlannedOperation) -> None:
    if operation.op == "skip":
        return
    if operation.op == "remove_duplicate":
        if operation.source and operation.source.exists():
            operation.source.unlink()
        return
    if operation.op == "delete_tree":
        if operation.source and operation.source.exists():
            shutil.rmtree(operation.source)
        return
    if operation.source is None or operation.destination is None:
        return
    if not operation.source.exists():
        return
    operation.destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.move(str(operation.source), str(operation.destination))


def _render_operation(root: Path, operation: PlannedOperation) -> str:
    source = _relative_or_absolute(root, operation.source)
    destination = _relative_or_absolute(root, operation.destination)
    if operation.op == "skip":
        return f"[skip] {source} ({operation.reason})"
    if operation.op == "remove_duplicate":
        return f"[duplicate] remove {source}; keep {destination}"
    if operation.op == "delete_tree":
        return f"[delete] {source}"
    return f"[{operation.op}] {source} -> {destination} ({operation.reason})"


def _relative_or_absolute(root: Path, value: Path | None) -> str:
    if value is None:
        return ""
    try:
        return f"./{value.resolve().relative_to(root.resolve())}"
    except ValueError:
        return str(value)
