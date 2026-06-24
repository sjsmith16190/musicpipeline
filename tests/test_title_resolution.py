import io
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from unittest.mock import patch

from musicpipeline.commands import command_title_resolution
from musicpipeline.title_resolution import _build_plan_from_metadata, iter_audio_files


class TitleResolutionTests(unittest.TestCase):
    def test_iter_audio_files_skips_hidden_macos_sidecars(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "song.m4a").write_bytes(b"audio")
            (root / "._song.m4a").write_bytes(b"sidecar")
            (root / ".hidden.flac").write_bytes(b"hidden")

            paths = list(iter_audio_files(root))

            self.assertEqual(paths, [root / "song.m4a"])

    def test_interactive_dry_run_can_flow_straight_into_write(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            calls: list[tuple[Path, bool, int | None]] = []

            def fake_apply(selected_root: Path, *, dry_run: bool, jobs: int | None = None):
                calls.append((selected_root, dry_run, jobs))
                return type("Summary", (), {"failed": 0})()

            with (
                patch("musicpipeline.commands.ensure_title_resolution_tools", return_value=[]),
                patch("musicpipeline.commands.apply_resolution_titles", side_effect=fake_apply),
                patch("builtins.input", side_effect=[str(root), "d", "y"]),
            ):
                code = command_title_resolution()

            self.assertEqual(code, 0)
            self.assertEqual(calls, [(root.resolve(), True, None), (root.resolve(), False, None)])

    def test_command_passes_jobs_through(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            calls: list[tuple[Path, bool, int | None]] = []

            def fake_apply(selected_root: Path, *, dry_run: bool, jobs: int | None = None):
                calls.append((selected_root, dry_run, jobs))
                return type("Summary", (), {"failed": 0})()

            with (
                patch("musicpipeline.commands.ensure_title_resolution_tools", return_value=[]),
                patch("musicpipeline.commands.apply_resolution_titles", side_effect=fake_apply),
            ):
                code = command_title_resolution(root, write=True, jobs=8)

            self.assertEqual(code, 0)
            self.assertEqual(calls, [(root.resolve(), False, 8)])

    def test_missing_directory_returns_error(self):
        stderr = io.StringIO()

        with (
            patch("musicpipeline.commands.ensure_title_resolution_tools", return_value=[]),
            redirect_stderr(stderr),
        ):
            code = command_title_resolution(Path("/definitely/not/here"), write=True)

        self.assertEqual(code, 1)
        self.assertIn("directory does not exist", stderr.getvalue())

    def test_invalid_jobs_returns_error(self):
        stderr = io.StringIO()

        with (
            patch("musicpipeline.commands.ensure_title_resolution_tools", return_value=[]),
            redirect_stderr(stderr),
        ):
            code = command_title_resolution(Path.cwd(), write=True, jobs=0)

        self.assertEqual(code, 2)
        self.assertIn("jobs must be at least 1", stderr.getvalue())

    def test_mp3_uses_mp3_suffix_and_title_cases_label(self):
        path = Path("/tmp/example.mp3")

        plan = _build_plan_from_metadata(
            path,
            metadata={
                "title": "my test song",
                "sample_rate": 44100,
                "bits_per_sample": None,
            },
        )

        self.assertIsNotNone(plan)
        self.assertEqual(plan.new_title, "My Test Song [MP3]")

    def test_existing_bracketed_title_avoids_extra_space_before_suffix(self):
        path = Path("/tmp/example.flac")

        plan = _build_plan_from_metadata(
            path,
            metadata={
                "title": "my song [live]",
                "sample_rate": 48000,
                "bits_per_sample": 16,
            },
        )

        self.assertIsNotNone(plan)
        self.assertEqual(plan.new_title, "My Song [Live][16-48]")

    def test_existing_matching_suffix_is_not_added_twice(self):
        path = Path("/tmp/example.flac")

        plan = _build_plan_from_metadata(
            path,
            metadata={
                "title": "my song [16-48]",
                "sample_rate": 48000,
                "bits_per_sample": 16,
            },
        )

        self.assertIsNotNone(plan)
        self.assertEqual(plan.new_title, "My Song [16-48]")

    def test_existing_matching_suffix_elsewhere_prevents_duplicate(self):
        path = Path("/tmp/example.flac")

        plan = _build_plan_from_metadata(
            path,
            metadata={
                "title": "my song [16-48] [24-96]",
                "sample_rate": 48000,
                "bits_per_sample": 16,
            },
        )

        self.assertIsNotNone(plan)
        self.assertEqual(plan.new_title, "My Song [16-48]")


if __name__ == "__main__":
    unittest.main()
