#!/usr/bin/env zsh
#
# musicpipeline.zsh
# Authored by Stephen J. Smith
# Created: 2026-04-18
# Purpose: Audit, sort, convert, and undo music-library intake workflows.

emulate -L zsh
setopt pipe_fail no_unset extended_glob

source "${${(%):-%x}:A:h}/musicpipeline_common.zsh"
# Source the worker scripts in "library mode" so we can call their main
# functions without auto-running them on import.
typeset -g MUSICLIB_SOURCE_ONLY=1
source "${${(%):-%x}:A:h}/sort_music.zsh"
source "${${(%):-%x}:A:h}/convert_music.zsh"
source "${${(%):-%x}:A:h}/cleanup_music.zsh"
unset MUSICLIB_SOURCE_ONLY

# These associative arrays act like simple sets/maps for the current wrapper
# run: one for artist roots we still need to process, one for artist roots that
# should skip conversion because routing left them in a risky state.
typeset -gA musicpipeline_ARTIST_TARGETS=()
typeset -gA musicpipeline_BLOCKED_CONVERT_ARTISTS=()
typeset -gi musicpipeline_PROCESSED_ARTIST_COUNT=0
typeset -gi musicpipeline_AUDIT_WARNING_COUNT=0
typeset -g MUSICPIPELINE_UI_MODE=""
typeset -g MUSICPIPELINE_UI_TARGET=""
typeset -g MUSICPIPELINE_UI_OUTPUT=""
typeset -gi MUSICPIPELINE_UI_DRY_RUN=0
typeset -gi MUSICPIPELINE_UI_MOVE=0
typeset -gi MUSICPIPELINE_UI_KEEP_SIDECARS=0

musicpipeline_usage() {
  cat <<'EOF'
Usage: musicpipeline <audit|sort|convert|both|undo|delete-source|delete-empty-dirs|delete-state-dirs|audio-scrape|dedup|dedup-delete> [options] [target]
       zsh ./musicpipeline.zsh <audit|sort|convert|both|undo|delete-source|delete-empty-dirs|delete-state-dirs|audio-scrape|dedup|dedup-delete> [options] [target]

Commands:
  audit       Read-only analysis of a target root
  sort        Normalize folders and track filenames
  convert     Convert supported source audio to ALAC or MP3
  both        Run conversion first, then sorts
  undo        Undo the last successful manifest-backed run for the target
  delete-source     Delete _originalSource folders after typed confirmation
  delete-empty-dirs Remove all completely empty directories under the target
  delete-state-dirs Delete all .musicpipeline directories under the target
  audio-scrape     Scrape audio into format buckets, with optional separate output root
  dedup             Move exact duplicate files into the run state area
  dedup-delete Hard-delete stashed duplicates and matching dedup manifests

Options:
  --dry-run         Log intended sort/convert changes without mutating files
  --keep-sidecars   Preserve .cue/.log/.txt files during sort
  --output DIR      Write audio-scrape results into DIR instead of the target root
  --move            With --output, move source files instead of copying them
  -h, --help        Show this help text

Target Types:
  - collection parent: contains configured lossless and lossy roots
  - archive root: mixed artist folders, loose release folders, and loose tracks
  - artist root: one artist folder containing releases and/or loose tracks
EOF
}

musicpipeline_prompt_mode() {
  return 1
}

musicpipeline_ui_init() {
  if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    typeset -g MUSICPIPELINE_UI_RESET=$'\033[0m'
    typeset -g MUSICPIPELINE_UI_DIM=$'\033[2m'
    typeset -g MUSICPIPELINE_UI_BOLD=$'\033[1m'
    typeset -g MUSICPIPELINE_UI_ACCENT=$'\033[38;5;45m'
    typeset -g MUSICPIPELINE_UI_ACCENT2=$'\033[38;5;81m'
    typeset -g MUSICPIPELINE_UI_WARN=$'\033[38;5;214m'
    typeset -g MUSICPIPELINE_UI_MUTED=$'\033[38;5;245m'
    typeset -g MUSICPIPELINE_UI_PANEL=$'\033[38;5;111m'
  else
    typeset -g MUSICPIPELINE_UI_RESET=""
    typeset -g MUSICPIPELINE_UI_DIM=""
    typeset -g MUSICPIPELINE_UI_BOLD=""
    typeset -g MUSICPIPELINE_UI_ACCENT=""
    typeset -g MUSICPIPELINE_UI_ACCENT2=""
    typeset -g MUSICPIPELINE_UI_WARN=""
    typeset -g MUSICPIPELINE_UI_MUTED=""
    typeset -g MUSICPIPELINE_UI_PANEL=""
  fi
}

musicpipeline_ui_rule() {
  print -r -- "${MUSICPIPELINE_UI_PANEL}================================================================${MUSICPIPELINE_UI_RESET}"
}

musicpipeline_ui_soft_rule() {
  print -r -- "${MUSICPIPELINE_UI_MUTED}----------------------------------------------------------------${MUSICPIPELINE_UI_RESET}"
}

musicpipeline_ui_print_action() {
  local key="$1"
  local command="$2"
  local summary="$3"
  printf '%s[%s]%s %-17s %s\n' "$MUSICPIPELINE_UI_ACCENT" "$key" "$MUSICPIPELINE_UI_RESET" "$command" "$summary"
}

musicpipeline_ui_usage_panel() {
  print
  musicpipeline_ui_rule
  print -r -- "${MUSICPIPELINE_UI_BOLD}${MUSICPIPELINE_UI_WARN}CLI Usage Reference${MUSICPIPELINE_UI_RESET}"
  print -r -- "${MUSICPIPELINE_UI_MUTED}Use this when you want the raw command syntax instead of the menu flow.${MUSICPIPELINE_UI_RESET}"
  musicpipeline_ui_rule
  musicpipeline_usage
  musicpipeline_ui_rule
}

musicpipeline_ui_yes() {
  local prompt="$1"
  local reply
  read "reply?$prompt [y/N]: "
  [[ "${reply:l}" == y || "${reply:l}" == yes ]]
}

musicpipeline_command_summary() {
  case "$1" in
    audit) print -r -- "Read-only analysis of the target root." ;;
    sort) print -r -- "Normalize structure, route files, and rename tracks." ;;
    convert) print -r -- "Convert supported source audio to ALAC or MP3." ;;
    both) print -r -- "Convert first, then sort for a full intake pass." ;;
    undo) print -r -- "Undo the last manifest-backed run for this exact target." ;;
    delete-source) print -r -- "Permanently delete _originalSource trees after confirmation." ;;
    delete-empty-dirs) print -r -- "Recursively remove completely empty directories." ;;
    delete-state-dirs) print -r -- "Permanently delete all .musicpipeline directories under the target." ;;
    audio-scrape) print -r -- "Bucket audio by format, with optional copy/move output mode." ;;
    dedup) print -r -- "Stash exact duplicate files into .musicpipeline/duplicates." ;;
    dedup-delete) print -r -- "Permanently delete stashed duplicates and dedup manifests." ;;
    *) print -r -- "" ;;
  esac
}

musicpipeline_terminal_ui() {
  local choice mode target output_root root_hint sidecar_hint

  [[ -t 0 ]] || return 1
  musicpipeline_ui_init

  while :; do
    if [[ -t 1 ]]; then
      clear
    fi
    musicpipeline_ui_rule
    print -r -- "${MUSICPIPELINE_UI_BOLD}${MUSICPIPELINE_UI_ACCENT2}Music Pipeline${MUSICPIPELINE_UI_RESET}  ${MUSICPIPELINE_UI_DIM}library intake, cleanup, and rollback${MUSICPIPELINE_UI_RESET}"
    print -r -- "${MUSICPIPELINE_UI_MUTED}Current directory:${MUSICPIPELINE_UI_RESET} $(ml_display_path "$PWD")"
    print -r -- "${MUSICPIPELINE_UI_MUTED}Tip:${MUSICPIPELINE_UI_RESET} Run ${MUSICPIPELINE_UI_BOLD}both${MUSICPIPELINE_UI_RESET} for a normal intake pass, ${MUSICPIPELINE_UI_BOLD}audit${MUSICPIPELINE_UI_RESET} when you want a preview first."
    musicpipeline_ui_rule
    print -r -- "${MUSICPIPELINE_UI_BOLD}Library Workflow${MUSICPIPELINE_UI_RESET}"
    musicpipeline_ui_print_action "1" "audit"             "$(musicpipeline_command_summary audit)"
    musicpipeline_ui_print_action "2" "sort"              "$(musicpipeline_command_summary sort)"
    musicpipeline_ui_print_action "3" "convert"           "$(musicpipeline_command_summary convert)"
    musicpipeline_ui_print_action "4" "both"              "$(musicpipeline_command_summary both)"
    musicpipeline_ui_print_action "5" "undo"              "$(musicpipeline_command_summary undo)"
    musicpipeline_ui_soft_rule
    print -r -- "${MUSICPIPELINE_UI_BOLD}Library Cleanup${MUSICPIPELINE_UI_RESET}"
    musicpipeline_ui_print_action "6" "delete-source"     "$(musicpipeline_command_summary delete-source)"
    musicpipeline_ui_print_action "7" "delete-empty-dirs" "$(musicpipeline_command_summary delete-empty-dirs)"
    musicpipeline_ui_print_action "a" "delete-state-dirs" "$(musicpipeline_command_summary delete-state-dirs)"
    musicpipeline_ui_soft_rule
    print -r -- "${MUSICPIPELINE_UI_BOLD}Utilities${MUSICPIPELINE_UI_RESET}"
    musicpipeline_ui_print_action "8" "audio-scrape"     "$(musicpipeline_command_summary audio-scrape)"
    musicpipeline_ui_print_action "9" "dedup"             "$(musicpipeline_command_summary dedup)"
    musicpipeline_ui_print_action "0" "dedup-delete" "$(musicpipeline_command_summary dedup-delete)"
    musicpipeline_ui_soft_rule
    print -r -- "${MUSICPIPELINE_UI_BOLD}Help And Exit${MUSICPIPELINE_UI_RESET}"
    musicpipeline_ui_print_action "u" "show-usage"        "Print the full CLI usage statement."
    musicpipeline_ui_print_action "q" "quit"              "Exit without running anything."
    musicpipeline_ui_rule
    print
    read "choice?Action: "

    case "${choice:l}" in
      1) mode="audit" ;;
      2) mode="sort" ;;
      3) mode="convert" ;;
      4) mode="both" ;;
      5) mode="undo" ;;
      6) mode="delete-source" ;;
      7) mode="delete-empty-dirs" ;;
      a) mode="delete-state-dirs" ;;
      8) mode="audio-scrape" ;;
      9) mode="dedup" ;;
      0) mode="dedup-delete" ;;
      u)
        if [[ -t 1 ]]; then
          clear
        fi
        musicpipeline_ui_usage_panel
        [[ -t 0 ]] && read "choice?Press Enter to return to the menu: "
        continue
        ;;
      q)
        return 1
        ;;
      *)
        print "Invalid selection."
        continue
        ;;
    esac

    print
    musicpipeline_ui_rule
    print -r -- "${MUSICPIPELINE_UI_BOLD}Selected:${MUSICPIPELINE_UI_RESET} ${MUSICPIPELINE_UI_ACCENT}$mode${MUSICPIPELINE_UI_RESET}"
    print -r -- "$(musicpipeline_command_summary "$mode")"
    case "$mode" in
      audit) root_hint="Good for checking routing, naming, missing tags, and convert blockers." ;;
      both) root_hint="Best default for newly added music under an archive or artist root." ;;
      undo) root_hint="Must be run from the same target root that recorded the original run." ;;
      dedup) root_hint="Only exact byte-for-byte duplicates are moved." ;;
      audio-scrape) root_hint="Scrapes audio into bucket dirs like _mp3/_flac and can write to a separate output root; --output defaults to copy unless you also pass --move." ;;
      dedup-delete) root_hint="This permanently removes stashed duplicates and dedup manifests." ;;
      delete-source) root_hint="This permanently deletes archived source material under _originalSource." ;;
      delete-empty-dirs) root_hint="Removes only completely empty folders, depth-first." ;;
      delete-state-dirs) root_hint="Deletes every .musicpipeline directory under the target tree." ;;
      *) root_hint="" ;;
    esac
    [[ -n "$root_hint" ]] && print -r -- "${MUSICPIPELINE_UI_MUTED}$root_hint${MUSICPIPELINE_UI_RESET}"
    read "target?Target directory [.]: "
    [[ -n "$target" ]] || target="."

    MUSICPIPELINE_UI_DRY_RUN=0
    MUSICPIPELINE_UI_OUTPUT=""
    MUSICPIPELINE_UI_MOVE=0
    MUSICPIPELINE_UI_KEEP_SIDECARS=0

    case "$mode" in
      audit|sort|convert|both|delete-source|delete-empty-dirs|delete-state-dirs|audio-scrape|dedup|dedup-delete)
        musicpipeline_ui_yes "Dry run?" && MUSICPIPELINE_UI_DRY_RUN=1
        ;;
    esac

    case "$mode" in
      audio-scrape)
        read "output_root?Output directory [in place]: "
        MUSICPIPELINE_UI_OUTPUT="$output_root"
        if [[ -n "$MUSICPIPELINE_UI_OUTPUT" ]]; then
          musicpipeline_ui_yes "Move source files instead of copying?" && MUSICPIPELINE_UI_MOVE=1
        fi
        ;;
    esac

    case "$mode" in
      sort|both)
        sidecar_hint="Keep .cue/.log/.txt files beside the music instead of quarantining them."
        print -r -- "${MUSICPIPELINE_UI_MUTED}$sidecar_hint${MUSICPIPELINE_UI_RESET}"
        musicpipeline_ui_yes "Keep sidecars?" && MUSICPIPELINE_UI_KEEP_SIDECARS=1
        ;;
    esac

    print
    musicpipeline_ui_rule
    print -r -- "${MUSICPIPELINE_UI_BOLD}Run Summary${MUSICPIPELINE_UI_RESET}"
    print -r -- "  command: ${MUSICPIPELINE_UI_ACCENT}$mode${MUSICPIPELINE_UI_RESET}"
    print -r -- "  target : ${target}"
    print -r -- "  dry-run: $([[ $MUSICPIPELINE_UI_DRY_RUN -eq 1 ]] && print yes || print no)"
    case "$mode" in
      audio-scrape)
        print -r -- "  output : ${MUSICPIPELINE_UI_OUTPUT:-[in place]}"
        print -r -- "  mode   : $([[ $MUSICPIPELINE_UI_MOVE -eq 1 ]] && print move || print copy)"
        ;;
    esac
    case "$mode" in
      sort|both)
        print -r -- "  sidecars: $([[ $MUSICPIPELINE_UI_KEEP_SIDECARS -eq 1 ]] && print keep || print quarantine)"
        ;;
    esac
    musicpipeline_ui_rule
    musicpipeline_ui_yes "Run this command?" || continue

    MUSICPIPELINE_UI_MODE="$mode"
    MUSICPIPELINE_UI_TARGET="$target"
    return 0
  done
}

musicpipeline_register_artist() {
  local artist_root="${1:A}"
  [[ -n "$artist_root" ]] || return 0
  musicpipeline_ARTIST_TARGETS["$artist_root"]=1
}

musicpipeline_block_convert_for_artist() {
  local artist_root="${1:A}"
  local reason="$2"
  [[ -n "$artist_root" ]] || return 0
  musicpipeline_BLOCKED_CONVERT_ARTISTS["$artist_root"]="$reason"
}

musicpipeline_sorted_artist_targets() {
  local -a artists

  # Pull the associative-array keys back out as a clean sorted list so later
  # loops stay deterministic even when paths contain spaces.
  artists=("${(@Qk)musicpipeline_ARTIST_TARGETS}")
  print -rl -- "${(@o)artists}"
}

# These helpers classify direct children so the wrapper can decide whether a
# root is holding artist folders, release folders, or just random clutter.
musicpipeline_direct_child_dirs() {
  local root="$1"
  ml_find_non_reserved_child_dirs "$root"
}

musicpipeline_direct_release_dirs() {
  local root="$1"
  local dir

  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    if [[ "$(ml_dir_kind "$dir")" == "release" ]]; then
      print -r -- "$dir"
    fi
  done < <(musicpipeline_direct_child_dirs "$root")
}

musicpipeline_direct_artist_dirs() {
  local root="$1"
  local dir

  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    if [[ "$(ml_dir_kind "$dir")" == "artist" ]]; then
      print -r -- "$dir"
    fi
  done < <(musicpipeline_direct_child_dirs "$root")
}

musicpipeline_find_archive_root() {
  local dir="${1:A}"

  # Walk up until we hit a configured archive root name or the filesystem root.
  while [[ "$dir" != "/" ]]; do
    if [[ -n "$LOSSLESS_DIR_NAME" && "${dir:t}" == "$LOSSLESS_DIR_NAME" ]]; then
      print -r -- "$dir"
      return 0
    fi
    if [[ -n "$LOSSY_DIR_NAME" && "${dir:t}" == "$LOSSY_DIR_NAME" ]]; then
      print -r -- "$dir"
      return 0
    fi
    dir="${dir:h}"
  done

  return 1
}

musicpipeline_prepare_config() {
  local script_dir="$1"
  local target_root="$2"

  # Plain artist-root or generic batch use should not force config setup. Only
  # archive-aware runs really care about the configured archive names.
  ml_load_config_if_present "$script_dir" && return 0

  if ml_target_looks_like_artist_root "$target_root" || ml_target_has_batch_content "$target_root"; then
    return 0
  fi

  [[ -t 0 ]] || return 0
  ml_bootstrap_config_if_needed "$script_dir" "$target_root"
  ml_load_config_if_present "$script_dir" || true
}

musicpipeline_detect_root_type() {
  ml_classify_root "$1"
}

musicpipeline_missing_tags_for_file() {
  local file="$1"
  local tags
  local -a missing

  # Audit wants a compact "what's missing?" answer without having to parse the
  # ffprobe output at every call site.
  tags="$(ml_file_tags "$file")"
  if [[ -z "$(ml_tag_value album_artist "$tags")" && -z "$(ml_tag_value artist "$tags")" ]]; then
    missing+=("album_artist_or_artist")
  fi
  [[ -n "$(ml_tag_value album "$tags")" ]] || missing+=("album")
  [[ -n "$(ml_tag_value title "$tags")" ]] || missing+=("title")
  [[ -n "$(ml_tag_value track "$tags")" ]] || missing+=("track")
  [[ -n "$(ml_tag_value disc "$tags")" ]] || missing+=("disc")
  [[ -n "$(ml_tag_value date "$tags")" ]] || missing+=("date")

  print -r -- "${(j:, :)missing}"
}

musicpipeline_warn_audit() {
  (( musicpipeline_AUDIT_WARNING_COUNT++ ))
  ml_warn "$*"
}

musicpipeline_audit_detail() {
  ml_log "  $*"
}

musicpipeline_audit_warn_detail() {
  (( musicpipeline_AUDIT_WARNING_COUNT++ ))
  ml_log "  warning: $*"
}

musicpipeline_fallback_artist_name() {
  local parent_root="$1"
  local current_artist_root="$2"
  local fallback=""

  if [[ -n "$current_artist_root" && "${current_artist_root:A}" != "${parent_root:A}" ]]; then
    fallback="$(ml_sanitize_name "${current_artist_root:t}")"
  fi

  print -r -- "$fallback"
}

musicpipeline_nested_fallback_artist_name() {
  local path="$1"
  local parent_root="$2"

  ml_first_nested_non_reserved_ancestor_name "$path" "$parent_root" 2>/dev/null || true
}

musicpipeline_audio_tree_is_alac_only() {
  local root="$1"
  local -a audio_files
  local file codec

  audio_files=("${(@f)$(find "$root" \
    \( -type d \( -name "$SOURCE_ARCHIVE_DIR" -o -name "$STATE_DIR_NAME" -o -name "$UNKNOWN_DIR_NAME" -o -name "$NOT_AUDIO_DIR_NAME" -o "${MUSICLIB_AUDIO_COLLECT_DIR_FIND_ARGS[@]}" -o -name "$LOSSY_ARCHIVE_DIR_NAME" -o -name "$MUSICLIB_LEGACY_LOSSY_ARCHIVE_DIR_NAME" -o -name '.*' \) -prune \) -o \
    -type f \( -iname '*.m4a' -o -iname '*.alac' -o -iname '*.flac' -o -iname '*.wav' -o -iname '*.aiff' -o -iname '*.aif' -o -iname '*.mp3' -o -iname '*.ogg' -o -iname '*.opus' -o -iname '*.wma' \) -print | LC_ALL=C sort)}")
  (( ${#audio_files[@]} > 0 )) || return 1

  for file in "${audio_files[@]}"; do
    [[ -e "$file" ]] || continue
    codec="$(ml_audio_codec "$file")"
    [[ "$codec" == "alac" ]] || return 1
  done

  return 0
}

musicpipeline_cleanup_empty_archive_stub() {
  local artist_root="$1"
  local archive_root="$artist_root/$SOURCE_ARCHIVE_DIR"
  local has_payload=1

  [[ -d "$archive_root" ]] || return 0

  find "$archive_root" -mindepth 1 -maxdepth 1 \
    ! -name '.DS_Store' \
    ! -name '.localized' \
    -print -quit | grep -q .
  has_payload=$?
  (( has_payload == 0 )) && return 0

  [[ -f "$archive_root/.DS_Store" ]] && ml_remove_file "$archive_root/.DS_Store" "cleanup_archive_stub" "remove empty archive stub"
  [[ -f "$archive_root/.localized" ]] && ml_remove_file "$archive_root/.localized" "cleanup_archive_stub" "remove empty archive stub"

  if (( MUSICLIB_DRY_RUN )); then
    ml_log_step "rmdir" "$(ml_display_path "$archive_root")"
  else
    rmdir -- "$archive_root" 2>/dev/null || true
  fi
  ml_record_event "cleanup_archive_stub" "" "$archive_root" "remove empty archive stub" ""

  find "$artist_root" -mindepth 1 -maxdepth 1 -print -quit | grep -q .
  if (( $? != 0 )); then
    if (( MUSICLIB_DRY_RUN )); then
      ml_log_step "rmdir" "$(ml_display_path "$artist_root")"
    else
      rmdir -- "$artist_root" 2>/dev/null || true
    fi
    ml_record_event "cleanup_archive_stub" "" "$artist_root" "remove empty artist stub" ""
  fi
}

musicpipeline_restore_archived_alac_for_artist() {
  local artist_root="$1"
  local archive_root="$artist_root/$SOURCE_ARCHIVE_DIR"
  local restored=0
  local item dst
  local -a archived_dirs archived_files
  local has_non_special=1

  [[ -d "$artist_root" && -d "$archive_root" ]] || return 1
  if whence -w ml_dir_has_non_special_content >/dev/null 2>&1; then
    ml_dir_has_non_special_content "$artist_root" && return 1
  else
    find "$artist_root" -mindepth 1 -maxdepth 1 \
      ! -name '.*' \
      ! -name "$SOURCE_ARCHIVE_DIR" \
      ! -name "$STATE_DIR_NAME" \
      ! -name "$UNKNOWN_DIR_NAME" \
      ! -name "$NOT_AUDIO_DIR_NAME" \
      ! -name "$LOSSY_ARCHIVE_DIR_NAME" \
      ! -name "$MUSICLIB_LEGACY_LOSSY_ARCHIVE_DIR_NAME" \
      -print | while IFS= read -r dir; do
        ml_is_audio_collect_dir_name "${dir:t}" && continue
        print -r -- "$dir"
        break
      done | grep -q .
    has_non_special=$?
    (( has_non_special == 0 )) && return 1
  fi

  archived_dirs=("${(@f)$(find "$archive_root" -mindepth 1 -maxdepth 1 -type d ! -name '.*' | LC_ALL=C sort)}")
  for item in "${archived_dirs[@]}"; do
    [[ -d "$item" ]] || continue
    musicpipeline_audio_tree_is_alac_only "$item" || continue
    dst="$artist_root/${item:t}"
    if ml_move_path "$item" "$dst" "restore_archived_alac" "restore archived ALAC release"; then
      ml_log_step "restore" "$(ml_display_path "$item") -> $(ml_display_path "$dst")"
      restored=1
    fi
  done

  archived_files=("${(@f)$(find "$archive_root" -mindepth 1 -maxdepth 1 -type f \( -iname '*.m4a' -o -iname '*.alac' \) | LC_ALL=C sort)}")
  for item in "${archived_files[@]}"; do
    [[ -f "$item" ]] || continue
    musicpipeline_audio_tree_is_alac_only "$item" || continue
    dst="$artist_root/${item:t}"
    if ml_move_path "$item" "$dst" "restore_archived_alac" "restore archived ALAC file"; then
      ml_log_step "restore" "$(ml_display_path "$item") -> $(ml_display_path "$dst")"
      restored=1
    fi
  done

  if (( restored )); then
    ml_cleanup_empty_dirs "$artist_root"
    musicpipeline_cleanup_empty_archive_stub "$artist_root"
    return 0
  fi

  musicpipeline_cleanup_empty_archive_stub "$artist_root"
  return 1
}

musicpipeline_path_is_under_registered_artist() {
  local path="${1:A}"
  local artist_root

  for artist_root in "${(@Qk)musicpipeline_ARTIST_TARGETS}"; do
    [[ -n "$artist_root" ]] || continue
    if [[ "$path" == "${artist_root:A}/"* ]]; then
      return 0
    fi
  done

  return 1
}

musicpipeline_file_is_under_release_dir() {
  local file="$1"
  local root="${2:A}"
  local dir="${file:h:A}"

  while [[ "$dir" != "$root" && "$dir" != "/" ]]; do
    if ml_is_reserved_dir_name "${dir:t}"; then
      dir="${dir:h}"
      continue
    fi
    if [[ "$(ml_dir_kind "$dir")" == "release" ]]; then
      return 0
    fi
    dir="${dir:h}"
  done

  return 1
}

musicpipeline_prepare_batch_root_deep() {
  local root="$1"
  local archive_type="$2"
  local progressed=0
  local dir track file
  local -a release_dirs loose_tracks misc_files

  release_dirs=("${(@f)$(find "$root" \
    \( -type d \( -name "$SOURCE_ARCHIVE_DIR" -o -name "$STATE_DIR_NAME" -o -name "$NOT_AUDIO_DIR_NAME" -o -name "$LOSSY_ARCHIVE_DIR_NAME" -o -name "$MUSICLIB_LEGACY_LOSSY_ARCHIVE_DIR_NAME" -o -name '.*' \) -prune \) -o \
    -mindepth 2 -type d -print | awk -F/ '{ print NF "\t" $0 }' | LC_ALL=C sort -rn | cut -f2-)}")
  for dir in "${release_dirs[@]}"; do
    [[ -d "$dir" ]] || continue
    ml_path_has_internal_skip_segment "$dir" "$root" && continue
    ml_is_reserved_dir_name "${dir:t}" && continue
    musicpipeline_path_is_under_registered_artist "$dir" && continue
    [[ "$(ml_dir_kind "$dir")" == "release" ]] || continue
    if musicpipeline_route_release_if_needed "$dir" "$root" "$archive_type" "$root"; then
      progressed=1
    fi
  done

  loose_tracks=("${(@f)$(find "$root" \
    \( -type d \( -name "$SOURCE_ARCHIVE_DIR" -o -name "$STATE_DIR_NAME" -o -name "$NOT_AUDIO_DIR_NAME" -o -name "$LOSSY_ARCHIVE_DIR_NAME" -o -name "$MUSICLIB_LEGACY_LOSSY_ARCHIVE_DIR_NAME" -o -name '.*' \) -prune \) -o \
    -mindepth 2 -type f \( "${MUSICLIB_AUDIO_FILE_FIND_ARGS[@]}" \) -print | LC_ALL=C sort)}")
  for track in "${loose_tracks[@]}"; do
    [[ -f "$track" ]] || continue
    ml_path_has_internal_skip_segment "$track" "$root" && continue
    musicpipeline_path_is_under_registered_artist "$track" && continue
    musicpipeline_file_is_under_release_dir "$track" "$root" && continue
    if musicpipeline_route_track_if_needed "$track" "$root" "$archive_type" "$root"; then
      progressed=1
    fi
  done

  misc_files=("${(@f)$(find "$root" \
    \( -type d \( -name "$SOURCE_ARCHIVE_DIR" -o -name "$STATE_DIR_NAME" -o -name "$NOT_AUDIO_DIR_NAME" -o -name "$LOSSY_ARCHIVE_DIR_NAME" -o -name "$MUSICLIB_LEGACY_LOSSY_ARCHIVE_DIR_NAME" -o -name '.*' \) -prune \) -o \
    -mindepth 2 -type f ! \( "${MUSICLIB_AUDIO_FILE_FIND_ARGS[@]}" \) -print | LC_ALL=C sort)}")
  for file in "${misc_files[@]}"; do
    [[ -f "$file" ]] || continue
    ml_path_has_internal_skip_segment "$file" "$root" && continue
    musicpipeline_path_is_under_registered_artist "$file" && continue
    musicpipeline_file_is_under_release_dir "$file" "$root" && continue
    if ml_move_misc_file "$file" "$root" "nested non-audio file"; then
      progressed=1
    fi
  done

  (( progressed )) && ml_cleanup_empty_recoverable_dirs "$root" >/dev/null
}

# Figure out which artist root a release or loose track really belongs to. In a
# lossy archive, lossless sources get pointed at the sibling lossless root.
musicpipeline_desired_artist_root_for_release() {
  local release_dir="$1"
  local parent_root="$2"
  local archive_type="$3"
  local current_artist_root="${4:-}"
  local artist base_root

  artist="$(ml_release_primary_artist "$release_dir")"
  if [[ -z "$artist" ]]; then
    artist="$(musicpipeline_fallback_artist_name "$parent_root" "$current_artist_root")"
  fi
  if [[ -z "$artist" ]]; then
    artist="$(musicpipeline_nested_fallback_artist_name "$release_dir" "$parent_root")"
  fi
  if [[ -z "$artist" ]]; then
    if [[ -n "$current_artist_root" && "${current_artist_root:A}" != "${parent_root:A}" && "${current_artist_root:t}" != "$UNKNOWN_DIR_NAME" ]]; then
      return 10
    fi
    artist="$UNKNOWN_DIR_NAME"
  fi

  base_root="$parent_root"
  if ml_artist_is_various "$artist"; then
    print -r -- "$base_root"
    return 0
  fi
  if [[ "$archive_type" == "archive_lossy" ]] && ml_release_has_lossless_sources "$release_dir"; then
    [[ -n "$LOSSLESS_DIR_NAME" ]] || return 11
    base_root="$(ml_sibling_lossless_root "$parent_root")"
    [[ -d "$base_root" ]] || return 12
  fi

  print -r -- "$base_root/$artist"
}

musicpipeline_desired_artist_root_for_track() {
  local track="$1"
  local parent_root="$2"
  local archive_type="$3"
  local current_artist_root="${4:-}"
  local artist base_root

  artist="$(ml_primary_artist_from_file "$track")"
  if [[ -z "$artist" ]]; then
    artist="$(musicpipeline_fallback_artist_name "$parent_root" "$current_artist_root")"
  fi
  if [[ -z "$artist" ]]; then
    artist="$(musicpipeline_nested_fallback_artist_name "$track" "$parent_root")"
  fi
  if [[ -z "$artist" ]]; then
    if [[ -n "$current_artist_root" && "${current_artist_root:A}" != "${parent_root:A}" && "${current_artist_root:t}" != "$UNKNOWN_DIR_NAME" ]]; then
      return 10
    fi
    artist="$UNKNOWN_DIR_NAME"
  fi

  base_root="$parent_root"
  if ml_artist_is_various "$artist"; then
    print -r -- "$base_root"
    return 0
  fi
  if [[ "$archive_type" == "archive_lossy" ]] && ml_is_lossless_source_file "$track"; then
    [[ -n "$LOSSLESS_DIR_NAME" ]] || return 11
    base_root="$(ml_sibling_lossless_root "$parent_root")"
    [[ -d "$base_root" ]] || return 12
  fi

  print -r -- "$base_root/$artist"
}

# Turn routing error codes into readable log messages, and block conversion for
# artist roots that would otherwise be left in a half-rerouted state.
musicpipeline_note_unroutable_release() {
  local release_dir="$1"
  local parent_root="$2"
  local current_artist_root="$3"
  local rc="$4"
  local msg

  case "$rc" in
    10)
      msg="missing album artist/artist tags"
      ;;
    11)
      msg="lossless reroute requested but config is missing LOSSLESS_DIR_NAME"
      ;;
    12)
      msg="lossless reroute destination is unavailable"
      ;;
    *)
      msg="unable to resolve destination artist root"
      ;;
  esac

  musicpipeline_warn_audit "release routing issue: $msg: $(ml_display_path "$release_dir")"
  ml_record_event "skip" "$release_dir" "$parent_root" "$msg" "route_release"

  if [[ "${current_artist_root:A}" != "${parent_root:A}" && ( "$rc" == 10 || "$rc" == 11 || "$rc" == 12 ) ]] && ml_release_has_lossless_sources "$release_dir"; then
    musicpipeline_block_convert_for_artist "$current_artist_root" "$msg"
  fi
}

musicpipeline_note_unroutable_track() {
  local track="$1"
  local parent_root="$2"
  local current_artist_root="$3"
  local rc="$4"
  local msg

  case "$rc" in
    10)
      msg="missing album artist/artist tags"
      ;;
    11)
      msg="lossless reroute requested but config is missing LOSSLESS_DIR_NAME"
      ;;
    12)
      msg="lossless reroute destination is unavailable"
      ;;
    *)
      msg="unable to resolve destination artist root"
      ;;
  esac

  musicpipeline_warn_audit "track routing issue: $msg: $(ml_display_path "$track")"
  ml_record_event "skip" "$track" "$parent_root" "$msg" "route_loose_track"

  if [[ "${current_artist_root:A}" != "${parent_root:A}" && ( "$rc" == 10 || "$rc" == 11 || "$rc" == 12 ) ]] && ml_is_lossless_source_file "$track"; then
    musicpipeline_block_convert_for_artist "$current_artist_root" "$msg"
  fi
}

# Treat an already-selected artist root as correct when its folder name matches
# the resolved artist after normalization, even if the raw path text differs.
musicpipeline_artist_root_matches_destination() {
  local current_artist_root="$1"
  local parent_root="$2"
  local desired_artist_root="$3"

  [[ "${desired_artist_root:A}" == "${current_artist_root:A}" ]] && return 0
  [[ "${current_artist_root:A}" == "${parent_root:A}" ]] && return 1
  [[ "$(ml_normalize_match_name "${current_artist_root:t}")" == "$(ml_normalize_match_name "${desired_artist_root:t}")" ]]
}

# Move a release/track only when it actually belongs somewhere else. A return of
# 1 here usually just means "nothing to do", not "something exploded".
musicpipeline_route_release_if_needed() {
  local release_dir="$1"
  local parent_root="$2"
  local archive_type="$3"
  local current_artist_root="$4"
  local desired_artist_root rc release_target

  desired_artist_root="$(musicpipeline_desired_artist_root_for_release "$release_dir" "$parent_root" "$archive_type" "$current_artist_root")"
  rc=$?
  if (( rc != 0 )); then
    if [[ "${current_artist_root:A}" != "${parent_root:A}" && "$rc" == 10 ]]; then
      return 1
    fi
    musicpipeline_note_unroutable_release "$release_dir" "$parent_root" "$current_artist_root" "$rc"
    ml_move_to_unknown "$release_dir" "$parent_root" "unroutable release" "route_unknown" >/dev/null 2>&1 || true
    return 1
  fi

  if musicpipeline_artist_root_matches_destination "$current_artist_root" "$parent_root" "$desired_artist_root"; then
    return 1
  fi

  if [[ "${desired_artist_root:A}" == "${release_dir:A}" ]]; then
    musicpipeline_register_artist "$release_dir"
    return 1
  fi

  release_target="$desired_artist_root/${release_dir:t}"
  if ml_route_release_to_artist "$release_dir" "$desired_artist_root"; then
    ml_log_move "route release" "$release_dir" "$release_target"
    musicpipeline_register_artist "$desired_artist_root"
    return 0
  fi

  ml_move_to_unknown "$release_dir" "$parent_root" "route release conflict" "route_unknown" >/dev/null 2>&1 || true

  return 1
}

musicpipeline_route_track_if_needed() {
  local track="$1"
  local parent_root="$2"
  local archive_type="$3"
  local current_artist_root="$4"
  local desired_artist_root rc dst_file

  desired_artist_root="$(musicpipeline_desired_artist_root_for_track "$track" "$parent_root" "$archive_type" "$current_artist_root")"
  rc=$?
  if (( rc != 0 )); then
    if [[ "${current_artist_root:A}" != "${parent_root:A}" && "$rc" == 10 ]]; then
      return 1
    fi
    musicpipeline_note_unroutable_track "$track" "$parent_root" "$current_artist_root" "$rc"
    ml_move_to_unknown "$track" "$parent_root" "unroutable loose track" "route_unknown" >/dev/null 2>&1 || true
    return 1
  fi

  if musicpipeline_artist_root_matches_destination "$current_artist_root" "$parent_root" "$desired_artist_root"; then
    return 1
  fi

  dst_file="$(ml_loose_track_target_path "$track" "$desired_artist_root")"

  if ml_route_loose_track_to_artist "$track" "$desired_artist_root"; then
    ml_log_move "copy to library" "$track" "$dst_file"
    musicpipeline_register_artist "$desired_artist_root"
    return 0
  fi

  ml_move_to_unknown "$track" "$parent_root" "route loose track conflict" "route_unknown" >/dev/null 2>&1 || true

  return 1
}

# Sweep one artist root for misplaced releases/loose files, then keep looping
# across registered artist roots until no more rerouting is happening.
musicpipeline_rehome_artist_root() {
  local artist_root="$1"
  local parent_root="${artist_root:h}"
  local archive_type
  local -a release_dirs loose_tracks
  local release_dir track

  [[ -d "$artist_root" ]] || return 0

  archive_type="$(ml_enclosing_archive_type "$artist_root")"
  release_dirs=("${(@f)$(musicpipeline_direct_release_dirs "$artist_root")}")
  for release_dir in "${release_dirs[@]}"; do
    [[ -n "$release_dir" ]] || continue
    [[ -e "$release_dir" ]] || continue
    musicpipeline_route_release_if_needed "$release_dir" "$parent_root" "$archive_type" "$artist_root"
  done

  loose_tracks=("${(@f)$(ml_find_loose_audio_files "$artist_root" | LC_ALL=C sort)}")
  for track in "${loose_tracks[@]}"; do
    [[ -n "$track" ]] || continue
    [[ -e "$track" ]] || continue
    musicpipeline_route_track_if_needed "$track" "$parent_root" "$archive_type" "$artist_root"
  done
}

musicpipeline_rehome_registered_artist_targets() {
  local -A visited=()
  local -a artist_roots
  local artist_root progressed

  while :; do
    progressed=0
    artist_roots=("${(@Qk)musicpipeline_ARTIST_TARGETS}")
    artist_roots=("${(@o)artist_roots}")
    for artist_root in "${artist_roots[@]}"; do
      [[ -n "$artist_root" ]] || continue
      [[ -n "${visited["$artist_root"]:-}" ]] && continue
      visited["$artist_root"]=1
      [[ -d "$artist_root" ]] || continue
      musicpipeline_rehome_artist_root "$artist_root"
      progressed=1
    done
    (( progressed )) || break
  done
}

# Audit helpers. These mirror the mutate path, but only report what would
# happen and where conflicts are waiting.
musicpipeline_audit_release_dir() {
  local release_dir="$1"
  local target_artist_root="$2"
  local first_audio normalized_dir
  local -a audio_files
  local -A planned=()
  local file target_name target_path output_path output_ext missing

  first_audio="$(ml_first_audio_file "$release_dir")"
  if [[ -z "$first_audio" ]]; then
    musicpipeline_warn_audit "non-audio release directory: $release_dir"
    ml_record_event "skip" "$release_dir" "" "non-audio release directory" "audit_release"
    return 0
  fi

  normalized_dir="$target_artist_root/$(ml_release_target_dir_name "$release_dir")"

  ml_log "release: $(ml_display_path "$release_dir")"
  musicpipeline_audit_detail "target: $(ml_display_path "$normalized_dir")"
  ml_record_event "audit_release" "$release_dir" "$normalized_dir" "release plan" ""

  if [[ "${normalized_dir:A}" != "${release_dir:A}" && -e "$normalized_dir" ]]; then
    musicpipeline_audit_warn_detail "folder conflict: normalized release already exists: $normalized_dir"
    ml_record_event "audit_conflict" "$release_dir" "$normalized_dir" "normalized release already exists" "release"
  fi

  audio_files=("${(@f)$(ml_find_audio_files "$release_dir" | LC_ALL=C sort)}")
  for file in "${audio_files[@]}"; do
    [[ -n "$file" ]] || continue
    [[ -e "$file" ]] || continue

    target_name="$(ml_track_target_name "$file")"
    target_path="$normalized_dir/$target_name"
    ml_log "track: $(ml_display_path "$file")"
    musicpipeline_audit_detail "target: $(ml_display_path "$target_path")"

    if [[ -n "${planned["$target_path"]:-}" && "${planned["$target_path"]}" != "$file" ]]; then
        musicpipeline_audit_warn_detail "duplicate normalized track target: $(ml_display_path "$target_path")"
      ml_record_event "audit_conflict" "$file" "$target_path" "duplicate normalized track target" "track"
    else
      planned["$target_path"]="$file"
    fi

    if [[ "${target_path:A}" != "${file:A}" && -e "$target_path" ]]; then
        musicpipeline_audit_warn_detail "track conflict: target already exists: $(ml_display_path "$target_path")"
      ml_record_event "audit_conflict" "$file" "$target_path" "track target already exists" "track"
    fi

    missing="$(musicpipeline_missing_tags_for_file "$file")"
    if [[ -n "$missing" ]]; then
      musicpipeline_audit_warn_detail "missing tags [$missing]"
      ml_record_event "audit_missing_tags" "$file" "" "$missing" "track"
    fi

    output_ext="$(ml_convert_output_extension_for_source "$file" 2>/dev/null || true)"
    if [[ -n "$output_ext" ]]; then
      output_path="${target_path:r}.$output_ext"
      if [[ -e "$output_path" ]]; then
        musicpipeline_audit_warn_detail "existing converted output may block conversion: $(ml_display_path "$output_path")"
        ml_record_event "audit_conflict" "$file" "$output_path" "existing converted output" "convert"
      else
        musicpipeline_audit_detail "convert: $(ml_display_path "$output_path")"
        ml_record_event "audit_convert" "$file" "$output_path" "source eligible for conversion" ""
      fi
    fi
  done
}

musicpipeline_audit_track_in_context() {
  local track="$1"
  local parent_root="$2"
  local archive_type="$3"
  local current_artist_root="$4"
  local desired_artist_root rc normalized_track output_path output_ext missing track_label
  local has_release_context=0

  desired_artist_root="$(musicpipeline_desired_artist_root_for_track "$track" "$parent_root" "$archive_type" "$current_artist_root")"
  rc=$?
  if (( rc != 0 )); then
    if [[ "${current_artist_root:A}" != "${parent_root:A}" && "$rc" == 10 ]]; then
      desired_artist_root="$current_artist_root"
    else
      musicpipeline_note_unroutable_track "$track" "$parent_root" "$current_artist_root" "$rc"
      if [[ "${current_artist_root:A}" != "${parent_root:A}" ]]; then
        desired_artist_root="$current_artist_root"
      else
        return 0
      fi
    fi
  fi

  if musicpipeline_artist_root_matches_destination "$current_artist_root" "$parent_root" "$desired_artist_root"; then
    desired_artist_root="$current_artist_root"
  fi

  normalized_track="$(ml_loose_track_target_path "$track" "$desired_artist_root")"
  track_label="loose track"
  if whence -w ml_track_has_release_context >/dev/null 2>&1; then
    ml_track_has_release_context "$track" && has_release_context=1
  else
    [[ -n "$(ml_tag_value album "$(ml_file_tags "$track")")" && -n "$(ml_tag_value track "$(ml_file_tags "$track")")" ]] && has_release_context=1
  fi
  (( has_release_context )) && track_label="album track"

  ml_log "$track_label: $(ml_display_path "$track")"
  musicpipeline_audit_detail "target: $(ml_display_path "$normalized_track")"
  ml_record_event "audit_loose_track" "$track" "$normalized_track" "loose track plan" ""

  if [[ "${normalized_track:A}" != "${track:A}" && -e "$normalized_track" ]]; then
    musicpipeline_audit_warn_detail "track conflict: normalized loose track already exists: $(ml_display_path "$normalized_track")"
    ml_record_event "audit_conflict" "$track" "$normalized_track" "normalized loose track already exists" "route_loose_track"
  fi

  missing="$(musicpipeline_missing_tags_for_file "$track")"
  if [[ -n "$missing" ]]; then
    musicpipeline_audit_warn_detail "missing tags [$missing]"
    ml_record_event "audit_missing_tags" "$track" "" "$missing" "loose_track"
  fi

  output_ext="$(ml_convert_output_extension_for_source "$track" 2>/dev/null || true)"
  if [[ -n "$output_ext" ]]; then
    output_path="${normalized_track:r}.$output_ext"
    if [[ -e "$output_path" ]]; then
      musicpipeline_audit_warn_detail "existing converted output may block conversion: $(ml_display_path "$output_path")"
      ml_record_event "audit_conflict" "$track" "$output_path" "existing converted output" "convert"
    else
      musicpipeline_audit_detail "convert: $(ml_display_path "$output_path")"
      ml_record_event "audit_convert" "$track" "$output_path" "loose track eligible for conversion" ""
    fi
  fi
}

musicpipeline_audit_release_in_context() {
  local release_dir="$1"
  local parent_root="$2"
  local archive_type="$3"
  local current_artist_root="$4"
  local desired_artist_root rc

  desired_artist_root="$(musicpipeline_desired_artist_root_for_release "$release_dir" "$parent_root" "$archive_type" "$current_artist_root")"
  rc=$?
  if (( rc != 0 )); then
    if [[ "${current_artist_root:A}" != "${parent_root:A}" && "$rc" == 10 ]]; then
      desired_artist_root="$current_artist_root"
    else
      musicpipeline_note_unroutable_release "$release_dir" "$parent_root" "$current_artist_root" "$rc"
      if [[ "${current_artist_root:A}" != "${parent_root:A}" ]]; then
        desired_artist_root="$current_artist_root"
      else
        return 0
      fi
    fi
  fi

  if musicpipeline_artist_root_matches_destination "$current_artist_root" "$parent_root" "$desired_artist_root"; then
    desired_artist_root="$current_artist_root"
  else
    ml_log "route release: $(ml_display_path "$release_dir") -> $(ml_display_path "$desired_artist_root/${release_dir:t}")"
    ml_record_event "audit_route_release" "$release_dir" "$desired_artist_root/${release_dir:t}" "route release to primary artist folder" ""
  fi

  musicpipeline_audit_release_dir "$release_dir" "$desired_artist_root"
}

musicpipeline_audit_artist_root() {
  local artist_root="$1"
  local parent_root="${artist_root:h}"
  local archive_type
  local -a direct_dirs loose_tracks
  local dir kind track

  ml_log ""
  ml_log "Artist root: $artist_root"
  archive_type="$(ml_enclosing_archive_type "$artist_root")"
  ml_log "Archive context: $archive_type"
  ml_record_event "audit_artist_root" "$artist_root" "" "$archive_type" ""

  direct_dirs=("${(@f)$(musicpipeline_direct_child_dirs "$artist_root")}")
  for dir in "${direct_dirs[@]}"; do
    [[ -n "$dir" ]] || continue
    kind="$(ml_dir_kind "$dir")"
    case "$kind" in
      release)
        musicpipeline_audit_release_in_context "$dir" "$parent_root" "$archive_type" "$artist_root"
        ;;
      artist)
        musicpipeline_audit_artist_root "$dir"
        ;;
      *)
        musicpipeline_warn_audit "unknown directory inside artist root: $dir"
        ml_record_event "skip" "$dir" "" "unknown directory kind" "artist_root"
        ;;
    esac
  done

  loose_tracks=("${(@f)$(ml_find_loose_audio_files "$artist_root" | LC_ALL=C sort)}")
  for track in "${loose_tracks[@]}"; do
    [[ -n "$track" ]] || continue
    musicpipeline_audit_track_in_context "$track" "$parent_root" "$archive_type" "$artist_root"
  done
}

musicpipeline_audit_batch_root_deep() {
  local root="$1"
  local archive_type="$2"
  local dir track
  local -a release_dirs loose_tracks

  release_dirs=("${(@f)$(find "$root" \
    \( -type d \( -name "$SOURCE_ARCHIVE_DIR" -o -name "$STATE_DIR_NAME" -o -name "$NOT_AUDIO_DIR_NAME" -o -name "$LOSSY_ARCHIVE_DIR_NAME" -o -name "$MUSICLIB_LEGACY_LOSSY_ARCHIVE_DIR_NAME" -o -name '.*' \) -prune \) -o \
    -mindepth 2 -type d -print | awk -F/ '{ print NF "\t" $0 }' | LC_ALL=C sort -rn | cut -f2-)}")
  for dir in "${release_dirs[@]}"; do
    [[ -d "$dir" ]] || continue
    ml_path_has_internal_skip_segment "$dir" "$root" && continue
    ml_is_reserved_dir_name "${dir:t}" && continue
    musicpipeline_path_is_under_registered_artist "$dir" && continue
    [[ "$(ml_dir_kind "$dir")" == "release" ]] || continue
    musicpipeline_audit_release_in_context "$dir" "$root" "$archive_type" "$root"
  done

  loose_tracks=("${(@f)$(find "$root" \
    \( -type d \( -name "$SOURCE_ARCHIVE_DIR" -o -name "$STATE_DIR_NAME" -o -name "$NOT_AUDIO_DIR_NAME" -o -name "$LOSSY_ARCHIVE_DIR_NAME" -o -name "$MUSICLIB_LEGACY_LOSSY_ARCHIVE_DIR_NAME" -o -name '.*' \) -prune \) -o \
    -mindepth 2 -type f \( "${MUSICLIB_AUDIO_FILE_FIND_ARGS[@]}" \) -print | LC_ALL=C sort)}")
  for track in "${loose_tracks[@]}"; do
    [[ -f "$track" ]] || continue
    ml_path_has_internal_skip_segment "$track" "$root" && continue
    musicpipeline_path_is_under_registered_artist "$track" && continue
    musicpipeline_file_is_under_release_dir "$track" "$root" && continue
    musicpipeline_audit_track_in_context "$track" "$root" "$archive_type" "$root"
  done
}

musicpipeline_audit_batch_root() {
  local root="$1"
  local archive_type="$2"
  local -a direct_dirs loose_tracks
  local dir kind track

  ml_log ""
  ml_log "Batch root: $root"
  ml_log "Root type: $archive_type"
  ml_record_event "audit_batch_root" "$root" "" "$archive_type" ""

  direct_dirs=("${(@f)$(musicpipeline_direct_child_dirs "$root")}")
  for dir in "${direct_dirs[@]}"; do
    [[ -n "$dir" ]] || continue
    [[ "$(ml_dir_kind "$dir")" == "artist" ]] && musicpipeline_register_artist "$dir"
  done
  for dir in "${direct_dirs[@]}"; do
    [[ -n "$dir" ]] || continue
    kind="$(ml_dir_kind "$dir")"
    case "$kind" in
      artist)
        musicpipeline_audit_artist_root "$dir"
        ;;
      release)
        musicpipeline_audit_release_in_context "$dir" "$root" "$archive_type" "$root"
        ;;
      *)
        musicpipeline_warn_audit "unknown top-level directory: $dir"
        ml_record_event "skip" "$dir" "" "unknown top-level directory" "batch_root"
        ;;
    esac
  done

  loose_tracks=("${(@f)$(ml_find_loose_audio_files "$root" | LC_ALL=C sort)}")
  for track in "${loose_tracks[@]}"; do
    [[ -n "$track" ]] || continue
    musicpipeline_audit_track_in_context "$track" "$root" "$archive_type" "$root"
  done

  musicpipeline_audit_batch_root_deep "$root" "$archive_type"
}

musicpipeline_audit_collection_parent() {
  local root="$1"
  local lossless_root="$root/$LOSSLESS_DIR_NAME"
  local lossy_root="$root/$LOSSY_DIR_NAME"

  ml_log "Collection parent: $root"
  ml_record_event "audit_collection_parent" "$root" "" "collection_parent" ""

  [[ -d "$lossless_root" ]] && musicpipeline_audit_batch_root "$lossless_root" "archive_lossless"
  [[ -d "$lossy_root" ]] && musicpipeline_audit_batch_root "$lossy_root" "archive_lossy"
}

# Pre-processing before sort/convert. Batch roots need to register existing
# artist folders, route loose releases/tracks, then run the reroute sweep.
musicpipeline_prepare_batch_root() {
  local root="$1"
  local archive_type="$2"
  local -a direct_dirs loose_tracks loose_files
  local dir kind track file

  direct_dirs=("${(@f)$(musicpipeline_direct_child_dirs "$root")}")
  for dir in "${direct_dirs[@]}"; do
    [[ -d "$dir" ]] || continue
    musicpipeline_restore_archived_alac_for_artist "$dir" || true
  done
  direct_dirs=("${(@f)$(musicpipeline_direct_child_dirs "$root")}")
  for dir in "${direct_dirs[@]}"; do
    [[ -n "$dir" ]] || continue
    kind="$(ml_dir_kind "$dir")"
    [[ "$kind" == "artist" ]] && musicpipeline_register_artist "$dir"
  done

  musicpipeline_prepare_batch_root_deep "$root" "$archive_type"
  direct_dirs=("${(@f)$(musicpipeline_direct_child_dirs "$root")}")
  for dir in "${direct_dirs[@]}"; do
    [[ -n "$dir" ]] || continue
    kind="$(ml_dir_kind "$dir")"
    [[ "$kind" == "artist" ]] && musicpipeline_register_artist "$dir"
  done

  for dir in "${direct_dirs[@]}"; do
    [[ -n "$dir" ]] || continue
    kind="$(ml_dir_kind "$dir")"
    case "$kind" in
      release)
        musicpipeline_route_release_if_needed "$dir" "$root" "$archive_type" "$root"
        ;;
      artist)
        ;;
      *)
        if ! ml_dir_has_non_special_content "$dir"; then
          ml_log_step "skip" "housekeeping-only directory $(ml_display_path "$dir")"
        elif ml_move_to_unknown "$dir" "$root" "unknown top-level directory" "route_unknown"; then
          ml_log_step "unknown" "$(ml_display_path "$dir")"
        else
          ml_warn "skipping unknown top-level directory: $dir"
          ml_record_event "skip" "$dir" "" "unknown top-level directory" "batch_root"
        fi
        ;;
    esac
  done

  loose_tracks=("${(@f)$(ml_find_loose_audio_files "$root" | LC_ALL=C sort)}")
  for track in "${loose_tracks[@]}"; do
    [[ -n "$track" ]] || continue
    musicpipeline_route_track_if_needed "$track" "$root" "$archive_type" "$root"
  done

  loose_files=("${(@f)$(find "$root" -mindepth 1 -maxdepth 1 -type f ! \( "${MUSICLIB_AUDIO_FILE_FIND_ARGS[@]}" \) | LC_ALL=C sort)}")
  for file in "${loose_files[@]}"; do
    [[ -n "$file" ]] || continue
    if ml_move_misc_file "$file" "$root" "unknown top-level file"; then
      if ml_is_known_media_file "$file"; then
        ml_log_step "unknown" "$(ml_display_path "$file")"
      else
        ml_log_step "not-audio" "$(ml_display_path "$file")"
      fi
    else
      ml_warn "skipping unknown top-level file: $file"
      ml_record_event "skip" "$file" "" "unknown top-level file" "batch_root"
    fi
  done

  musicpipeline_rehome_registered_artist_targets
}

musicpipeline_prepare_artist_root() {
  local artist_root="$1"

  musicpipeline_restore_archived_alac_for_artist "$artist_root" || true
  musicpipeline_register_artist "$artist_root"
  musicpipeline_rehome_registered_artist_targets
}

# Thin wrappers around the worker scripts so the top-level wrapper can pass down
# flags without duplicating their inner logic.
musicpipeline_run_sort_for_artist() {
  local artist_root="$1"
  local -a args

  args=()
  (( musicpipeline_DRY_RUN )) && args+=(--dry-run)
  (( musicpipeline_KEEP_SIDECARS )) && args+=(--keep-sidecars)
  args+=("$artist_root")
  sort_music_main "${args[@]}"
}

musicpipeline_run_convert_for_artist() {
  local artist_root="$1"

  if [[ -n "${musicpipeline_BLOCKED_CONVERT_ARTISTS["$artist_root"]:-}" ]]; then
    ml_warn "skipping convert for $artist_root: ${musicpipeline_BLOCKED_CONVERT_ARTISTS["$artist_root"]}"
    ml_record_event "skip" "$artist_root" "" "${musicpipeline_BLOCKED_CONVERT_ARTISTS["$artist_root"]}" "convert_artist_root"
    return 0
  fi

  MUSICLIB_DRY_RUN=$musicpipeline_DRY_RUN
  ml_need_cmd ffmpeg
  ml_need_cmd ffprobe
  ml_need_cmd exiftool
  ml_need_cmd find
  ml_need_cmd sed
  ml_need_cmd awk
  convert_artist_root "$artist_root"
}

musicpipeline_release_target_after_sort() {
  local release_dir="$1"
  local normalized_dir

  [[ -n "$(ml_first_audio_file "$release_dir")" ]] || {
    print -r -- "$release_dir"
    return 0
  }

  normalized_dir="${release_dir:h}/$(ml_release_target_dir_name "$release_dir")"

  if (( ! musicpipeline_DRY_RUN )) && [[ -d "$normalized_dir" ]]; then
    print -r -- "$normalized_dir"
  else
    print -r -- "$release_dir"
  fi
}

musicpipeline_process_release_root() {
  local mode="$1"
  local release_dir="$2"
  local current_release_dir="$release_dir"
  local -a args

  ml_log_scope "release" "$release_dir"

  case "$mode" in
    sort)
      sort_release_dir "$current_release_dir"
      ;;
    convert)
      args=()
      (( musicpipeline_DRY_RUN )) && args+=(--dry-run)
      args+=("$current_release_dir")
      convert_music_main "${args[@]}"
      ;;
    both)
      args=()
      (( musicpipeline_DRY_RUN )) && args+=(--dry-run)
      args+=("$current_release_dir")
      convert_music_main "${args[@]}"
      [[ -d "$current_release_dir" ]] && sort_release_dir "$current_release_dir"
      ;;
  esac
}

musicpipeline_process_artist_targets() {
  local mode="$1"
  local -a artist_roots
  local artist_root

  musicpipeline_PROCESSED_ARTIST_COUNT=0

  artist_roots=("${(@Qk)musicpipeline_ARTIST_TARGETS}")
  artist_roots=("${(@o)artist_roots}")
  for artist_root in "${artist_roots[@]}"; do
    if [[ ! -d "$artist_root" ]]; then
      ml_warn "skipping missing artist root: $artist_root"
      ml_record_event "skip" "$artist_root" "" "artist root does not exist on disk" "process_artist_root"
      continue
    fi

    (( musicpipeline_PROCESSED_ARTIST_COUNT++ ))
    ml_log_scope "artist" "$artist_root"

    case "$mode" in
      sort)
        musicpipeline_run_sort_for_artist "$artist_root"
        ;;
      convert)
        musicpipeline_run_convert_for_artist "$artist_root"
        ;;
      both)
        musicpipeline_run_convert_for_artist "$artist_root"
        [[ -d "$artist_root" ]] && musicpipeline_run_sort_for_artist "$artist_root"
        ;;
    esac
  done
}

musicpipeline_main() {
  local mode="" target="." output_root=""
  local move_mode=0
  local arg script_dir root_type persist

  # Reset wrapper state every time so a reused shell session does not leak old
  # artist targets or warning counts into the next run.
  musicpipeline_DRY_RUN=0
  musicpipeline_KEEP_SIDECARS=0
  musicpipeline_ARTIST_TARGETS=()
  musicpipeline_BLOCKED_CONVERT_ARTISTS=()
  musicpipeline_PROCESSED_ARTIST_COUNT=0
  musicpipeline_AUDIT_WARNING_COUNT=0
  MUSICPIPELINE_UI_MODE=""
  MUSICPIPELINE_UI_TARGET=""
  MUSICPIPELINE_UI_OUTPUT=""
  MUSICPIPELINE_UI_DRY_RUN=0
  MUSICPIPELINE_UI_MOVE=0
  MUSICPIPELINE_UI_KEEP_SIDECARS=0

  if (( $# )) && [[ "$1" == (audit|sort|convert|both|undo|delete-source|delete-empty-dirs|delete-state-dirs|audio-scrape|collect-mp3|dedup|dedup-delete) ]]; then
    mode="$1"
    shift
  elif (( $# )) && [[ "$1" == (-h|--help) ]]; then
    musicpipeline_usage
    return 0
  fi

  if [[ -z "$mode" ]]; then
    musicpipeline_terminal_ui || { musicpipeline_usage; return 1; }
    mode="$MUSICPIPELINE_UI_MODE"
    target="$MUSICPIPELINE_UI_TARGET"
    output_root="$MUSICPIPELINE_UI_OUTPUT"
    musicpipeline_DRY_RUN=$MUSICPIPELINE_UI_DRY_RUN
    move_mode=$MUSICPIPELINE_UI_MOVE
    musicpipeline_KEEP_SIDECARS=$MUSICPIPELINE_UI_KEEP_SIDECARS
  fi

  # Parse top-level wrapper flags. The worker scripts handle their own argument
  # parsing later once we know which artist roots they should touch.
  while (( $# )); do
    arg="$1"
    case "$arg" in
      --dry-run)
        musicpipeline_DRY_RUN=1
        ;;
      --keep-sidecars)
        musicpipeline_KEEP_SIDECARS=1
        ;;
      --output)
        shift
        (( $# )) || { ml_die "--output requires a directory argument"; return 1; }
        output_root="$1"
        ;;
      --move)
        move_mode=1
        ;;
      -h|--help)
        musicpipeline_usage
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
        if [[ "$target" != "." ]]; then
          ml_die "unexpected extra argument: $arg"
          return 1
        fi
        target="$arg"
        ;;
    esac
    shift
  done

  (( $# == 0 )) || { ml_die "unexpected extra arguments: $*"; return 1; }

  script_dir="$(ml_script_dir)"
  [[ -d "$target" ]] || { ml_die "target directory not found: $target"; return 1; }
  target="${target:A}"
  if [[ -n "$output_root" ]]; then
    if [[ -e "$output_root" && ! -d "$output_root" ]]; then
      ml_die "output path exists and is not a directory: $output_root"
      return 1
    fi
    output_root="${output_root:A}"
  fi
  MUSICLIB_DRY_RUN=$musicpipeline_DRY_RUN
  MUSICLIB_KEEP_SIDECARS=$musicpipeline_KEEP_SIDECARS

  case "$mode" in
    undo)
      ml_undo_last_run "$target"
      return $?
      ;;
    delete-empty-dirs)
      cleanup_music_delete_empty_dirs "$target"
      return $?
      ;;
    delete-state-dirs)
      cleanup_music_delete_state_dirs "$target"
      return $?
      ;;
    audio-scrape|collect-mp3)
      [[ -z "$output_root" ]] && move_mode=1
      cleanup_music_collect_audio "$target" "${output_root:-$target}" "$move_mode"
      return $?
      ;;
    dedup)
      cleanup_music_dedup "$target"
      return $?
      ;;
    dedup-delete)
      cleanup_music_delete_duplicates "$target"
      return $?
      ;;
  esac

  musicpipeline_prepare_config "$script_dir" "$target"
  root_type="$(musicpipeline_detect_root_type "$target")"

  case "$mode" in
    delete-source)
      cleanup_music_delete_source "$target" "$root_type"
      return $?
      ;;
    audit)
      # Audit gets its own read-only run context so it still leaves behind a
      # useful log/manifest without touching library files.
      ml_start_run "audit" "$target" 1
      ml_record_event "root_type" "$target" "" "$root_type" ""
      case "$root_type" in
        collection_parent)
          musicpipeline_audit_collection_parent "$target"
          ;;
        archive_lossless|archive_lossy|batch_root)
          musicpipeline_audit_batch_root "$target" "$root_type"
          ;;
        release_root)
          musicpipeline_audit_release_dir "$target" "${target:h}"
          ;;
        artist_root)
          musicpipeline_audit_artist_root "$target"
          ;;
        *)
          musicpipeline_warn_audit "unknown target type: $target"
          ml_record_event "skip" "$target" "" "unknown target type" "audit"
          ;;
      esac
      ml_finish_run "success" "Audit complete. warnings=$musicpipeline_AUDIT_WARNING_COUNT"
      MUSICLIB_RUN_ACTIVE=0
      return 0
      ;;
  esac

  case "$root_type" in
    collection_parent)
      # A collection parent is too broad for mutating commands. Make the user
      # point at the actual archive root or artist root they want to change.
      ml_die "mutating commands require an archive root or artist root, not the collection parent"
      return 1
      ;;
    unknown)
      ml_die "could not classify target root: $target"
      return 1
      ;;
  esac

  persist=$(( ! musicpipeline_DRY_RUN ))
  ml_start_run "$mode" "$target" "$persist"
  ml_record_event "root_type" "$target" "" "$root_type" ""

  # First decide which artist roots need work. Only after routing settles down
  # do we hand those artist roots to sort/convert.
  case "$root_type" in
    archive_lossless|archive_lossy|batch_root)
      musicpipeline_prepare_batch_root "$target" "$root_type"
      ;;
    release_root)
      musicpipeline_process_release_root "$mode" "$target"
      ml_cleanup_empty_dirs "$target:h"
      ml_finish_run "success" "Done. release_root_processed=1"
      if (( musicpipeline_DRY_RUN )); then
        ml_log "Dry run only. No filesystem changes were made."
      fi
      MUSICLIB_RUN_ACTIVE=0
      return 0
      ;;
    artist_root)
      musicpipeline_prepare_artist_root "$target"
      ;;
  esac

  musicpipeline_process_artist_targets "$mode"
  ml_cleanup_empty_recoverable_dirs "$target"
  ml_cleanup_empty_dirs "$target"
  ml_finish_run "success" "Done. artist_roots_processed=$musicpipeline_PROCESSED_ARTIST_COUNT"

  if (( musicpipeline_DRY_RUN )); then
    ml_log "Dry run only. No filesystem changes were made."
  fi

  MUSICLIB_RUN_ACTIVE=0
}

# Expose a short shell-native entrypoint when the file is sourced, but keep the
# underlying main function around so direct script usage still works the same.
musicpipeline() {
  emulate -L zsh
  musicpipeline_main "$@"
}

if [[ "${ZSH_EVAL_CONTEXT:-}" == "toplevel" ]]; then
  musicpipeline "$@"
fi
