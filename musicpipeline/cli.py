from __future__ import annotations

import argparse
from pathlib import Path

from .commands import (
    command_audit,
    command_audio_scrape,
    command_both,
    command_convert,
    command_delete_empty_dirs,
    command_delete_source,
    command_undo,
    command_retag_apply,
    command_retag_review,
    command_sort,
)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="musicpipeline",
        description=(
            "Normalize and maintain a messy music intake library. Commands cover "
            "planning (`audit`), sorting (`sort`), lossless-to-ALAC conversion "
            "(`convert`), combined convert+sort runs (`both`), source cleanup "
            "(`delete-source`), retag review/application (`retag`, `retag-apply`), "
            "undo, empty-directory cleanup, and audio importing from external "
            "staging folders (`audio-scrape`)."
        ),
        epilog=(
            "Run `musicpipeline <command> --help` for detailed help on one command.\n"
            "Examples:\n"
            "  musicpipeline sort --dry-run\n"
            "  musicpipeline both /path/to/library\n"
            "  musicpipeline audio-scrape /path/to/source --destination /path/to/library"
        ),
        formatter_class=argparse.RawTextHelpFormatter,
    )
    subparsers = parser.add_subparsers(
        dest="command",
        required=True,
        title="commands",
        metavar="command",
        description=(
            "Choose one command below. The command name is the main positional "
            "argument for `musicpipeline`."
        ),
    )

    _add_root_command(
        subparsers,
        "audit",
        description=(
            "Read-only planning pass for `sort`. This scans the target library root, "
            "classifies files, and prints the exact routing plan that `sort` would "
            "execute without moving or deleting anything."
        ),
        help_text="read-only dry run that prints the sort plan without changing files",
    )
    _add_root_command(
        subparsers,
        "sort",
        allow_dry_run=True,
        description=(
            "Scan the target library root, classify audio and sidecar files, and "
            "move them into the normalized library structure. This is the main "
            "organizing command."
        ),
        help_text="classify and route files into the library structure",
    )
    _add_root_command(
        subparsers,
        "convert",
        allow_dry_run=True,
        description=(
            "Convert eligible lossless source audio to ALAC `.m4a`, validate the "
            "result, and preserve original source material under `_originalSource` "
            "before later sorting."
        ),
        help_text="convert eligible lossless audio to ALAC `.m4a` and preserve sources",
    )
    _add_root_command(
        subparsers,
        "both",
        allow_dry_run=True,
        description=(
            "Run `convert` first and then `sort` against the same target library "
            "root. Use this when you want a single end-to-end intake pass."
        ),
        help_text="run `convert` first and then `sort` on the same library root",
    )
    _add_root_command(
        subparsers,
        "delete-empty-dirs",
        allow_dry_run=True,
        description=(
            "Remove empty directories under the target library root. This is useful "
            "after moves, imports, undos, or manual cleanup work."
        ),
        help_text="remove empty directories under the target root",
    )
    undo = _add_root_command(
        subparsers,
        "undo",
        allow_dry_run=True,
        description=(
            "Reverse the latest reversible manifest-backed run by replaying logged "
            "move operations in reverse order. This does not restore duplicate "
            "deletions or other irreversible actions."
        ),
        help_text="reverse the latest reversible manifest-backed run",
    )
    undo.add_argument(
        "--run-id",
        help=(
            "specific run manifest timestamp to undo. If omitted, the latest "
            "reversible run for this library root is used."
        ),
    )
    retag = _add_root_command(
        subparsers,
        "retag",
        description=(
            "Build a review manifest of proposed metadata tag changes for the target "
            "library root. This does not modify audio files; it creates a review "
            "step for later approval."
        ),
        help_text="build a review manifest of proposed tag changes",
    )
    retag.add_argument(
        "--provider",
        default="musicbrainz",
        help=(
            "tag lookup provider to use when building the review manifest. Defaults "
            "to `musicbrainz`."
        ),
    )
    retag.add_argument(
        "--manifest",
        type=Path,
        help=(
            "optional path for the generated review manifest. If omitted, the "
            "default `.musicpipeline/retag_review.json` path is used."
        ),
    )
    retag.add_argument(
        "--acoustid-client",
        help=(
            "AcoustID client key to use for fingerprint-based lookups. If omitted, "
            "the command falls back to the environment or metadata-only matching."
        ),
    )
    retag_apply = _add_root_command(
        subparsers,
        "retag-apply",
        allow_dry_run=True,
        description=(
            "Apply only the approved entries from a retag review manifest back into "
            "the target library's audio files."
        ),
        help_text="apply only the approved tag changes from a retag review manifest",
    )
    retag_apply.add_argument(
        "--manifest",
        type=Path,
        help=(
            "review manifest to apply. If omitted, the default "
            "`.musicpipeline/retag_review.json` path is used."
        ),
    )

    delete_source = _add_root_command(
        subparsers,
        "delete-source",
        allow_dry_run=True,
        description=(
            "Delete preserved `_originalSource` trees and the `_NotAudio` directory "
            "from the target library root after review. In interactive mode it "
            "audits each target before asking for confirmation."
        ),
        help_text="delete preserved `_originalSource` trees and `_NotAudio` after review",
    )
    delete_source.add_argument(
        "--yes",
        action="store_true",
        help=(
            "delete discovered `_originalSource` and `_NotAudio` targets without "
            "interactive confirmation prompts."
        ),
    )

    audio_scrape = subparsers.add_parser(
        "audio-scrape",
        help="import audio plus sidecars from a separate source tree into the library",
        description=(
            "Import audio files and common sidecars from a separate source directory "
            "into the target music library root while preserving the source-relative "
            "folder structure. Use this for ingesting downloads or staging folders, "
            "not for re-processing the library root itself."
        ),
    )
    audio_scrape.add_argument(
        "source",
        nargs="?",
        type=Path,
        help=(
            "directory to import from. This should be a separate staging/download "
            "folder that contains the audio and sidecar files you want to bring "
            "into the library."
        ),
    )
    audio_scrape.add_argument(
        "--destination",
        "--root",
        dest="root",
        type=Path,
        default=Path.cwd(),
        help=(
            "destination library root to import into. The scraped files keep their "
            "relative paths underneath this directory. Defaults to the current directory. "
            "`--root` is accepted as a backward-compatible alias."
        ),
    )
    audio_scrape.add_argument(
        "--move",
        action="store_true",
        help=(
            "move files out of the source directory instead of copying them. Empty "
            "source directories are cleaned up afterward."
        ),
    )
    audio_scrape.add_argument(
        "--bucket-by-format",
        action="store_true",
        help=(
            "flatten imported files into destination format buckets such as `_flac`, "
            "`_alac`, and `_mp3` instead of preserving the source directory structure."
        ),
    )
    audio_scrape.add_argument(
        "--dry-run",
        action="store_true",
        help=(
            "show what would be copied or moved without making any filesystem changes."
        ),
    )
    audio_scrape.set_defaults(_subparser=audio_scrape)
    return parser


def _add_root_command(
    subparsers,
    name: str,
    allow_dry_run: bool = False,
    help_text: str | None = None,
    description: str | None = None,
):
    parser = subparsers.add_parser(name, help=help_text, description=description)
    parser.add_argument(
        "--root",
        type=Path,
        default=Path.cwd(),
        help=(
            "target library root to operate on. Defaults to the current directory "
            "unless you provide the positional target path."
        ),
    )
    parser.add_argument(
        "target",
        nargs="?",
        type=Path,
        help=(
            "optional positional shorthand for the target library root. When both "
            "are given, this positional path takes precedence over `--root`."
        ),
    )
    if allow_dry_run:
        parser.add_argument(
            "--dry-run",
            action="store_true",
            help="preview the command without making filesystem changes.",
        )
    return parser


def _resolved_root(args) -> Path:
    return (args.target or args.root).resolve()


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    command = args.command
    if command == "audit":
        return command_audit(_resolved_root(args))
    if command == "sort":
        return command_sort(_resolved_root(args), dry_run=args.dry_run)
    if command == "convert":
        return command_convert(_resolved_root(args), dry_run=args.dry_run)
    if command == "both":
        return command_both(_resolved_root(args), dry_run=args.dry_run)
    if command == "audio-scrape":
        if args.source is None:
            args._subparser.print_help()
            return 2
        return command_audio_scrape(
            args.root.resolve(),
            args.source.resolve(),
            move=args.move,
            dry_run=args.dry_run,
            bucket_by_format=args.bucket_by_format,
        )
    if command == "delete-empty-dirs":
        return command_delete_empty_dirs(_resolved_root(args), dry_run=args.dry_run)
    if command == "undo":
        return command_undo(_resolved_root(args), dry_run=args.dry_run, run_id=args.run_id)
    if command == "retag":
        return command_retag_review(
            _resolved_root(args),
            provider=args.provider,
            manifest_path=args.manifest.resolve() if args.manifest else None,
            acoustid_client=args.acoustid_client,
        )
    if command == "retag-apply":
        return command_retag_apply(
            _resolved_root(args),
            manifest_path=args.manifest.resolve() if args.manifest else None,
            dry_run=args.dry_run,
        )
    if command == "delete-source":
        return command_delete_source(_resolved_root(args), dry_run=args.dry_run, yes=args.yes)
    parser.error(f"unknown command: {command}")
    return 2
