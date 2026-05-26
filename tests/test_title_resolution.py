import io
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from unittest.mock import patch

from musicpipeline.commands import command_title_resolution
from musicpipeline.title_resolution import iter_audio_files


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
            calls: list[tuple[Path, bool]] = []

            def fake_apply(selected_root: Path, *, dry_run: bool):
                calls.append((selected_root, dry_run))
                return type("Summary", (), {"failed": 0})()

            with (
                patch("musicpipeline.commands.ensure_title_resolution_tools", return_value=[]),
                patch("musicpipeline.commands.apply_resolution_titles", side_effect=fake_apply),
                patch("builtins.input", side_effect=[str(root), "d", "y"]),
            ):
                code = command_title_resolution()

            self.assertEqual(code, 0)
            self.assertEqual(calls, [(root.resolve(), True), (root.resolve(), False)])

    def test_missing_directory_returns_error(self):
        stderr = io.StringIO()

        with (
            patch("musicpipeline.commands.ensure_title_resolution_tools", return_value=[]),
            redirect_stderr(stderr),
        ):
            code = command_title_resolution(Path("/definitely/not/here"), write=True)

        self.assertEqual(code, 1)
        self.assertIn("directory does not exist", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
