import unittest

from musicpipeline.models import ProbeResult
from musicpipeline.normalize import album_quality_suffix, apply_album_group_consensus, apply_consensus_album_artist, codec_quality_tag, normalize_metadata, sanitize_path_component


class NormalizeTests(unittest.TestCase):
    def test_sanitize_path_component_rejects_placeholders_and_invalid_chars(self):
        self.assertIsNone(sanitize_path_component(" unknown "))
        self.assertEqual(sanitize_path_component("Artist/Name"), "Artist-Name")
        self.assertIsNone(sanitize_path_component("..."))

    def test_normalize_metadata_uses_precedence_and_missing_flags(self):
        metadata = normalize_metadata(
            {
                "album_artist": "",
                "albumartist": "  Various Artists  ",
                "artist": " Track Artist ",
                "album": " Album Name ",
                "title": " Song Title ",
                "date": "1999-03-01",
                "genre": "",
                "track": "01/12",
                "disc": "2/2",
            }
        )

        self.assertEqual(metadata.album_artist, "Various Artists")
        self.assertEqual(metadata.artist, "Track Artist")
        self.assertEqual(metadata.year, "1999")
        self.assertEqual(metadata.track_number, 1)
        self.assertEqual(metadata.disc_number, 2)
        self.assertTrue(metadata.is_various_artists)
        self.assertEqual(metadata.routing_artist, "VA")
        self.assertEqual(metadata.missing_important_tags, ("genre",))

    def test_normalize_metadata_strips_legacy_prefixes_and_extension_leaks(self):
        metadata = normalize_metadata(
            {
                "artist": "[56] Zinc Ft. No.Lay",
                "album": "01. Break",
                "title": "Bohemian Rhapsody.Mp3",
                "year": "2011",
                "genre": "Dubstep",
                "track": "01",
            }
        )

        self.assertEqual(metadata.artist, "Zinc Ft. No.Lay")
        self.assertEqual(metadata.album, "Break")
        self.assertEqual(metadata.title, "Bohemian Rhapsody")

    def test_codec_quality_tag_maps_lossless_and_lossy(self):
        self.assertEqual(
            codec_quality_tag(
                ProbeResult(
                    status="audio",
                    codec="flac",
                    audio_kind="lossless",
                    sample_rate=44100,
                    bits_per_sample=16,
                )
            ),
            "16-44",
        )
        self.assertEqual(codec_quality_tag(ProbeResult(status="audio", codec="aac", audio_kind="lossy")), "aac")

    def test_apply_consensus_album_artist_fills_missing_album_artist(self):
        first = normalize_metadata(
            {
                "artist": "Teddy Swims",
                "album_artist": "Teddy Swims",
                "album": "Album",
                "title": "Song A",
                "year": "2025",
                "track": "1",
            }
        )
        second = normalize_metadata(
            {
                "artist": "Guest/Teddy Swims",
                "album_artist": "",
                "album": "Album",
                "title": "Song B",
                "year": "2025",
                "track": "2",
            }
        )

        harmonized = apply_consensus_album_artist([first, second])

        self.assertEqual(harmonized[1].album_artist, "Teddy Swims")
        self.assertEqual(harmonized[1].routing_artist, "Teddy Swims")
        self.assertNotIn("album_artist", harmonized[1].missing_important_tags)

    def test_apply_album_group_consensus_overrides_outlier_routing_artist(self):
        dominant = normalize_metadata(
            {
                "artist": "Teddy Swims",
                "album_artist": "Teddy Swims",
                "album": "Album",
                "title": "Song A",
                "year": "2025",
                "track": "1",
            }
        )
        outlier = normalize_metadata(
            {
                "artist": "Teddy Swims/Muni Long",
                "album_artist": "Teddy Swims/Muni Long",
                "album": "Album",
                "title": "Song B",
                "year": "2025",
                "track": "2",
            }
        )
        harmonized = apply_album_group_consensus([dominant, dominant, outlier])
        self.assertEqual(harmonized[2].routing_artist, "Teddy Swims")

    def test_album_quality_suffix_combines_multiple_qualities(self):
        self.assertEqual(album_quality_suffix(["24-44", "24-48", "24-44"]), "[24-48][24-44]")


if __name__ == "__main__":
    unittest.main()
