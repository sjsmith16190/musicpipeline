from __future__ import annotations

from pathlib import Path

STATE_DIR_NAME = ".musicpipeline"
LOSSY_DIR_NAME = "_Lossy"
NO_METADATA_DIR_NAME = "_NoMetadata"
NOT_AUDIO_DIR_NAME = "_NotAudio"
CONFLICTS_DIR_NAME = "_Conflicts"
QUARANTINE_DIR_NAME = "_Quarantine"
ORIGINAL_SOURCE_DIR_NAME = "_originalSource"

MANAGED_ROOT_NAMES = {
    LOSSY_DIR_NAME,
    NO_METADATA_DIR_NAME,
    NOT_AUDIO_DIR_NAME,
    CONFLICTS_DIR_NAME,
    QUARANTINE_DIR_NAME,
    STATE_DIR_NAME,
}

TEMP_DIR_NAMES = {
    ".musicpipeline-tmp",
}

KNOWN_AUDIO_EXTENSIONS = {
    ".flac",
    ".alac",
    ".wav",
    ".aiff",
    ".aif",
    ".ape",
    ".tak",
    ".wv",
    ".mka",
    ".m4a",
    ".mp3",
    ".aac",
    ".ogg",
    ".opus",
    ".wma",
    ".dsf",
    ".dff",
}

SIDECAR_EXTENSIONS = {
    ".cue",
    ".log",
    ".txt",
    ".nfo",
    ".m3u",
    ".m3u8",
    ".jpg",
    ".jpeg",
    ".png",
}

ARTWORK_PRIORITY = (
    "cover.jpg",
    "folder.jpg",
    "front.jpg",
    "cover.png",
    "folder.png",
    "front.png",
)

LOSSLESS_CODECS = {
    "alac",
    "flac",
    "ape",
    "tak",
    "wavpack",
    "wmalossless",
    "truehd",
    "mlp",
    "tta",
}

LOSSY_CODECS = {
    "aac",
    "mp3",
    "vorbis",
    "opus",
    "wmav1",
    "wmav2",
    "wmapro",
    "wmavoice",
}

LOSSLESS_PCM_PREFIXES = ("pcm_",)

LOSSY_QUALITY_LABELS = {
    "mp3": "mp3",
    "aac": "aac",
    "vorbis": "ogg",
    "opus": "opus",
    "wmav1": "wma",
    "wmav2": "wma",
    "wmapro": "wma",
    "wmavoice": "wma",
}

VA_NAMES = {
    "various artists",
    "various",
    "va",
}

PLACEHOLDER_VALUES = {
    "",
    "unknown",
    "untitled",
    "audio track",
}

MISSING_TAG_MANIFEST_NAME = "missing_tags.json"
RETAG_REVIEW_MANIFEST_NAME = "retag_review.json"
RUNS_DIR_NAME = "runs"
DEFAULT_MUSICBRAINZ_USER_AGENT = "musicpipeline/0.1.0 (local use)"

FFPROBE_METADATA_FIELDS = [
    "artist",
    "album_artist",
    "albumartist",
    "album",
    "title",
    "date",
    "year",
    "genre",
    "track",
    "disc",
]

IMPORTANT_TAGS = ("artist", "album_artist", "album", "title", "year", "genre")


def is_managed_dir_name(name: str) -> bool:
    return name in MANAGED_ROOT_NAMES or name in TEMP_DIR_NAMES


def state_path(root: Path) -> Path:
    return root / STATE_DIR_NAME
