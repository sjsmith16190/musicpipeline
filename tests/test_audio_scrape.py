import io
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest.mock import patch

from musicpipeline.cli import build_parser, main
from musicpipeline.commands import command_audio_scrape
from musicpipeline.models import ProbeResult


class AudioScrapeTests(unittest.TestCase):
    def test_audio_scrape_without_source_prints_help_and_exits_nonzero(self):
        stdout = io.StringIO()

        with redirect_stdout(stdout):
            code = main(["audio-scrape"])

        output = stdout.getvalue()
        self.assertEqual(code, 2)
        self.assertIn("Import audio files and common sidecars", output)
        self.assertIn("--destination, --root ROOT", output)
        self.assertIn("--bucket-by-format", output)

    def test_parser_accepts_destination_flag_and_root_alias(self):
        parser = build_parser()

        destination_args = parser.parse_args(
            ["audio-scrape", "--destination", "/tmp/library", "--bucket-by-format", "/tmp/source"]
        )
        root_alias_args = parser.parse_args(
            ["audio-scrape", "--root", "/tmp/library", "/tmp/source"]
        )

        self.assertEqual(str(destination_args.root), "/tmp/library")
        self.assertEqual(str(root_alias_args.root), "/tmp/library")
        self.assertEqual(str(destination_args.source), "/tmp/source")
        self.assertEqual(str(root_alias_args.source), "/tmp/source")
        self.assertTrue(destination_args.bucket_by_format)
        self.assertFalse(root_alias_args.bucket_by_format)

    def test_audio_scrape_rejects_same_root_and_source(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            stderr = io.StringIO()

            with redirect_stderr(stderr):
                code = command_audio_scrape(root, root, move=False, dry_run=False)

            self.assertEqual(code, 1)
            self.assertIn("must not overlap --destination", stderr.getvalue())
            self.assertFalse((root / ".musicpipeline").exists())

    def test_audio_scrape_rejects_nested_source_and_root(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "library"
            source = root / "incoming"
            source.mkdir(parents=True, exist_ok=True)
            stderr = io.StringIO()

            with redirect_stderr(stderr):
                code = command_audio_scrape(root, source, move=False, dry_run=False)

            self.assertEqual(code, 1)
            self.assertIn("must not overlap --destination", stderr.getvalue())

    def test_audio_scrape_copies_audio_and_sidecars_but_skips_managed_dirs(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            root = tmp_path / "library"
            source = tmp_path / "incoming"
            album = source / "Artist" / "Album"
            album.mkdir(parents=True, exist_ok=True)
            (album / "01 - Song.flac").write_bytes(b"audio")
            (album / "cover.jpg").write_bytes(b"image")

            managed_log = source / ".musicpipeline" / "runs" / "source-sidecar.log"
            managed_log.parent.mkdir(parents=True, exist_ok=True)
            managed_log.write_text("skip me", encoding="utf-8")

            managed_audio = source / "_NoMetadata" / "ignored.flac"
            managed_audio.parent.mkdir(parents=True, exist_ok=True)
            managed_audio.write_bytes(b"ignored")

            with patch("musicpipeline.commands.probe_file", side_effect=_fake_probe_file):
                code = command_audio_scrape(root, source, move=False, dry_run=False)

            self.assertEqual(code, 0)
            self.assertTrue((root / "Artist" / "Album" / "01 - Song.flac").exists())
            self.assertTrue((root / "Artist" / "Album" / "cover.jpg").exists())
            self.assertFalse((root / ".musicpipeline" / "runs" / "source-sidecar.log").exists())
            self.assertFalse((root / "_NoMetadata" / "ignored.flac").exists())

    def test_audio_scrape_bucket_by_format_flattens_into_bucket_roots(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            root = tmp_path / "library"
            source = tmp_path / "incoming"

            album_a = source / "Artist A" / "Album One"
            album_b = source / "Artist B" / "Album Two"
            single = source / "Singles"
            album_a.mkdir(parents=True, exist_ok=True)
            album_b.mkdir(parents=True, exist_ok=True)
            single.mkdir(parents=True, exist_ok=True)

            (album_a / "01 - Song.flac").write_bytes(b"audio-a")
            (album_a / "cover.jpg").write_bytes(b"cover-a")
            (album_b / "01 - Song.flac").write_bytes(b"audio-b")
            (album_b / "cover.jpg").write_bytes(b"cover-b")
            (single / "track.mp3").write_bytes(b"audio-c")

            with patch("musicpipeline.commands.probe_file", side_effect=_fake_probe_file):
                code = command_audio_scrape(root, source, move=False, dry_run=False, bucket_by_format=True)

            self.assertEqual(code, 0)
            self.assertTrue((root / "_flac" / "01 - Song.flac").exists())
            self.assertTrue((root / "_flac" / "01 - Song (2).flac").exists())
            self.assertTrue((root / "_flac" / "cover.jpg").exists())
            self.assertTrue((root / "_flac" / "cover (2).jpg").exists())
            self.assertTrue((root / "_mp3" / "track.mp3").exists())
            self.assertFalse((root / "Artist A").exists())
            self.assertFalse((root / "Artist B").exists())


def _fake_probe_file(path: Path) -> ProbeResult:
    if path.suffix.casefold() == ".flac":
        return ProbeResult(status="audio", codec="flac", audio_kind="lossless")
    if path.suffix.casefold() == ".mp3":
        return ProbeResult(status="audio", codec="mp3", audio_kind="lossy")
    return ProbeResult(status="not_audio")


if __name__ == "__main__":
    unittest.main()
