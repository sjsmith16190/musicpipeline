# MusicPipeline

`musicpipeline` is a metadata-first library normalizer for messy music intake roots.

The current implementation is centered on a Python planner/executor with a thin `zsh` shim for shell usage:

- `audit`
- `sort`
- `convert`
- `both`
- `audio-scrape`
- `retag`
- `retag-apply`
- `undo`
- `delete-empty-dirs`
- `delete-source`

The working root is the current directory unless you pass `--root`.

Your shell can keep exposing `musicpipeline` by sourcing [musicpipeline.zsh](/Users/sjsmith/Desktop/sjsmith16190/musicpipeline/musicpipeline.zsh) from `.zshrc`. That file now contains no legacy sorting logic; it only dispatches into the Python CLI.

## Requirements

- Python 3.11+
- `ffprobe`
- `ffmpeg`
- `yt-dlp` for `musicpipelineyt`
- `fpcalc` plus an `ACOUSTID_CLIENT` API key for `retag` on untagged files

## Managed Roots

These directories are pipeline-managed and excluded from normal `sort` and `audit` scans:

- `./_Lossy`
- `./_NoMetadata`
- `./_NotAudio`
- `./_Conflicts`
- `./_Quarantine`
- `./.musicpipeline`
- any `./<Artist>/_originalSource/...` subtree

## Core Rules

- Embedded metadata is the source of truth for normal library placement.
- There is no general filename or folder-name fallback for main library routing.
- Lossless audio is routed into the main library root.
- Lossy audio is routed under `./_Lossy`.
- Insufficient metadata routes to `./_NoMetadata`.
- Non-audio routes to `./_NotAudio/_{extension}/...`.
- Broken or unprobeable audio routes to `./_Quarantine/...`.
- Non-duplicate path collisions route to `./_Conflicts/...`.
- Exact duplicates are removed by keeping the existing destination copy.
- Missing important routable tags are recorded in `./.musicpipeline/missing_tags.json`.

## Naming

Standard album:

```text
Artist/[YEAR] Album [quality]/[track] Title [quality].ext
Artist/Album [quality]/[track] Title [quality].ext
```

Multi-disc album:

```text
Artist/[YEAR] Album [quality]/[disc-track] Title [quality].ext
```

Single:

```text
Artist/[YEAR] Artist - Title [quality].ext
Artist/Artist - Title [quality].ext
```

Various Artists album:

```text
[YEAR] VA - Album [quality]/[track] Artist - Title [quality].ext
VA - Album [quality]/[track] Artist - Title [quality].ext
```

Lossy uses the same structure under `./_Lossy`.

## Commands

### `audit`

Read-only dry run of the `sort` planner.

Examples:

```zsh
python3 -m musicpipeline audit
python3 -m musicpipeline audit --root "/path/to/library"
zsh ./musicpipeline.zsh audit "/path/to/library"
```

`audit` prints what `sort` would do and does not write run state.

### `sort`

Scans the working root, classifies files, builds the deterministic routing plan, and executes it.

Examples:

```zsh
python3 -m musicpipeline sort
python3 -m musicpipeline sort --dry-run --root "/path/to/library"
zsh ./musicpipeline.zsh sort "/path/to/library"
```

### `convert`

Converts eligible lossless audio to ALAC `.m4a`, validates the output, and preserves original source material under per-artist `_originalSource`.

Current implementation notes:

- release conversion requires stable album metadata across the release directory
- single-file conversion requires `artist` and `title`
- if a valid ALAC destination already exists, conversion is skipped
- failed conversions are quarantined

Examples:

```zsh
python3 -m musicpipeline convert
python3 -m musicpipeline convert --dry-run --root "/path/to/library"
zsh ./musicpipeline.zsh convert "/path/to/library"
```

### `both`

Runs:

```text
convert -> sort
```

Examples:

```zsh
python3 -m musicpipeline both --root "/path/to/library"
zsh ./musicpipeline.zsh both "/path/to/library"
```

### `audio-scrape`

Imports audio plus common related sidecars into the working root while preserving the source-relative structure.

Behavior:

- requires an explicit source directory
- default mode is copy
- `--move` moves instead of copying
- `--bucket-by-format` flattens imported files into destination buckets such as `./_flac`, `./_alac`, and `./_mp3`
- rejects source/root overlaps such as scraping the library into itself
- skips managed and internal directories such as `.musicpipeline`, `_NoMetadata`, `_NotAudio`, `_Lossy`, `_Quarantine`, `_Conflicts`, and `_originalSource`
- empty-dir cleanup runs only after move mode
- `--destination DIR` is the preferred destination flag
- `--root DIR` and the legacy shell `--output DIR` are accepted as backward-compatible aliases

Examples:

```zsh
python3 -m musicpipeline audio-scrape "/path/to/source"
python3 -m musicpipeline audio-scrape "/path/to/source" --move
python3 -m musicpipeline audio-scrape "/path/to/source" --destination "/path/to/library"
python3 -m musicpipeline audio-scrape "/path/to/source" --destination "/path/to/library" --bucket-by-format
zsh ./musicpipeline.zsh audio-scrape --output "/path/to/library" "/path/to/source"
```

### `delete-empty-dirs`

Removes empty directories under the target root.

Examples:

```zsh
python3 -m musicpipeline delete-empty-dirs --root "/path/to/library"
zsh ./musicpipeline.zsh delete-empty-dirs "/path/to/library"
```

### `undo`

Reverses the most recent reversible manifest-backed run under the target root.

Behavior:

- looks in `./.musicpipeline/runs/*.jsonl`
- defaults to the latest run with `move` or `move_tree` events
- replays those events in reverse order
- skips irreversible actions such as duplicate deletions
- supports `--dry-run`
- `--run-id` can target a specific recorded run prefix

Examples:

```zsh
python3 -m musicpipeline undo --root "/path/to/library"
python3 -m musicpipeline undo --dry-run --root "/path/to/library"
python3 -m musicpipeline undo --run-id 20260422T231500Z --root "/path/to/library"
zsh ./musicpipeline.zsh undo "/path/to/library"
```

### `retag`

Generates a review manifest of proposed metadata updates from MusicBrainz. This command does not write tags into audio files.

Behavior:

- default provider is `musicbrainz`
- uses `fpcalc` plus `ACOUSTID_CLIENT` for fingerprint-based lookup on poorly tagged or untagged files
- falls back to MusicBrainz text search when `artist` and `title` already exist
- writes a review manifest to `./.musicpipeline/retag_review.json`
- every proposal is created with `"approved": false`

Examples:

```zsh
python3 -m musicpipeline retag --root "/path/to/library"
ACOUSTID_CLIENT="your_key" python3 -m musicpipeline retag --root "/path/to/library"
zsh ./musicpipeline.zsh retag "/path/to/library"
```

Review the generated JSON and set `"approved": true` only for the entries you want to apply.

### `retag-apply`

Applies only the approved entries from the review manifest using `exiftool`.

Behavior:

- ignores entries unless `"approved": true`
- ignores entries that are unmatched, ambiguous, or have no proposed changes
- supports `--dry-run`

Examples:

```zsh
python3 -m musicpipeline retag-apply --root "/path/to/library"
python3 -m musicpipeline retag-apply --dry-run --root "/path/to/library"
zsh ./musicpipeline.zsh retag-apply "/path/to/library"
```

### `delete-source`

Deletes `_originalSource` trees and the `_NotAudio` directory when present.

Behavior:

- default mode prints a recursive audit listing for each target before prompting
- default mode prompts per discovered `_originalSource` tree and for `./_NotAudio`
- `--yes` deletes all discovered targets without prompting

Examples:

```zsh
python3 -m musicpipeline delete-source --root "/path/to/library"
python3 -m musicpipeline delete-source --yes --root "/path/to/library"
zsh ./musicpipeline.zsh delete-source "/path/to/library"
```

## State

Mutating commands write run logs and manifests under:

```text
./.musicpipeline/runs/
```

Missing-tag entries are written to:

```text
./.musicpipeline/missing_tags.json
```

## YouTube Helper

If your `.zshrc` sources [musicpipeline_youtube.zsh](/Users/sjsmith/Desktop/sjsmith16190/musicpipeline/musicpipeline_youtube.zsh), you can keep using:

```zsh
musicpipelineyt --output-dir "/path/to/output" "https://www.youtube.com/watch?v=VIDEO_ID"
musiclibyt --output-dir "/path/to/output" "https://www.youtube.com/watch?v=VIDEO_ID"
```

That file is now only a zsh shim into the Python implementation in [musicpipeline/youtube.py](/Users/sjsmith/Desktop/sjsmith16190/musicpipeline/musicpipeline/youtube.py).

## Compatibility Notes

- [musicpipeline.zsh](/Users/sjsmith/Desktop/sjsmith16190/musicpipeline/musicpipeline.zsh) is now only a sourceable/execable shim into the Python CLI.
- [musicpipeline_youtube.zsh](/Users/sjsmith/Desktop/sjsmith16190/musicpipeline/musicpipeline_youtube.zsh) is now only a sourceable/execable shim into the Python YouTube helper.
- The old shell implementation files were removed so there is no legacy sort/convert route left to call accidentally.
