from __future__ import annotations

import json
import os
import shutil
import subprocess
import time
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

from .constants import DEFAULT_MUSICBRAINZ_USER_AGENT, IMPORTANT_TAGS, RETAG_REVIEW_MANIFEST_NAME, state_path
from .executor import RunLogger
from .normalize import normalize_metadata
from .probe import probe_file
from .scan import iter_scanned_files

ACOUSTID_LOOKUP_URL = "https://api.acoustid.org/v2/lookup"
MUSICBRAINZ_RECORDING_URL = "https://musicbrainz.org/ws/2/recording/{recording_id}"
MUSICBRAINZ_SEARCH_URL = "https://musicbrainz.org/ws/2/recording/"
RETAG_SUPPORTED_FIELDS = ("artist", "album_artist", "album", "title", "year", "genre", "track", "disc")
_LAST_MB_REQUEST_AT = 0.0


def build_retag_review(
    root: Path,
    logger: RunLogger,
    *,
    provider: str = "musicbrainz",
    manifest_path: Path | None = None,
    acoustid_client: str | None = None,
) -> int:
    if provider != "musicbrainz":
        logger.log(f"unsupported retag provider: {provider}")
        return 2
    manifest_target = manifest_path or (state_path(root) / RETAG_REVIEW_MANIFEST_NAME)
    scanned = iter_scanned_files(root)
    entries: list[dict[str, object]] = []
    fpcalc_path = shutil.which("fpcalc")
    acoustid_client = acoustid_client or os.environ.get("ACOUSTID_CLIENT")
    summary = {
        "scanned_files": 0,
        "audio_files": 0,
        "proposals": 0,
        "approved_entries": 0,
        "unchanged_matches": 0,
        "unmatched": 0,
        "ambiguous": 0,
        "lookup_failures": 0,
        "skipped_no_lookup_method": 0,
    }

    for scanned_file in scanned:
        summary["scanned_files"] += 1
        if scanned_file.probe.status != "audio":
            continue
        summary["audio_files"] += 1
        current_metadata = normalize_metadata(scanned_file.probe.metadata)
        entry = _build_review_entry(
            root,
            scanned_file.path,
            current_metadata,
            fpcalc_path=fpcalc_path,
            acoustid_client=acoustid_client,
        )
        entries.append(entry)
        status = str(entry["status"])
        if status == "pending":
            if entry["changes"]:
                summary["proposals"] += 1
            else:
                summary["unchanged_matches"] += 1
        elif status == "unmatched":
            summary["unmatched"] += 1
        elif status == "ambiguous":
            summary["ambiguous"] += 1
        elif status == "lookup_failed":
            summary["lookup_failures"] += 1
        elif status == "skipped":
            summary["skipped_no_lookup_method"] += 1
        logger.log(f"[retag:{status}] ./{entry['path']}")

    manifest = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "provider": provider,
        "requires_review": True,
        "root": str(root.resolve()),
        "instructions": [
            "Review each pending entry before applying metadata changes.",
            "Set approved to true only for entries you want to apply.",
            "retag-apply will ignore entries without approved=true.",
        ],
        "summary": summary,
        "entries": entries,
    }
    manifest_target.parent.mkdir(parents=True, exist_ok=True)
    manifest_target.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    logger.log("")
    logger.log(f"Review manifest written to {manifest_target}")
    for key in sorted(summary):
        logger.log(f"  {key}: {summary[key]}")
    logger.persist()
    return 0


def apply_retag_review(root: Path, logger: RunLogger, *, manifest_path: Path | None = None, dry_run: bool = False) -> int:
    manifest_target = manifest_path or (state_path(root) / RETAG_REVIEW_MANIFEST_NAME)
    if not manifest_target.exists():
        logger.log(f"retag manifest not found: {manifest_target}")
        return 2
    payload = json.loads(manifest_target.read_text(encoding="utf-8"))
    entries = payload.get("entries") or []
    applied = 0
    skipped = 0
    failed = 0
    for entry in entries:
        if not entry.get("approved"):
            skipped += 1
            continue
        if entry.get("status") != "pending":
            skipped += 1
            continue
        changes = entry.get("changes") or {}
        if not changes:
            skipped += 1
            continue
        target = root / str(entry["path"])
        logger.log(f"[retag-apply] ./{entry['path']}")
        if dry_run:
            applied += 1
            continue
        ok, reason = _write_tags_with_exiftool(target, entry.get("proposed_tags") or {})
        if ok:
            applied += 1
            continue
        failed += 1
        logger.log(f"  failed: {reason}")
    logger.log("")
    logger.log("Retag apply summary:")
    logger.log(f"  applied: {applied}")
    logger.log(f"  failed: {failed}")
    logger.log(f"  skipped: {skipped}")
    if dry_run:
        logger.log("  dry_run: 1")
    logger.persist()
    return 0 if failed == 0 else 1


def _build_review_entry(
    root: Path,
    path: Path,
    current_metadata,
    *,
    fpcalc_path: str | None,
    acoustid_client: str | None,
) -> dict[str, object]:
    relative_path = path.resolve().relative_to(root.resolve())
    current_tags = _metadata_to_tag_dict(current_metadata)

    if fpcalc_path and acoustid_client:
        result = _lookup_by_acoustid(path, fpcalc_path=fpcalc_path, acoustid_client=acoustid_client)
    elif current_metadata.artist and current_metadata.title:
        result = _lookup_by_text(current_metadata.artist, current_metadata.title, current_metadata.album)
    else:
        result = {
            "status": "skipped",
            "reason": "no lookup method available; install fpcalc and set ACOUSTID_CLIENT for untagged files",
        }

    entry: dict[str, object] = {
        "path": str(relative_path),
        "approved": False,
        "current_tags": current_tags,
        "provider": "musicbrainz",
        "lookup": {},
        "proposed_tags": {},
        "changes": {},
        "status": result["status"],
    }
    if "reason" in result:
        entry["reason"] = result["reason"]
    if result.get("lookup"):
        entry["lookup"] = result["lookup"]
    if result.get("candidates"):
        entry["candidates"] = result["candidates"]
    proposed_tags = result.get("proposed_tags") or {}
    entry["proposed_tags"] = proposed_tags
    entry["changes"] = _diff_tags(current_tags, proposed_tags)
    return entry


def _metadata_to_tag_dict(metadata) -> dict[str, str]:
    values = {
        "artist": metadata.artist,
        "album_artist": metadata.album_artist,
        "album": metadata.album,
        "title": metadata.title,
        "year": metadata.year,
        "genre": metadata.genre,
        "track": str(metadata.track_number) if metadata.track_number is not None else None,
        "disc": str(metadata.disc_number) if metadata.disc_number is not None else None,
    }
    return {key: value for key, value in values.items() if value}


def _diff_tags(current_tags: dict[str, str], proposed_tags: dict[str, str]) -> dict[str, dict[str, str]]:
    changes: dict[str, dict[str, str]] = {}
    for key in RETAG_SUPPORTED_FIELDS:
        current_value = current_tags.get(key)
        proposed_value = proposed_tags.get(key)
        if not proposed_value or proposed_value == current_value:
            continue
        changes[key] = {"from": current_value or "", "to": proposed_value}
    return changes


def _lookup_by_acoustid(path: Path, *, fpcalc_path: str, acoustid_client: str) -> dict[str, object]:
    fpcalc = subprocess.run(
        [fpcalc_path, "-json", str(path)],
        check=False,
        capture_output=True,
        text=True,
    )
    if fpcalc.returncode != 0:
        return {"status": "lookup_failed", "reason": (fpcalc.stderr or "fpcalc failed").strip()}
    try:
        payload = json.loads(fpcalc.stdout)
    except json.JSONDecodeError:
        return {"status": "lookup_failed", "reason": "invalid fpcalc json"}
    fingerprint = payload.get("fingerprint")
    duration = payload.get("duration")
    if not fingerprint or not duration:
        return {"status": "lookup_failed", "reason": "missing fpcalc fingerprint or duration"}
    query = urllib.parse.urlencode(
        {
            "client": acoustid_client,
            "duration": int(duration),
            "fingerprint": fingerprint,
            "meta": "recordings recordingids releases releaseids tracks compress",
            "format": "json",
        }
    )
    lookup = _http_json(f"{ACOUSTID_LOOKUP_URL}?{query}", user_agent="musicpipeline/0.1.0")
    results = lookup.get("results") or []
    if not results:
        return {"status": "unmatched", "reason": "no AcoustID matches"}
    ranked = sorted(results, key=lambda item: float(item.get("score") or 0.0), reverse=True)
    top = ranked[0]
    top_score = float(top.get("score") or 0.0)
    second_score = float(ranked[1].get("score") or 0.0) if len(ranked) > 1 else 0.0
    if top_score < 0.90 or (len(ranked) > 1 and (top_score - second_score) < 0.05):
        return {
            "status": "ambiguous",
            "reason": "AcoustID match confidence too low for auto-proposal",
            "lookup": {"method": "acoustid", "score": top_score},
            "candidates": [_summarize_acoustid_result(item) for item in ranked[:5]],
        }
    recording_id = _extract_recording_id(top)
    if not recording_id:
        return {
            "status": "unmatched",
            "reason": "AcoustID result did not include a MusicBrainz recording id",
            "lookup": {"method": "acoustid", "score": top_score},
        }
    proposal = _fetch_musicbrainz_recording(recording_id)
    proposal["lookup"] = {
        "method": "acoustid",
        "score": top_score,
        "recording_id": recording_id,
        "acoustid_id": top.get("id", ""),
    }
    return proposal


def _lookup_by_text(artist: str, title: str, album: str | None) -> dict[str, object]:
    parts = [f'recording:"{title}"', f'artist:"{artist}"']
    if album:
        parts.append(f'release:"{album}"')
    query = urllib.parse.urlencode({"query": " AND ".join(parts), "fmt": "json", "limit": 5})
    response = _musicbrainz_json(f"{MUSICBRAINZ_SEARCH_URL}?{query}")
    recordings = response.get("recordings") or []
    if not recordings:
        return {"status": "unmatched", "reason": "no MusicBrainz text matches"}
    top = recordings[0]
    top_score = int(top.get("score") or 0)
    second_score = int(recordings[1].get("score") or 0) if len(recordings) > 1 else 0
    if top_score < 95 or (len(recordings) > 1 and (top_score - second_score) < 5):
        return {
            "status": "ambiguous",
            "reason": "MusicBrainz text search confidence too low for auto-proposal",
            "lookup": {"method": "text", "score": top_score},
            "candidates": [_summarize_mb_search_result(item) for item in recordings[:5]],
        }
    proposal = _fetch_musicbrainz_recording(str(top["id"]))
    proposal["lookup"] = {"method": "text", "score": top_score, "recording_id": str(top["id"])}
    return proposal


def _fetch_musicbrainz_recording(recording_id: str) -> dict[str, object]:
    response = _musicbrainz_json(
        MUSICBRAINZ_RECORDING_URL.format(recording_id=recording_id)
        + "?fmt=json&inc=artists+releases+release-groups+genres+tags"
    )
    releases = response.get("releases") or []
    release = _pick_release(releases)
    title = str(response.get("title") or "").strip()
    artist = _artist_credit_name(response.get("artist-credit") or [])
    proposed = {
        "artist": artist,
        "title": title,
    }
    if release:
        release_title = str(release.get("title") or "").strip()
        release_year = _release_year(release)
        release_artist = _artist_credit_name(release.get("artist-credit") or [])
        if release_title:
            proposed["album"] = release_title
        if release_year:
            proposed["year"] = release_year
        if release_artist:
            proposed["album_artist"] = release_artist
        track_info = _find_track_in_release(release, recording_id)
        if track_info.get("track"):
            proposed["track"] = track_info["track"]
        if track_info.get("disc"):
            proposed["disc"] = track_info["disc"]
    genre = _extract_genre(response)
    if genre:
        proposed["genre"] = genre
    normalized = normalize_metadata(proposed)
    proposed_tags = _metadata_to_tag_dict(normalized)
    if not proposed_tags.get("artist") or not proposed_tags.get("title"):
        return {"status": "lookup_failed", "reason": "MusicBrainz response missing required tags"}
    return {"status": "pending", "proposed_tags": proposed_tags}


def _pick_release(releases: list[dict[str, object]]) -> dict[str, object] | None:
    if not releases:
        return None
    def sort_key(release: dict[str, object]) -> tuple[int, str, str]:
        status = str(release.get("status") or "")
        primary = 0 if status.casefold() == "official" else 1
        date = str(release.get("date") or "")
        return (primary, date or "9999", str(release.get("title") or ""))
    return sorted(releases, key=sort_key)[0]


def _find_track_in_release(release: dict[str, object], recording_id: str) -> dict[str, str]:
    media = release.get("media") or []
    for medium in media:
        disc = str(medium.get("position") or "") or None
        for track in medium.get("tracks") or []:
            recording = track.get("recording") or {}
            if str(recording.get("id") or "") != recording_id:
                continue
            return {
                "track": str(track.get("number") or track.get("position") or "").split("/", 1)[0],
                "disc": disc or "",
            }
    return {}


def _release_year(release: dict[str, object]) -> str | None:
    value = str(release.get("date") or "")
    if len(value) >= 4 and value[:4].isdigit():
        return value[:4]
    release_group = release.get("release-group") or {}
    value = str(release_group.get("first-release-date") or "")
    if len(value) >= 4 and value[:4].isdigit():
        return value[:4]
    return None


def _artist_credit_name(credits: list[dict[str, object]]) -> str | None:
    parts: list[str] = []
    for item in credits:
        name = str(item.get("name") or "").strip()
        join_phrase = str(item.get("joinphrase") or "")
        if name:
            parts.append(name)
        if join_phrase:
            parts.append(join_phrase)
    result = "".join(parts).strip()
    return result or None


def _extract_genre(recording: dict[str, object]) -> str | None:
    genres = recording.get("genres") or []
    if genres:
        top = sorted(genres, key=lambda item: int(item.get("count") or 0), reverse=True)[0]
        name = str(top.get("name") or "").strip()
        return name or None
    tags = recording.get("tags") or []
    if tags:
        top = sorted(tags, key=lambda item: int(item.get("count") or 0), reverse=True)[0]
        name = str(top.get("name") or "").strip()
        return name or None
    return None


def _extract_recording_id(result: dict[str, object]) -> str | None:
    recordings = result.get("recordings") or []
    if not recordings:
        return None
    return str(recordings[0].get("id") or "") or None


def _summarize_acoustid_result(item: dict[str, object]) -> dict[str, object]:
    recordings = item.get("recordings") or []
    recording = recordings[0] if recordings else {}
    return {
        "score": float(item.get("score") or 0.0),
        "recording_id": str(recording.get("id") or ""),
        "title": str(recording.get("title") or ""),
    }


def _summarize_mb_search_result(item: dict[str, object]) -> dict[str, object]:
    return {
        "score": int(item.get("score") or 0),
        "recording_id": str(item.get("id") or ""),
        "title": str(item.get("title") or ""),
        "artist": _artist_credit_name(item.get("artist-credit") or []),
    }


def _write_tags_with_exiftool(path: Path, proposed_tags: dict[str, str]) -> tuple[bool, str | None]:
    if not path.exists():
        return False, "file no longer exists"
    command = ["exiftool", "-overwrite_original"]
    tag_map = {
        "artist": ["-artist"],
        "album_artist": ["-albumartist"],
        "album": ["-album"],
        "title": ["-title"],
        "year": ["-date", "-year"],
        "genre": ["-genre"],
        "track": ["-track"],
        "disc": ["-discnumber"],
    }
    for field in RETAG_SUPPORTED_FIELDS:
        value = proposed_tags.get(field)
        if not value:
            continue
        for flag in tag_map[field]:
            command.append(f"{flag}={value}")
    command.append(str(path))
    completed = subprocess.run(command, check=False, capture_output=True, text=True)
    if completed.returncode != 0:
        return False, (completed.stderr or completed.stdout or "exiftool failed").strip()
    probed = probe_file(path)
    if probed.status != "audio":
        return False, "file could not be reprobed after tag write"
    return True, None


def _musicbrainz_json(url: str) -> dict[str, object]:
    global _LAST_MB_REQUEST_AT
    elapsed = time.monotonic() - _LAST_MB_REQUEST_AT
    if elapsed < 1.05:
        time.sleep(1.05 - elapsed)
    payload = _http_json(url, user_agent=DEFAULT_MUSICBRAINZ_USER_AGENT)
    _LAST_MB_REQUEST_AT = time.monotonic()
    return payload


def _http_json(url: str, *, user_agent: str) -> dict[str, object]:
    request = urllib.request.Request(
        url,
        headers={
            "Accept": "application/json",
            "User-Agent": user_agent,
        },
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.loads(response.read().decode("utf-8"))
