from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="musicpipelineyt",
        description=(
            "Download the best native audio stream yt-dlp can get for a single "
            "YouTube URL or playlist without converting it."
        ),
    )
    parser.add_argument("--output-dir", required=True, type=Path, help="folder where the downloaded audio should land")
    parser.add_argument("--dry-run", action="store_true", help="show the selected format and destination without downloading")
    parser.add_argument("uri", help="YouTube video or playlist URL")
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return run(args.output_dir.resolve(), args.uri, dry_run=args.dry_run)


def run(output_dir: Path, uri: str, dry_run: bool = False) -> int:
    for command in ("yt-dlp", "ffmpeg", "ffprobe"):
        _need_cmd(command)

    if not dry_run:
        output_dir.mkdir(parents=True, exist_ok=True)

    command = [
        "yt-dlp",
        "--ignore-config",
        "--no-update",
        "--output-na-placeholder",
        "?",
        "--format",
        "bestaudio/best",
        "--yes-playlist",
        "--write-info-json",
        "--paths",
        f"home:{output_dir}",
        "--output",
        _output_template(),
    ]

    if dry_run:
        command.extend(
            [
                "--simulate",
                "--print",
                "before_dl:----------------------------------------",
                "--print",
                "before_dl:Title: %(playlist_index&{} - |)s%(title|untitled)s",
                "--print",
                "before_dl:Format: id=%(format_id|?)s ext=%(ext|?)s acodec=%(acodec|?)s abr=%(abr|?)s asr=%(asr|?)s",
                "--print",
                "before_dl:Path: %(filename|unknown)s",
            ]
        )
        return subprocess.run(command + [uri], check=False).returncode

    with tempfile.NamedTemporaryFile(prefix="musicpipelineyt.paths.", delete=False) as handle:
        path_log = Path(handle.name)
    try:
        completed = subprocess.run(
            command + ["--print", "after_move:filepath", uri],
            check=False,
            capture_output=True,
            text=True,
        )
        if completed.returncode != 0:
            if completed.stdout:
                print(completed.stdout, end="")
            if completed.stderr:
                print(completed.stderr, end="", file=sys.stderr)
            return completed.returncode
        path_log.write_text(completed.stdout, encoding="utf-8")
        for line in path_log.read_text(encoding="utf-8").splitlines():
            downloaded_file = line.strip()
            if downloaded_file:
                report_file(Path(downloaded_file))
        return 0
    finally:
        path_log.unlink(missing_ok=True)


def report_file(path: Path) -> None:
    if not path.is_file():
        print(f"saved: {path}")
        print("stream: file was reported by yt-dlp but is not visible on disk yet")
        return
    completed = subprocess.run(
        [
            "ffprobe",
            "-v",
            "error",
            "-select_streams",
            "a:0",
            "-show_entries",
            "format=format_name,bit_rate:stream=codec_name,sample_rate,channels,bit_rate",
            "-of",
            "default=noprint_wrappers=1",
            str(path),
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    probe_lines = completed.stdout.splitlines()
    values: dict[str, list[str]] = {}
    for line in probe_lines:
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        values.setdefault(key, []).append(value)
    bitrate_values = values.get("bit_rate", [])
    audio_bitrate = bitrate_values[0] if bitrate_values else ""
    if not audio_bitrate or audio_bitrate == "N/A":
        audio_bitrate = bitrate_values[1] if len(bitrate_values) > 1 else "unknown"
    print(f"saved: {path}")
    print(
        "stream: "
        f"container={_first(values, 'format_name', 'unknown')} "
        f"codec={_first(values, 'codec_name', 'unknown')} "
        f"sample_rate={_first(values, 'sample_rate', 'unknown')}Hz "
        f"channels={_first(values, 'channels', 'unknown')} "
        f"bitrate={pretty_bitrate(audio_bitrate)}"
    )


def pretty_bitrate(value: str) -> str:
    try:
        bitrate = int(value, 10)
    except (TypeError, ValueError):
        return value or "unknown"
    return f"{bitrate // 1000} kb/s"


def _first(values: dict[str, list[str]], key: str, default: str) -> str:
    items = values.get(key) or []
    return items[0] if items else default


def _need_cmd(command: str) -> None:
    if shutil.which(command):
        return
    if command == "yt-dlp":
        raise SystemExit(f"error: missing required command: {command} (install with: brew install yt-dlp ffmpeg)")
    raise SystemExit(f"error: missing required command: {command}")


def _output_template() -> str:
    return "%(playlist,uploader,channel|Unknown Source)s/%(playlist_index&{} - |)s%(title|untitled)s [%(id)s].%(ext)s"
