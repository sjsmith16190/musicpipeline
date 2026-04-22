# Shared helpers for the Music Prep Scripts suite.

# Keep the common helpers reload-safe in long-lived shells. That way `source
# ~/.zshrc` after an update actually refreshes the function set instead of
# leaving you stuck with an older in-memory copy.
typeset -g MUSICLIB_COMMON_FILE_VERSION="20260422.6"
if [[ "${MUSICLIB_COMMON_LOADED_VERSION:-}" == "$MUSICLIB_COMMON_FILE_VERSION" ]]; then
  return 0 2>/dev/null || exit 0
fi
typeset -g MUSICLIB_COMMON_LOADED=1
typeset -g MUSICLIB_COMMON_LOADED_VERSION="$MUSICLIB_COMMON_FILE_VERSION"

: ${MUSICLIB_DEFAULT_STATE_DIR_NAME:=.musicpipeline}
: ${MUSICLIB_DEFAULT_SOURCE_ARCHIVE_DIR:=_originalSource}
: ${MUSICLIB_LEGACY_SOURCE_ARCHIVE_DIR:=_SOURCE_FLAC}
: ${MUSICLIB_CONFIG_FILENAME:=musicpipeline.config.zsh}
: ${MUSICLIB_DEFAULT_UNKNOWN_DIR_NAME:=_Unknown}
: ${MUSICLIB_DEFAULT_NOT_AUDIO_DIR_NAME:=_NotAudio}
: ${MUSICLIB_DEFAULT_MP3_COLLECT_DIR_NAME:=_mp3}
: ${MUSICLIB_DEFAULT_LOSSY_ARCHIVE_DIR_NAME:=_Lossy}
: ${MUSICLIB_LEGACY_LOSSY_ARCHIVE_DIR_NAME:=_LossyArchive}

: ${STATE_DIR_NAME:=$MUSICLIB_DEFAULT_STATE_DIR_NAME}
: ${SOURCE_ARCHIVE_DIR:=$MUSICLIB_DEFAULT_SOURCE_ARCHIVE_DIR}
: ${UNKNOWN_DIR_NAME:=$MUSICLIB_DEFAULT_UNKNOWN_DIR_NAME}
: ${NOT_AUDIO_DIR_NAME:=$MUSICLIB_DEFAULT_NOT_AUDIO_DIR_NAME}
: ${MP3_COLLECT_DIR_NAME:=$MUSICLIB_DEFAULT_MP3_COLLECT_DIR_NAME}
: ${LOSSY_ARCHIVE_DIR_NAME:=$MUSICLIB_DEFAULT_LOSSY_ARCHIVE_DIR_NAME}
typeset -ga MUSICLIB_AUDIO_COLLECT_DIR_NAMES=(
  "$MP3_COLLECT_DIR_NAME"
  "_alac"
  "_wav"
  "_flac"
  "_aiff"
  "_m4a"
  "_aac"
  "_ogg"
  "_opus"
  "_wma"
  "_ape"
  "_wv"
  "_mka"
  "_dsf"
  "_dff"
)
typeset -ga MUSICLIB_AUDIO_COLLECT_DIR_FIND_ARGS=(
  -name "$MP3_COLLECT_DIR_NAME"
  -o -name "_alac"
  -o -name "_wav"
  -o -name "_flac"
  -o -name "_aiff"
  -o -name "_m4a"
  -o -name "_aac"
  -o -name "_ogg"
  -o -name "_opus"
  -o -name "_wma"
  -o -name "_ape"
  -o -name "_wv"
  -o -name "_mka"
  -o -name "_dsf"
  -o -name "_dff"
)
typeset -ga MUSICLIB_AUDIO_FILE_FIND_ARGS=(
  -iname '*.m4a'
  -o -iname '*.flac'
  -o -iname '*.alac'
  -o -iname '*.mp3'
  -o -iname '*.aiff'
  -o -iname '*.aif'
  -o -iname '*.wav'
  -o -iname '*.wma'
  -o -iname '*.aac'
  -o -iname '*.ogg'
  -o -iname '*.opus'
  -o -iname '*.ape'
  -o -iname '*.wv'
  -o -iname '*.mka'
  -o -iname '*.dsf'
  -o -iname '*.dff'
)
typeset -ga MUSICLIB_CONVERT_SOURCE_FILE_FIND_ARGS=(
  -iname '*.flac'
  -o -iname '*.wav'
  -o -iname '*.aiff'
  -o -iname '*.aif'
  -o -iname '*.wma'
)

# These globals are the little bit of shared state that lets the wrapper,
# sorter, and converter all write to one run log/manifest when needed.
typeset -g MUSICLIB_DRY_RUN=${MUSICLIB_DRY_RUN:-0}
typeset -g MUSICLIB_KEEP_SIDECARS=${MUSICLIB_KEEP_SIDECARS:-0}
typeset -g MUSICLIB_RUN_ACTIVE=${MUSICLIB_RUN_ACTIVE:-0}
typeset -g MUSICLIB_RUN_MODE=""
typeset -g MUSICLIB_TARGET_ROOT=""
typeset -g MUSICLIB_RUN_ID=""
typeset -g MUSICLIB_STATE_DIR=""
typeset -g MUSICLIB_RUNS_DIR=""
typeset -g MUSICLIB_TRASH_DIR=""
typeset -g MUSICLIB_LOG_FILE=""
typeset -g MUSICLIB_MANIFEST_FILE=""
typeset -g MUSICLIB_PERSIST_STATE=0
typeset -gi MUSICLIB_LAST_EMPTY_DIR_CLEANUP_COUNT=0
typeset -gA MUSICLIB_TAG_ENRICH_ATTEMPTED=()
typeset -g LOSSLESS_DIR_NAME="${LOSSLESS_DIR_NAME:-}"
typeset -g LOSSY_DIR_NAME="${LOSSY_DIR_NAME:-}"

# Logging / manifest helpers.
ml_die() {
  print -ru2 -- "error: $*"
  return 1
}

ml_warn() {
  local msg="warning: $*"
  print -ru2 -- "$msg"
  [[ -n "${MUSICLIB_LOG_FILE:-}" && -f "${MUSICLIB_LOG_FILE:-}" ]] && print -r -- "$msg" >> "$MUSICLIB_LOG_FILE"
}

ml_log() {
  local msg="$*"
  print -r -- "$msg"
  [[ -n "${MUSICLIB_LOG_FILE:-}" && -f "${MUSICLIB_LOG_FILE:-}" ]] && print -r -- "$msg" >> "$MUSICLIB_LOG_FILE"
}

ml_display_path() {
  local path="${1:-}"
  local abs root parent home

  [[ -n "$path" ]] || {
    print -r -- ""
    return 0
  }

  abs="${path:A}"
  root="${MUSICLIB_TARGET_ROOT:-}"
  parent="${root:h}"
  home="${HOME:-}"

  if [[ -n "$root" && "$abs" == "${root:A}" ]]; then
    print -r -- "."
    return 0
  fi
  if [[ -n "$root" && "$abs" == "${root:A}/"* ]]; then
    print -r -- "./${abs#${root:A}/}"
    return 0
  fi
  if [[ -n "$parent" && "$abs" == "${parent:A}/"* ]]; then
    print -r -- "../${abs#${parent:A}/}"
    return 0
  fi
  if [[ -n "$home" && "$abs" == "${home:A}/"* ]]; then
    print -r -- "~/${abs#${home:A}/}"
    return 0
  fi

  print -r -- "$path"
}

ml_log_step() {
  local tag="$1"
  shift
  ml_log "[$tag] $*"
}

ml_log_move() {
  local tag="$1"
  local src="$2"
  local dst="$3"
  ml_log_step "$tag" "$(ml_display_path "$src") -> $(ml_display_path "$dst")"
}

ml_log_scope() {
  local kind="$1"
  local path="$2"
  ml_log ""
  ml_log "== ${kind}: $(ml_display_path "$path") =="
}

ml_need_cmd() {
  command -v "$1" >/dev/null 2>&1 || ml_die "missing required command: $1"
}

ml_script_dir() {
  print -r -- "${${(%):-%x}:A:h}"
}

ml_config_file() {
  local script_dir="$1"
  print -r -- "$script_dir/$MUSICLIB_CONFIG_FILENAME"
}

ml_ensure_dir() {
  local dir="$1"
  [[ -d "$dir" ]] && return 0
  if (( MUSICLIB_DRY_RUN )); then
    ml_log_step "mkdir" "$(ml_display_path "$dir")"
  else
    mkdir -p -- "$dir"
  fi
}

ml_sanitize_name() {
  local value="${1:-}"
  value=${value//$'\r'/ }
  value=${value//$'\n'/ }
  value=${value//\//-}
  printf '%s' "$value" | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'
}

ml_start_case_name() {
  local value
  value="$(ml_sanitize_name "${1:-}")"
  [[ -n "$value" ]] || {
    print -r -- ""
    return 0
  }

  printf '%s' "$value" | perl -CS -pe 's/([[:alpha:]])([[:alpha:]]*)/\U$1\L$2/g'
}

ml_tag_value() {
  local key="$1"
  local text="$2"
  printf '%s\n' "$text" | awk -v want="tag:${key}=" '
    index(tolower($0), want) == 1 {
      sub(/^[^=]*=/, "")
      print
      exit
    }
  '
}

ml_json_escape() {
  printf '%s' "${1:-}" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

ml_is_audio_collect_dir_name() {
  local name="$1"
  local dir_name

  for dir_name in "${MUSICLIB_AUDIO_COLLECT_DIR_NAMES[@]}"; do
    [[ "$name" == "$dir_name" ]] && return 0
  done

  return 1
}

ml_is_reserved_dir_name() {
  local name="$1"

  [[ -n "$name" ]] || return 1
  [[ "$name" == "$STATE_DIR_NAME" || "$name" == "$SOURCE_ARCHIVE_DIR" || "$name" == "$UNKNOWN_DIR_NAME" || "$name" == "$NOT_AUDIO_DIR_NAME" || "$name" == "$LOSSY_ARCHIVE_DIR_NAME" || "$name" == "$MUSICLIB_LEGACY_LOSSY_ARCHIVE_DIR_NAME" || "$name" == .* ]] && return 0
  ml_is_audio_collect_dir_name "$name"
}

ml_is_cleanup_protected_dir_name() {
  local name="$1"

  [[ -n "$name" ]] || return 1
  [[ "$name" == "$STATE_DIR_NAME" || "$name" == "$SOURCE_ARCHIVE_DIR" || "$name" == "$NOT_AUDIO_DIR_NAME" || "$name" == "$LOSSY_ARCHIVE_DIR_NAME" || "$name" == "$MUSICLIB_LEGACY_LOSSY_ARCHIVE_DIR_NAME" || "$name" == .* ]]
}

ml_path_has_hidden_or_state_segment() {
  local path="$1"
  local base="${2:-}"
  local rel="$path"
  local -a segments
  local segment

  if [[ -n "$base" && "$path" == "$base/"* ]]; then
    rel="${path#$base/}"
  fi

  segments=("${(@s:/:)rel}")
  for segment in "${segments[@]}"; do
    [[ -n "$segment" ]] || continue
    if ml_is_reserved_dir_name "$segment"; then
      return 0
    fi
  done

  return 1
}

ml_path_has_internal_skip_segment() {
  local path="$1"
  local base="${2:-}"
  local rel="$path"
  local -a segments
  local segment

  if [[ -n "$base" && "$path" == "$base/"* ]]; then
    rel="${path#$base/}"
  fi

  segments=("${(@s:/:)rel}")
  for segment in "${segments[@]}"; do
    [[ -n "$segment" ]] || continue
    if [[ "$segment" == "$STATE_DIR_NAME" || "$segment" == "$SOURCE_ARCHIVE_DIR" || "$segment" == "$NOT_AUDIO_DIR_NAME" || "$segment" == "$LOSSY_ARCHIVE_DIR_NAME" || "$segment" == "$MUSICLIB_LEGACY_LOSSY_ARCHIVE_DIR_NAME" || "$segment" == .* ]]; then
      return 0
    fi
  done

  return 1
}

ml_path_has_cleanup_protected_segment() {
  local path="$1"
  local base="${2:-}"
  local rel="$path"
  local -a segments
  local segment

  if [[ -n "$base" && "$path" == "$base/"* ]]; then
    rel="${path#$base/}"
  fi

  segments=("${(@s:/:)rel}")
  for segment in "${segments[@]}"; do
    [[ -n "$segment" ]] || continue
    if ml_is_cleanup_protected_dir_name "$segment"; then
      return 0
    fi
  done

  return 1
}

ml_b64_encode() {
  if [[ -z "${1-}" ]]; then
    print -r -- ""
  else
    printf '%s' "$1" | base64 | tr -d '\n'
  fi
}

ml_b64_decode() {
  if [[ -z "${1-}" ]]; then
    print -r -- ""
  else
    printf '%s' "$1" | base64 -d 2>/dev/null
  fi
}

# Store manifest fields as base64 so paths with spaces, quotes, and other mess
# stay easy to round-trip in plain shell tooling.
ml_record_event() {
  local op="$1"
  local src="${2-}"
  local dst="${3-}"
  local reason="${4-}"
  local extra="${5-}"
  local line

  (( MUSICLIB_PERSIST_STATE )) || return 0

  line=$(printf '{"ts":"%s","op":"%s","src_b64":"%s","dst_b64":"%s","reason_b64":"%s","extra_b64":"%s"}\n' \
    "$(ml_json_escape "$(date '+%Y-%m-%dT%H:%M:%S')")" \
    "$(ml_json_escape "$op")" \
    "$(ml_json_escape "$(ml_b64_encode "$src")")" \
    "$(ml_json_escape "$(ml_b64_encode "$dst")")" \
    "$(ml_json_escape "$(ml_b64_encode "$reason")")" \
    "$(ml_json_escape "$(ml_b64_encode "$extra")")")
  print -r -- "$line" >> "$MUSICLIB_MANIFEST_FILE"
}

ml_reverse_file_lines() {
  awk '{ lines[NR] = $0 } END { for (i = NR; i >= 1; i--) print lines[i] }' "$1"
}

ml_manifest_field() {
  local key="$1"
  local line="$2"
  printf '%s\n' "$line" | sed -n "s/.*\"${key}\":\"\\([^\"]*\\)\".*/\\1/p" | head -n 1
}

ml_current_timestamp() {
  date '+%Y%m%dT%H%M%S'
}

# Start a shared run context. The worker scripts piggyback on this when the
# wrapper is driving the whole workflow so everything lands in one manifest.
ml_start_run() {
  local mode="$1"
  local root="$2"
  local persist="${3:-1}"

  MUSICLIB_RUN_ACTIVE=1
  MUSICLIB_RUN_MODE="$mode"
  MUSICLIB_TARGET_ROOT="${root:A}"
  MUSICLIB_RUN_ID="$(ml_current_timestamp).$$"
  MUSICLIB_PERSIST_STATE="$persist"
  MUSICLIB_STATE_DIR="$MUSICLIB_TARGET_ROOT/$STATE_DIR_NAME"
  MUSICLIB_RUNS_DIR="$MUSICLIB_STATE_DIR/runs"
  MUSICLIB_TRASH_DIR="$MUSICLIB_STATE_DIR/trash/$MUSICLIB_RUN_ID"
  MUSICLIB_LOG_FILE=""
  MUSICLIB_MANIFEST_FILE=""

  if (( MUSICLIB_PERSIST_STATE )); then
    mkdir -p -- "$MUSICLIB_RUNS_DIR" "$MUSICLIB_TRASH_DIR"
    MUSICLIB_LOG_FILE="$MUSICLIB_RUNS_DIR/$MUSICLIB_RUN_ID.log"
    MUSICLIB_MANIFEST_FILE="$MUSICLIB_RUNS_DIR/$MUSICLIB_RUN_ID.jsonl"
    : > "$MUSICLIB_LOG_FILE"
    : > "$MUSICLIB_MANIFEST_FILE"
    ml_record_event "meta" "$MUSICLIB_TARGET_ROOT" "" "$mode" ""
  fi

  ml_log ""
  ml_log "== Run $MUSICLIB_RUN_ID =="
  ml_log "mode:   $mode"
  ml_log "target: $(ml_display_path "$MUSICLIB_TARGET_ROOT")"
}

# Finish the run and remember the manifest path for later undo.
ml_finish_run() {
  local run_status="${1:-success}"
  local summary="${2:-}"

  ml_record_event "summary" "" "" "$run_status" "$summary"

  if (( MUSICLIB_PERSIST_STATE )) && [[ "$run_status" == "success" ]] && [[ "$MUSICLIB_RUN_MODE" != "audit" ]] && [[ "$MUSICLIB_RUN_MODE" != "undo" ]]; then
    print -r -- "$MUSICLIB_RUNS_DIR/$MUSICLIB_RUN_ID.jsonl" > "$MUSICLIB_STATE_DIR/last_successful_run"
  fi

  [[ -n "$summary" ]] && ml_log "$summary"
}

# Config helpers.
ml_load_config_if_present() {
  local script_dir="$1"
  local config_file

  config_file="$(ml_config_file "$script_dir")"
  [[ -f "$config_file" ]] || return 1
  source "$config_file"
  : ${STATE_DIR_NAME:=$MUSICLIB_DEFAULT_STATE_DIR_NAME}
  : ${SOURCE_ARCHIVE_DIR:=$MUSICLIB_DEFAULT_SOURCE_ARCHIVE_DIR}
  : ${UNKNOWN_DIR_NAME:=$MUSICLIB_DEFAULT_UNKNOWN_DIR_NAME}
  : ${NOT_AUDIO_DIR_NAME:=$MUSICLIB_DEFAULT_NOT_AUDIO_DIR_NAME}
  : ${MP3_COLLECT_DIR_NAME:=$MUSICLIB_DEFAULT_MP3_COLLECT_DIR_NAME}
  : ${LOSSY_ARCHIVE_DIR_NAME:=$MUSICLIB_DEFAULT_LOSSY_ARCHIVE_DIR_NAME}
  if [[ "$SOURCE_ARCHIVE_DIR" == "$MUSICLIB_LEGACY_SOURCE_ARCHIVE_DIR" ]]; then
    SOURCE_ARCHIVE_DIR="$MUSICLIB_DEFAULT_SOURCE_ARCHIVE_DIR"
  fi
  return 0
}

ml_write_config() {
  local script_dir="$1"
  local lossless_name="$2"
  local lossy_name="$3"
  local config_file

  config_file="$(ml_config_file "$script_dir")"
  cat > "$config_file" <<EOF
# Auto-generated by musicpipeline on first setup.
LOSSLESS_DIR_NAME=$(printf '%q' "$lossless_name")
LOSSY_DIR_NAME=$(printf '%q' "$lossy_name")
STATE_DIR_NAME=$(printf '%q' "$MUSICLIB_DEFAULT_STATE_DIR_NAME")
SOURCE_ARCHIVE_DIR=$(printf '%q' "$MUSICLIB_DEFAULT_SOURCE_ARCHIVE_DIR")
EOF
  source "$config_file"
}

# Only ask first-run config questions when we really need archive-name-aware
# routing. Plain artist-root use should not force setup.
ml_bootstrap_config_if_needed() {
  local script_dir="$1"
  local target_root="$2"
  local config_file lossless_name lossy_name

  config_file="$(ml_config_file "$script_dir")"
  [[ -f "$config_file" ]] && return 0

  if ml_target_looks_like_artist_root "$target_root" || ml_target_has_batch_content "$target_root"; then
    return 0
  fi

  print "First run setup:"
  read "lossless_name?Enter the directory name for your lossless archive root: "
  read "lossy_name?Enter the directory name for your lossy archive root: "
  [[ -n "$lossless_name" && -n "$lossy_name" ]] || ml_die "both lossless and lossy directory names are required"
  ml_write_config "$script_dir" "$lossless_name" "$lossy_name"
}

# Root-shape helpers. These are intentionally heuristic: they only need to be
# good enough to decide which workflow branch to take next.
ml_normalize_match_name() {
  local value="${1:-}"
  value="$(ml_sanitize_name "$value")"
  value="${value:l}"
  printf '%s' "$value" | sed -E 's/[^[:alnum:]]+/ /g; s/^ //; s/ $//'
}

ml_root_single_primary_artist() {
  local root="$1"
  local -a direct_dirs loose_audio
  local dir kind track artist first_artist="" first_artist_key="" first_audio=""

  direct_dirs=("${(@f)$(ml_find_non_reserved_child_dirs "$root")}")
  for dir in "${direct_dirs[@]}"; do
    [[ -n "$dir" ]] || continue
    kind="$(ml_dir_kind "$dir")"
    case "$kind" in
      artist)
        first_audio="$(ml_first_audio_file "$dir")"
        [[ -n "$first_audio" ]] || continue
        artist="$(ml_primary_artist_from_file "$first_audio")"
        ;;
      release)
        artist="$(ml_release_primary_artist "$dir")"
        ;;
      *)
        continue
        ;;
    esac

    [[ -n "$artist" ]] || continue
    if [[ -z "$first_artist" ]]; then
      first_artist="$artist"
      first_artist_key="$(ml_normalize_match_name "$artist")"
      continue
    fi

    [[ "$(ml_normalize_match_name "$artist")" == "$first_artist_key" ]] || return 1
  done

  loose_audio=("${(@f)$(ml_find_loose_audio_files "$root" | LC_ALL=C sort)}")
  for track in "${loose_audio[@]}"; do
    [[ -n "$track" ]] || continue
    artist="$(ml_primary_artist_from_file "$track")"
    [[ -n "$artist" ]] || continue

    if [[ -z "$first_artist" ]]; then
      first_artist="$artist"
      first_artist_key="$(ml_normalize_match_name "$artist")"
      continue
    fi

    [[ "$(ml_normalize_match_name "$artist")" == "$first_artist_key" ]] || return 1
  done

  [[ -n "$first_artist" ]] || return 1
  print -r -- "$first_artist"
}

ml_root_name_matches_artist() {
  local root="$1"
  local artist="$2"
  local root_key artist_key

  root_key="$(ml_normalize_match_name "${root:t}")"
  artist_key="$(ml_normalize_match_name "$artist")"

  [[ -n "$root_key" && -n "$artist_key" ]] || return 1
  [[ "$root_key" == "$artist_key" ]] && return 0
  [[ "$root_key" == "$artist_key "* ]] && return 0
  [[ "$root_key" == *" $artist_key" ]] && return 0
  [[ "$root_key" == *" $artist_key "* ]]
}

ml_target_looks_like_artist_root() {
  local root="$1"
  local artist

  artist="$(ml_root_single_primary_artist "$root")" || return 1
  ml_root_name_matches_artist "$root" "$artist"
}

ml_target_has_batch_content() {
  local root="$1"
  local -a direct_dirs loose_audio
  local dir kind

  loose_audio=("${(@f)$(ml_find_loose_audio_files "$root" | LC_ALL=C sort)}")
  (( ${#loose_audio[@]} > 0 )) && return 0

  if find "$root" -mindepth 1 -maxdepth 1 -type d \
    \( -name "$UNKNOWN_DIR_NAME" -o "${MUSICLIB_AUDIO_COLLECT_DIR_FIND_ARGS[@]}" \) \
    -print -quit | grep -q .
  then
    return 0
  fi

  direct_dirs=("${(@f)$(ml_find_non_reserved_child_dirs "$root")}")
  for dir in "${direct_dirs[@]}"; do
    kind="$(ml_dir_kind "$dir")"
    if [[ "$kind" == "release" || "$kind" == "artist" ]]; then
      return 0
    fi
  done

  return 1
}

ml_classify_root() {
  local root="$1"
  local base="${root:t}"
  local root_kind

  if [[ -n "$LOSSLESS_DIR_NAME" && -n "$LOSSY_DIR_NAME" ]] && [[ -d "$root/$LOSSLESS_DIR_NAME" && -d "$root/$LOSSY_DIR_NAME" ]]; then
    print -r -- "collection_parent"
    return 0
  fi

  if [[ -n "$LOSSLESS_DIR_NAME" && "$base" == "$LOSSLESS_DIR_NAME" ]]; then
    print -r -- "archive_lossless"
    return 0
  fi

  if [[ -n "$LOSSY_DIR_NAME" && "$base" == "$LOSSY_DIR_NAME" ]]; then
    print -r -- "archive_lossy"
    return 0
  fi

  root_kind="$(ml_dir_kind "$root")"
  if [[ "$root_kind" == "release" && -n "$(ml_release_cue_file "$root")" ]]; then
    print -r -- "release_root"
    return 0
  fi

  if ml_target_looks_like_artist_root "$root"; then
    print -r -- "artist_root"
    return 0
  fi

  if [[ "$root_kind" == "release" ]]; then
    print -r -- "release_root"
    return 0
  fi

  if ml_target_has_batch_content "$root"; then
    print -r -- "batch_root"
  else
    print -r -- "unknown"
  fi
}

ml_enclosing_archive_type() {
  local root="${1:A}"
  local dir="$root"

  while [[ "$dir" != "/" ]]; do
    if [[ -n "$LOSSLESS_DIR_NAME" && "${dir:t}" == "$LOSSLESS_DIR_NAME" ]]; then
      print -r -- "archive_lossless"
      return 0
    fi
    if [[ -n "$LOSSY_DIR_NAME" && "${dir:t}" == "$LOSSY_DIR_NAME" ]]; then
      print -r -- "archive_lossy"
      return 0
    fi
    dir="${dir:h}"
  done

  print -r -- "none"
}

ml_sibling_lossless_root() {
  local root="$1"
  print -r -- "${root:h}/$LOSSLESS_DIR_NAME"
}

# File discovery / metadata helpers.
ml_find_audio_files() {
  local root="$1"
  find "$root" \
    \( -type d \( -name "$SOURCE_ARCHIVE_DIR" -o -name "$STATE_DIR_NAME" -o -name "$UNKNOWN_DIR_NAME" -o -name "$NOT_AUDIO_DIR_NAME" -o "${MUSICLIB_AUDIO_COLLECT_DIR_FIND_ARGS[@]}" -o -name "$LOSSY_ARCHIVE_DIR_NAME" -o -name "$MUSICLIB_LEGACY_LOSSY_ARCHIVE_DIR_NAME" -o -name '.*' \) -prune \) -o \
    -type f \( "${MUSICLIB_AUDIO_FILE_FIND_ARGS[@]}" \) -print
}

ml_find_loose_audio_files() {
  local root="$1"
  find "$root" -mindepth 1 -maxdepth 1 -type f \
    \( "${MUSICLIB_AUDIO_FILE_FIND_ARGS[@]}" \) -print
}

ml_dir_has_non_special_content() {
  local dir="$1"
  find "$dir" -mindepth 1 -maxdepth 1 \
    ! -name '.*' \
    ! -name "$SOURCE_ARCHIVE_DIR" \
    ! -name "$STATE_DIR_NAME" \
    ! -name "$UNKNOWN_DIR_NAME" \
    ! -name "$NOT_AUDIO_DIR_NAME" \
    ! -name "$LOSSY_ARCHIVE_DIR_NAME" \
    ! -name "$MUSICLIB_LEGACY_LOSSY_ARCHIVE_DIR_NAME" \
    -print | while IFS= read -r path; do
      ml_is_audio_collect_dir_name "${path:t}" && continue
      print -r -- "$path"
      break
    done | grep -q .
}

ml_find_non_reserved_child_dirs() {
  local root="$1"
  local dir

  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    ml_is_reserved_dir_name "${dir:t}" && continue
    print -r -- "$dir"
  done < <(find "$root" -mindepth 1 -maxdepth 1 -type d ! -name '.*' | LC_ALL=C sort)
}

ml_is_known_media_file() {
  local ext="${1:e:l}"
  [[ -n "$ext" ]] || return 1

  [[ "$ext" == flac || "$ext" == wav || "$ext" == aiff || "$ext" == aif || "$ext" == alac || "$ext" == m4a || "$ext" == aac || "$ext" == mp3 || "$ext" == ogg || "$ext" == opus || "$ext" == wma || "$ext" == ape || "$ext" == wv || "$ext" == mka || "$ext" == dsf || "$ext" == dff || "$ext" == mp4 || "$ext" == m4v || "$ext" == mov || "$ext" == mkv || "$ext" == avi || "$ext" == jpg || "$ext" == jpeg || "$ext" == png || "$ext" == gif || "$ext" == webp || "$ext" == tif || "$ext" == tiff || "$ext" == bmp ]]
}

ml_is_collectable_audio_file() {
  local ext="${1:e:l}"
  [[ "$ext" == flac || "$ext" == wav || "$ext" == aiff || "$ext" == aif || "$ext" == alac || "$ext" == m4a || "$ext" == aac || "$ext" == mp3 || "$ext" == ogg || "$ext" == opus || "$ext" == wma || "$ext" == ape || "$ext" == wv || "$ext" == mka || "$ext" == dsf || "$ext" == dff ]]
}

ml_relative_path_from_root() {
  local path="$1"
  local root="$2"

  path="${path:A}"
  root="${root:A}"
  if [[ "$path" == "$root" ]]; then
    print -r -- ""
  elif [[ "$path" == "$root/"* ]]; then
    print -r -- "${path#$root/}"
  else
    print -r -- "${path:t}"
  fi
}

ml_first_nested_non_reserved_ancestor_name() {
  local path="$1"
  local root="$2"
  local rel segment
  local -a segments

  rel="$(ml_relative_path_from_root "$path" "$root")"
  [[ -n "$rel" ]] || return 1
  segments=("${(@s:/:)rel}")
  (( ${#segments[@]} >= 2 )) || return 1

  for segment in "${segments[@]:0:$(( ${#segments[@]} - 1 ))}"; do
    [[ -n "$segment" ]] || continue
    ml_is_reserved_dir_name "$segment" && continue
    print -r -- "$(ml_sanitize_name "$segment")"
    return 0
  done

  return 1
}

ml_audio_collection_bucket_name() {
  local file="$1"
  local ext codec

  ext="${file:e:l}"
  codec="$(ml_audio_codec "$file")"
  codec="${codec:l}"

  case "$codec" in
    alac) print -r -- "alac"; return 0 ;;
    aac) print -r -- "aac"; return 0 ;;
    mp3) print -r -- "mp3"; return 0 ;;
    flac) print -r -- "flac"; return 0 ;;
    opus) print -r -- "opus"; return 0 ;;
    vorbis) print -r -- "ogg"; return 0 ;;
    wmav1|wmav2|wmapro|wmalossless|wmavoice) print -r -- "wma"; return 0 ;;
    wavpack) print -r -- "wv"; return 0 ;;
    ape) print -r -- "ape"; return 0 ;;
    pcm_*|wav) print -r -- "wav"; return 0 ;;
  esac

  case "$ext" in
    mp3) print -r -- "mp3" ;;
    alac) print -r -- "alac" ;;
    flac) print -r -- "flac" ;;
    wav) print -r -- "wav" ;;
    aiff|aif) print -r -- "aiff" ;;
    m4a) print -r -- "m4a" ;;
    aac) print -r -- "aac" ;;
    ogg) print -r -- "ogg" ;;
    opus) print -r -- "opus" ;;
    wma) print -r -- "wma" ;;
    ape) print -r -- "ape" ;;
    wv) print -r -- "wv" ;;
    mka) print -r -- "mka" ;;
    dsf) print -r -- "dsf" ;;
    dff) print -r -- "dff" ;;
    *) return 1 ;;
  esac
}

ml_is_lossless_extension() {
  local ext="${1:e:l}"
  [[ "$ext" == flac || "$ext" == wav || "$ext" == aiff || "$ext" == aif || "$ext" == alac ]]
}

ml_audio_codec() {
  local file="$1"
  ffprobe -v error -select_streams a:0 -show_entries stream=codec_name \
    -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null | head -n 1
}

ml_audio_is_lossless_codec() {
  local codec="${1:l}"
  [[ -n "$codec" ]] || return 1
  [[ "$codec" == alac || "$codec" == flac || "$codec" == ape || "$codec" == wavpack || "$codec" == tak || "$codec" == truehd || "$codec" == mlp || "$codec" == wmalossless || "$codec" == pcm_* ]]
}

ml_is_lossless_source_file() {
  local file="$1"
  local codec

  codec="$(ml_audio_codec "$file")"
  if [[ -n "$codec" ]]; then
    ml_audio_is_lossless_codec "$codec"
    return $?
  fi

  ml_is_lossless_extension "$file"
}

ml_conversion_profile_for_source() {
  local file="$1"
  local codec ext output_label

  codec="$(ml_audio_codec "$file")"
  codec="${codec:l}"
  ext="${file:e:l}"

  if [[ "$codec" == "wmalossless" ]]; then
    output_label="$(ml_probe_format "$file")"
    reply=("m4a" "alac" "alac" "$output_label")
    return 0
  fi

  if [[ "$ext" == "wma" || "$codec" == "wmav1" || "$codec" == "wmav2" || "$codec" == "wmapro" || "$codec" == "wmavoice" ]]; then
    reply=("mp3" "libmp3lame" "mp3" "mp3")
    return 0
  fi

  case "$ext" in
    flac|wav|aiff|aif)
      output_label="$(ml_probe_format "$file")"
      reply=("m4a" "alac" "alac" "$output_label")
      return 0
      ;;
  esac

  return 1
}

ml_convert_output_extension_for_source() {
  ml_conversion_profile_for_source "$1" || return 1
  print -r -- "$reply[1]"
}

ml_is_lossy_audio_file() {
  local file="$1"
  local codec ext

  codec="$(ml_audio_codec "$file")"
  if [[ -n "$codec" ]]; then
    ml_audio_is_lossless_codec "$codec" && return 1
    return 0
  fi

  ext="${file:e:l}"
  [[ "$ext" == mp3 || "$ext" == m4a || "$ext" == aac || "$ext" == ogg || "$ext" == opus || "$ext" == wma ]]
}

ml_release_has_lossy_audio() {
  local dir="$1"
  local -a files
  local file

  files=("${(@f)$(ml_find_audio_files "$dir" | LC_ALL=C sort)}")
  for file in "${files[@]}"; do
    [[ -e "$file" ]] || continue
    if ml_is_lossy_audio_file "$file"; then
      return 0
    fi
  done

  return 1
}

ml_release_has_lossless_audio() {
  local dir="$1"
  local -a files
  local file codec

  files=("${(@f)$(ml_find_audio_files "$dir" | LC_ALL=C sort)}")
  for file in "${files[@]}"; do
    [[ -e "$file" ]] || continue
    codec="$(ml_audio_codec "$file")"
    if [[ -n "$codec" ]]; then
      ml_audio_is_lossless_codec "$codec" && return 0
    elif ml_is_lossless_extension "$file"; then
      return 0
    fi
  done

  return 1
}

ml_is_sidecar_file() {
  local ext="${1:e:l}"
  [[ "$ext" == cue || "$ext" == log || "$ext" == txt ]]
}

ml_first_audio_file() {
  local root="$1"
  ml_find_audio_files "$root" | LC_ALL=C sort | head -n 1
}

ml_probe_format() {
  local file="$1"
  local out rate bits sample_fmt khz codec ext

  ext="${file:e:l}"
  codec="$(ml_audio_codec "$file")"
  if [[ "$codec" == "mp3" || "$ext" == "mp3" ]]; then
    print -r -- "mp3"
    return 0
  fi

  out=$(ffprobe -v error -select_streams a:0 \
    -show_entries stream=sample_rate,bits_per_raw_sample,bits_per_sample,sample_fmt \
    -of default=noprint_wrappers=1:nokey=0 "$file" 2>/dev/null || true)

  rate=$(printf '%s\n' "$out" | sed -n 's/^sample_rate=//p' | head -n 1)
  bits=$(printf '%s\n' "$out" | sed -n -E 's/^(bits_per_raw_sample|bits_per_sample)=//p' | awk '$1 > max { max = $1 } END { if (max > 0) print max }')

  if [[ -z "$bits" ]]; then
    # ffprobe is inconsistent here, so fall back to parsing the sample format
    # when the cleaner bit-depth fields are empty.
    sample_fmt=$(printf '%s\n' "$out" | sed -n 's/^sample_fmt=//p' | head -n 1)
    if [[ "$sample_fmt" =~ '([0-9]+)' ]]; then
      bits="$match[1]"
    fi
  fi

  [[ -z "$bits" || "$bits" == "N/A" ]] && bits="unknown"
  if [[ -n "$rate" && "$rate" == <-> ]]; then
    khz=$(( (rate + 500) / 1000 ))
  else
    khz="unknown"
  fi
  [[ -z "$khz" || "$khz" == "N/A" ]] && khz="unknown"
  bits="${bits//\//-}"
  khz="${khz//\//-}"

  print -r -- "${bits}-${khz}"
}

ml_infer_year() {
  local name="$1"
  local date_value="${2:-}"
  if [[ "$name" =~ '^([0-9]{4})' ]]; then
    print -r -- "$match[1]"
  elif [[ "$name" =~ '\[([0-9]{4})\]' ]]; then
    print -r -- "$match[1]"
  elif [[ -n "$date_value" && "$date_value" =~ '([0-9]{4})' ]]; then
    print -r -- "$match[1]"
  else
    print -r -- "0000"
  fi
}

ml_strip_format_suffix() {
  local value
  value="$(ml_sanitize_name "${1:-}")"
  printf '%s' "$value" | sed -E 's/[[:space:]]+\[[^][]+\]$//'
}

ml_strip_leading_year_prefix() {
  local value
  value="$(ml_sanitize_name "${1:-}")"
  printf '%s' "$value" | sed -E 's/^\[([0-9]{4})\][[:space:]]*[-_.]?[[:space:]]*//; s/^([0-9]{4})[[:space:]]*[-_.][[:space:]]*//'
}

ml_regex_escape() {
  printf '%s' "${1:-}" | sed -E 's/[][(){}.^$*+?|\\]/\\&/g'
}

ml_strip_matching_artist_prefix() {
  local value artist escaped_artist
  value="$(ml_sanitize_name "${1:-}")"
  artist="$(ml_sanitize_name "${2:-}")"
  [[ -n "$artist" ]] || {
    print -r -- "$value"
    return 0
  }

  escaped_artist="$(ml_regex_escape "$artist")"
  printf '%s' "$value" | sed -E "s/^${escaped_artist}([[:space:]]*-[[:space:]]*|[[:space:]]+)//"
}

ml_cleanup_display_title() {
  local title artist year cleaned

  title="$(ml_sanitize_name "${1:-}")"
  artist="$(ml_sanitize_name "${2:-}")"
  year="${3:-0000}"
  cleaned="$title"

  if [[ -n "$cleaned" && "$year" != "0000" ]]; then
    cleaned="$(printf '%s' "$cleaned" | sed -E "s/^\\[?$year\\]?[[:space:]]*[-_.]?[[:space:]]*//")"
  fi
  cleaned="$(ml_strip_matching_artist_prefix "$cleaned" "$artist")"
  if [[ -n "$cleaned" && "$year" != "0000" ]]; then
    cleaned="$(printf '%s' "$cleaned" | sed -E "s/^\\[?$year\\]?[[:space:]]*[-_.]?[[:space:]]*//")"
  fi

  cleaned="$(ml_start_case_name "$cleaned")"
  print -r -- "${cleaned:-$(ml_start_case_name "$title")}"
}

ml_file_tags() {
  local file="$1"
  local raw_tags inferred_tags

  raw_tags="$(ffprobe -v error -show_entries format_tags=artist,album_artist,album,title,track,disc,date \
    -of default=noprint_wrappers=1:nokey=0 "$file" 2>/dev/null || true)"

  if (( ! MUSICLIB_DRY_RUN )) && [[ "${MUSICLIB_RUN_MODE:-}" == (sort|convert|both) ]] && [[ -z "${MUSICLIB_TAG_ENRICH_ATTEMPTED["$file"]:-}" ]]; then
    ml_enrich_file_tags_if_needed "$file" "$raw_tags"
    MUSICLIB_TAG_ENRICH_ATTEMPTED["$file"]=1
    raw_tags="$(ffprobe -v error -show_entries format_tags=artist,album_artist,album,title,track,disc,date \
      -of default=noprint_wrappers=1:nokey=0 "$file" 2>/dev/null || true)"
  fi

  inferred_tags="$(ml_inferred_tags_text "$file" "$raw_tags")"
  print -r -- "$raw_tags"
  [[ -n "$raw_tags" && -n "$inferred_tags" ]] && print
  [[ -n "$inferred_tags" ]] && print -r -- "$inferred_tags"
}

ml_release_cue_file() {
  local dir="$1"
  find "$dir" -mindepth 1 -maxdepth 1 -type f -iname '*.cue' | LC_ALL=C sort | head -n 1
}

ml_infer_track_disc_from_path() {
  local file="$1"
  local basename parent_dir track_num="" disc_num=""

  basename="$(ml_strip_format_suffix "${file:t:r}")"
  if [[ "$basename" =~ '^([0-9]{2})-([0-9]{2})' ]]; then
    disc_num="$match[1]"
    track_num="$match[2]"
  elif [[ "$basename" =~ '^([0-9]{1,2})[ ._-]' ]]; then
    track_num="$match[1]"
  fi

  parent_dir="${file:h:t}"
  if [[ -z "$disc_num" ]] && [[ "${parent_dir:l}" == cd* || "${parent_dir:l}" == disc* ]] && [[ "$parent_dir" =~ '([0-9]+)' ]]; then
    disc_num="$match[1]"
  fi

  reply=("$track_num" "$disc_num")
}

ml_infer_album_from_path() {
  local file="$1"
  local dir name

  dir="${file:h}"
  name="${dir:t}"
  if [[ "${name:l}" == cd* || "${name:l}" == disc* ]]; then
    dir="${dir:h}"
    name="${dir:t}"
  fi
  ml_is_reserved_dir_name "$name" && return 1
  name="$(ml_strip_leading_year_prefix "$(ml_strip_format_suffix "$name")")"
  name="$(ml_start_case_name "$name")"
  [[ -n "$name" ]] || return 1
  print -r -- "$name"
}

ml_infer_artist_from_path() {
  local file="$1"
  local dir name basename parsed_artist

  dir="${file:h}"
  name="${dir:t}"

  if [[ "${name:l}" == cd* || "${name:l}" == disc* ]]; then
    dir="${dir:h}"
    name="${dir:t}"
  fi

  if ! ml_is_reserved_dir_name "$name"; then
    if [[ -n "$(ml_infer_album_from_path "$file" 2>/dev/null || true)" ]]; then
      dir="${dir:h}"
      name="${dir:t}"
      if [[ -n "$name" ]] && ! ml_is_reserved_dir_name "$name"; then
        print -r -- "$(ml_path_artist_label "$name")"
        return 0
      fi
    else
      print -r -- "$(ml_path_artist_label "$name")"
      return 0
    fi
  fi

  basename="$(ml_strip_format_suffix "${file:t:r}")"
  if [[ "$basename" =~ '^(.+)[[:space:]]-[[:space:]](.+)$' ]]; then
    parsed_artist="$(ml_path_artist_label "$match[1]")"
    [[ -n "$parsed_artist" ]] && print -r -- "$parsed_artist" && return 0
  fi

  return 1
}

ml_infer_title_from_filename() {
  local file="$1"
  local basename fallback inferred_artist year

  basename="$(ml_strip_format_suffix "${file:t:r}")"
  fallback="$(printf '%s\n' "$basename" | sed -E 's/^[0-9]{2}-[0-9]{2}[[:space:]]*-[[:space:]]*//; s/^[0-9]{1,2}([ ._-][[:space:]]*|[[:space:]]*-[[:space:]]*)//')"
  inferred_artist="$(ml_infer_artist_from_path "$file" 2>/dev/null || true)"
  year="$(ml_infer_year "$basename" "")"
  ml_cleanup_display_title "$fallback" "$inferred_artist" "$year"
}

ml_inferred_tags_text() {
  local file="$1"
  local raw_tags="$2"
  local artist album_artist album title track disc date_value
  local inferred_artist="" inferred_album="" inferred_title="" inferred_track="" inferred_disc="" inferred_date=""

  artist="$(ml_tag_value artist "$raw_tags")"
  album_artist="$(ml_tag_value album_artist "$raw_tags")"
  album="$(ml_tag_value album "$raw_tags")"
  title="$(ml_tag_value title "$raw_tags")"
  track="$(ml_tag_value track "$raw_tags")"
  disc="$(ml_tag_value disc "$raw_tags")"
  date_value="$(ml_tag_value date "$raw_tags")"

  if [[ -z "$artist" || -z "$album_artist" ]]; then
    inferred_artist="$(ml_infer_artist_from_path "$file" 2>/dev/null || true)"
  fi
  [[ -z "$album" ]] && inferred_album="$(ml_infer_album_from_path "$file" 2>/dev/null || true)"
  [[ -z "$title" ]] && inferred_title="$(ml_infer_title_from_filename "$file" 2>/dev/null || true)"
  if [[ -z "$track" || -z "$disc" ]]; then
    ml_infer_track_disc_from_path "$file"
    inferred_track="$reply[1]"
    inferred_disc="$reply[2]"
  fi
  if [[ -z "$date_value" ]]; then
    inferred_date="$(ml_infer_year "${file:h:t}" "")"
    [[ "$inferred_date" == "0000" ]] && inferred_date="$(ml_infer_year "${file:t}" "")"
    [[ "$inferred_date" == "0000" ]] && inferred_date=""
  fi

  if [[ -z "$artist" && -n "$inferred_artist" ]]; then
    print -r -- "tag:artist=$inferred_artist"
  fi
  if [[ -z "$album_artist" && -n "$inferred_artist" && -n "${inferred_album:-$album}" ]]; then
    print -r -- "tag:album_artist=$inferred_artist"
  fi
  if [[ -z "$album" && -n "$inferred_album" ]]; then
    print -r -- "tag:album=$inferred_album"
  fi
  if [[ -z "$title" && -n "$inferred_title" ]]; then
    print -r -- "tag:title=$inferred_title"
  fi
  if [[ -z "$track" && -n "$inferred_track" ]]; then
    print -r -- "tag:track=$((10#$inferred_track))"
  fi
  if [[ -z "$disc" ]]; then
    if [[ -n "$inferred_disc" ]]; then
      print -r -- "tag:disc=$((10#$inferred_disc))"
    elif [[ -n "${track:-$inferred_track}" ]]; then
      print -r -- "tag:disc=1"
    fi
  fi
  if [[ -z "$date_value" && -n "$inferred_date" ]]; then
    print -r -- "tag:date=$inferred_date"
  fi
}

ml_apply_tag_snapshot() {
  local file="$1"
  local tags_text="$2"
  local artist album_artist album title track disc date_value
  local -a cmd

  artist="$(ml_tag_value artist "$tags_text")"
  album_artist="$(ml_tag_value album_artist "$tags_text")"
  album="$(ml_tag_value album "$tags_text")"
  title="$(ml_tag_value title "$tags_text")"
  track="$(ml_tag_value track "$tags_text")"
  disc="$(ml_tag_value disc "$tags_text")"
  date_value="$(ml_tag_value date "$tags_text")"

  cmd=(exiftool -q -q -overwrite_original)
  [[ -n "$artist" ]] && cmd+=("-Artist=$artist") || cmd+=(-Artist=)
  [[ -n "$album_artist" ]] && cmd+=("-AlbumArtist=$album_artist") || cmd+=(-AlbumArtist=)
  [[ -n "$album" ]] && cmd+=("-Album=$album") || cmd+=(-Album=)
  [[ -n "$title" ]] && cmd+=("-Title=$title") || cmd+=(-Title=)
  [[ -n "$track" ]] && cmd+=("-Track=$track") || cmd+=(-Track=)
  [[ -n "$disc" ]] && cmd+=("-Disc=$disc") || cmd+=(-Disc=)
  [[ -n "$date_value" ]] && cmd+=("-Date=$date_value") || cmd+=(-Date=)
  cmd+=("$file")
  "${cmd[@]}" >/dev/null 2>&1
}

ml_enrich_file_tags_if_needed() {
  local file="$1"
  local raw_tags="${2:-}"
  local inferred_tags

  command -v exiftool >/dev/null 2>&1 || return 0
  [[ -n "$raw_tags" ]] || raw_tags="$(ffprobe -v error -show_entries format_tags=artist,album_artist,album,title,track,disc,date \
    -of default=noprint_wrappers=1:nokey=0 "$file" 2>/dev/null || true)"
  inferred_tags="$(ml_inferred_tags_text "$file" "$raw_tags")"
  [[ -n "$inferred_tags" ]] || return 0

  if ml_apply_tag_snapshot "$file" "$raw_tags"$'\n'"$inferred_tags"; then
    ml_log_step "enrich-tags" "$(ml_display_path "$file")"
    print -r -- "$inferred_tags" | while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      ml_log "  ${line#tag:}"
    done
    ml_record_event "enrich_tags" "$file" "$inferred_tags" "$raw_tags" ""
  fi
}

ml_release_signature_for_dir() {
  local dir="$1"
  local first tags artist album year

  first="$(ml_first_audio_file "$dir")"
  [[ -n "$first" ]] || return 1

  tags="$(ml_file_tags "$first")"
  artist="$(ml_tag_value album_artist "$tags")"
  [[ -z "$artist" ]] && artist="$(ml_tag_value artist "$tags")"
  album="$(ml_tag_value album "$tags")"
  year="$(ml_infer_year "${dir:t}" "$(ml_tag_value date "$tags")")"

  artist="$(ml_sanitize_name "$artist")"
  album="$(ml_sanitize_name "$album")"
  [[ -n "$artist" && -n "$album" ]] || return 1

  print -r -- "$(ml_normalize_match_name "$artist")|$(ml_normalize_match_name "$album")|$year"
}

ml_dir_is_split_release() {
  local dir="$1"
  local -a child_dirs
  local child signature first_signature="" matched_children=0

  child_dirs=("${(@f)$(ml_find_non_reserved_child_dirs "$dir")}")
  for child in "${child_dirs[@]}"; do
    [[ -n "$child" ]] || continue
    [[ -n "$(ml_first_audio_file "$child")" ]] || continue

    signature="$(ml_release_signature_for_dir "$child")" || return 1
    if [[ -z "$first_signature" ]]; then
      first_signature="$signature"
    elif [[ "$signature" != "$first_signature" ]]; then
      return 1
    fi
    (( matched_children++ ))
  done

  (( matched_children >= 2 ))
}

ml_primary_artist_from_file() {
  local file="$1"
  local tags artist
  tags="$(ml_file_tags "$file")"
  artist="$(ml_tag_value album_artist "$tags")"
  [[ -z "$artist" ]] && artist="$(ml_tag_value artist "$tags")"
  artist="$(ml_start_case_name "$artist")"
  print -r -- "$artist"
}

ml_artist_is_various() {
  local artist
  artist="$(ml_normalize_match_name "$(ml_sanitize_name "${1:-}")")"
  [[ "$artist" == "various" || "$artist" == "various artists" || "$artist" == "va" ]]
}

ml_path_artist_label() {
  local artist
  artist="$(ml_sanitize_name "${1:-}")"
  if ml_artist_is_various "$artist"; then
    print -r -- "VA"
  else
    print -r -- "$(ml_start_case_name "$artist")"
  fi
}

ml_release_primary_artist() {
  local dir="$1"
  local first
  first="$(ml_first_audio_file "$dir")"
  [[ -n "$first" ]] || return 1
  ml_primary_artist_from_file "$first"
}

ml_release_album_name() {
  local dir="$1"
  local first tags album year fallback
  first="$(ml_first_audio_file "$dir")"
  [[ -n "$first" ]] || return 1
  tags="$(ml_file_tags "$first")"
  album="$(ml_tag_value album "$tags")"
  year="$(ml_infer_year "${dir:t}" "$(ml_tag_value date "$tags")")"
  fallback="$(ml_strip_leading_year_prefix "$(ml_strip_format_suffix "${dir:t}")")"
  album="$(ml_start_case_name "${album:-$fallback}")"
  if [[ -n "$album" && "$year" != "0000" ]]; then
    album="$(printf '%s' "$album" | sed -E "s/^\\[?$year\\]?[[:space:]]*[-_.]?[[:space:]]*//")"
    album="$(ml_start_case_name "$album")"
  fi
  [[ -n "$album" ]] || album="$(ml_start_case_name "$(ml_strip_format_suffix "${dir:t}")")"
  print -r -- "$album"
}

ml_release_year() {
  local dir="$1"
  local first tags date_value
  first="$(ml_first_audio_file "$dir")"
  [[ -n "$first" ]] || { print -r -- "0000"; return 0; }
  tags="$(ml_file_tags "$first")"
  date_value="$(ml_tag_value date "$tags")"
  ml_infer_year "${dir:t}" "$date_value"
}

ml_year_prefix() {
  local year="${1:-}"

  if [[ -n "$year" && "$year" != "0000" ]]; then
    print -r -- "[$year] "
  else
    print -r -- ""
  fi
}

ml_release_target_dir_name() {
  local dir="$1"
  local first_audio album_name year format fallback_name year_prefix artist_label

  first_audio="$(ml_first_audio_file "$dir")"
  [[ -n "$first_audio" ]] || {
    print -r -- "${dir:t}"
    return 0
  }

  album_name="$(ml_release_album_name "$dir")"
  year="$(ml_release_year "$dir")"
  format="$(ml_probe_format "$first_audio")"
  fallback_name="$(ml_strip_format_suffix "${dir:t}")"
  year_prefix="$(ml_year_prefix "$year")"
  artist_label="$(ml_path_artist_label "$(ml_release_primary_artist "$dir" 2>/dev/null || true)")"

  if [[ -n "$album_name" ]]; then
    if [[ "$artist_label" == "VA" ]]; then
      print -r -- "${year_prefix}VA - ${album_name} [$format]"
    else
      print -r -- "${year_prefix}${album_name} [$format]"
    fi
  else
    if [[ "$artist_label" == "VA" ]]; then
      print -r -- "${year_prefix}VA - ${fallback_name} [$format]"
    else
      print -r -- "${year_prefix}${fallback_name} [$format]"
    fi
  fi
}

ml_track_display_title() {
  local file="$1"
  local tags title basename fallback artist year

  tags="$(ml_file_tags "$file")"
  artist="$(ml_tag_value album_artist "$tags")"
  [[ -z "$artist" ]] && artist="$(ml_tag_value artist "$tags")"
  basename="$(ml_strip_format_suffix "${file:t:r}")"
  year="$(ml_infer_year "$basename" "$(ml_tag_value date "$tags")")"
  title="$(ml_tag_value title "$tags")"
  if [[ -z "$title" ]]; then
    fallback=$(printf '%s\n' "$basename" | sed -E 's/^[0-9]{2}-[0-9]{2}[[:space:]]*-[[:space:]]*//; s/^[0-9]{1,2}([ ._-][[:space:]]*|[[:space:]]*-[[:space:]]*)//')
    title="$fallback"
  fi

  ml_cleanup_display_title "$title" "$artist" "$year"
}

ml_track_target_name() {
  local file="$1"
  local tags title track_raw disc_raw track_num="" disc_num="" disc_total="" basename parent_dir format show_disc=0

  tags="$(ml_file_tags "$file")"

  title="$(ml_track_display_title "$file")"
  track_raw="$(ml_tag_value track "$tags")"
  disc_raw="$(ml_tag_value disc "$tags")"
  format="$(ml_probe_format "$file")"
  basename="$(ml_strip_format_suffix "${file:t:r}")"

  track_num="${track_raw%%/*}"
  disc_num="${disc_raw%%/*}"
  if [[ "$disc_raw" == */* ]]; then
    disc_total="${disc_raw#*/}"
  fi

  if [[ -z "$track_num" ]]; then
    if [[ "$basename" =~ '^([0-9]{2})-([0-9]{2}) - ' ]]; then
      disc_num="${match[1]}"
      track_num="${match[2]}"
    elif [[ "$basename" =~ '^([0-9]{1,2})[ ._-]' ]]; then
      track_num="${match[1]}"
    fi
  fi

  if [[ -z "$disc_num" ]]; then
    parent_dir="${file:h:t}"
    if [[ "${parent_dir:l}" == cd* || "${parent_dir:l}" == disc* ]] && [[ "$parent_dir" =~ '([0-9]+)' ]]; then
      disc_num="${match[1]}"
    else
      disc_num="1"
    fi
  fi

  if [[ -n "$track_num" ]]; then
    [[ -z "$disc_num" ]] && disc_num="1"
    if [[ "$disc_num" != "1" ]]; then
      show_disc=1
    elif [[ -n "$disc_total" && "$disc_total" != "1" ]]; then
      show_disc=1
    fi

    if (( ! show_disc )); then
      printf '[%02d] %s [%s].%s' "$track_num" "$title" "$format" "${file:e}"
    else
      printf '[%02d-%02d] %s [%s].%s' "$disc_num" "$track_num" "$title" "$format" "${file:e}"
    fi
  else
    printf '%s [%s].%s' "${title:-$basename}" "$format" "${file:e}"
  fi
}

ml_dir_kind() {
  local dir="$1"
  local direct_audio cd_audio other_audio

  direct_audio=$(find "$dir" -mindepth 1 -maxdepth 1 -type f \
    \( "${MUSICLIB_AUDIO_FILE_FIND_ARGS[@]}" \) | wc -l | awk '{print $1}')
  cd_audio=$(find "$dir" -mindepth 1 -maxdepth 1 -type d \( -iname 'CD *' -o -iname 'Disc *' -o -iname 'Disc*' \) | while IFS= read -r sub; do
    [[ -n "$(ml_first_audio_file "$sub")" ]] && print -r -- "$sub"
  done | wc -l | awk '{print $1}')
  other_audio=$(ml_find_non_reserved_child_dirs "$dir" | while IFS= read -r sub; do
    [[ "${sub:t}" == (#i)(cd\ *|disc\ *|disc*) ]] && continue
    [[ -n "$(ml_first_audio_file "$sub")" ]] && print -r -- "$sub"
  done | wc -l | awk '{print $1}')

  if (( (direct_audio > 0 || cd_audio > 0) && other_audio == 0 )); then
    print -r -- "release"
  elif ml_dir_is_split_release "$dir"; then
    print -r -- "release"
  elif (( other_audio > 0 )); then
    print -r -- "artist"
  else
    print -r -- "unknown"
  fi
}

ml_release_has_lossless_sources() {
  local dir="$1"
  local -a files
  local file

  files=("${(@f)$(ml_find_audio_files "$dir" | LC_ALL=C sort)}")
  for file in "${files[@]}"; do
    [[ -e "$file" ]] || continue
    if ml_is_lossless_source_file "$file"; then
      return 0
    fi
  done

  return 1
}

ml_loose_track_folder_name() {
  local file="$1"
  local tags album title date_value format year base year_prefix artist_label
  tags="$(ml_file_tags "$file")"
  album="$(ml_tag_value album "$tags")"
  title="$(ml_tag_value title "$tags")"
  date_value="$(ml_tag_value date "$tags")"
  year="$(ml_infer_year "${file:t}" "$date_value")"
  format="$(ml_probe_format "$file")"
  base="$(ml_start_case_name "${album:-$title}")"
  [[ -n "$album" ]] || base="$(ml_start_case_name "${base:-${file:t:r}} - Single")"
  [[ "$base" == *" - Single" ]] || [[ -n "$album" ]] || base="${base} - Single"
  year_prefix="$(ml_year_prefix "$year")"
  artist_label="$(ml_path_artist_label "$(ml_primary_artist_from_file "$file")")"
  if [[ "$artist_label" == "VA" ]]; then
    print -r -- "${year_prefix}VA - ${base} [$format]"
  else
    print -r -- "${year_prefix}${base} [$format]"
  fi
}

ml_loose_track_target_name() {
  local file="$1"
  local artist_root="$2"
  local tags artist title basename format date_value year year_prefix artist_root_name display_artist

  tags="$(ml_file_tags "$file")"
  artist="$(ml_primary_artist_from_file "$file")"
  title="$(ml_track_display_title "$file")"
  basename="$(ml_strip_format_suffix "${file:t:r}")"
  format="$(ml_probe_format "$file")"
  date_value="$(ml_tag_value date "$tags")"
  year="$(ml_infer_year "$basename" "$date_value")"
  year_prefix="$(ml_year_prefix "$year")"

  if [[ -n "$artist_root" ]]; then
    artist_root_name="$(ml_sanitize_name "${artist_root:t}")"
  fi
  [[ -z "$artist" ]] && artist="$artist_root_name"
  display_artist="$(ml_path_artist_label "$artist")"
  title="$(ml_cleanup_display_title "$title" "${display_artist:-$artist_root_name}" "$year")"

  if [[ -n "$display_artist" ]]; then
    print -r -- "${year_prefix}${display_artist} - ${title:-$basename} [${format}].${file:e}"
  else
    print -r -- "${year_prefix}${title:-$basename} [${format}].${file:e}"
  fi
}

ml_track_has_release_context() {
  local file="$1"
  local tags album track_value

  tags="$(ml_file_tags "$file")"
  album="$(ml_sanitize_name "$(ml_tag_value album "$tags")")"
  track_value="$(ml_tag_value track "$tags")"

  [[ -n "$album" && -n "$track_value" ]]
}

ml_loose_track_target_path() {
  local file="$1"
  local artist_root="$2"
  local release_dir

  if ml_track_has_release_context "$file"; then
    release_dir="$artist_root/$(ml_loose_track_folder_name "$file")"
    print -r -- "$release_dir/$(ml_track_target_name "$file")"
  else
    print -r -- "$artist_root/$(ml_loose_track_target_name "$file" "$artist_root")"
  fi
}

ml_output_not_audio_target_path() {
  local src="$1"
  local source_root="$2"
  local output_root="$3"
  local rel

  [[ -n "$src" && -n "$source_root" && -n "$output_root" ]] || return 1
  rel="$(ml_relative_path_from_root "$src" "$source_root")"
  [[ -n "$rel" ]] || rel="${src:t}"
  print -r -- "$(ml_unique_destination_path "$output_root/$NOT_AUDIO_DIR_NAME/$rel")"
}

ml_audio_scrape_target_path() {
  local file="$1"
  local source_root="$2"
  local output_root="$3"
  local bucket artist_root release_dir album format year_prefix album_name rel
  local tags

  bucket="$(ml_audio_collection_bucket_name "$file")" || return 1
  artist_root="$output_root/_$bucket"

  artist_root="$artist_root/$(ml_primary_artist_from_file "$file")"
  if [[ -n "${artist_root:t}" && "${artist_root:t}" != "_$bucket" ]]; then
    tags="$(ml_file_tags "$file")"
    album="$(ml_sanitize_name "$(ml_tag_value album "$tags")")"
    if [[ -n "$album" ]]; then
      format="$(ml_probe_format "$file")"
      year_prefix="$(ml_year_prefix "$(ml_infer_year "${file:t}" "$(ml_tag_value date "$tags")")")"
      album_name="$(ml_sanitize_name "$album")"
      release_dir="$artist_root/${year_prefix}${album_name} [$format]"
      print -r -- "$(ml_unique_destination_path "$release_dir/$(ml_track_target_name "$file")")"
      return 0
    fi

    print -r -- "$(ml_unique_destination_path "$artist_root/$(ml_loose_track_target_name "$file" "$artist_root")")"
    return 0
  fi

  rel="$(ml_relative_path_from_root "$file" "$source_root")"
  [[ -n "$rel" ]] || rel="${file:t}"
  print -r -- "$(ml_unique_destination_path "$output_root/_$bucket/$rel")"
}

# Filesystem mutation helpers.
ml_move_path() {
  local src="$1"
  local dst="$2"
  local op="${3:-move}"
  local reason="${4:-}"

  [[ "$src" == "$dst" ]] && return 0

  if [[ -e "$dst" ]]; then
    ml_warn "conflict: $(ml_display_path "$dst") already exists"
    ml_record_event "skip" "$src" "$dst" "$reason" "$op"
    return 1
  fi

  ml_ensure_dir "${dst:h}"
  if (( MUSICLIB_DRY_RUN )); then
    ml_log_move "$op" "$src" "$dst"
  else
    mv -- "$src" "$dst"
  fi
  ml_record_event "$op" "$src" "$dst" "$reason" ""
}

ml_copy_file() {
  local src="$1"
  local dst="$2"
  local op="${3:-copy_file}"
  local reason="${4:-}"

  if [[ -e "$dst" ]]; then
    ml_warn "conflict: $(ml_display_path "$dst") already exists"
    ml_record_event "skip" "$src" "$dst" "$reason" "$op"
    return 1
  fi

  ml_ensure_dir "${dst:h}"
  if (( MUSICLIB_DRY_RUN )); then
    ml_log_move "$op" "$src" "$dst"
  else
    cp -p -- "$src" "$dst"
  fi
  ml_record_event "$op" "$src" "$dst" "$reason" ""
}

ml_unique_destination_path() {
  local candidate="$1"
  local dir base stem ext i next

  if [[ ! -e "$candidate" ]]; then
    print -r -- "$candidate"
    return 0
  fi

  dir="${candidate:h}"
  base="${candidate:t}"
  if [[ -d "$candidate" || "$base" != *.* ]]; then
    stem="$base"
    ext=""
  else
    stem="${base%.*}"
    ext=".${base##*.}"
  fi

  i=2
  while :; do
    next="$dir/${stem} ($i)$ext"
    if [[ ! -e "$next" ]]; then
      print -r -- "$next"
      return 0
    fi
    (( i++ ))
  done
}

ml_unknown_target_path() {
  local src="$1"
  local scope_root="$2"
  local rel dst

  [[ -n "$src" && -n "$scope_root" ]] || return 1
  scope_root="${scope_root:A}"
  src="${src:A}"

  if [[ "$src" == "$scope_root/$UNKNOWN_DIR_NAME" || "$src" == "$scope_root/$UNKNOWN_DIR_NAME/"* ]]; then
    return 1
  fi

  if [[ "$src" == "$scope_root/"* ]]; then
    rel="${src#$scope_root/}"
  else
    rel="${src:t}"
  fi

  dst="$scope_root/$UNKNOWN_DIR_NAME/$rel"
  dst="$(ml_unique_destination_path "$dst")"
  print -r -- "$dst"
}

ml_move_to_unknown() {
  local src="$1"
  local scope_root="$2"
  local reason="${3:-unclassified content}"
  local op="${4:-route_unknown}"
  local dst

  dst="$(ml_unknown_target_path "$src" "$scope_root")" || return 1
  ml_move_path "$src" "$dst" "$op" "$reason"
}

ml_not_audio_target_path() {
  local src="$1"
  local scope_root="$2"
  local rel dst

  [[ -n "$src" && -n "$scope_root" ]] || return 1
  scope_root="${scope_root:A}"
  src="${src:A}"

  if [[ "$src" == "$scope_root/$NOT_AUDIO_DIR_NAME" || "$src" == "$scope_root/$NOT_AUDIO_DIR_NAME/"* ]]; then
    return 1
  fi

  if [[ "$src" == "$scope_root/"* ]]; then
    rel="${src#$scope_root/}"
  else
    rel="${src:t}"
  fi

  dst="$scope_root/$NOT_AUDIO_DIR_NAME/$rel"
  dst="$(ml_unique_destination_path "$dst")"
  print -r -- "$dst"
}

ml_move_to_not_audio() {
  local src="$1"
  local scope_root="$2"
  local reason="${3:-non-audio content}"
  local op="${4:-route_not_audio}"
  local dst

  dst="$(ml_not_audio_target_path "$src" "$scope_root")" || return 1
  ml_move_path "$src" "$dst" "$op" "$reason"
}

ml_move_misc_file() {
  local src="$1"
  local scope_root="$2"
  local reason="${3:-unclassified file}"

  if ml_is_known_media_file "$src"; then
    ml_move_to_unknown "$src" "$scope_root" "$reason" "route_unknown"
  else
    ml_move_to_not_audio "$src" "$scope_root" "$reason" "route_not_audio"
  fi
}

ml_lossy_archive_root_for_artist_root() {
  local artist_root="$1"
  print -r -- "${artist_root:h}/$LOSSY_ARCHIVE_DIR_NAME/${artist_root:t}"
}

ml_lossy_release_target_dir() {
  local release_dir="$1"
  local artist_root="$2"
  print -r -- "$(ml_lossy_archive_root_for_artist_root "$artist_root")/$(ml_release_target_dir_name "$release_dir")"
}

ml_lossy_track_target_path() {
  local file="$1"
  local artist_root="$2"
  local lossy_artist_root

  lossy_artist_root="$(ml_lossy_archive_root_for_artist_root "$artist_root")"
  if ml_track_has_release_context "$file"; then
    print -r -- "$lossy_artist_root/$(ml_loose_track_folder_name "$file")/$(ml_track_target_name "$file")"
  else
    print -r -- "$lossy_artist_root/$(ml_loose_track_target_name "$file" "$artist_root")"
  fi
}

ml_remove_file() {
  local target_path="$1"
  local op="${2:-remove}"
  local reason="${3:-}"

  [[ -e "$target_path" ]] || return 0
  if (( MUSICLIB_DRY_RUN )); then
    ml_log_step "rm" "$(ml_display_path "$target_path")"
  else
    rm -f -- "$target_path"
  fi
  ml_record_event "$op" "" "$target_path" "$reason" ""
}

ml_quarantine_sidecar() {
  local file="$1"
  local root="$2"
  local rel dst parent_root

  # Keep trash paths readable. If a file got rerouted into a sibling archive
  # root first, fall back to the parent root so the quarantine path still
  # reflects where it came from.
  if [[ "$file" == "$root/"* ]]; then
    rel="${file#$root/}"
  else
    parent_root="${root:h}"
    if [[ "$file" == "$parent_root/"* ]]; then
      rel="${file#$parent_root/}"
    else
      rel="${file:t}"
    fi
  fi
  dst="$MUSICLIB_TRASH_DIR/$rel"
  ml_move_path "$file" "$dst" "quarantine_sidecar" "quarantine sidecar"
}

ml_cleanup_empty_dirs() {
  local root="$1"
  local dir

  if (( MUSICLIB_DRY_RUN )); then
    find "$root" -depth -mindepth 1 -type d -empty | LC_ALL=C sort | while IFS= read -r dir; do
      ml_path_has_hidden_or_state_segment "$dir" "$root" && continue
      ml_log_step "rmdir" "$(ml_display_path "$dir")"
    done
  else
    while IFS= read -r dir; do
      ml_path_has_hidden_or_state_segment "$dir" "$root" && continue
      rmdir -- "$dir" 2>/dev/null || true
    done < <(find "$root" -depth -mindepth 1 -type d -empty | LC_ALL=C sort)
  fi
}

ml_cleanup_empty_recoverable_dirs() {
  local root="$1"
  local dir count=0

  MUSICLIB_LAST_EMPTY_DIR_CLEANUP_COUNT=0

  if (( MUSICLIB_DRY_RUN )); then
    while IFS= read -r dir; do
      ml_path_has_cleanup_protected_segment "$dir" "$root" && continue
      ml_log_step "rmdir" "$(ml_display_path "$dir")"
      (( count++ ))
    done < <(find "$root" -depth -mindepth 1 -type d -empty | LC_ALL=C sort)
  else
    while IFS= read -r dir; do
      ml_path_has_cleanup_protected_segment "$dir" "$root" && continue
      if rmdir -- "$dir" 2>/dev/null; then
        ml_log_step "rmdir" "$(ml_display_path "$dir")"
        ml_record_event "cleanup_empty_dir" "" "$dir" "remove empty directory" ""
        (( count++ ))
      fi
    done < <(find "$root" -depth -mindepth 1 -type d -empty | LC_ALL=C sort)
  fi

  MUSICLIB_LAST_EMPTY_DIR_CLEANUP_COUNT=$count
}

ml_cleanup_empty_aux_dirs() {
  local root="$1"
  local dir

  if (( MUSICLIB_DRY_RUN )); then
    find "$root" -depth -mindepth 1 -type d \
      \( -name "$SOURCE_ARCHIVE_DIR" -o -name "$UNKNOWN_DIR_NAME" -o -name "$NOT_AUDIO_DIR_NAME" -o "${MUSICLIB_AUDIO_COLLECT_DIR_FIND_ARGS[@]}" -o -name "$LOSSY_ARCHIVE_DIR_NAME" -o -name "$MUSICLIB_LEGACY_LOSSY_ARCHIVE_DIR_NAME" \) \
      -empty | LC_ALL=C sort | while IFS= read -r dir; do
      ml_log_step "rmdir" "$(ml_display_path "$dir")"
    done
  else
    while IFS= read -r dir; do
      rmdir -- "$dir" 2>/dev/null || true
    done < <(find "$root" -depth -mindepth 1 -type d \
      \( -name "$SOURCE_ARCHIVE_DIR" -o -name "$UNKNOWN_DIR_NAME" -o -name "$NOT_AUDIO_DIR_NAME" -o "${MUSICLIB_AUDIO_COLLECT_DIR_FIND_ARGS[@]}" -o -name "$LOSSY_ARCHIVE_DIR_NAME" -o -name "$MUSICLIB_LEGACY_LOSSY_ARCHIVE_DIR_NAME" \) \
      -empty | LC_ALL=C sort)
  fi
}

ml_cleanup_all_empty_dirs() {
  local root="$1"
  local dir count=0

  MUSICLIB_LAST_EMPTY_DIR_CLEANUP_COUNT=0

  if (( MUSICLIB_DRY_RUN )); then
    while IFS= read -r dir; do
      [[ -n "$dir" ]] || continue
      ml_log_step "rmdir" "$(ml_display_path "$dir")"
      (( count++ ))
    done < <(find "$root" -depth -mindepth 1 -type d -empty | LC_ALL=C sort)
  else
    while IFS= read -r dir; do
      [[ -n "$dir" ]] || continue
      if rmdir -- "$dir" 2>/dev/null; then
        ml_log_step "rmdir" "$(ml_display_path "$dir")"
        ml_record_event "cleanup_empty_dir" "" "$dir" "remove empty directory" ""
        (( count++ ))
      fi
    done < <(find "$root" -depth -mindepth 1 -type d -empty | LC_ALL=C sort)
  fi

  MUSICLIB_LAST_EMPTY_DIR_CLEANUP_COUNT=$count
}

ml_find_dedupe_candidate_files() {
  local root="$1"
  find "$root" \
    \( -type d \( -name "$STATE_DIR_NAME" -o -name "$SOURCE_ARCHIVE_DIR" -o -name "$UNKNOWN_DIR_NAME" -o -name "$NOT_AUDIO_DIR_NAME" -o "${MUSICLIB_AUDIO_COLLECT_DIR_FIND_ARGS[@]}" -o -name "$LOSSY_ARCHIVE_DIR_NAME" -o -name "$MUSICLIB_LEGACY_LOSSY_ARCHIVE_DIR_NAME" -o -name '.*' \) -prune \) -o \
    -type f -print | LC_ALL=C sort
}

ml_duplicate_stash_path() {
  local file="$1"
  local root="$2"
  local rel dst

  rel="${file#$root/}"
  dst="$MUSICLIB_STATE_DIR/duplicates/$MUSICLIB_RUN_ID/$rel"
  print -r -- "$(ml_unique_destination_path "$dst")"
}

# Routing helpers used by the wrapper before sort/convert runs.
ml_route_release_to_artist() {
  local release_dir="$1"
  local artist_root="$2"
  local dst="$artist_root/${release_dir:t}"

  ml_move_path "$release_dir" "$dst" "route_release" "route release"
}

ml_route_loose_track_to_artist() {
  local track="$1"
  local artist_root="$2"
  local dst_file

  dst_file="$(ml_loose_track_target_path "$track" "$artist_root")"
  [[ "${track:A}" == "${dst_file:A}" ]] && return 0

  if [[ -e "$dst_file" ]]; then
    ml_warn "conflict: loose track target already exists: $(ml_display_path "$dst_file")"
    ml_record_event "skip" "$track" "$dst_file" "loose track target already exists" "route_loose_track"
    return 1
  fi

  ml_move_path "$track" "$dst_file" "route_loose_track" "route loose track"
}

ml_route_release_to_archive_root() {
  local release_dir="$1"
  local archive_root="$2"
  local artist

  artist="$(ml_release_primary_artist "$release_dir")"
  if [[ -z "$artist" ]]; then
    ml_warn "skipping release with no album artist/artist tag: $(ml_display_path "$release_dir")"
    ml_record_event "skip" "$release_dir" "" "missing artist tags" "route_release"
    return 1
  fi

  ml_route_release_to_artist "$release_dir" "$archive_root/$artist"
}

ml_route_loose_track_to_archive_root() {
  local track="$1"
  local archive_root="$2"
  local artist

  artist="$(ml_primary_artist_from_file "$track")"
  if [[ -z "$artist" ]]; then
    ml_warn "skipping loose track with no album artist/artist tag: $(ml_display_path "$track")"
    ml_record_event "skip" "$track" "" "missing artist tags" "route_loose_track"
    return 1
  fi

  ml_route_loose_track_to_artist "$track" "$archive_root/$artist"
}

# Undo works by replaying the manifest backwards. That lets us restore paths in
# the reverse order they were changed, which is the least surprising way to
# unwind moves and conversions.
ml_undo_last_run() {
  local root="$1"
  local state_dir="$root/$STATE_DIR_NAME"
  local last_run_file="$state_dir/last_successful_run"
  local manifest_file line op src_b64 dst_b64 reason_b64 src dst reason

  [[ -f "$last_run_file" ]] || ml_die "no recorded successful run for $root"
  manifest_file="$(<"$last_run_file")"
  [[ -f "$manifest_file" ]] || ml_die "manifest not found: $manifest_file"

  ml_start_run "undo" "$root" 1
  ml_log_scope "undo" "$root"
  ml_log_step "manifest" "$(ml_display_path "$manifest_file")"

  while IFS= read -r line; do
    op="$(ml_manifest_field op "$line")"
    src_b64="$(ml_manifest_field src_b64 "$line")"
    dst_b64="$(ml_manifest_field dst_b64 "$line")"
    reason_b64="$(ml_manifest_field reason_b64 "$line")"
    src="$(ml_b64_decode "$src_b64")"
    dst="$(ml_b64_decode "$dst_b64")"
    reason="$(ml_b64_decode "$reason_b64")"

    case "$op" in
      convert)
        if [[ -n "$dst" && -e "$dst" ]]; then
          ml_remove_file "$dst" "undo_remove_created" "undo created file"
        fi
        ;;
      cleanup_empty_dir)
        if [[ -z "$dst" ]]; then
          continue
        fi
        if [[ -e "$dst" && ! -d "$dst" ]]; then
          ml_warn "undo conflict: path exists and is not a directory: $(ml_display_path "$dst")"
          ml_record_event "skip" "" "$dst" "undo directory path blocked by file" "undo"
          continue
        fi
        if [[ -d "$dst" ]]; then
          continue
        fi
        ml_ensure_dir "$dst"
        ml_record_event "undo_mkdir" "" "$dst" "undo recreate empty directory" ""
        ;;
      route_release|route_loose_track|rename_audio|move_nested_file|archive_source|restore_archived_alac|quarantine_sidecar|normalize_release|route_unknown|route_not_audio|route_lossy|dedupe_move|collect_mp3|collect_audio)
        if [[ -z "$src" || -z "$dst" ]]; then
          continue
        fi
        if [[ ! -e "$dst" ]]; then
          ml_warn "undo skip: destination missing: $(ml_display_path "$dst")"
          ml_record_event "skip" "$dst" "$src" "undo destination missing" "undo"
          continue
        fi
        if [[ -e "$src" ]]; then
          ml_warn "undo conflict: original path already exists: $(ml_display_path "$src")"
          ml_record_event "skip" "$dst" "$src" "undo source already exists" "undo"
          continue
        fi
        ml_move_path "$dst" "$src" "undo_move" "undo"
        ;;
      collect_audio_copy)
        if [[ -n "$dst" && -e "$dst" ]]; then
          ml_remove_file "$dst" "undo_remove_created" "undo copied file"
        fi
        ;;
      enrich_tags)
        if [[ -n "$src" && -e "$src" ]]; then
          ml_apply_tag_snapshot "$src" "$reason"
          ml_record_event "undo_enrich_tags" "$src" "" "undo tag enrichment" ""
        fi
        ;;
      *)
        ;;
    esac
  done < <(ml_reverse_file_lines "$manifest_file")

  ml_cleanup_empty_dirs "$root"
  ml_cleanup_empty_aux_dirs "$root"
  [[ "$root:h" != "$root" ]] && ml_cleanup_empty_dirs "$root:h"
  [[ "$root:h" != "$root" ]] && ml_cleanup_empty_aux_dirs "$root:h"
  [[ -f "$last_run_file" ]] && rm -f -- "$last_run_file"
  ml_finish_run "success" "Undo complete."
}

ml_find_source_archive_dirs() {
  local root="$1"
  find "$root" -type d -name "$SOURCE_ARCHIVE_DIR" ! -path '*/.*/*' | LC_ALL=C sort
}

ml_archive_dir_bytes() {
  local dir="$1"
  du -sk "$dir" 2>/dev/null | awk '{print $1 * 1024}'
}

ml_human_bytes() {
  local bytes="${1:-0}"
  local units=(B KB MB GB TB)
  local unit_index=1
  local value="$bytes"

  while (( value >= 1024 && unit_index < ${#units[@]} )); do
    value=$(( value / 1024 ))
    (( unit_index++ ))
  done

  print -r -- "${value}${units[$unit_index]}"
}
