import json
import tempfile
import unittest
from pathlib import Path

from musicpipeline.undo import command_undo


class UndoTests(unittest.TestCase):
    def test_undo_restores_last_move_manifest(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            runs = root / ".musicpipeline" / "runs"
            runs.mkdir(parents=True, exist_ok=True)
            source = root / "Artist" / "Song.mp3"
            destination = root / "_Lossy" / "Artist" / "Song.mp3"
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(b"audio")
            manifest = runs / "20260423T001000Z.sort.jsonl"
            manifest.write_text(
                json.dumps(
                    {
                        "op": "move",
                        "stage": "sort",
                        "reason": "normalized audio route",
                        "source": str(source),
                        "destination": str(destination),
                    }
                )
                + "\n",
                encoding="utf-8",
            )

            code = command_undo(root, dry_run=False)

            self.assertEqual(code, 0)
            self.assertTrue(source.exists())
            self.assertFalse(destination.exists())


if __name__ == "__main__":
    unittest.main()
