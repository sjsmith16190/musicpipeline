# Music Prep Scripts

Authored by Stephen J. Smith  
Created: 2026-04-18

This folder contains a `zsh` toolkit for auditing, organizing, converting, and rolling back music-library intake work.

The main entrypoint is `musicpipeline.zsh`.

## Quick Start

1. Put newly downloaded music into either your lossless archive root or your lossy archive root.
2. Run an audit first:

```zsh
zsh ./musicpipeline.zsh audit "/path/to/Collection"
```

3. Run the full workflow on the archive root that actually contains the intake:

```zsh
zsh ./musicpipeline.zsh both "/path/to/Lossy"
```

4. If you need to roll back that run, undo it from the same target root:

```zsh
zsh ./musicpipeline.zsh undo "/path/to/Lossy"
```

## Files In This Folder

- `musicpipeline.zsh`: main CLI for `audit`, `sort`, `convert`, `both`, `undo`, and `cleanup-originals`
- `sort_music.zsh`: artist-root-only sorter
- `convert_music.zsh`: converter for artist roots or direct release folders
- `musicpipeline_youtube.zsh`: sourceable `musicpipelineyt` helper for native-source YouTube audio downloads
- `musicpipeline_common.zsh`: shared helper library
- `musicpipeline.config.zsh`: optional local config file for archive-aware routing

## Target Types

The wrapper understands three practical target types.

### 1. Collection Parent

A folder that contains both configured archive roots.

Example:

```text
Collection/
  Lossless/
  Lossy/
```

Use this for:

- `audit`

Do not use this for:

- `sort`
- `convert`
- `both`
- `undo`

Mutating commands require a narrower target.

### 2. Archive Root

A single intake/archive root that can contain:

- artist folders
- loose release folders
- loose tracks directly in the root

Example:

```text
Lossy/
  Kanye West/
  Some Loose Release/
  random single.flac
```

This is the normal target for:

- `sort`
- `convert`
- `both`
- `undo`

### 3. Artist Root

A single artist folder containing releases and/or loose tracks.

Example:

```text
Lossless/
  Kanye West/
    2004 - The College Dropout [16-44]/
    loose-track.flac
```

This is the narrowest valid target for:

- `sort`
- `convert`
- `both`

## Naming Conventions

Artist folders:

```text
Album Artist/
```

Album folders:

```text
[YYYY] Album [BitDepth-SampleRate]
```

Track files:

```text
Album tracks: [DD-TT] Title [BitDepth-SampleRate].ext
Loose singles: [YYYY] Artist - Title [BitDepth-SampleRate].ext
```

Examples:

```text
Kanye West/[2004] The College Dropout [16-44]/[01-01] We Don't Care [16-44].m4a
Kanye West/[2021] Donda (Deluxe) [16-44]/[02-01] Junya, Pt. 2 [16-44].m4a
Kanye West/[2014] Only One [24-48].m4a
```

This keeps multi-disc albums in one album folder while still sorting correctly alphabetically.

## Command Overview

### `audit`

Read-only preflight analysis.

It reports:

- target/root classification
- routing decisions
- normalized destination paths
- missing metadata
- duplicate normalized track targets
- folder and file conflicts
- existing ALAC outputs that would block conversion

`audit` writes a log and manifest into `.musicpipeline/runs`, but does not mutate your library files.

### `sort`

Normalizes structure and names.

Behavior:

- keeps standalone tracks directly under the artist folder
- normalizes album folder names
- recurses into nested artist-like folders instead of skipping them
- renames album tracks to `[DD-TT] Title [BitDepth-SampleRate].ext`
- renames loose singles to `[YYYY] Artist - Title [BitDepth-SampleRate].ext` when a year is available
- flattens nested disc folders
- quarantines `.cue`, `.log`, and `.txt` files into `.musicpipeline/trash`
- skips conflicts instead of auto-renaming over them

### `convert`

Converts eligible lossless source files to ALAC.

Behavior:

- converts `.flac`, `.wav`, `.aiff`, and `.aif` to `.m4a`
- splits single-file cue-based releases into per-track `.m4a` outputs
- prefers folder artwork first
- falls back to embedded source artwork
- archives original source files and whole converted release folders into `_originalSource`
- skips conflicting outputs instead of replacing them

### `both`

Runs:

1. sort
2. convert

This is the normal command for newly downloaded lossless material.

### `undo`

Reverses the most recent successful manifest-backed run recorded for the target root.

Behavior:

- removes ALAC files created by that run
- moves files and folders back to prior paths
- restores quarantined sidecars
- moves archived sources back out of `_originalSource`
- cleans up empty directories where possible

## Primary Artist Routing

Artist routing uses:

1. `album_artist`
2. `artist` if `album_artist` is missing

This means:

- collaboration releases stay under the primary tagged artist folder
- loose tracks are routed directly under the tagged primary artist folder
- the scripts do not try to infer “first billed artist” from a collaboration string

## Lossless / Lossy Routing

When you run against a configured lossy archive root:

- lossy-only material can stay in the lossy root
- lossless source material is rerouted into the configured lossless root before or during processing

This lets you throw mixed intake into one place while still ending up with a clean split between lossy and lossless storage.

## Config File

Archive-aware routing uses a separate config file beside the scripts:

```text
musicpipeline.config.zsh
```

Example:

```zsh
LOSSLESS_DIR_NAME='Lossless'
LOSSY_DIR_NAME='Lossy'
STATE_DIR_NAME='.musicpipeline'
SOURCE_ARCHIVE_DIR='_originalSource'
```

How it behaves:

- if the config file exists, it is loaded automatically
- if it is missing, artist-root and generic batch-root usage can still work
- archive-name-aware behavior depends on the config being present
- on a first interactive run that needs archive-name-aware routing, the script can prompt and write the config for you

## State, Logs, And Rollback

Each mutating run writes state into the target root:

```text
.musicpipeline/
  last_successful_run
  runs/
  trash/
```

This state is used for:

- manifests
- logs
- conflict reporting
- sidecar quarantine
- rollback

Important undo scope rule:

- `undo` is tied to the exact target root that recorded the run
- if you ran `both` on `Lossy`, undo from `Lossy`
- `undo` is only for the last successful run on that target

### `cleanup-originals`

Deletes every `_originalSource` directory under the chosen archive root, batch root, or artist root.

Safety behavior:

- always lists the folders it found before deleting anything
- supports `--dry-run` so you can inspect the target set first
- requires an interactive terminal
- requires typing an exact confirmation phrase before deletion starts

Examples:

```zsh
zsh ./musicpipeline.zsh cleanup-originals --dry-run "/path/to/Lossless"
zsh ./musicpipeline.zsh cleanup-originals "/path/to/Lossless"
```

## Wrapper vs Direct Scripts

Use `musicpipeline.zsh` unless you have a specific reason not to.

### Use `musicpipeline.zsh` when you want:

- archive-aware routing
- batch-root handling
- `audit`
- `undo`
- manifest/log tracking
- lossy-to-lossless rerouting

### Use `sort_music.zsh` or `convert_music.zsh` directly only when:

- you are already working inside a single artist root
- you intentionally want to bypass the wrapper workflow

The direct scripts are not the right interface for collection parents or mixed archive roots.

## YouTube Audio Helper

`musicpipelineyt` is a separate helper for grabbing the best native audio stream from a YouTube video or playlist URI.

Behavior:

- uses `yt-dlp` with `bestaudio/best`
- keeps the source codec/container as served instead of converting to ALAC
- writes adjacent `.info.json` sidecars for provenance
- stores playlist downloads under the playlist title with playlist-order prefixes

Important quality note:

- converting a YouTube download to ALAC would not improve the source fidelity
- `musicpipelineyt` intentionally keeps the native source stream so you preserve the highest quality YouTube actually served

### Setup

Source the helper from your shell profile, for example in `~/.zshrc`:

```zsh
source "/absolute/path/to/_MusicPrepScripts/musicpipeline_youtube.zsh"
```

### `musicpipelineyt` Usage

Show the built-in help text:

```zsh
musicpipelineyt -h
musicpipelineyt --help
```

Download a single video:

```zsh
musicpipelineyt --output-dir "/path/to/output" "https://www.youtube.com/watch?v=VIDEO_ID"
```

Download a playlist:

```zsh
musicpipelineyt --output-dir "/path/to/output" "https://www.youtube.com/playlist?list=PLAYLIST_ID"
```

Preview the selected format and destination without downloading:

```zsh
musicpipelineyt --dry-run --output-dir "/path/to/output" "https://www.youtube.com/watch?v=VIDEO_ID"
```

### Verifying A Download

After `musicpipelineyt` finishes, you can inspect the saved file directly:

```zsh
ffprobe -v error -select_streams a:0 \
  -show_entries stream=codec_name,sample_rate,channels,bit_rate:format=format_name \
  -of default=noprint_wrappers=1 "/path/to/output/Playlist or Uploader/Track [VIDEO_ID].ext"
```

## Usage

Source the wrapper from your shell profile if you want `musicpipeline` available as a shell command:

```zsh
source "/absolute/path/to/_MusicPrepScripts/musicpipeline.zsh"
```

Shell usage after sourcing:

```zsh
musicpipeline audit "/path/to/Collection"
musicpipeline sort "/path/to/Artist"
musicpipeline convert "/path/to/Artist"
musicpipeline both "/path/to/Lossy"
musicpipeline undo "/path/to/Lossy"
```

Run from inside `_MusicPrepScripts`:

```zsh
zsh ./musicpipeline.zsh audit "/path/to/Collection"
zsh ./musicpipeline.zsh sort "/path/to/Artist"
zsh ./musicpipeline.zsh convert "/path/to/Artist"
zsh ./musicpipeline.zsh both "/path/to/Lossy"
zsh ./musicpipeline.zsh undo "/path/to/Lossy"
```

Dry run:

```zsh
zsh ./musicpipeline.zsh both --dry-run "/path/to/Artist"
```

Keep sidecars during sort:

```zsh
zsh ./musicpipeline.zsh sort --keep-sidecars "/path/to/Artist"
```

Direct script usage:

```zsh
zsh ./sort_music.zsh "/path/to/Artist"
zsh ./sort_music.zsh --dry-run "/path/to/Artist"
zsh ./convert_music.zsh "/path/to/Artist"
zsh ./convert_music.zsh --dry-run "/path/to/Artist"
```

## Example Result

```text
Lossless/
  Kanye West/
    [2024] Test Album [16-44]/
      [01-01] First Track.m4a
      cover.jpg
    _originalSource/
      [2024] Test Album [16-44]/
        [01-01] First Track.flac
```

## Dependencies

Required commands:

- `zsh`
- `ffmpeg`
- `ffprobe`
- `yt-dlp` for `musicpipelineyt`
- `exiftool`
- `find`
- `sed`
- `awk`
- `base64`

## Known Caveats

- If `ffprobe` cannot determine bit depth or sample rate cleanly, format labels may fall back to values like `[unknown-44]`.
- Conflicts are skipped and logged; the scripts do not auto-suffix or overwrite by default.
- `audit` is the safest first step for new intake roots.
- Sidecar files are quarantined, not deleted outright, unless you later remove them yourself.
- `musicpipelineyt` preserves the best source stream YouTube serves; wrapping that stream in ALAC would not raise the actual fidelity.
