from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

OUTPUT_FORMATS = ("alac", "flac", "wav", "native")


def add_audio_format_argument(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "--audio-format",
        choices=OUTPUT_FORMATS,
        default="alac",
        help=(
            "output format: alac (.m4a, default), flac, wav, or native "
            "(original codec). Lossless output cannot restore quality missing "
            "from the YouTube source."
        ),
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="musicpipelineyt",
        description=(
            "Download the best audio stream yt-dlp can get for a single "
            "YouTube URL or playlist and save it as ALAC, FLAC, WAV, or native audio."
        ),
    )
    parser.add_argument("--output-dir", required=True, type=Path, help="folder where the downloaded audio should land")
    parser.add_argument("--dry-run", action="store_true", help="show the selected format and destination without downloading")
    add_audio_format_argument(parser)
    parser.add_argument("uri", help="YouTube video or playlist URL")
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return run(args.output_dir.resolve(), args.uri, dry_run=args.dry_run, audio_format=args.audio_format)


def run(
    output_dir: Path,
    uri: str,
    dry_run: bool = False,
    *,
    playlist: bool = True,
    audio_format: str = "alac",
) -> int:
    if audio_format not in OUTPUT_FORMATS:
        raise ValueError(f"unsupported audio format: {audio_format}")
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
        "bestaudio",
        "--extract-audio",
        "--audio-format",
        "best",
        "--yes-playlist" if playlist else "--no-playlist",
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
                "video:----------------------------------------",
                "--print",
                "video:Title: %(playlist_index&{} - |)s%(title|untitled)s",
                "--print",
                "video:Format: id=%(format_id|?)s ext=%(ext|?)s acodec=%(acodec|?)s abr=%(abr|?)s asr=%(asr|?)s",
                "--print",
                "video:Source path (before audio extraction): %(filename|unknown)s",
                "--print",
                f"video:Output audio format: {audio_format}",
            ]
        )
        return subprocess.run(command + ["--", uri], check=False).returncode

    with tempfile.NamedTemporaryFile(prefix="musicpipelineyt.paths.", delete=False) as handle:
        path_log = Path(handle.name)
    try:
        completed = subprocess.run(
            command + ["--print", "after_move:filepath", "--", uri],
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
                try:
                    audio_path = _convert_audio(Path(downloaded_file), audio_format)
                except (OSError, ValueError, RuntimeError) as error:
                    print(f"error: {error}", file=sys.stderr)
                    return 1
                report_file(audio_path)
        return 0
    finally:
        path_log.unlink(missing_ok=True)


def _convert_audio(source: Path, audio_format: str) -> Path:
    if audio_format == "native":
        return source
    extension, codec, options = {
        "alac": (".m4a", "alac", ["-sample_fmt", "s32p", "-bits_per_raw_sample", "24", "-movflags", "+faststart"]),
        "flac": (".flac", "flac", ["-sample_fmt", "s32", "-bits_per_raw_sample", "24"]),
        "wav": (".wav", "pcm_s24le", []),
    }[audio_format]
    destination = source.with_suffix(extension)
    if destination != source and destination.exists():
        raise FileExistsError(f"output already exists: {destination}; downloaded source retained at {source}")
    with tempfile.NamedTemporaryFile(prefix=".musicpipeline-grab-", suffix=extension, dir=source.parent, delete=False) as handle:
        temporary = Path(handle.name)
    try:
        completed = subprocess.run(
            ["ffmpeg", "-nostdin", "-v", "error", "-y", "-i", str(source),
             "-map", "0:a:0", "-vn", "-map_metadata", "0", "-c:a", codec,
             *options, str(temporary)],
            check=False, capture_output=True, text=True,
        )
        if completed.returncode != 0:
            raise RuntimeError(f"{audio_format} encoding failed; source retained at {source}\n{completed.stderr.strip()}")
        probe = subprocess.run(
            ["ffprobe", "-v", "error", "-select_streams", "a:0", "-show_entries",
             "stream=codec_name", "-of", "json", str(temporary)],
            check=False, capture_output=True, text=True,
        )
        try:
            streams = json.loads(probe.stdout).get("streams", [])
        except (ValueError, AttributeError):
            streams = []
        if probe.returncode != 0 or not streams or streams[0].get("codec_name") != codec:
            raise RuntimeError(f"{audio_format} output validation failed; source retained at {source}")
        if destination == source:
            temporary.replace(destination)
        else:
            # Publish without overwriting a file created while ffmpeg was running.
            destination.hardlink_to(temporary)
            source.unlink()
        return destination
    finally:
        temporary.unlink(missing_ok=True)


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
    return "%(artist,uploader,channel|Unknown Artist)s - %(title|untitled)s [YouTube].%(ext)s"


if __name__ == "__main__":
    raise SystemExit(main())
