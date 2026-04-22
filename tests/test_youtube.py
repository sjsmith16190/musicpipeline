import unittest

from musicpipeline.youtube import build_parser, pretty_bitrate


class YouTubeHelperTests(unittest.TestCase):
    def test_pretty_bitrate_formats_numeric_values(self):
        self.assertEqual(pretty_bitrate("192000"), "192 kb/s")
        self.assertEqual(pretty_bitrate("unknown"), "unknown")

    def test_parser_accepts_existing_shell_call_shape(self):
        parser = build_parser()
        args = parser.parse_args(
            [
                "--output-dir",
                "/tmp/out",
                "--dry-run",
                "https://www.youtube.com/watch?v=VIDEO_ID",
            ]
        )
        self.assertEqual(str(args.output_dir), "/tmp/out")
        self.assertTrue(args.dry_run)
        self.assertEqual(args.uri, "https://www.youtube.com/watch?v=VIDEO_ID")


if __name__ == "__main__":
    unittest.main()
