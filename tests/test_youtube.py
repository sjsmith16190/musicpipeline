import io
import json
import shutil
import subprocess
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest.mock import patch

from musicpipeline.cli import main as cli_main
from musicpipeline.youtube import _convert_audio, build_parser, pretty_bitrate, run


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
        self.assertEqual(args.audio_format, "alac")
        self.assertEqual(args.uri, "https://www.youtube.com/watch?v=VIDEO_ID")

    def test_grab_defaults_to_current_directory_and_single_video(self):
        uri = "https://www.youtube.com/watch?v=VIDEO_ID&list=PLAYLIST_ID"
        with patch("musicpipeline.cli.command_grab", return_value=0) as download:
            result = cli_main(["grab", uri])

        self.assertEqual(result, 0)
        download.assert_called_once_with(
            Path.cwd().resolve(), uri, dry_run=False, playlist=False, audio_format="alac"
        )

    def test_grab_forwards_output_directory_dry_run_playlist_and_exit_code(self):
        uri = "https://www.youtube.com/watch?v=VIDEO_ID&list=PLAYLIST_ID"
        with patch("musicpipeline.cli.command_grab", return_value=7) as download:
            result = cli_main([
                "grab", uri, "-o", "downloads", "--dry-run", "--playlist",
                "--audio-format", "flac",
            ])

        self.assertEqual(result, 7)
        download.assert_called_once_with(
            Path("downloads").resolve(), uri, dry_run=True, playlist=True, audio_format="flac"
        )

    @patch("musicpipeline.youtube._need_cmd")
    def test_dry_run_selects_only_native_audio_without_creating_output(self, need_cmd):
        uri = "https://www.youtube.com/watch?v=VIDEO_ID"
        with tempfile.TemporaryDirectory() as temp_dir:
            output_dir = Path(temp_dir) / "new downloads"
            with patch("musicpipeline.youtube.subprocess.run") as execute:
                execute.return_value.returncode = 0
                result = run(output_dir, uri, dry_run=True, playlist=False)
            self.assertFalse(output_dir.exists())

        self.assertEqual(result, 0)
        command = execute.call_args.args[0]
        self.assertEqual(command[command.index("--format") + 1], "bestaudio")
        self.assertIn("--ignore-config", command)
        self.assertIn("--simulate", command)
        self.assertIn("--no-playlist", command)
        self.assertNotIn("--yes-playlist", command)
        self.assertIn("--extract-audio", command)
        self.assertEqual(command[command.index("--audio-format") + 1], "best")
        self.assertEqual(command[-2:], ["--", uri])

    @patch("musicpipeline.youtube._need_cmd")
    def test_download_reports_native_stream_details(self, need_cmd):
        uri = "https://www.youtube.com/watch?v=VIDEO_ID"
        with tempfile.TemporaryDirectory() as temp_dir:
            output_dir = Path(temp_dir)
            audio_path = output_dir / "Track with spaces [VIDEO_ID].opus"
            audio_path.touch()
            stdout = io.StringIO()
            with patch("musicpipeline.youtube.subprocess.run") as execute:
                execute.side_effect = [
                    subprocess.CompletedProcess([], 0, f"{audio_path}\n", ""),
                    subprocess.CompletedProcess(
                        [],
                        0,
                        "codec_name=opus\nsample_rate=48000\nchannels=2\n"
                        "bit_rate=N/A\nformat_name=ogg\nbit_rate=160000\n",
                        "",
                    ),
                ]
                with redirect_stdout(stdout):
                    result = run(output_dir, uri, audio_format="native")

        self.assertEqual(result, 0)
        self.assertEqual(execute.call_count, 2)
        download_command = execute.call_args_list[0].args[0]
        self.assertIn("--yes-playlist", download_command)
        self.assertEqual(download_command[download_command.index("--format") + 1], "bestaudio")
        self.assertEqual(execute.call_args_list[1].args[0][0], "ffprobe")
        self.assertIn(f"saved: {audio_path}", stdout.getvalue())
        self.assertIn("codec=opus sample_rate=48000Hz channels=2 bitrate=160 kb/s", stdout.getvalue())

    @patch("musicpipeline.youtube._need_cmd")
    def test_download_failure_surfaces_diagnostics_and_exit_code(self, need_cmd):
        stdout = io.StringIO()
        stderr = io.StringIO()
        with tempfile.TemporaryDirectory() as temp_dir:
            with patch("musicpipeline.youtube.subprocess.run") as execute:
                execute.return_value = subprocess.CompletedProcess(
                    [], 1, "Resolving video\n", "ERROR: Requested format is not available\n"
                )
                with redirect_stdout(stdout), redirect_stderr(stderr):
                    result = run(Path(temp_dir), "https://www.youtube.com/watch?v=VIDEO_ID")

        self.assertEqual(result, 1)
        execute.assert_called_once()
        self.assertIn("Resolving video", stdout.getvalue())
        self.assertIn("Requested format is not available", stderr.getvalue())

    @unittest.skipUnless(shutil.which("yt-dlp"), "yt-dlp is not installed")
    def test_dry_run_prints_selected_audio_with_real_downloader(self):
        real_run = subprocess.run
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            output_dir = root / "preview"
            info_path = root / "video.info.json"
            info_path.write_text(json.dumps({
                "id": "offline-audio-test",
                "title": "Offline Audio Test",
                "uploader": "Test Uploader",
                "extractor": "youtube",
                "formats": [
                    {"format_id": "audio-low", "url": "https://example.invalid/low.webm",
                     "ext": "webm", "vcodec": "none", "acodec": "opus", "abr": 48},
                    {"format_id": "audio-best", "url": "https://example.invalid/best.webm",
                     "ext": "webm", "vcodec": "none", "acodec": "opus", "abr": 160},
                    {"format_id": "combined", "url": "https://example.invalid/video.mp4",
                     "ext": "mp4", "vcodec": "avc1", "acodec": "aac", "abr": 256},
                ],
            }), encoding="utf-8")
            results = []

            def simulate_from_fixture(command, **kwargs):
                completed = real_run(
                    command[:-2] + ["--load-info-json", str(info_path)],
                    **kwargs,
                    capture_output=True,
                    text=True,
                )
                results.append(completed)
                return completed

            with patch("musicpipeline.youtube._need_cmd"), patch(
                "musicpipeline.youtube.subprocess.run", side_effect=simulate_from_fixture
            ):
                result = run(output_dir, "https://www.youtube.com/watch?v=TEST", dry_run=True)

            self.assertFalse(output_dir.exists())
            self.assertEqual(result, 0, results[0].stderr)
            self.assertIn("Format: id=audio-best ext=webm acodec=opus abr=160", results[0].stdout)
            self.assertIn(str(output_dir / "Test Uploader"), results[0].stdout)

    @unittest.skipUnless(
        all(shutil.which(command) for command in ("yt-dlp", "ffmpeg", "ffprobe")),
        "yt-dlp, ffmpeg, and ffprobe are required",
    )
    def test_native_audio_files_preserve_encoded_packets(self):
        real_run = subprocess.run

        def packet_hashes(path):
            completed = real_run(
                ["ffprobe", "-v", "error", "-select_streams", "a:0",
                 "-show_packets", "-show_entries", "packet=data_hash",
                 "-show_data_hash", "sha256", "-of", "json", str(path)],
                check=True, capture_output=True, text=True,
            )
            return [packet["data_hash"] for packet in json.loads(completed.stdout)["packets"]]

        for source_ext, encoder, codec, output_ext, audio_format in (
            ("webm", "libopus", "opus", "opus", "native"),
            ("m4a", "aac", "mp4a.40.2", "m4a", "native"),
            ("webm", "libopus", "opus", "m4a", "alac"),
        ):
            with self.subTest(codec=codec), tempfile.TemporaryDirectory() as temp_dir:
                root = Path(temp_dir)
                source = root / f"source.{source_ext}"
                real_run(
                    ["ffmpeg", "-nostdin", "-v", "error", "-f", "lavfi",
                     "-i", "sine=frequency=440:duration=0.2", "-c:a", encoder, str(source)],
                    check=True, capture_output=True, text=True,
                )
                info_path = root / "video.info.json"
                info_path.write_text(json.dumps({
                    "id": "offline-audio-test", "title": "Audio Test",
                    "uploader": "Test Uploader", "extractor": "youtube",
                    "formats": [{
                        "format_id": "native-audio", "url": source.as_uri(),
                        "ext": source_ext, "vcodec": "none", "acodec": codec,
                    }],
                }), encoding="utf-8")

                def download_from_fixture(command, **kwargs):
                    if command[0] == "yt-dlp":
                        command = command[:-2] + [
                            "--enable-file-urls", "--load-info-json", str(info_path)
                        ]
                    return real_run(command, **kwargs)

                stdout = io.StringIO()
                stderr = io.StringIO()
                output_dir = root / "downloads"
                with patch("musicpipeline.youtube.subprocess.run", side_effect=download_from_fixture):
                    with redirect_stdout(stdout), redirect_stderr(stderr):
                        result = run(output_dir, "https://www.youtube.com/watch?v=TEST", audio_format=audio_format)

                self.assertEqual(result, 0, stderr.getvalue())
                outputs = list(output_dir.rglob(f"*.{output_ext}"))
                self.assertEqual(len(outputs), 1)
                self.assertIn(f"saved: {outputs[0]}", stdout.getvalue())
                if audio_format == "native":
                    self.assertEqual(packet_hashes(source), packet_hashes(outputs[0]))
                else:
                    self.assertIn("codec=alac", stdout.getvalue())
                self.assertFalse(list(output_dir.rglob("*.webm")))

    @unittest.skipUnless(
        all(shutil.which(command) for command in ("ffmpeg", "ffprobe")),
        "ffmpeg and ffprobe are required",
    )
    def test_lossless_formats_preserve_decoded_24bit_audio(self):
        def decoded_hash(path):
            completed = subprocess.run(
                ["ffmpeg", "-nostdin", "-v", "error", "-i", str(path),
                 "-map", "0:a:0", "-c:a", "pcm_s24le", "-f", "hash", "-hash", "sha256", "-"],
                check=True, capture_output=True, text=True,
            )
            return completed.stdout

        for source_ext, encoder in (("opus", "libopus"), ("m4a", "aac")):
            with tempfile.TemporaryDirectory() as temp_dir:
                root = Path(temp_dir)
                original = root / f"original.{source_ext}"
                subprocess.run(
                    ["ffmpeg", "-nostdin", "-v", "error", "-f", "lavfi",
                     "-i", "sine=frequency=440:duration=0.2", "-ac", "2",
                     "-c:a", encoder, str(original)],
                    check=True, capture_output=True, text=True,
                )
                expected_hash = decoded_hash(original)
                for audio_format, extension, codec in (
                    ("alac", ".m4a", "alac"),
                    ("flac", ".flac", "flac"),
                    ("wav", ".wav", "pcm_s24le"),
                ):
                    with self.subTest(source=source_ext, output=audio_format):
                        source = root / f"output-{audio_format}.{source_ext}"
                        shutil.copyfile(original, source)
                        destination = _convert_audio(source, audio_format)
                        self.assertEqual(destination.suffix, extension)
                        self.assertEqual(decoded_hash(destination), expected_hash)
                        probe = subprocess.run(
                            ["ffprobe", "-v", "error", "-select_streams", "a:0",
                             "-show_entries", "stream=codec_name,channels", "-of", "json", str(destination)],
                            check=True, capture_output=True, text=True,
                        )
                        stream = json.loads(probe.stdout)["streams"][0]
                        self.assertEqual(stream["codec_name"], codec)
                        self.assertEqual(stream["channels"], 2)
                        if destination != source:
                            self.assertFalse(source.exists())
                self.assertFalse(list(root.glob(".musicpipeline-grab-*")))

    def test_failed_encoding_retains_download_and_cleans_temporary_file(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            source = Path(temp_dir) / "track.opus"
            source.write_bytes(b"original audio")
            with patch("musicpipeline.youtube.subprocess.run") as execute:
                execute.return_value = subprocess.CompletedProcess([], 1, "", "encoding failed")
                with self.assertRaisesRegex(RuntimeError, "source retained"):
                    _convert_audio(source, "alac")
            self.assertEqual(source.read_bytes(), b"original audio")
            self.assertFalse(source.with_suffix(".m4a").exists())
            self.assertFalse(list(Path(temp_dir).glob(".musicpipeline-grab-*")))

    def test_failed_validation_retains_aac_source(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            source = Path(temp_dir) / "track.m4a"
            source.write_bytes(b"original AAC audio")
            with patch("musicpipeline.youtube.subprocess.run") as execute:
                execute.side_effect = [
                    subprocess.CompletedProcess([], 0, "", ""),
                    subprocess.CompletedProcess([], 0, '{"streams": [{"codec_name": "aac"}]}', ""),
                ]
                with self.assertRaisesRegex(RuntimeError, "validation failed"):
                    _convert_audio(source, "alac")
            self.assertEqual(source.read_bytes(), b"original AAC audio")
            self.assertFalse(list(Path(temp_dir).glob(".musicpipeline-grab-*")))

    def test_conversion_protects_existing_destination(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            source = Path(temp_dir) / "track.opus"
            destination = source.with_suffix(".m4a")
            source.write_bytes(b"source audio")
            destination.write_bytes(b"existing destination")
            with self.assertRaises(FileExistsError):
                _convert_audio(source, "alac")
            self.assertEqual(source.read_bytes(), b"source audio")
            self.assertEqual(destination.read_bytes(), b"existing destination")

    def test_shell_shim_exposes_grab_help(self):
        repo_root = Path(__file__).resolve().parents[1]
        completed = subprocess.run(
            ["zsh", str(repo_root / "musicpipeline.zsh"), "grab", "--help"],
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn("musicpipeline grab", completed.stdout)
        self.assertIn("--output-dir", completed.stdout)
        self.assertIn("--dry-run", completed.stdout)

    def test_legacy_shell_helper_exposes_help(self):
        repo_root = Path(__file__).resolve().parents[1]
        completed = subprocess.run(
            ["zsh", str(repo_root / "musicpipeline_youtube.zsh"), "--help"],
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn("musicpipelineyt", completed.stdout)
        self.assertIn("--output-dir", completed.stdout)


if __name__ == "__main__":
    unittest.main()
