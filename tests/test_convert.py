import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from musicpipeline.convert import convert_units
from musicpipeline.models import ProbeResult, ScannedFile


def _audio_probe(
    *,
    artist: str = "Artist",
    album_artist: str = "Artist",
    album: str = "One Track Release",
    title: str = "Standalone Song",
    date: str = "2025",
) -> ProbeResult:
    return ProbeResult(
        status="audio",
        codec="flac",
        audio_kind="lossless",
        sample_rate=44100,
        bits_per_sample=16,
        metadata={
            "artist": artist,
            "album_artist": album_artist,
            "albumartist": album_artist,
            "album": album,
            "title": title,
            "date": date,
            "year": "",
            "genre": "Pop",
            "track": "",
            "disc": "",
        },
    )


def _scanned(root: Path, relative: str, probe: ProbeResult) -> ScannedFile:
    path = root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b"audio")
    return ScannedFile(
        path=path,
        relative_path=Path(relative),
        size=5,
        suffix=path.suffix.casefold(),
        probe=probe,
    )


class _Logger:
    def __init__(self) -> None:
        self.messages: list[str] = []

    def log(self, message: str) -> None:
        self.messages.append(message)


class ConvertTests(unittest.TestCase):
    def test_one_file_release_unit_converts_to_artist_root_single_name(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            scanned = [_scanned(root, "drop/Single/song.flac", _audio_probe())]
            logger = _Logger()

            with (
                patch("musicpipeline.convert._run_ffmpeg_convert", return_value=(True, None)),
                patch("musicpipeline.convert.validate_alac_output", return_value=(True, None)),
            ):
                summary = convert_units(root, scanned, logger, dry_run=True)

            self.assertEqual(summary["converted_files"], 1)
            self.assertIn(
                "[convert] ./drop/Single/song.flac -> ./Artist/Artist - Standalone Song [2025][16-44].m4a",
                logger.messages,
            )
            self.assertIn(
                "[preserve-source] ./drop/Single -> ./Artist/_originalSource/[2025] One Track Release",
                logger.messages,
            )


if __name__ == "__main__":
    unittest.main()
