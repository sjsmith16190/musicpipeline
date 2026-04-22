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
    parser = argparse.ArgumentParser(prog="musicpipeline")
    subparsers = parser.add_subparsers(dest="command", required=True)

    _add_root_command(subparsers, "audit")
    _add_root_command(subparsers, "sort", allow_dry_run=True)
    _add_root_command(subparsers, "convert", allow_dry_run=True)
    _add_root_command(subparsers, "both", allow_dry_run=True)
    _add_root_command(subparsers, "delete-empty-dirs", allow_dry_run=True)
    undo = _add_root_command(subparsers, "undo", allow_dry_run=True)
    undo.add_argument("--run-id")
    retag = _add_root_command(subparsers, "retag")
    retag.add_argument("--provider", default="musicbrainz")
    retag.add_argument("--manifest", type=Path)
    retag.add_argument("--acoustid-client")
    retag_apply = _add_root_command(subparsers, "retag-apply", allow_dry_run=True)
    retag_apply.add_argument("--manifest", type=Path)

    delete_source = _add_root_command(subparsers, "delete-source", allow_dry_run=True)
    delete_source.add_argument("--yes", action="store_true", help="delete without per-folder prompts")

    audio_scrape = subparsers.add_parser("audio-scrape")
    audio_scrape.add_argument("source", nargs="?", type=Path)
    audio_scrape.add_argument("--root", type=Path, default=Path.cwd())
    audio_scrape.add_argument("--move", action="store_true")
    audio_scrape.add_argument("--dry-run", action="store_true")
    return parser


def _add_root_command(subparsers, name: str, allow_dry_run: bool = False):
    parser = subparsers.add_parser(name)
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("target", nargs="?", type=Path)
    if allow_dry_run:
        parser.add_argument("--dry-run", action="store_true")
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
        return command_audio_scrape(args.root.resolve(), (args.source or Path.cwd()).resolve(), move=args.move, dry_run=args.dry_run)
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
