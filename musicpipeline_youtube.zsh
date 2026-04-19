#!/usr/bin/env zsh
#
# musicpipeline_youtube.zsh
# Authored by Stephen J. Smith
# Created: 2026-04-18
# Purpose: Sourceable shell helper for native-source YouTube audio downloads.

# Keep the public help text in one place so the shell function and the README
# can describe the feature the same way.
musicpipelineyt_usage() {
  emulate -L zsh

  cat <<'EOF'
Usage: musicpipelineyt [--dry-run] --output-dir DIR URI
       musicpipelineyt -h | --help

Downloads the best native audio stream yt-dlp can get for a single YouTube URL
or playlist. It keeps the source codec/container as-is instead of converting
anything to ALAC.

Options:
  --output-dir DIR   Folder where the downloaded audio should land
  --dry-run          Show the selected format and destination without downloading
  -h, --help         Show this help text

Setup:
  source "/absolute/path/to/_MusicPrepScripts/musicpipeline_youtube.zsh"

Examples:
  musicpipelineyt --output-dir "/path/to/output" "https://www.youtube.com/watch?v=VIDEO_ID"
  musicpipelineyt --output-dir "/path/to/output" "https://www.youtube.com/playlist?list=PLAYLIST_ID"
  musicpipelineyt --dry-run --output-dir "/path/to/output" "https://www.youtube.com/watch?v=VIDEO_ID"

Dependencies:
  brew install yt-dlp ffmpeg

What it writes:
  - best available native audio stream
  - adjacent .info.json sidecar with source metadata
  - playlist downloads inside a playlist folder with playlist-order prefixes
EOF
}

# These small helpers stay prefixed so sourcing this file into a shell does not
# spray generic names like `usage` or `die` into the user's session.
musicpipelineyt_die() {
  emulate -L zsh
  print -ru2 -- "error: $*"
}

musicpipelineyt_need_cmd() {
  emulate -L zsh
  local cmd="$1"

  command -v "$cmd" >/dev/null 2>&1 && return 0

  if [[ "$cmd" == "yt-dlp" ]]; then
    musicpipelineyt_die "missing required command: $cmd (install with: brew install yt-dlp ffmpeg)"
  else
    musicpipelineyt_die "missing required command: $cmd"
  fi
  return 1
}

# This template keeps single videos under the uploader name and flips over to
# playlist-title folders automatically when the URI is a playlist.
musicpipelineyt_output_template() {
  emulate -L zsh
  print -r -- '%(playlist,uploader,channel|Unknown Source)s/%(playlist_index&{} - |)s%(title|untitled)s [%(id)s].%(ext)s'
}

# ffprobe already knows the truth about the file that landed on disk, so use it
# for a quick sanity check instead of guessing from yt-dlp's console output.
musicpipelineyt_pretty_bitrate() {
  emulate -L zsh
  local bitrate="${1:-}"

  if [[ "$bitrate" == <-> ]]; then
    print -r -- "$(( bitrate / 1000 )) kb/s"
  else
    print -r -- "${bitrate:-unknown}"
  fi
}

musicpipelineyt_report_file() {
  emulate -L zsh
  setopt pipe_fail no_unset extended_glob

  local file="$1"
  local probe_output container codec sample_rate channels
  local -a bitrate_values
  local audio_bitrate=""

  [[ -f "$file" ]] || {
    print -r -- "saved: $file"
    print -r -- "stream: file was reported by yt-dlp but is not visible on disk yet"
    return 0
  }

  probe_output="$(
    ffprobe -v error -select_streams a:0 \
      -show_entries format=format_name,bit_rate:stream=codec_name,sample_rate,channels,bit_rate \
      -of default=noprint_wrappers=1 "$file" 2>/dev/null
  )"

  container="$(printf '%s\n' "$probe_output" | sed -n 's/^format_name=//p' | head -n 1)"
  codec="$(printf '%s\n' "$probe_output" | sed -n 's/^codec_name=//p' | head -n 1)"
  sample_rate="$(printf '%s\n' "$probe_output" | sed -n 's/^sample_rate=//p' | head -n 1)"
  channels="$(printf '%s\n' "$probe_output" | sed -n 's/^channels=//p' | head -n 1)"
  bitrate_values=("${(@f)$(printf '%s\n' "$probe_output" | sed -n 's/^bit_rate=//p')}")

  audio_bitrate="${bitrate_values[1]:-}"
  if [[ -z "$audio_bitrate" || "$audio_bitrate" == "N/A" ]]; then
    audio_bitrate="${bitrate_values[2]:-unknown}"
  fi

  print -r -- "saved: $file"
  print -r -- "stream: container=${container:-unknown} codec=${codec:-unknown} sample_rate=${sample_rate:-unknown}Hz channels=${channels:-unknown} bitrate=$(musicpipelineyt_pretty_bitrate "$audio_bitrate")"
}

# The public entrypoint mirrors the rest of the repo: parse args, fail clearly,
# and keep help working even on a machine that has not been fully set up yet.
musicpipelineyt() {
  emulate -L zsh
  setopt pipe_fail no_unset extended_glob

  local dry_run=0
  local output_dir=""
  local uri=""
  local arg output_template path_log
  local -a yt_dlp_cmd

  # Parse flags first so `musicpipelineyt --help` does not depend on yt-dlp already
  # being installed.
  while (( $# )); do
    arg="$1"
    case "$arg" in
      --dry-run)
        dry_run=1
        ;;
      --output-dir)
        shift
        (( $# )) || {
          musicpipelineyt_die "--output-dir needs a directory path"
          musicpipelineyt_usage >&2
          return 1
        }
        output_dir="$1"
        ;;
      --output-dir=*)
        output_dir="${arg#*=}"
        ;;
      -h|--help)
        musicpipelineyt_usage
        return 0
        ;;
      --)
        shift
        break
        ;;
      -*)
        musicpipelineyt_die "unknown option: $arg"
        musicpipelineyt_usage >&2
        return 1
        ;;
      *)
        if [[ -n "$uri" ]]; then
          musicpipelineyt_die "unexpected extra argument: $arg"
          musicpipelineyt_usage >&2
          return 1
        fi
        uri="$arg"
        ;;
    esac
    shift
  done

  # If the user used `--`, accept one trailing URI and reject anything beyond
  # that so the call shape stays simple.
  if (( $# )); then
    if [[ -n "$uri" || $# -gt 1 ]]; then
      musicpipelineyt_die "unexpected extra arguments: $*"
      musicpipelineyt_usage >&2
      return 1
    fi
    uri="$1"
  fi

  [[ -n "$output_dir" ]] || {
    musicpipelineyt_die "--output-dir is required"
    musicpipelineyt_usage >&2
    return 1
  }
  [[ -n "$uri" ]] || {
    musicpipelineyt_die "URI is required"
    musicpipelineyt_usage >&2
    return 1
  }

  output_dir="${output_dir:A}"

  if (( ! dry_run )); then
    mkdir -p -- "$output_dir" || {
      musicpipelineyt_die "could not create output directory: $output_dir"
      return 1
    }
  fi

  musicpipelineyt_need_cmd yt-dlp || return 1
  musicpipelineyt_need_cmd ffmpeg || return 1
  musicpipelineyt_need_cmd ffprobe || return 1

  output_template="$(musicpipelineyt_output_template)"
  yt_dlp_cmd=(
    yt-dlp
    --ignore-config
    --no-update
    --output-na-placeholder '?'
    --format 'bestaudio/best'
    --yes-playlist
    --write-info-json
    --paths "home:$output_dir"
    --output "$output_template"
  )

  # Build one shared yt-dlp command so dry runs and real downloads choose the
  # same formats and paths.
  if (( dry_run )); then
    yt_dlp_cmd+=(
      --simulate
      --print 'before_dl:----------------------------------------'
      --print 'before_dl:Title: %(playlist_index&{} - |)s%(title|untitled)s'
      --print 'before_dl:Format: id=%(format_id|?)s ext=%(ext|?)s acodec=%(acodec|?)s abr=%(abr|?)s asr=%(asr|?)s'
      --print 'before_dl:Path: %(filename|unknown)s'
    )
    "${yt_dlp_cmd[@]}" "$uri"
    return $?
  fi

  # For real downloads, capture the final moved paths so the follow-up ffprobe
  # summary points at the exact files that landed on disk.
  path_log="$(mktemp "${TMPDIR:-/tmp}/musicpipelineyt.paths.XXXXXX")" || {
    musicpipelineyt_die "could not create temporary path log"
    return 1
  }

  if ! "${yt_dlp_cmd[@]}" --print 'after_move:filepath' "$uri" > "$path_log"; then
    rm -f -- "$path_log"
    return 1
  fi

  while IFS= read -r downloaded_file; do
    [[ -n "$downloaded_file" ]] || continue
    musicpipelineyt_report_file "$downloaded_file"
  done < "$path_log"

  rm -f -- "$path_log"
}

if [[ "${ZSH_EVAL_CONTEXT:-}" == "toplevel" ]]; then
  musicpipelineyt "$@"
fi

# Backward-compatible alias for users who already sourced the old helper name.
musiclibyt_usage() { musicpipelineyt_usage "$@"; }
musiclibyt_die() { musicpipelineyt_die "$@"; }
musiclibyt_need_cmd() { musicpipelineyt_need_cmd "$@"; }
musiclibyt_output_template() { musicpipelineyt_output_template "$@"; }
musiclibyt_pretty_bitrate() { musicpipelineyt_pretty_bitrate "$@"; }
musiclibyt_report_file() { musicpipelineyt_report_file "$@"; }
musiclibyt() { musicpipelineyt "$@"; }
