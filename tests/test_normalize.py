import unittest

from musicpipeline.models import ProbeResult
from musicpipeline.normalize import codec_quality_tag, normalize_metadata, sanitize_path_component


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


if __name__ == "__main__":
    unittest.main()
