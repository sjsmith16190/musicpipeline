# Shared helpers for the Music Prep Scripts suite.

# Keep the common helpers reload-safe in long-lived shells. That way `source
# ~/.zshrc` after an update actually refreshes the function set instead of
# leaving you stuck with an older in-memory copy.
typeset -g MUSICLIB_COMMON_FILE_VERSION="20260421.1"
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
: ${MUSICLIB_DEFAULT_LOSSY_ARCHIVE_DIR_NAME:=_Lossy}
: ${MUSICLIB_LEGACY_LOSSY_ARCHIVE_DIR_NAME:=_LossyArchive}

: ${STATE_DIR_NAME:=$MUSICLIB_DEFAULT_STATE_DIR_NAME}
: ${SOURCE_ARCHIVE_DIR:=$MUSICLIB_DEFAULT_SOURCE_ARCHIVE_DIR}
: ${UNKNOWN_DIR_NAME:=$MUSICLIB_DEFAULT_UNKNOWN_DIR_NAME}
: ${NOT_AUDIO_DIR_NAME:=$MUSICLIB_DEFAULT_NOT_AUDIO_DIR_NAME}
: ${LOSSY_ARCHIVE_DIR_NAME:=$MUSICLIB_DEFAULT_LOSSY_ARCHIVE_DIR_NAME}

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
    if [[ "$segment" == "$STATE_DIR_NAME" || "$segment" == "$SOURCE_ARCHIVE_DIR" || "$segment" == "$UNKNOWN_DIR_NAME" || "$segment" == "$NOT_AUDIO_DIR_NAME" || "$segment" == "$LOSSY_ARCHIVE_DIR_NAME" || "$segment" == "$MUSICLIB_LEGACY_LOSSY_ARCHIVE_DIR_NAME" || "$segment" == .* ]]; then
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

  direct_dirs=("${(@f)$(find "$root" -mindepth 1 -maxdepth 1 -type d ! -name '.*' ! -name "$SOURCE_ARCHIVE_DIR" ! -name "$STATE_DIR_NAME" ! -name "$UNKNOWN_DIR_NAME" ! -name "$NOT_AUDIO_DIR_NAME" ! -name "$LOSSY_ARCHIVE_DIR_NAME" ! -name "$MUSICLIB_LEGACY_LOSSY_ARCHIVE_DIR_NAME" | LC_ALL=C sort)}")
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

  direct_dirs=("${(@f)$(find "$root" -mindepth 1 -maxdepth 1 -type d ! -name '.*' ! -name "$SOURCE_ARCHIVE_DIR" ! -name "$STATE_DIR_NAME" ! -name "$UNKNOWN_DIR_NAME" ! -name "$NOT_AUDIO_DIR_NAME" ! -name "$LOSSY_ARCHIVE_DIR_NAME" ! -name "$MUSICLIB_LEGACY_LOSSY_ARCHIVE_DIR_NAME" | LC_ALL=C sort)}")
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
    \( -type d \( -name "$SOURCE_ARCHIVE_DIR" -o -name "$STATE_DIR_NAME" -o -name "$UNKNOWN_DIR_NAME" -o -name "$NOT_AUDIO_DIR_NAME" -o -name "$LOSSY_ARCHIVE_DIR_NAME" -o -name "$MUSICLIB_LEGACY_LOSSY_ARCHIVE_DIR_NAME" -o -name '.*' \) -prune \) -o \
    -type f \( -iname '*.m4a' -o -iname '*.flac' -o -iname '*.alac' -o -iname '*.mp3' -o -iname '*.aiff' -o -iname '*.aif' -o -iname '*.wav' \) -print
}

ml_find_loose_audio_files() {
  local root="$1"
  find "$root" -mindepth 1 -maxdepth 1 -type f \
    \( -iname '*.m4a' -o -iname '*.flac' -o -iname '*.alac' -o -iname '*.mp3' -o -iname '*.aiff' -o -iname '*.aif' -o -iname '*.wav' \) -print
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
    -print -quit | grep -q .
}

ml_is_known_media_file() {
  local ext="${1:e:l}"
  [[ -n "$ext" ]] || return 1

  [[ "$ext" == flac || "$ext" == wav || "$ext" == aiff || "$ext" == aif || "$ext" == alac || "$ext" == m4a || "$ext" == aac || "$ext" == mp3 || "$ext" == ogg || "$ext" == opus || "$ext" == wma || "$ext" == ape || "$ext" == wv || "$ext" == mka || "$ext" == dsf || "$ext" == dff || "$ext" == mp4 || "$ext" == m4v || "$ext" == mov || "$ext" == mkv || "$ext" == avi || "$ext" == jpg || "$ext" == jpeg || "$ext" == png || "$ext" == gif || "$ext" == webp || "$ext" == tif || "$ext" == tiff || "$ext" == bmp ]]
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
  [[ "$codec" == alac || "$codec" == flac || "$codec" == ape || "$codec" == wavpack || "$codec" == tak || "$codec" == truehd || "$codec" == mlp || "$codec" == pcm_* ]]
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
  local out rate bits sample_fmt khz

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

  cleaned="$(ml_sanitize_name "$cleaned")"
  print -r -- "${cleaned:-$title}"
}

ml_file_tags() {
  local file="$1"
  ffprobe -v error -show_entries format_tags=artist,album_artist,album,title,track,disc,date \
    -of default=noprint_wrappers=1:nokey=0 "$file" 2>/dev/null || true
}

ml_release_cue_file() {
  local dir="$1"
  find "$dir" -mindepth 1 -maxdepth 1 -type f -iname '*.cue' | LC_ALL=C sort | head -n 1
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

  child_dirs=("${(@f)$(find "$dir" -mindepth 1 -maxdepth 1 -type d ! -name '.*' ! -name "$SOURCE_ARCHIVE_DIR" ! -name "$STATE_DIR_NAME" ! -name "$UNKNOWN_DIR_NAME" ! -name "$NOT_AUDIO_DIR_NAME" ! -name "$LOSSY_ARCHIVE_DIR_NAME" ! -name "$MUSICLIB_LEGACY_LOSSY_ARCHIVE_DIR_NAME" | LC_ALL=C sort)}")
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
  artist="$(ml_sanitize_name "$artist")"
  print -r -- "$artist"
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
  album="$(ml_sanitize_name "${album:-$fallback}")"
  if [[ -n "$album" && "$year" != "0000" ]]; then
    album="$(printf '%s' "$album" | sed -E "s/^\\[?$year\\]?[[:space:]]*[-_.]?[[:space:]]*//")"
    album="$(ml_sanitize_name "$album")"
  fi
  [[ -n "$album" ]] || album="$(ml_sanitize_name "$(ml_strip_format_suffix "${dir:t}")")"
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
  local first_audio album_name year format fallback_name year_prefix

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

  if [[ -n "$album_name" ]]; then
    print -r -- "${year_prefix}${album_name} [$format]"
  else
    print -r -- "${year_prefix}${fallback_name} [$format]"
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
    \( -iname '*.m4a' -o -iname '*.flac' -o -iname '*.alac' -o -iname '*.mp3' -o -iname '*.aiff' -o -iname '*.aif' -o -iname '*.wav' \) | wc -l | awk '{print $1}')
  cd_audio=$(find "$dir" -mindepth 1 -maxdepth 1 -type d \( -iname 'CD *' -o -iname 'Disc *' -o -iname 'Disc*' \) | while IFS= read -r sub; do
    [[ -n "$(ml_first_audio_file "$sub")" ]] && print -r -- "$sub"
  done | wc -l | awk '{print $1}')
  other_audio=$(find "$dir" -mindepth 1 -maxdepth 1 -type d ! \( -iname 'CD *' -o -iname 'Disc *' -o -iname 'Disc*' \) ! -name '.*' ! -name "$SOURCE_ARCHIVE_DIR" ! -name "$STATE_DIR_NAME" ! -name "$UNKNOWN_DIR_NAME" ! -name "$NOT_AUDIO_DIR_NAME" ! -name "$LOSSY_ARCHIVE_DIR_NAME" ! -name "$MUSICLIB_LEGACY_LOSSY_ARCHIVE_DIR_NAME" | while IFS= read -r sub; do
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
  find "$dir" \
    \( -type d \( -name "$SOURCE_ARCHIVE_DIR" -o -name "$STATE_DIR_NAME" -o -name "$UNKNOWN_DIR_NAME" -o -name "$NOT_AUDIO_DIR_NAME" -o -name "$LOSSY_ARCHIVE_DIR_NAME" -o -name "$MUSICLIB_LEGACY_LOSSY_ARCHIVE_DIR_NAME" -o -name '.*' \) -prune \) -o \
    -type f \( -iname '*.flac' -o -iname '*.wav' -o -iname '*.aiff' -o -iname '*.aif' -o -iname '*.alac' \) -print |
    grep -q .
}

ml_loose_track_folder_name() {
  local file="$1"
  local tags album title date_value format year base year_prefix
  tags="$(ml_file_tags "$file")"
  album="$(ml_tag_value album "$tags")"
  title="$(ml_tag_value title "$tags")"
  date_value="$(ml_tag_value date "$tags")"
  year="$(ml_infer_year "${file:t}" "$date_value")"
  format="$(ml_probe_format "$file")"
  base="$(ml_sanitize_name "${album:-$title}")"
  [[ -n "$album" ]] || base="$(ml_sanitize_name "${base:-${file:t:r}} - Single")"
  [[ "$base" == *" - Single" ]] || [[ -n "$album" ]] || base="${base} - Single"
  year_prefix="$(ml_year_prefix "$year")"
  print -r -- "${year_prefix}${base} [$format]"
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
  display_artist="$(ml_sanitize_name "$artist")"
  title="$(ml_cleanup_display_title "$title" "${display_artist:-$artist_root_name}" "$year")"

  if [[ -n "$display_artist" ]]; then
    print -r -- "${year_prefix}${display_artist} - ${title:-$basename} [${format}].${file:e}"
  else
    print -r -- "${year_prefix}${title:-$basename} [${format}].${file:e}"
  fi
}

ml_loose_track_target_path() {
  local file="$1"
  local artist_root="$2"

  print -r -- "$artist_root/$(ml_loose_track_target_name "$file" "$artist_root")"
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
  print -r -- "$(ml_lossy_archive_root_for_artist_root "$artist_root")/$(ml_loose_track_target_name "$file" "$artist_root")"
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
  local manifest_file line op src_b64 dst_b64 src dst

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
    src="$(ml_b64_decode "$src_b64")"
    dst="$(ml_b64_decode "$dst_b64")"

    case "$op" in
      convert)
        if [[ -n "$dst" && -e "$dst" ]]; then
          ml_remove_file "$dst" "undo_remove_created" "undo created file"
        fi
        ;;
      route_release|route_loose_track|rename_audio|move_nested_file|archive_source|restore_archived_alac|quarantine_sidecar|normalize_release|route_unknown|route_not_audio|route_lossy)
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
      *)
        ;;
    esac
  done < <(ml_reverse_file_lines "$manifest_file")

  ml_cleanup_empty_dirs "$root"
  [[ "$root:h" != "$root" ]] && ml_cleanup_empty_dirs "$root:h"
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
