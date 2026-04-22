import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from musicpipeline.retag import _diff_tags, apply_retag_review
from musicpipeline.executor import RunLogger


class RetagTests(unittest.TestCase):
    def test_diff_tags_only_emits_real_changes(self):
        changes = _diff_tags(
            {
                "artist": "Queen",
                "title": "Bohemian Rhapsody",
                "year": "1975",
            },
            {
                "artist": "Queen",
                "title": "Bohemian Rhapsody",
                "album": "A Night at the Opera",
                "year": "1975",
            },
        )

        self.assertEqual(
            changes,
            {
                "album": {
                    "from": "",
                    "to": "A Night at the Opera",
                }
            },
        )

    def test_apply_retag_review_only_applies_approved_pending_entries(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "song1.mp3").write_bytes(b"one")
            (root / "song2.mp3").write_bytes(b"two")
            manifest = {
                "entries": [
                    {
                        "path": "song1.mp3",
                        "approved": True,
                        "status": "pending",
                        "changes": {"artist": {"from": "", "to": "Queen"}},
                        "proposed_tags": {"artist": "Queen", "title": "Bohemian Rhapsody"},
                    },
                    {
                        "path": "song2.mp3",
                        "approved": False,
                        "status": "pending",
                        "changes": {"artist": {"from": "", "to": "Blur"}},
                        "proposed_tags": {"artist": "Blur", "title": "Song 2"},
                    },
                    {
                        "path": "song3.mp3",
                        "approved": True,
                        "status": "ambiguous",
                        "changes": {"artist": {"from": "", "to": "Nero"}},
                        "proposed_tags": {"artist": "Nero", "title": "Promises"},
                    },
                ]
            }
            manifest_path = root / ".musicpipeline" / "retag_review.json"
            manifest_path.parent.mkdir(parents=True, exist_ok=True)
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
            logger = RunLogger(root, "retag-apply", dry_run=False)

            calls: list[tuple[Path, dict[str, str]]] = []

            def fake_write_tags(path: Path, proposed_tags: dict[str, str]):
                calls.append((path, proposed_tags))
                return True, None

            with patch("musicpipeline.retag._write_tags_with_exiftool", side_effect=fake_write_tags):
                code = apply_retag_review(root, logger, manifest_path=manifest_path, dry_run=False)

            self.assertEqual(code, 0)
            self.assertEqual(
                calls,
                [
                    (
                        root / "song1.mp3",
                        {"artist": "Queen", "title": "Bohemian Rhapsody"},
                    )
                ],
            )


if __name__ == "__main__":
    unittest.main()
