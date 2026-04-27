import io
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch

from musicpipeline.commands import command_delete_source
from musicpipeline.constants import NOT_AUDIO_DIR_NAME, ORIGINAL_SOURCE_DIR_NAME


class DeleteSourceTests(unittest.TestCase):
    def test_delete_source_lists_audit_before_interactive_prompt(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            original_source = root / "Artist" / ORIGINAL_SOURCE_DIR_NAME / "[2025] Album"
            original_source.mkdir(parents=True, exist_ok=True)
            (original_source / "01 - Song.flac").write_bytes(b"audio")

            not_audio = root / NOT_AUDIO_DIR_NAME / "_jpg" / "Album"
            not_audio.mkdir(parents=True, exist_ok=True)
            (not_audio / "cover.jpg").write_bytes(b"image")

            stdout = io.StringIO()
            with redirect_stdout(stdout), patch("builtins.input", side_effect=["n", "n"]):
                code = command_delete_source(root, dry_run=False, yes=False)

            output = stdout.getvalue()
            self.assertEqual(code, 0)
            self.assertIn("[audit] ./Artist/_originalSource", output)
            self.assertIn("[2025] Album/", output)
            self.assertIn("[2025] Album/01 - Song.flac", output)
            self.assertIn("[audit] ./_NotAudio", output)
            self.assertIn("_jpg/Album/cover.jpg", output)
            self.assertTrue((root / "Artist" / ORIGINAL_SOURCE_DIR_NAME).exists())
            self.assertTrue((root / NOT_AUDIO_DIR_NAME).exists())

    def test_delete_source_yes_removes_original_source_and_not_audio(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            original_source = root / "Artist" / ORIGINAL_SOURCE_DIR_NAME / "[2025] Album"
            original_source.mkdir(parents=True, exist_ok=True)
            (original_source / "01 - Song.flac").write_bytes(b"audio")

            not_audio = root / NOT_AUDIO_DIR_NAME / "_jpg" / "Album"
            not_audio.mkdir(parents=True, exist_ok=True)
            (not_audio / "cover.jpg").write_bytes(b"image")

            code = command_delete_source(root, dry_run=False, yes=True)

            self.assertEqual(code, 0)
            self.assertFalse((root / "Artist" / ORIGINAL_SOURCE_DIR_NAME).exists())
            self.assertFalse((root / NOT_AUDIO_DIR_NAME).exists())

    def test_delete_source_removes_empty_parent_dirs_left_by_original_source(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            original_release_dir = root / "Artist" / "Old Release"
            original_source = original_release_dir / ORIGINAL_SOURCE_DIR_NAME / "[2025] Album"
            original_source.mkdir(parents=True, exist_ok=True)
            (original_source / "01 - Song.flac").write_bytes(b"audio")

            code = command_delete_source(root, dry_run=False, yes=True)

            self.assertEqual(code, 0)
            self.assertFalse(original_release_dir.exists())
            self.assertFalse((root / "Artist").exists())


if __name__ == "__main__":
    unittest.main()
