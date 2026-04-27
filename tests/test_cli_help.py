import io
import unittest
from contextlib import redirect_stdout

from musicpipeline.cli import main


class CliHelpTests(unittest.TestCase):
    def test_top_level_help_includes_command_descriptions(self):
        stdout = io.StringIO()

        with redirect_stdout(stdout):
            with self.assertRaises(SystemExit) as raised:
                main(["--help"])

        output = stdout.getvalue()
        self.assertEqual(raised.exception.code, 0)
        self.assertIn("Normalize and maintain a messy music intake library.", output)
        self.assertIn("commands:", output)
        self.assertIn("audio-scrape       import audio plus sidecars", output)
        self.assertIn("musicpipeline <command> --help", output)

    def test_subcommand_help_includes_description_and_detailed_options(self):
        stdout = io.StringIO()

        with redirect_stdout(stdout):
            with self.assertRaises(SystemExit) as raised:
                main(["retag", "--help"])

        output = stdout.getvalue()
        self.assertEqual(raised.exception.code, 0)
        self.assertIn("Build a review manifest of proposed metadata tag changes", output)
        self.assertIn("tag lookup provider to use when building the review", output)
        self.assertIn("AcoustID client key to use for fingerprint-based", output)


if __name__ == "__main__":
    unittest.main()
