from __future__ import annotations

import re
import unicodedata
from collections import Counter
from dataclasses import replace
from pathlib import Path

from .constants import IMPORTANT_TAGS, KNOWN_AUDIO_EXTENSIONS, LOSSY_QUALITY_LABELS, PLACEHOLDER_VALUES, VA_NAMES
from .models import NormalizedMetadata, ProbeResult

_MULTISPACE_RE = re.compile(r"\s+")
_CONTROL_RE = re.compile(r"[\x00-\x1f\x7f]")
_SYMBOL_ONLY_RE = re.compile(r"^[^\w]+$", re.UNICODE)
_INVALID_PATH_CHARS_RE = re.compile(r'[<>:"|?*]')
_TRACKISH_RE = re.compile(r"^track\s*0*[0-9]+$", re.IGNORECASE)
_BRACKET_INDEX_PREFIX_RE = re.compile(r"^\[\d+\]\s+")
_DECIMAL_INDEX_PREFIX_RE = re.compile(r"^\d+[.)]\s+")
_DASHED_INDEX_PREFIX_RE = re.compile(r"^\d{1,2}[-_]\s*")
_NUMERIC_QUALITY_RE = re.compile(r"^(\d+)-(\d+)$")


def _strip_legacy_prefixes(value: str) -> str:
    stripped = value
    while True:
        updated = _BRACKET_INDEX_PREFIX_RE.sub("", stripped, count=1)
        updated = _DECIMAL_INDEX_PREFIX_RE.sub("", updated, count=1)
        updated = _DASHED_INDEX_PREFIX_RE.sub("", updated, count=1)
        updated = updated.lstrip()
        if updated == stripped:
            return stripped
        stripped = updated


def _strip_extension_suffix(value: str) -> str:
    stripped = value
    while True:
        lower_value = stripped.casefold()
        matched = False
        for extension in sorted(KNOWN_AUDIO_EXTENSIONS, key=len, reverse=True):
            suffix = extension.casefold()
            dotted_suffix = suffix if suffix.startswith(".") else f".{suffix}"
            if lower_value.endswith(dotted_suffix):
                stripped = stripped[: -len(dotted_suffix)].rstrip(" ._-")
                matched = True
                break
        if not matched:
            return stripped


def _normalize_text(value: str | None, *, strip_legacy_prefixes: bool = False, strip_extension_suffix: bool = False) -> str | None:
    if value is None:
        return None
    normalized = unicodedata.normalize("NFKC", value)
    normalized = _CONTROL_RE.sub("", normalized)
    normalized = normalized.strip()
    normalized = _MULTISPACE_RE.sub(" ", normalized)
    if strip_legacy_prefixes:
        normalized = _strip_legacy_prefixes(normalized)
    if strip_extension_suffix:
        normalized = _strip_extension_suffix(normalized)
    normalized = normalized.rstrip(" .")
    if not normalized:
        return None
    lowered = normalized.casefold()
    if lowered in PLACEHOLDER_VALUES or _TRACKISH_RE.match(lowered):
        return None
    if _SYMBOL_ONLY_RE.match(normalized):
        return None
    return normalized


def normalize_text(value: str | None) -> str | None:
    return _normalize_text(value)


def sanitize_path_component(value: str | None) -> str | None:
    normalized = _normalize_text(value)
    if normalized is None:
        return None
    normalized = normalized.replace("/", "-").replace("\\", "-")
    normalized = _INVALID_PATH_CHARS_RE.sub("", normalized)
    normalized = normalized.rstrip(" .")
    normalized = _MULTISPACE_RE.sub(" ", normalized).strip()
    return normalized or None


def sanitize_metadata_component(
    value: str | None,
    *,
    strip_legacy_prefixes: bool = False,
    strip_extension_suffix: bool = False,
) -> str | None:
    normalized = _normalize_text(
        value,
        strip_legacy_prefixes=strip_legacy_prefixes,
        strip_extension_suffix=strip_extension_suffix,
    )
    if normalized is None:
        return None
    normalized = normalized.replace("/", "-").replace("\\", "-")
    normalized = _INVALID_PATH_CHARS_RE.sub("", normalized)
    normalized = normalized.rstrip(" .")
    normalized = _MULTISPACE_RE.sub(" ", normalized).strip()
    return normalized or None


def parse_index(value: str | None) -> int | None:
    if value is None:
        return None
    normalized = normalize_text(value)
    if normalized is None:
        return None
    current = normalized.split("/", 1)[0].strip()
    digits = re.sub(r"[^\d]", "", current)
    if not digits:
        return None
    try:
        return int(digits, 10)
    except ValueError:
        return None


def extract_year(value: str | None) -> str | None:
    normalized = normalize_text(value)
    if normalized is None:
        return None
    match = re.search(r"(\d{4})", normalized)
    return match.group(1) if match else None


def is_various_artists(value: str | None) -> bool:
    normalized = normalize_text(value)
    if normalized is None:
        return False
    return normalized.casefold() in VA_NAMES


def codec_quality_tag(probe: ProbeResult) -> str:
    if probe.audio_kind == "lossless":
        bits = probe.bits_per_sample or 0
        rate = probe.sample_rate or 0
        if bits <= 0 or rate <= 0:
            return "lossless"
        khz = max(1, round(rate / 1000))
        return f"{bits}-{khz}"
    codec = (probe.codec or "").casefold()
    return LOSSY_QUALITY_LABELS.get(codec, codec or "lossy")


def normalize_metadata(raw: dict[str, str]) -> NormalizedMetadata:
    album_artist = sanitize_metadata_component(
        raw.get("album_artist") or raw.get("albumartist"),
        strip_legacy_prefixes=True,
    )
    artist = sanitize_metadata_component(raw.get("artist"), strip_legacy_prefixes=True)
    album = sanitize_metadata_component(raw.get("album"), strip_legacy_prefixes=True)
    title = sanitize_metadata_component(
        raw.get("title"),
        strip_legacy_prefixes=True,
        strip_extension_suffix=True,
    )
    year = extract_year(raw.get("date") or raw.get("year"))
    genre = sanitize_metadata_component(raw.get("genre"))
    track_number = parse_index(raw.get("track"))
    disc_number = parse_index(raw.get("disc"))
    various = is_various_artists(album_artist)
    routing_artist = None
    if various:
        routing_artist = "VA"
    elif album_artist:
        routing_artist = album_artist
    elif artist:
        routing_artist = artist
    missing: list[str] = []
    for key in IMPORTANT_TAGS:
        if key == "artist":
            if not artist:
                missing.append(key)
        elif key == "album_artist":
            if not album_artist:
                missing.append(key)
        elif key == "year":
            if not year:
                missing.append(key)
        else:
            if not locals()[key]:
                missing.append(key)
    return NormalizedMetadata(
        album_artist=album_artist,
        artist=artist,
        album=album,
        title=title,
        year=year,
        genre=genre,
        track_number=track_number,
        disc_number=disc_number,
        is_various_artists=various,
        routing_artist=routing_artist,
        missing_important_tags=tuple(missing),
    )


def apply_consensus_album_artist(items: list[NormalizedMetadata]) -> list[NormalizedMetadata]:
    consensus_values = sorted({item.album_artist for item in items if item.album_artist})
    if len(consensus_values) != 1:
        return items
    consensus = consensus_values[0]
    output: list[NormalizedMetadata] = []
    for item in items:
        if item.album_artist:
            output.append(item)
            continue
        output.append(
            replace(
                item,
                album_artist=consensus,
                routing_artist="VA" if item.is_various_artists else consensus,
                missing_important_tags=tuple(tag for tag in item.missing_important_tags if tag != "album_artist"),
            )
        )
    return output


def apply_album_group_consensus(items: list[NormalizedMetadata]) -> list[NormalizedMetadata]:
    output = apply_consensus_album_artist(items)
    routing_counts = Counter(item.routing_artist for item in output if item.routing_artist and not item.is_various_artists)
    if not routing_counts:
        return output
    ranked = routing_counts.most_common(2)
    top_value, top_count = ranked[0]
    second_count = ranked[1][1] if len(ranked) > 1 else 0
    if top_count < 2 or top_count <= second_count:
        return output
    return [replace(item, routing_artist="VA" if item.is_various_artists else top_value) for item in output]


def album_quality_suffix(quality_tags: list[str]) -> str:
    values = sorted({tag for tag in quality_tags if tag}, key=_quality_sort_key)
    if not values:
        return "[unknown]"
    return "".join(f"[{tag}]" for tag in values)


def _quality_sort_key(tag: str) -> tuple[int, int, int, str]:
    match = _NUMERIC_QUALITY_RE.match(tag)
    if match:
        bits = int(match.group(1))
        khz = int(match.group(2))
        return (0, -bits, -khz, tag)
    return (1, 0, 0, tag)


def build_track_token(track_number: int, disc_number: int | None, multi_disc: bool) -> str:
    if multi_disc:
        if disc_number is None:
            raise ValueError("disc number required for multi-disc output")
        return f"[{disc_number}-{track_number}]"
    return f"[{track_number}]"


def ensure_relative_to_root(path: Path, root: Path) -> Path:
    return path.resolve().relative_to(root.resolve())
