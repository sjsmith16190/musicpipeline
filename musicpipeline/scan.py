from __future__ import annotations

import os
from pathlib import Path

from .constants import ORIGINAL_SOURCE_DIR_NAME, TEMP_DIR_NAMES, is_managed_dir_name
from .models import ScannedFile
from .probe import probe_file


def iter_scanned_files(root: Path) -> list[ScannedFile]:
    scanned: list[ScannedFile] = []
    root = root.resolve()
    for current_root, dirnames, filenames in os.walk(root):
        current_path = Path(current_root)
        dirnames[:] = [
            dirname
            for dirname in sorted(dirnames)
            if not _should_prune_dir(current_path / dirname, root)
        ]
        for filename in sorted(filenames):
            path = current_path / filename
            relative = path.relative_to(root)
            stat = path.stat()
            scanned.append(
                ScannedFile(
                    path=path,
                    relative_path=relative,
                    size=stat.st_size,
                    suffix=path.suffix.casefold(),
                    probe=probe_file(path),
                )
            )
    return scanned


def _should_prune_dir(path: Path, root: Path) -> bool:
    name = path.name
    if name == ORIGINAL_SOURCE_DIR_NAME:
        return True
    if is_managed_dir_name(name):
        return True
    if name in TEMP_DIR_NAMES:
        return True
    if name.startswith(".") and path != root / ".musicpipeline":
        return True
    return False

