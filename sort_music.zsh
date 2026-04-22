#!/usr/bin/env zsh
#
# sort_music.zsh
# Authored by Stephen J. Smith
# Created: 2026-04-18
# Purpose: Normalize album folders and track filenames for the music library.

emulate -L zsh
setopt pipe_fail no_unset extended_glob

source "${${(%):-%x}:A:h}/musicpipeline_common.zsh"

sort_music_usage() {
  cat <<'EOF'
Usage: sort_music.zsh [--dry-run] [--keep-sidecars] [artist_dir]

Normalizes artist-folder content to:
  album folders: [YYYY] Album [BitDepth-SampleRate]
  album tracks:  [DD-TT] Title [BitDepth-SampleRate].ext
  loose singles: [YYYY] Title [BitDepth-SampleRate].ext

Rules:
  - flattens disc subfolders into the album root
  - routes lossy audio into _Lossy using Artist/Album/Song or Artist/Song
  - quarantines .cue/.log/.txt sidecars by default into .musicpipeline/trash
  - moves unclassifiable or conflicting content into _Unknown
  - ignores archived source files in _originalSource
EOF
}

# Simple counters for the run summary at the end.
typeset -gi sort_MOVE_COUNT=0
typeset -gi sort_QUARANTINE_COUNT=0
typeset -gi sort_SKIP_COUNT=0
typeset -gi sort_UNKNOWN_COUNT=0
typeset -gi sort_LOSSY_COUNT=0

sort_move_to_unknown() {
  local src="$1"
  local scope_root="$2"
  local reason="$3"

  if ml_move_to_unknown "$src" "$scope_root" "$reason" "route_unknown"; then
    (( sort_MOVE_COUNT++ ))
    (( sort_UNKNOWN_COUNT++ ))
  else
    (( sort_SKIP_COUNT++ ))
  fi
}

sort_move_to_lossy() {
  local src="$1"
  local dst="$2"
  local reason="$3"
  local fallback_root="${4:-$MUSICLIB_TARGET_ROOT}"

  if ml_move_path "$src" "$dst" "route_lossy" "$reason"; then
    (( sort_MOVE_COUNT++ ))
    (( sort_LOSSY_COUNT++ ))
  else
    sort_move_to_unknown "$src" "$fallback_root" "$reason"
  fi
}

sort_move_unknown_top_level_files() {
  local root="$1"
  local -a files
  local file

  files=("${(@f)$(find "$root" -mindepth 1 -maxdepth 1 -type f ! \( -iname '*.m4a' -o -iname '*.flac' -o -iname '*.alac' -o -iname '*.mp3' -o -iname '*.aiff' -o -iname '*.aif' -o -iname '*.wav' \) | LC_ALL=C sort)}")
  for file in "${files[@]}"; do
    [[ -e "$file" ]] || continue
    ml_move_misc_file "$file" "$root" "unknown top-level file" || true
  done
}

sort_move_lossy_release() {
  local release_dir="$1"
  local artist_root="$2"
  local target_dir

  target_dir="$(ml_lossy_release_target_dir "$release_dir" "$artist_root")"
  sort_move_to_lossy "$release_dir" "$target_dir" "lossy release" "${artist_root:h}"
}

sort_lossy_artist_root_for_release() {
  local release_dir="$1"
  local parent_root="${release_dir:h}"
  local artist

  if ml_target_looks_like_artist_root "$parent_root"; then
    print -r -- "$parent_root"
    return 0
  fi

  artist="$(ml_release_primary_artist "$release_dir")"
  if [[ -n "$artist" ]]; then
    print -r -- "$parent_root/$artist"
  else
    print -r -- "$parent_root/${parent_root:t}"
  fi
}

sort_move_lossy_tracks_from_release() {
  local release_dir="$1"
  local artist_root="$2"
  local lossy_release_dir
  local -a audio_files
  local file target

  lossy_release_dir="$(ml_lossy_release_target_dir "$release_dir" "$artist_root")"
  audio_files=("${(@f)$(ml_find_audio_files "$release_dir" | LC_ALL=C sort)}")

  for file in "${audio_files[@]}"; do
    [[ -e "$file" ]] || continue
    ml_is_lossy_audio_file "$file" || continue
    target="$lossy_release_dir/$(ml_track_target_name "$file")"
    sort_move_to_lossy "$file" "$target" "lossy track" "${artist_root:h}"
  done
}

# Sidecars are noise for the active library, but we quarantine them instead of
# deleting them so undo still has something to restore.
sort_quarantine_sidecars() {
  local release_dir="$1"
  local -a files
  local file

  (( MUSICLIB_KEEP_SIDECARS )) && return 0

  files=("${(@f)$(find "$release_dir" \
    \( -type d \( -name "$SOURCE_ARCHIVE_DIR" -o -name "$STATE_DIR_NAME" -o "${MUSICLIB_AUDIO_COLLECT_DIR_FIND_ARGS[@]}" -o -name "$LOSSY_ARCHIVE_DIR_NAME" -o -name "$MUSICLIB_LEGACY_LOSSY_ARCHIVE_DIR_NAME" -o -name '.*' \) -prune \) -o \
    -type f \( -iname '*.cue' -o -iname '*.log' -o -iname '*.txt' \) -print | LC_ALL=C sort)}")

  for file in "${files[@]}"; do
    [[ -e "$file" ]] || continue
    if ml_quarantine_sidecar "$file" "$MUSICLIB_TARGET_ROOT"; then
      (( sort_QUARANTINE_COUNT++ ))
    else
      (( sort_SKIP_COUNT++ ))
    fi
  done
}

# If a release came in with nested scans, PDFs, art, or similar extras, flatten
# them back into the album root with a readable prefix instead of just dropping
# them on top of each other.
sort_move_nested_non_audio() {
  local release_dir="$1"
  local -a files
  local file rel_dir prefix target

  files=("${(@f)$(find "$release_dir" \
    \( -type d \( -name "$SOURCE_ARCHIVE_DIR" -o -name "$STATE_DIR_NAME" -o "${MUSICLIB_AUDIO_COLLECT_DIR_FIND_ARGS[@]}" -o -name "$LOSSY_ARCHIVE_DIR_NAME" -o -name "$MUSICLIB_LEGACY_LOSSY_ARCHIVE_DIR_NAME" -o -name '.*' \) -prune \) -o \
    -mindepth 2 -type f ! \( -iname '*.m4a' -o -iname '*.flac' -o -iname '*.alac' -o -iname '*.mp3' -o -iname '*.aiff' -o -iname '*.aif' -o -iname '*.wav' -o -iname '*.cue' -o -iname '*.log' -o -iname '*.txt' \) -print | LC_ALL=C sort)}")

  for file in "${files[@]}"; do
    [[ -e "$file" ]] || continue
    ml_path_has_hidden_or_state_segment "$file" "$release_dir" && continue
    rel_dir="${file:h}"
    rel_dir="${rel_dir#$release_dir/}"
    prefix="${rel_dir//\// - }"
    target="$release_dir/$prefix - ${file:t}"
    if ml_move_path "$file" "$target" "move_nested_file" "flatten nested non-audio"; then
      (( sort_MOVE_COUNT++ ))
    else
      (( sort_SKIP_COUNT++ ))
    fi
  done
}

# Rename audio files into the final disc-track format, but keep a tiny in-memory
# map so we can catch duplicate normalized names before we start moving things.
sort_release_audio() {
  local release_dir="$1"
  local -a audio_files
  local file target
  local -A planned

  audio_files=("${(@f)$(ml_find_audio_files "$release_dir" | LC_ALL=C sort)}")

  for file in "${audio_files[@]}"; do
    [[ -e "$file" ]] || continue
    target="$release_dir/$(ml_track_target_name "$file")"

    if [[ -n "${planned[$target]:-}" && "${planned[$target]}" != "$file" ]]; then
      ml_warn "conflict: duplicate normalized track target $(ml_display_path "$target")"
      ml_record_event "skip" "$file" "$target" "duplicate normalized track target" "rename_audio"
      sort_move_to_unknown "$file" "${release_dir:h}" "duplicate normalized track target"
      continue
    fi
    planned[$target]="$file"

    if ml_move_path "$file" "$target" "rename_audio" "normalize track name"; then
      (( sort_MOVE_COUNT++ ))
    else
      sort_move_to_unknown "$file" "${release_dir:h}" "track rename conflict"
    fi
  done
}

sort_release_dir() {
  local release_dir="$1"
  local artist_root="${2:-$(sort_lossy_artist_root_for_release "$1")}"
  local first_audio normalized_dir

  # Grab the album-level metadata before we start renaming tracks. Once those
  # files move, the old first-audio path may no longer exist.
  first_audio="$(ml_first_audio_file "$release_dir")"
  if [[ -z "$first_audio" ]]; then
    ml_warn "moving non-audio directory to $UNKNOWN_DIR_NAME: $(ml_display_path "$release_dir")"
    sort_move_to_unknown "$release_dir" "${release_dir:h}" "non-audio directory"
    return 0
  fi

  if ml_release_has_lossy_audio "$release_dir"; then
    if ! ml_release_has_lossless_audio "$release_dir"; then
      ml_log_step "lossy" "release $(ml_display_path "$release_dir")"
      sort_move_lossy_release "$release_dir" "$artist_root"
      return 0
    fi

    ml_log_step "lossy" "mixed release $(ml_display_path "$release_dir")"
    sort_move_lossy_tracks_from_release "$release_dir" "$artist_root"
    ml_cleanup_empty_dirs "$release_dir"
    first_audio="$(ml_first_audio_file "$release_dir")"
    if [[ -z "$first_audio" ]]; then
      sort_move_to_unknown "$release_dir" "${release_dir:h}" "release emptied after lossy routing"
      return 0
    fi
  fi

  sort_quarantine_sidecars "$release_dir"
  sort_release_audio "$release_dir"
  sort_move_nested_non_audio "$release_dir"
  ml_cleanup_empty_dirs "$release_dir"
  normalized_dir="${release_dir:h}/$(ml_release_target_dir_name "$release_dir")"

  if ml_move_path "$release_dir" "$normalized_dir" "normalize_release" "normalize release folder"; then
    (( sort_MOVE_COUNT++ ))
  else
    sort_move_to_unknown "$release_dir" "${release_dir:h}" "release folder normalize conflict"
  fi
}

sort_route_loose_tracks() {
  local artist_root="$1"
  local -a loose_tracks
  local track target

  # Keep standalone tracks directly under the artist root, but still normalize
  # their filenames so mixed albums + singles stay tidy.
  loose_tracks=("${(@f)$(ml_find_loose_audio_files "$artist_root" | LC_ALL=C sort)}")
  for track in "${loose_tracks[@]}"; do
    [[ -e "$track" ]] || continue
    if ml_is_lossy_audio_file "$track"; then
      target="$(ml_lossy_track_target_path "$track" "$artist_root")"
      sort_move_to_lossy "$track" "$target" "lossy loose track" "${artist_root:h}"
      continue
    fi
    if ml_route_loose_track_to_artist "$track" "$artist_root"; then
      (( sort_MOVE_COUNT++ ))
    else
      sort_move_to_unknown "$track" "$artist_root" "loose track routing conflict"
    fi
  done
}

sort_artist_root() {
  local artist_root="$1"
  local -a release_dirs
  local dir kind

  # Normal artist-root pass: handle loose files first, then walk the release
  # directories one level down and normalize each one.
  sort_route_loose_tracks "$artist_root"
  sort_move_unknown_top_level_files "$artist_root"

  release_dirs=("${(@f)$(ml_find_non_reserved_child_dirs "$artist_root")}")
  for dir in "${release_dirs[@]}"; do
    [[ -n "$dir" ]] || continue
    kind="$(ml_dir_kind "$dir")"
    case "$kind" in
      release)
        sort_release_dir "$dir" "$artist_root"
        ;;
      artist)
        ml_log_step "recurse" "nested artist directory $(ml_display_path "$dir")"
        sort_artist_root "$dir"
        ;;
      *)
        if ! ml_dir_has_non_special_content "$dir"; then
          ml_log_step "skip" "housekeeping-only directory $(ml_display_path "$dir")"
        else
          ml_warn "moving unknown directory to $UNKNOWN_DIR_NAME: $(ml_display_path "$dir")"
          sort_move_to_unknown "$dir" "$artist_root" "unknown directory kind"
        fi
        ;;
    esac
  done

  ml_cleanup_empty_dirs "$artist_root"
}

sort_music_main() {
  local root_dir="."
  local arg
  local own_run=0

  # Reset per-run globals so direct calls and wrapper-driven calls start from a
  # predictable baseline.
  MUSICLIB_DRY_RUN=0
  MUSICLIB_KEEP_SIDECARS=0
  sort_MOVE_COUNT=0
  sort_QUARANTINE_COUNT=0
  sort_SKIP_COUNT=0
  sort_UNKNOWN_COUNT=0
  sort_LOSSY_COUNT=0

  while (( $# )); do
    arg="$1"
    case "$arg" in
      --dry-run)
        MUSICLIB_DRY_RUN=1
        ;;
      --keep-sidecars)
        MUSICLIB_KEEP_SIDECARS=1
        ;;
      -h|--help)
        sort_music_usage
        return 0
        ;;
      --)
        shift
        break
        ;;
      -*)
        ml_die "unknown option: $arg"
        return 1
        ;;
      *)
        root_dir="$arg"
        ;;
    esac
    shift
  done

  (( $# == 0 )) || { ml_die "unexpected extra arguments: $*"; return 1; }

  ml_need_cmd ffprobe
  ml_need_cmd find
  ml_need_cmd sed
  ml_need_cmd awk

  [[ -d "$root_dir" ]] || { ml_die "artist directory not found: $root_dir"; return 1; }
  root_dir="${root_dir:A}"

  # When the wrapper already opened a run, reuse it. Otherwise create a small
  # standalone run so direct script usage still gets logs/manifests.
  if (( ! MUSICLIB_RUN_ACTIVE )); then
    own_run=1
    ml_start_run "sort" "$root_dir" $(( ! MUSICLIB_DRY_RUN ))
  fi

  sort_artist_root "$root_dir"
  ml_cleanup_empty_dirs "$root_dir"
  [[ "${root_dir:h}" != "$root_dir" ]] && ml_cleanup_empty_dirs "${root_dir:h}"

  if (( own_run )); then
    ml_finish_run "success" "Done. moved=$sort_MOVE_COUNT lossy=$sort_LOSSY_COUNT quarantined=$sort_QUARANTINE_COUNT unknown=$sort_UNKNOWN_COUNT skipped=$sort_SKIP_COUNT"
    if (( MUSICLIB_DRY_RUN )); then
      ml_log "Dry run only. No filesystem changes were made."
    fi
    MUSICLIB_RUN_ACTIVE=0
  fi
}

if [[ -z "${MUSICLIB_SOURCE_ONLY:-}" && "${ZSH_EVAL_CONTEXT:-}" == "toplevel" ]]; then
  sort_music_main "$@"
fi
