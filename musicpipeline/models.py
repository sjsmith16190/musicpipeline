from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Literal


OperationType = Literal[
    "move",
    "move_tree",
    "remove_duplicate",
    "skip",
    "convert",
    "copy",
    "delete_tree",
]


@dataclass(frozen=True)
class ProbeResult:
    status: Literal["audio", "not_audio", "broken_audio"]
    codec: str | None = None
    container: str | None = None
    audio_kind: Literal["lossless", "lossy"] | None = None
    sample_rate: int | None = None
    bits_per_sample: int | None = None
    metadata: dict[str, str] = field(default_factory=dict)
    failure_stage: str | None = None
    failure_reason: str | None = None


@dataclass(frozen=True)
class ScannedFile:
    path: Path
    relative_path: Path
    size: int
    suffix: str
    probe: ProbeResult


@dataclass(frozen=True)
class NormalizedMetadata:
    album_artist: str | None
    artist: str | None
    album: str | None
    title: str | None
    year: str | None
    genre: str | None
    track_number: int | None
    disc_number: int | None
    is_various_artists: bool
    routing_artist: str | None
    missing_important_tags: tuple[str, ...]


@dataclass(frozen=True)
class AudioCandidate:
    scanned_file: ScannedFile
    metadata: NormalizedMetadata
    quality_tag: str
    profile: Literal["album", "single", "unresolved"]
    library_root: Literal["main", "lossy"]


@dataclass(frozen=True)
class PlannedOperation:
    op: OperationType
    source: Path | None
    destination: Path | None
    reason: str
    stage: str
    details: dict[str, str] = field(default_factory=dict)


@dataclass
class Plan:
    operations: list[PlannedOperation] = field(default_factory=list)
    missing_manifest: dict[str, list[dict[str, str]]] = field(default_factory=dict)
    summary: dict[str, int] = field(default_factory=dict)

    def add(self, operation: PlannedOperation) -> None:
        self.operations.append(operation)

    def bump(self, key: str, amount: int = 1) -> None:
        self.summary[key] = self.summary.get(key, 0) + amount

