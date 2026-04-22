import unittest
from pathlib import Path

from musicpipeline.convert import _parse_cue_file
from musicpipeline.models import ProbeResult, ScannedFile
from musicpipeline.planner import build_sort_plan


def _audio_probe(
    *,
    codec: str,
    kind: str,
    artist: str = "",
    album_artist: str = "",
    album: str = "",
    title: str = "",
    date: str = "",
    genre: str = "",
    track: str = "",
    disc: str = "",
    sample_rate: int = 44100,
    bits_per_sample: int = 16,
) -> ProbeResult:
    return ProbeResult(
        status="audio",
        codec=codec,
        audio_kind=kind,
        sample_rate=sample_rate,
        bits_per_sample=bits_per_sample,
        metadata={
            "artist": artist,
            "album_artist": album_artist,
            "albumartist": album_artist,
            "album": album,
            "title": title,
            "date": date,
            "year": "",
            "genre": genre,
            "track": track,
            "disc": disc,
        },
    )


def _scanned(root: Path, relative: str, probe: ProbeResult, content: bytes = b"x") -> ScannedFile:
    path = root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(content)
    return ScannedFile(
        path=path,
        relative_path=Path(relative),
        size=len(content),
        suffix=path.suffix.casefold(),
        probe=probe,
    )


class PlannerTests(unittest.TestCase):
    def test_album_route_and_missing_year_manifest(self):
        with self.subTest():
            import tempfile

            with tempfile.TemporaryDirectory() as directory:
                tmp_path = Path(directory).resolve()
                scanned = [
                    _scanned(
                        tmp_path,
                        "inbox/song.flac",
                        _audio_probe(
                            codec="flac",
                            kind="lossless",
                            artist="Song Artist",
                            album_artist="Album Artist",
                            album="Album Name",
                            title="Song Name",
                            track="1/10",
                            genre="Ambient",
                        ),
                    )
                ]
                plan = build_sort_plan(tmp_path, scanned)
                self.assertTrue(
                    any(
                        operation.destination == tmp_path / "Album Artist" / "Album Name [16-44]" / "[1] Song Name [16-44].flac"
                        for operation in plan.operations
                        if operation.op == "move"
                    )
                )
                self.assertIn("year", plan.missing_manifest)

    def test_various_artists_album_routes_at_library_root(self):
        import tempfile

        with tempfile.TemporaryDirectory() as directory:
            tmp_path = Path(directory).resolve()
            scanned = [
                _scanned(
                    tmp_path,
                    "drop/track.flac",
                    _audio_probe(
                        codec="flac",
                        kind="lossless",
                        artist="Track Artist",
                        album_artist="Various Artists",
                        album="Compilation",
                        title="Song Name",
                        date="2002",
                        track="7/20",
                        genre="Electronic",
                    ),
                )
            ]
            plan = build_sort_plan(tmp_path, scanned)
            self.assertTrue(
                any(
                    operation.destination == tmp_path / "[2002] VA - Compilation [16-44]" / "[7] Track Artist - Song Name [16-44].flac"
                    for operation in plan.operations
                    if operation.op == "move"
                )
            )

    def test_attached_release_sidecar_moves_with_routable_album(self):
        import tempfile

        with tempfile.TemporaryDirectory() as directory:
            tmp_path = Path(directory).resolve()
            scanned = [
                _scanned(
                    tmp_path,
                    "drop/track.flac",
                    _audio_probe(
                        codec="flac",
                        kind="lossless",
                        artist="Track Artist",
                        album_artist="Album Artist",
                        album="Album Name",
                        title="Song Name",
                        date="2002",
                        track="1/10",
                        genre="Electronic",
                    ),
                ),
                _scanned(
                    tmp_path,
                    "drop/cover.jpg",
                    ProbeResult(status="not_audio"),
                ),
            ]
            plan = build_sort_plan(tmp_path, scanned)
            self.assertTrue(
                any(
                    operation.destination == tmp_path / "Album Artist" / "[2002] Album Name [16-44]" / "cover.jpg"
                    for operation in plan.operations
                    if operation.op == "move"
                )
            )

    def test_unresolved_album_group_moves_to_no_metadata(self):
        import tempfile

        with tempfile.TemporaryDirectory() as directory:
            tmp_path = Path(directory).resolve()
            scanned = [
                _scanned(
                    tmp_path,
                    "release/song.flac",
                    _audio_probe(
                        codec="flac",
                        kind="lossless",
                        artist="Artist",
                        album="Album",
                        title="Song",
                        genre="Jazz",
                    ),
                )
            ]
            plan = build_sort_plan(tmp_path, scanned)
            self.assertTrue(
                any(
                    operation.op == "move_tree"
                    and operation.destination == tmp_path / "_NoMetadata" / "release"
                    for operation in plan.operations
                )
            )

    def test_unresolved_group_move_absorbs_sidecars(self):
        import tempfile

        with tempfile.TemporaryDirectory() as directory:
            tmp_path = Path(directory).resolve()
            scanned = [
                _scanned(
                    tmp_path,
                    "release/song.flac",
                    _audio_probe(
                        codec="flac",
                        kind="lossless",
                        artist="Artist",
                        album="Album",
                        title="Song",
                        genre="Jazz",
                    ),
                ),
                _scanned(
                    tmp_path,
                    "release/cover.jpg",
                    ProbeResult(status="not_audio"),
                ),
            ]
            plan = build_sort_plan(tmp_path, scanned)
            self.assertTrue(
                any(
                    operation.op == "move_tree"
                    and operation.destination == tmp_path / "_NoMetadata" / "release"
                    for operation in plan.operations
                )
            )
            self.assertFalse(
                any(
                    operation.op == "move" and operation.source == tmp_path / "release" / "cover.jpg"
                    for operation in plan.operations
                )
            )

    def test_nested_unresolved_dirs_only_plan_topmost_group_move(self):
        import tempfile

        with tempfile.TemporaryDirectory() as directory:
            tmp_path = Path(directory).resolve()
            scanned = [
                _scanned(
                    tmp_path,
                    "_Unknown/rootsong.flac",
                    _audio_probe(
                        codec="flac",
                        kind="lossless",
                        title="Root Song",
                    ),
                ),
                _scanned(
                    tmp_path,
                    "_Unknown/_flac/song.flac",
                    _audio_probe(
                        codec="flac",
                        kind="lossless",
                        title="Song",
                    ),
                )
            ]
            plan = build_sort_plan(tmp_path, scanned)
            move_trees = [operation for operation in plan.operations if operation.op == "move_tree"]
            self.assertEqual(len(move_trees), 1)
            self.assertEqual(move_trees[0].source, tmp_path / "_Unknown")
            self.assertEqual(move_trees[0].destination, tmp_path / "_NoMetadata" / "_Unknown")

    def test_not_audio_routes_into_extension_bucket(self):
        import tempfile

        with tempfile.TemporaryDirectory() as directory:
            tmp_path = Path(directory).resolve()
            scanned = [
                _scanned(
                    tmp_path,
                    "SomeAlbum/notes.txt",
                    ProbeResult(status="not_audio"),
                )
            ]
            plan = build_sort_plan(tmp_path, scanned)
            self.assertTrue(
                any(
                    operation.destination == tmp_path / "_NotAudio" / "_txt" / "SomeAlbum" / "notes.txt"
                    for operation in plan.operations
                    if operation.op == "move"
                )
            )

    def test_existing_exact_duplicate_becomes_remove_duplicate(self):
        import tempfile

        with tempfile.TemporaryDirectory() as directory:
            tmp_path = Path(directory).resolve()
            target = tmp_path / "Artist" / "[2001] Album [16-44]" / "[1] Song [16-44].flac"
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(b"same-bytes")
            scanned = [
                _scanned(
                    tmp_path,
                    "incoming/song.flac",
                    _audio_probe(
                        codec="flac",
                        kind="lossless",
                        artist="Artist",
                        album_artist="Artist",
                        album="Album",
                        title="Song",
                        date="2001",
                        track="1/10",
                        genre="Rock",
                    ),
                    content=b"same-bytes",
                )
            ]
            plan = build_sort_plan(tmp_path, scanned)
            self.assertTrue(any(operation.op == "remove_duplicate" for operation in plan.operations))

    def test_multidisc_group_with_missing_disc_number_becomes_unresolved(self):
        import tempfile

        with tempfile.TemporaryDirectory() as directory:
            tmp_path = Path(directory).resolve()
            scanned = [
                _scanned(
                    tmp_path,
                    "release/disc2.flac",
                    _audio_probe(
                        codec="flac",
                        kind="lossless",
                        artist="Artist",
                        album_artist="Artist",
                        album="Album",
                        title="Disc Two Track",
                        date="2005",
                        track="1/10",
                        disc="2/2",
                        genre="Classical",
                    ),
                ),
                _scanned(
                    tmp_path,
                    "release/missing-disc.flac",
                    _audio_probe(
                        codec="flac",
                        kind="lossless",
                        artist="Artist",
                        album_artist="Artist",
                        album="Album",
                        title="Missing Disc",
                        date="2005",
                        track="2/10",
                        genre="Classical",
                    ),
                ),
            ]
            plan = build_sort_plan(tmp_path, scanned)
            self.assertTrue(
                any(
                    operation.op == "move_tree"
                    and operation.destination == tmp_path / "_NoMetadata" / "release"
                    for operation in plan.operations
                )
            )

    def test_parse_cue_file_extracts_album_and_track_metadata(self):
        import tempfile

        with tempfile.TemporaryDirectory() as directory:
            cue_path = Path(directory) / "album.cue"
            cue_path.write_text(
                '\n'.join(
                    [
                        'PERFORMER "Album Artist"',
                        'TITLE "Album Name"',
                        'REM DATE 2001',
                        'FILE "image.flac" WAVE',
                        '  TRACK 01 AUDIO',
                        '    TITLE "Track One"',
                        '    PERFORMER "Track Artist"',
                        '    INDEX 01 00:00:00',
                        '  TRACK 02 AUDIO',
                        '    TITLE "Track Two"',
                        '    INDEX 01 04:12:00',
                    ]
                ),
                encoding="utf-8",
            )
            album_meta, tracks = _parse_cue_file(cue_path)
            self.assertEqual(album_meta["album_artist"], "Album Artist")
            self.assertEqual(album_meta["album"], "Album Name")
            self.assertEqual(album_meta["date"], "2001")
            self.assertEqual(len(tracks), 2)
            self.assertEqual(tracks[0]["title"], "Track One")
            self.assertEqual(tracks[0]["performer"], "Track Artist")
            self.assertEqual(tracks[1]["track_number"], 2)


if __name__ == "__main__":
    unittest.main()
