from __future__ import annotations

import hashlib
from collections import defaultdict
from dataclasses import replace
from pathlib import Path

from .constants import CONFLICTS_DIR_NAME, LOSSY_DIR_NAME, NO_METADATA_DIR_NAME, NOT_AUDIO_DIR_NAME, QUARANTINE_DIR_NAME, SIDECAR_EXTENSIONS
from .models import AudioCandidate, NormalizedMetadata, Plan, PlannedOperation, ProbeResult, ScannedFile
from .normalize import build_track_token, codec_quality_tag, normalize_metadata, sanitize_path_component


def build_sort_plan(root: Path, scanned_files: list[ScannedFile]) -> Plan:
    root = root.resolve()
    plan = Plan()
    dir_audio_candidates: dict[Path, list[AudioCandidate]] = defaultdict(list)
    sidecars_by_parent: dict[Path, list[ScannedFile]] = defaultdict(list)
    pending_non_audio: list[PlannedOperation] = []
    pending_quarantine: list[PlannedOperation] = []
    routable: list[AudioCandidate] = []
    unresolved: list[AudioCandidate] = []

    for scanned in scanned_files:
        plan.bump("scanned_files")
        probe = scanned.probe
        if probe.status == "not_audio":
            if scanned.suffix in SIDECAR_EXTENSIONS:
                sidecars_by_parent[scanned.relative_path.parent].append(scanned)
                continue
            destination = root / _not_audio_relative_path(scanned.relative_path)
            pending_non_audio.append(
                PlannedOperation(
                    op="move",
                    source=scanned.path,
                    destination=destination,
                    reason="non-audio file",
                    stage="sort",
                )
            )
            plan.bump("non_audio_files")
            continue
        if probe.status == "broken_audio":
            destination = root / QUARANTINE_DIR_NAME / scanned.relative_path
            pending_quarantine.append(
                PlannedOperation(
                    op="move",
                    source=scanned.path,
                    destination=destination,
                    reason=probe.failure_reason or "broken audio",
                    stage=probe.failure_stage or "probe",
                )
            )
            plan.bump("quarantined_files")
            continue

        candidate = _build_audio_candidate(scanned, probe)
        dir_audio_candidates[scanned.relative_path.parent].append(candidate)
        if candidate.profile == "unresolved":
            unresolved.append(candidate)
        else:
            routable.append(candidate)
        if candidate.library_root == "lossy":
            plan.bump("lossy_audio_files")
        else:
            plan.bump("lossless_audio_files")

    album_groups = _group_album_candidates([candidate for candidate in routable if candidate.profile == "album"])
    ambiguous_album_sources = {
        path
        for key, info in album_groups.items()
        if bool(info["disc_ambiguous"])
        for path in info["sources"]
    }
    stable_routable: list[AudioCandidate] = []
    for candidate in routable:
        if candidate.profile == "album" and candidate.scanned_file.path in ambiguous_album_sources:
            unresolved.append(replace(candidate, profile="unresolved"))
            continue
        stable_routable.append(candidate)
    routable = stable_routable
    album_groups = _group_album_candidates([candidate for candidate in routable if candidate.profile == "album"])
    routed_operations = _routable_audio_operations(root, routable, album_groups)
    final_dir_audio_candidates: dict[Path, list[AudioCandidate]] = defaultdict(list)
    for candidate in [*routable, *unresolved]:
        final_dir_audio_candidates[candidate.scanned_file.relative_path.parent].append(candidate)
    unresolved_group_dirs = _unresolved_group_dirs(root, final_dir_audio_candidates)

    group_move_dirs: set[Path] = set()
    for relative_dir, candidates in unresolved_group_dirs.items():
        source_dir = root / relative_dir
        group_move_dirs.add(source_dir)
        destination = root / NO_METADATA_DIR_NAME / relative_dir
        plan.add(
            PlannedOperation(
                op="move_tree",
                source=source_dir,
                destination=destination,
                reason="insufficient metadata for group",
                stage="sort",
            )
        )
        plan.bump("nometadata_groups")

    covered_sources = {
        operation.source
        for operation in plan.operations
        if operation.op == "move_tree" and operation.source is not None
    }
    for operation in pending_non_audio:
        if operation.source and any(operation.source.is_relative_to(source) for source in group_move_dirs):
            continue
        plan.add(operation)
    for operation in pending_quarantine:
        if operation.source and any(operation.source.is_relative_to(source) for source in group_move_dirs):
            continue
        plan.add(operation)

    for candidate in unresolved:
        if any(candidate.scanned_file.path.is_relative_to(source) for source in covered_sources):
            continue
        destination = root / NO_METADATA_DIR_NAME / candidate.scanned_file.relative_path
        plan.add(
            PlannedOperation(
                op="move",
                source=candidate.scanned_file.path,
                destination=destination,
                reason="insufficient metadata",
                stage="sort",
            )
        )
        plan.bump("nometadata_files")

    for operation in routed_operations:
        plan.add(operation)

    sidecar_album_destinations = _sidecar_album_destinations(root, routable, album_groups)
    for relative_parent, sidecars in sidecars_by_parent.items():
        parent_path = root / relative_parent
        if any(parent_path.is_relative_to(source) for source in group_move_dirs):
            continue
        destination_dir = sidecar_album_destinations.get(relative_parent)
        for sidecar in sidecars:
            if destination_dir is not None:
                plan.add(
                    PlannedOperation(
                        op="move",
                        source=sidecar.path,
                        destination=destination_dir / sidecar.path.name,
                        reason="release sidecar",
                        stage="sort",
                    )
                )
                continue
            plan.add(
                PlannedOperation(
                    op="move",
                    source=sidecar.path,
                    destination=root / _not_audio_relative_path(sidecar.relative_path),
                    reason="non-audio sidecar outside attached release",
                    stage="sort",
                )
            )
            plan.bump("non_audio_files")

    _attach_missing_tag_manifest(plan, routable)
    return resolve_duplicates_and_conflicts(root, plan)


def resolve_duplicates_and_conflicts(root: Path, plan: Plan) -> Plan:
    resolved = Plan(summary=dict(plan.summary), missing_manifest=plan.missing_manifest)
    claimed: dict[Path, Path] = {}
    claimed_destinations: set[Path] = set()
    for operation in plan.operations:
        if operation.destination is None or operation.source is None:
            resolved.add(operation)
            continue
        if operation.op == "move_tree":
            if operation.source == operation.destination:
                resolved.add(replace(operation, op="skip", reason="already normalized"))
                resolved.bump("already_normalized")
                continue
            if operation.destination.exists():
                conflict_destination = _unique_destination(
                    root / CONFLICTS_DIR_NAME / operation.destination.relative_to(root),
                    claimed_destinations,
                )
                resolved.add(replace(operation, destination=conflict_destination, reason="destination tree already exists"))
                resolved.bump("conflicts")
            else:
                resolved.add(operation)
                claimed_destinations.add(operation.destination)
            continue

        if operation.source == operation.destination:
            resolved.add(replace(operation, op="skip", reason="already normalized"))
            resolved.bump("already_normalized")
            continue

        if operation.destination in claimed:
            kept = claimed[operation.destination]
            if _same_file_content(kept, operation.source):
                resolved.add(
                    PlannedOperation(
                        op="remove_duplicate",
                        source=operation.source,
                        destination=operation.destination,
                        reason=f"exact duplicate of {kept}",
                        stage=operation.stage,
                    )
                )
                resolved.bump("duplicates")
                continue
            conflict_destination = _unique_destination(
                root / CONFLICTS_DIR_NAME / operation.destination.relative_to(root),
                claimed_destinations,
            )
            resolved.add(replace(operation, destination=conflict_destination, reason="planned path collision"))
            resolved.bump("conflicts")
            claimed_destinations.add(conflict_destination)
            continue

        if operation.destination.exists():
            if _same_file_content(operation.destination, operation.source):
                resolved.add(
                    PlannedOperation(
                        op="remove_duplicate",
                        source=operation.source,
                        destination=operation.destination,
                        reason=f"exact duplicate of {operation.destination}",
                        stage=operation.stage,
                    )
                )
                resolved.bump("duplicates")
                continue
            conflict_destination = _unique_destination(
                root / CONFLICTS_DIR_NAME / operation.destination.relative_to(root),
                claimed_destinations,
            )
            resolved.add(replace(operation, destination=conflict_destination, reason="existing destination collision"))
            resolved.bump("conflicts")
            claimed_destinations.add(conflict_destination)
            continue

        claimed[operation.destination] = operation.source
        claimed_destinations.add(operation.destination)
        resolved.add(operation)
    return resolved


def _routable_audio_operations(
    root: Path,
    routable: list[AudioCandidate],
    album_groups: dict[tuple[str, ...], dict[str, object]],
) -> list[PlannedOperation]:
    operations: list[PlannedOperation] = []
    for candidate in sorted(routable, key=lambda item: str(item.scanned_file.relative_path)):
        if candidate.profile == "single":
            destination = root / _single_relative_path(candidate)
        else:
            group_key = _album_group_key(candidate)
            album_info = album_groups[group_key]
            multi_disc = bool(album_info["multi_disc"])
            destination = root / _album_relative_path(candidate, multi_disc)
        operations.append(
            PlannedOperation(
                op="move",
                source=candidate.scanned_file.path,
                destination=destination,
                reason="normalized audio route",
                stage="sort",
            )
        )
    return operations


def _album_relative_path(candidate: AudioCandidate, multi_disc: bool) -> Path:
    metadata = candidate.metadata
    artist_label = metadata.routing_artist or "Unknown Artist"
    track_artist = metadata.artist or artist_label
    year_prefix = f"[{metadata.year}] " if metadata.year else ""
    root_parts: list[str] = []
    if candidate.library_root == "lossy":
        root_parts.append(LOSSY_DIR_NAME)
    if metadata.is_various_artists:
        album_dir = f"{year_prefix}VA - {metadata.album} [{candidate.quality_tag}]"
        file_name = f"{build_track_token(metadata.track_number or 0, metadata.disc_number, multi_disc)} {track_artist} - {metadata.title} [{candidate.quality_tag}]{candidate.scanned_file.suffix}"
        root_parts.append(album_dir)
        root_parts.append(file_name)
        return Path(*root_parts)
    album_dir = f"{year_prefix}{metadata.album} [{candidate.quality_tag}]"
    file_name = f"{build_track_token(metadata.track_number or 0, metadata.disc_number, multi_disc)} {metadata.title} [{candidate.quality_tag}]{candidate.scanned_file.suffix}"
    root_parts.extend([artist_label, album_dir, file_name])
    return Path(*root_parts)


def _single_relative_path(candidate: AudioCandidate) -> Path:
    metadata = candidate.metadata
    artist_label = metadata.artist or metadata.routing_artist or "Unknown Artist"
    year_prefix = f"[{metadata.year}] " if metadata.year else ""
    file_name = f"{year_prefix}{artist_label} - {metadata.title} [{candidate.quality_tag}]{candidate.scanned_file.suffix}"
    if candidate.library_root == "lossy":
        return Path(LOSSY_DIR_NAME, artist_label, file_name)
    return Path(artist_label, file_name)


def _group_album_candidates(candidates: list[AudioCandidate]) -> dict[tuple[str, ...], dict[str, object]]:
    groups: dict[tuple[str, ...], list[AudioCandidate]] = defaultdict(list)
    for candidate in candidates:
        groups[_album_group_key(candidate)].append(candidate)
    output: dict[tuple[str, ...], dict[str, object]] = {}
    for key, grouped in groups.items():
        discs = {candidate.metadata.disc_number or 1 for candidate in grouped}
        multi_disc = len(discs) > 1 or any(value > 1 for value in discs)
        output[key] = {
            "multi_disc": multi_disc,
            "disc_ambiguous": multi_disc and any(candidate.metadata.disc_number is None for candidate in grouped),
            "sources": [candidate.scanned_file.path for candidate in grouped],
        }
    return output


def _build_audio_candidate(scanned: ScannedFile, probe: ProbeResult) -> AudioCandidate:
    metadata = normalize_metadata(probe.metadata)
    profile = _profile_for_metadata(metadata)
    if profile == "album" and metadata.track_number is None:
        profile = "unresolved"
    if profile == "album" and metadata.is_various_artists and metadata.artist is None:
        profile = "unresolved"
    library_root = "lossy" if probe.audio_kind == "lossy" else "main"
    return AudioCandidate(
        scanned_file=scanned,
        metadata=metadata,
        quality_tag=codec_quality_tag(probe),
        profile=profile,
        library_root=library_root,
    )


def _profile_for_metadata(metadata: NormalizedMetadata) -> str:
    if metadata.album and metadata.title and (metadata.album_artist or metadata.artist):
        return "album"
    if metadata.artist and metadata.title and not metadata.album:
        return "single"
    return "unresolved"


def _album_group_key(candidate: AudioCandidate) -> tuple[str, ...]:
    metadata = candidate.metadata
    return (
        candidate.library_root,
        "va" if metadata.is_various_artists else "artist",
        metadata.routing_artist or "",
        metadata.album or "",
        metadata.year or "",
        candidate.quality_tag,
    )


def _not_audio_relative_path(relative_path: Path) -> Path:
    suffix = relative_path.suffix.casefold().lstrip(".")
    bucket = f"_{suffix}" if suffix else "_noext"
    return Path(NOT_AUDIO_DIR_NAME, bucket, relative_path)


def _unresolved_group_dirs(
    root: Path,
    dir_audio_candidates: dict[Path, list[AudioCandidate]],
) -> dict[Path, list[AudioCandidate]]:
    grouped: dict[Path, list[AudioCandidate]] = {}
    sorted_dirs = sorted(
        (
            relative_dir
            for relative_dir, candidates in dir_audio_candidates.items()
            if relative_dir != Path(".") and candidates and all(candidate.profile == "unresolved" for candidate in candidates)
        ),
        key=lambda path: len(path.parts),
    )
    selected_roots: list[Path] = []
    for relative_dir in sorted_dirs:
        if any(relative_dir.is_relative_to(existing_root) for existing_root in selected_roots):
            continue
        selected_roots.append(relative_dir)
        grouped[relative_dir] = dir_audio_candidates[relative_dir]
    return grouped


def _attach_missing_tag_manifest(plan: Plan, routable: list[AudioCandidate]) -> None:
    manifest: dict[str, list[dict[str, str]]] = defaultdict(list)
    for candidate in routable:
        missing = set(candidate.metadata.missing_important_tags)
        for tag in sorted(missing):
            manifest[tag].append(
                {
                    "source": str(candidate.scanned_file.relative_path),
                    "profile": candidate.profile,
                }
            )
            plan.bump("missing_tag_entries")
    plan.missing_manifest = {key: sorted(value, key=lambda item: item["source"]) for key, value in sorted(manifest.items())}


def _same_file_content(first: Path, second: Path) -> bool:
    if not first.exists() or not second.exists():
        return False
    if first.stat().st_size != second.stat().st_size:
        return False
    return _sha256(first) == _sha256(second)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _unique_destination(candidate: Path, claimed_destinations: set[Path]) -> Path:
    if candidate not in claimed_destinations and not candidate.exists():
        return candidate
    stem = candidate.stem
    suffix = candidate.suffix
    parent = candidate.parent
    index = 2
    while True:
        next_candidate = parent / f"{stem} ({index}){suffix}"
        if next_candidate not in claimed_destinations and not next_candidate.exists():
            return next_candidate
        index += 1


def _sidecar_album_destinations(
    root: Path,
    routable: list[AudioCandidate],
    album_groups: dict[tuple[str, ...], dict[str, object]],
) -> dict[Path, Path]:
    destinations: dict[Path, set[Path]] = defaultdict(set)
    for candidate in routable:
        if candidate.profile != "album":
            continue
        group_key = _album_group_key(candidate)
        multi_disc = bool(album_groups[group_key]["multi_disc"])
        destinations[candidate.scanned_file.relative_path.parent].add((root / _album_relative_path(candidate, multi_disc)).parent)
    resolved: dict[Path, Path] = {}
    for parent, targets in destinations.items():
        if len(targets) == 1:
            resolved[parent] = next(iter(targets))
    return resolved
