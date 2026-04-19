#!/usr/bin/env zsh
#
# convert_music.zsh
# Authored by Stephen J. Smith
# Created: 2026-04-18
# Purpose: Convert FLAC source files to ALAC and archive original sources.

emulate -L zsh
setopt pipe_fail no_unset extended_glob

source "${${(%):-%x}:A:h}/musicpipeline_common.zsh"

convert_music_usage() {
  cat <<'EOF'
Usage: convert_music.zsh [--dry-run] [artist_dir]

Converts lossless source files to ALAC (.m4a) inside an artist root.

Rules:
  - converts FLAC/WAV/AIFF/AIF sources into ALAC outputs
  - splits single-file cue releases into per-track ALAC files
  - prefers folder artwork before embedded source artwork
  - archives original release folders and source files into _originalSource
  - skips conflicts instead of replacing existing outputs
EOF
}

# Simple counters for the run summary at the end.
typeset -gi CONVERT_CREATED_COUNT=0
typeset -gi CONVERT_ARCHIVE_COUNT=0
typeset -gi CONVERT_SKIP_COUNT=0

# Scan for the formats we still treat as source material. Archived sources and
# state directories are ignored so reruns stay predictable.
convert_find_source_files() {
  local root="$1"
  find "$root" \
    \( -type d \( -name "$SOURCE_ARCHIVE_DIR" -o -name "$STATE_DIR_NAME" -o -name '.*' \) -prune \) -o \
    -type f \( -iname '*.flac' -o -iname '*.wav' -o -iname '*.aiff' -o -iname '*.aif' \) -print
}

convert_find_artwork_in_dir() {
  local dir="$1"
  find "$dir" -maxdepth 1 -type f \
    \( -iname 'cover.jpg' -o -iname 'cover.jpeg' -o -iname 'cover.png' \
       -o -iname 'folder.jpg' -o -iname 'folder.jpeg' -o -iname 'folder.png' \
       -o -iname 'front.jpg' -o -iname 'front.jpeg' -o -iname 'front.png' \
       -o -iname '*cover*.jpg' -o -iname '*cover*.jpeg' -o -iname '*cover*.png' \
       -o -iname '*folder*.jpg' -o -iname '*folder*.jpeg' -o -iname '*folder*.png' \
       -o -iname '*front*.jpg' -o -iname '*front*.jpeg' -o -iname '*front*.png' \) |
    LC_ALL=C sort |
    head -n 1
}

# Prefer obvious folder art first, then fall back to album-root art if the
# source file came from a subfolder.
convert_find_artwork_file() {
  local source_file="$1"
  local album_dir="$2"
  local from_source_dir from_album_dir

  from_source_dir="$(convert_find_artwork_in_dir "${source_file:h}")"
  if [[ -n "$from_source_dir" ]]; then
    print -r -- "$from_source_dir"
    return 0
  fi

  if [[ "${source_file:h}" != "$album_dir" ]]; then
    from_album_dir="$(convert_find_artwork_in_dir "$album_dir")"
    if [[ -n "$from_album_dir" ]]; then
      print -r -- "$from_album_dir"
      return 0
    fi
  fi

  return 1
}

# Validation helpers. We only archive the original source once the ALAC output
# looks real and, if expected, actually has artwork embedded.
convert_source_has_embedded_art() {
  local file="$1"
  exiftool -q -q -b -Picture "$file" >/dev/null 2>&1
}

convert_target_has_embedded_art() {
  local file="$1"
  exiftool -q -q -b -CoverArt "$file" >/dev/null 2>&1
}

convert_is_valid_alac() {
  local file="$1"
  local codec

  [[ -f "$file" ]] || return 1
  codec=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name \
    -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null | head -n 1)
  [[ "$codec" == "alac" ]]
}

convert_verify_output() {
  local file="$1"
  local expect_art="$2"

  convert_is_valid_alac "$file" || return 1
  if (( expect_art )) && ! convert_target_has_embedded_art "$file"; then
    return 1
  fi
  return 0
}

# Pull embedded art out to a temp file when we need a standalone image to feed
# back into the ALAC after conversion.
convert_extract_embedded_artwork() {
  local source_file="$1"
  local temp_dir="$2"
  local mime ext extracted_file

  mime=$(exiftool -q -q -s3 -PictureMIMEType "$source_file" 2>/dev/null | head -n 1)
  case "$mime" in
    image/png)
      ext="png"
      ;;
    *)
      ext="jpg"
      ;;
  esac

  extracted_file="$temp_dir/.${source_file:t:r}.cover.$$.${ext}"

  if (( MUSICLIB_DRY_RUN )); then
    ml_log "extract-art: $source_file -> $extracted_file"
    print -r -- "$extracted_file"
    return 0
  fi

  if ! exiftool -q -q -b -Picture "$source_file" > "$extracted_file" 2>/dev/null; then
    rm -f -- "$extracted_file"
    return 1
  fi

  print -r -- "$extracted_file"
}

convert_inject_cover_art() {
  local output_file="$1"
  local artwork_file="$2"

  if (( MUSICLIB_DRY_RUN )); then
    ml_log "art: $artwork_file -> $output_file"
    return 0
  fi

  exiftool -q -q -overwrite_original "-CoverArt<=$artwork_file" "$output_file" >/dev/null 2>&1
}

convert_metadata_args_from_values() {
  local artist="$1"
  local album_artist="$2"
  local album="$3"
  local title="$4"
  local track="$5"
  local disc="$6"
  local date_value="$7"

  reply=()
  [[ -n "$artist" ]] && reply+=(-metadata "artist=$artist")
  [[ -n "$album_artist" ]] && reply+=(-metadata "album_artist=$album_artist")
  [[ -n "$album" ]] && reply+=(-metadata "album=$album")
  [[ -n "$title" ]] && reply+=(-metadata "title=$title")
  [[ -n "$track" ]] && reply+=(-metadata "track=$track")
  [[ -n "$disc" ]] && reply+=(-metadata "disc=$disc")
  [[ -n "$date_value" && "$date_value" != "0000" ]] && reply+=(-metadata "date=$date_value")
}

convert_metadata_args_for_source_file() {
  local source_file="$1"
  local tags artist album_artist album title track disc date_value

  tags="$(ml_file_tags "$source_file")"
  artist="$(ml_tag_value artist "$tags")"
  album_artist="$(ml_tag_value album_artist "$tags")"
  album="$(ml_tag_value album "$tags")"
  title="$(ml_tag_value title "$tags")"
  track="$(ml_tag_value track "$tags")"
  disc="$(ml_tag_value disc "$tags")"
  date_value="$(ml_tag_value date "$tags")"
  convert_metadata_args_from_values "$artist" "$album_artist" "$album" "$title" "$track" "$disc" "$date_value"
}

# ffmpeg writes the audio stream to a temp file first so a failed conversion
# does not leave a half-baked library file behind.
convert_audio_only() {
  local source_file="$1"
  local temp_file="$2"
  local -a cmd metadata_args

  convert_metadata_args_for_source_file "$source_file"
  metadata_args=("${reply[@]}")

  cmd=(
    ffmpeg -hide_banner -loglevel error -nostdin -y
    -i "$source_file"
    -map 0:a:0
    -map_metadata -1
    -map_chapters -1
    "${metadata_args[@]}"
    -c:a alac
    -vn
    -movflags use_metadata_tags
    "$temp_file"
  )

  if (( MUSICLIB_DRY_RUN )); then
    ml_log "ffmpeg: ${cmd[*]}"
    return 0
  fi

  "${cmd[@]}"
}

convert_audio_segment() {
  local source_file="$1"
  local temp_file="$2"
  local start_time="$3"
  local end_time="$4"
  local artist="$5"
  local album_artist="$6"
  local album="$7"
  local title="$8"
  local track="$9"
  local disc="${10}"
  local date_value="${11}"
  local -a cmd metadata_args

  convert_metadata_args_from_values "$artist" "$album_artist" "$album" "$title" "$track" "$disc" "$date_value"
  metadata_args=("${reply[@]}")

  cmd=(
    ffmpeg -hide_banner -loglevel error -nostdin -y
    -i "$source_file"
    -ss "$start_time"
  )
  [[ -n "$end_time" ]] && cmd+=(-to "$end_time")
  cmd+=(
    -map 0:a:0
    -map_metadata -1
    -map_chapters -1
    "${metadata_args[@]}"
    -c:a alac
    -vn
    -movflags use_metadata_tags
    "$temp_file"
  )

  if (( MUSICLIB_DRY_RUN )); then
    ml_log "ffmpeg: ${cmd[*]}"
    return 0
  fi

  "${cmd[@]}"
}

convert_archive_source() {
  local source_file="$1"
  local artist_root="$2"
  local rel_path target_path

  rel_path="${source_file#$artist_root/}"
  target_path="$artist_root/$SOURCE_ARCHIVE_DIR/$rel_path"
  if ml_move_path "$source_file" "$target_path" "archive_source" "archive source file"; then
    (( CONVERT_ARCHIVE_COUNT++ ))
  else
    (( CONVERT_SKIP_COUNT++ ))
  fi
}

convert_find_release_source_files() {
  local release_dir="$1"
  convert_find_source_files "$release_dir" | LC_ALL=C sort
}

convert_find_loose_source_files() {
  local artist_root="$1"
  find "$artist_root" -mindepth 1 -maxdepth 1 -type f \
    \( -iname '*.flac' -o -iname '*.wav' -o -iname '*.aiff' -o -iname '*.aif' \) |
    LC_ALL=C sort
}

convert_release_stage_dir() {
  local release_dir="$1"
  print -r -- "${release_dir:h}/.${release_dir:t}.convert.$$.tmp"
}

convert_cue_time_to_ffmpeg() {
  local cue_time="$1"
  local total_ms hours minutes seconds frames remaining

  if [[ "$cue_time" =~ '^([0-9]+):([0-9]{2}):([0-9]{2})$' ]]; then
    minutes=$((10#$match[1]))
    seconds=$((10#$match[2]))
    frames=$((10#$match[3]))
    total_ms=$(( (minutes * 60 + seconds) * 1000 + ((frames * 1000 + 37) / 75) ))
    hours=$(( total_ms / 3600000 ))
    remaining=$(( total_ms % 3600000 ))
    minutes=$(( remaining / 60000 ))
    remaining=$(( remaining % 60000 ))
    seconds=$(( remaining / 1000 ))
    frames=$(( remaining % 1000 ))
    printf '%02d:%02d:%02d.%03d' "$hours" "$minutes" "$seconds" "$frames"
  else
    print -r -- "$cue_time"
  fi
}

convert_parse_cue_sheet() {
  local cue_file="$1"

  awk '
    function trim(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }
    function unquote(value) {
      value = trim(value)
      if (value ~ /^"/) {
        sub(/^"/, "", value)
        sub(/"$/, "", value)
      }
      return value
    }
    BEGIN {
      album_artist = ""
      album_title = ""
      album_date = "0000"
      cue_source = ""
      current_track = ""
      track_title = ""
      track_artist = ""
      track_start = ""
    }
    {
      sub(/\r$/, "", $0)
    }
    /^REM[[:space:]]+DATE[[:space:]]+/ {
      line = $0
      sub(/^REM[[:space:]]+DATE[[:space:]]+/, "", line)
      if (match(line, /[0-9]{4}/)) {
        album_date = substr(line, RSTART, RLENGTH)
      }
      next
    }
    /^[[:space:]]*PERFORMER[[:space:]]+/ {
      line = $0
      sub(/^[[:space:]]*PERFORMER[[:space:]]+/, "", line)
      line = unquote(line)
      if (current_track == "") {
        album_artist = line
      } else {
        track_artist = line
      }
      next
    }
    /^[[:space:]]*TITLE[[:space:]]+/ {
      line = $0
      sub(/^[[:space:]]*TITLE[[:space:]]+/, "", line)
      line = unquote(line)
      if (current_track == "") {
        album_title = line
      } else {
        track_title = line
      }
      next
    }
    /^[[:space:]]*FILE[[:space:]]+/ {
      line = $0
      sub(/^[[:space:]]*FILE[[:space:]]+/, "", line)
      if (match(line, /^"[^"]+"/)) {
        cue_source = substr(line, 2, RLENGTH - 2)
      } else {
        sub(/[[:space:]]+(WAVE|FLAC|MP3|AIFF|AIF|WAV).*$/, "", line)
        cue_source = trim(line)
      }
      next
    }
    /^[[:space:]]*TRACK[[:space:]]+[0-9]+[[:space:]]+AUDIO/ {
      if (current_track != "") {
        print "TRACK\t" current_track "\t" track_start "\t" track_title "\t" track_artist
      }
      line = $0
      sub(/^[[:space:]]*TRACK[[:space:]]+/, "", line)
      sub(/[[:space:]]+AUDIO.*$/, "", line)
      current_track = sprintf("%02d", trim(line) + 0)
      track_title = ""
      track_artist = ""
      track_start = ""
      next
    }
    /^[[:space:]]*INDEX[[:space:]]+01[[:space:]]+/ {
      if (current_track != "") {
        line = $0
        sub(/^[[:space:]]*INDEX[[:space:]]+01[[:space:]]+/, "", line)
        track_start = trim(line)
      }
      next
    }
    END {
      print "META\t" album_artist "\t" album_title "\t" album_date "\t" cue_source
      if (current_track != "") {
        print "TRACK\t" current_track "\t" track_start "\t" track_title "\t" track_artist
      }
    }
  ' "$cue_file"
}

convert_release_track_output_name() {
  local track_num="$1"
  local title="$2"
  local format="$3"

  printf '01-%02d - %s [%s].m4a' "$((10#$track_num))" "$title" "$format"
}

convert_process_temp_output() {
  local temp_file="$1"
  local output_file="$2"
  local source_file="$3"
  local artwork_file="$4"
  local _extracted_art="$5"
  local expect_art="$6"

  if [[ -n "$artwork_file" ]]; then
    convert_inject_cover_art "$temp_file" "$artwork_file" || {
      ml_warn "artwork embedding failed: $source_file"
      (( ! MUSICLIB_DRY_RUN )) && rm -f -- "$temp_file" "$_extracted_art"
      ml_record_event "skip" "$source_file" "$output_file" "artwork embedding failed" "convert"
      (( CONVERT_SKIP_COUNT++ ))
      return 1
    }
  fi

  if ! (( MUSICLIB_DRY_RUN )); then
    if ! convert_verify_output "$temp_file" "$expect_art"; then
      ml_warn "verification failed for converted file: $source_file"
      rm -f -- "$temp_file" "$_extracted_art"
      ml_record_event "skip" "$source_file" "$output_file" "verification failed" "convert"
      (( CONVERT_SKIP_COUNT++ ))
      return 1
    fi
  fi

  ml_record_event "convert" "$source_file" "$output_file" "created alac output" ""
  (( CONVERT_CREATED_COUNT++ ))
  return 0
}

convert_prepare_release_artwork() {
  local source_file="$1"
  local release_dir="$2"
  local temp_dir="$3"
  local artwork_file="" extracted_art="" expect_art=0

  artwork_file="$(convert_find_artwork_file "$source_file" "$release_dir" || true)"
  if [[ -n "$artwork_file" ]]; then
    expect_art=1
  elif convert_source_has_embedded_art "$source_file"; then
    expect_art=1
    extracted_art="$(convert_extract_embedded_artwork "$source_file" "$temp_dir" || true)"
    artwork_file="$extracted_art"
  fi

  print -r -- "$expect_art"$'\t'"$artwork_file"$'\t'"$extracted_art"
}

convert_stage_regular_release() {
  local release_dir="$1"
  local stage_dir="$2"
  local -a source_files
  local source_file rel_path output_rel output_file temp_file art_info
  local expect_art artwork_file extracted_art

  source_files=("${(@f)$(convert_find_release_source_files "$release_dir")}")
  (( ${#source_files[@]} > 0 )) || return 1

  (( ! MUSICLIB_DRY_RUN )) && mkdir -p -- "$stage_dir"

  for source_file in "${source_files[@]}"; do
    [[ -e "$source_file" ]] || continue
    rel_path="${source_file#$release_dir/}"
    output_rel="${rel_path:r}.m4a"
    output_file="$release_dir/$output_rel"
    temp_file="$stage_dir/$output_rel"

    art_info="$(convert_prepare_release_artwork "$source_file" "$release_dir" "$stage_dir")"
    expect_art="${art_info%%$'\t'*}"
    artwork_file="${${art_info#*$'\t'}%%$'\t'*}"
    extracted_art="${art_info##*$'\t'}"

    if (( MUSICLIB_DRY_RUN )); then
      if [[ -n "$artwork_file" ]]; then
        ml_log "convert: $source_file -> $output_file (art: $artwork_file)"
      else
        ml_log "convert: $source_file -> $output_file"
      fi
    fi

    (( ! MUSICLIB_DRY_RUN )) && mkdir -p -- "${temp_file:h}"
    convert_audio_only "$source_file" "$temp_file" || {
      ml_warn "conversion failed: $source_file"
      (( ! MUSICLIB_DRY_RUN )) && rm -f -- "$temp_file" "$extracted_art"
      ml_record_event "skip" "$source_file" "$output_file" "conversion failed" "convert"
      (( CONVERT_SKIP_COUNT++ ))
      return 1
    }

    convert_process_temp_output "$temp_file" "$output_file" "$source_file" "$artwork_file" "$extracted_art" "$expect_art" || return 1
    if (( ! MUSICLIB_DRY_RUN )) && [[ -n "$extracted_art" ]]; then
      rm -f -- "$extracted_art"
    fi
  done

  return 0
}

convert_stage_cue_release() {
  local release_dir="$1"
  local source_file="$2"
  local cue_file="$3"
  local stage_dir="$4"
  local -a cue_lines track_numbers track_starts track_titles track_artists
  local line kind track_num track_start track_title track_artist
  local album_artist="" album_title="" album_date="0000" cue_source=""
  local total_tracks format art_info expect_art artwork_file extracted_art
  local start_time end_time output_name output_file temp_file track_artist_value track_meta

  cue_lines=("${(@f)$(convert_parse_cue_sheet "$cue_file")}")
  for line in "${cue_lines[@]}"; do
    kind="${line%%$'\t'*}"
    case "$kind" in
      META)
        line="${line#*$'\t'}"
        album_artist="${line%%$'\t'*}"
        line="${line#*$'\t'}"
        album_title="${line%%$'\t'*}"
        line="${line#*$'\t'}"
        album_date="${line%%$'\t'*}"
        cue_source="${line##*$'\t'}"
        ;;
      TRACK)
        line="${line#*$'\t'}"
        track_num="${line%%$'\t'*}"
        line="${line#*$'\t'}"
        track_start="${line%%$'\t'*}"
        line="${line#*$'\t'}"
        track_title="${line%%$'\t'*}"
        track_artist="${line##*$'\t'}"
        track_numbers+=("$track_num")
        track_starts+=("$track_start")
        track_titles+=("$track_title")
        track_artists+=("$track_artist")
        ;;
    esac
  done

  total_tracks=${#track_numbers[@]}
  (( total_tracks > 0 )) || return 1
  format="$(ml_probe_format "$source_file")"
  [[ "$album_date" == "0000" ]] && album_date="$(ml_infer_year "${source_file:t}" "")"
  album_artist="$(ml_sanitize_name "${album_artist:-$(ml_primary_artist_from_file "$source_file")}")"
  album_title="$(ml_sanitize_name "${album_title:-$(ml_release_album_name "$release_dir")}")"

  (( ! MUSICLIB_DRY_RUN )) && mkdir -p -- "$stage_dir"
  art_info="$(convert_prepare_release_artwork "$source_file" "$release_dir" "$stage_dir")"
  expect_art="${art_info%%$'\t'*}"
  artwork_file="${${art_info#*$'\t'}%%$'\t'*}"
  extracted_art="${art_info##*$'\t'}"

  for (( idx = 1; idx <= total_tracks; idx++ )); do
    track_num="${track_numbers[idx]}"
    track_title="$(ml_cleanup_display_title "${track_titles[idx]}" "${track_artists[idx]:-$album_artist}" "$album_date")"
    track_artist_value="$(ml_sanitize_name "${track_artists[idx]:-$album_artist}")"
    start_time="$(convert_cue_time_to_ffmpeg "${track_starts[idx]}")"
    if (( idx < total_tracks )); then
      end_time="$(convert_cue_time_to_ffmpeg "${track_starts[idx + 1]}")"
    else
      end_time=""
    fi

    output_name="$(convert_release_track_output_name "$track_num" "$track_title" "$format")"
    output_file="$release_dir/$output_name"
    temp_file="$stage_dir/$output_name"
    track_meta="$((10#$track_num))/$total_tracks"

    if (( MUSICLIB_DRY_RUN )); then
      ml_log "split+convert: $source_file -> $output_file"
    fi

    convert_audio_segment "$source_file" "$temp_file" "$start_time" "$end_time" "$track_artist_value" "$album_artist" "$album_title" "$track_title" "$track_meta" "1/1" "$album_date" || {
      ml_warn "cue split conversion failed: $source_file"
      (( ! MUSICLIB_DRY_RUN )) && rm -rf -- "$stage_dir" "$extracted_art"
      ml_record_event "skip" "$source_file" "$output_file" "cue split conversion failed" "convert"
      (( CONVERT_SKIP_COUNT++ ))
      return 1
    }

    convert_process_temp_output "$temp_file" "$output_file" "$source_file" "$artwork_file" "$extracted_art" "$expect_art" || return 1
  done

  if (( ! MUSICLIB_DRY_RUN )) && [[ -n "$extracted_art" ]]; then
    rm -f -- "$extracted_art"
  fi

  return 0
}

convert_install_staged_release() {
  local release_dir="$1"
  local stage_dir="$2"
  local archive_dir="$3"
  local stage_state_dir stage_runs_dir stage_log_file stage_manifest_file

  if (( MUSICLIB_DRY_RUN )); then
    ml_log "mv: $release_dir -> $archive_dir"
    ml_log "mv: $stage_dir -> $release_dir"
    (( CONVERT_ARCHIVE_COUNT++ ))
    return 0
  fi

  if (( MUSICLIB_RUN_ACTIVE )) && [[ "${MUSICLIB_TARGET_ROOT:A}" == "${release_dir:A}" ]]; then
    stage_state_dir="$stage_dir/$STATE_DIR_NAME"
    stage_runs_dir="$stage_state_dir/runs"
    stage_log_file="$stage_runs_dir/$MUSICLIB_RUN_ID.log"
    stage_manifest_file="$stage_runs_dir/$MUSICLIB_RUN_ID.jsonl"
    mkdir -p -- "$stage_runs_dir" "$stage_state_dir/trash/$MUSICLIB_RUN_ID"
    [[ -f "$MUSICLIB_LOG_FILE" ]] && cp "$MUSICLIB_LOG_FILE" "$stage_log_file"
    [[ -f "$MUSICLIB_MANIFEST_FILE" ]] && cp "$MUSICLIB_MANIFEST_FILE" "$stage_manifest_file"
    MUSICLIB_STATE_DIR="$stage_state_dir"
    MUSICLIB_RUNS_DIR="$stage_runs_dir"
    MUSICLIB_TRASH_DIR="$stage_state_dir/trash/$MUSICLIB_RUN_ID"
    MUSICLIB_LOG_FILE="$stage_log_file"
    MUSICLIB_MANIFEST_FILE="$stage_manifest_file"
  fi

  if ! ml_move_path "$release_dir" "$archive_dir" "archive_source" "archive original release"; then
    if (( MUSICLIB_RUN_ACTIVE )) && [[ "${MUSICLIB_TARGET_ROOT:A}" == "${release_dir:A}" ]]; then
      MUSICLIB_STATE_DIR="$release_dir/$STATE_DIR_NAME"
      MUSICLIB_RUNS_DIR="$MUSICLIB_STATE_DIR/runs"
      MUSICLIB_TRASH_DIR="$MUSICLIB_STATE_DIR/trash/$MUSICLIB_RUN_ID"
      MUSICLIB_LOG_FILE="$MUSICLIB_RUNS_DIR/$MUSICLIB_RUN_ID.log"
      MUSICLIB_MANIFEST_FILE="$MUSICLIB_RUNS_DIR/$MUSICLIB_RUN_ID.jsonl"
    fi
    rm -rf -- "$stage_dir"
    (( CONVERT_SKIP_COUNT++ ))
    return 1
  fi
  (( CONVERT_ARCHIVE_COUNT++ ))

  if ! mv -- "$stage_dir" "$release_dir"; then
    ml_warn "failed to install converted release: $release_dir"
    [[ -d "$archive_dir" && ! -e "$release_dir" ]] && mv -- "$archive_dir" "$release_dir"
    if (( MUSICLIB_RUN_ACTIVE )) && [[ "${MUSICLIB_TARGET_ROOT:A}" == "${release_dir:A}" ]]; then
      MUSICLIB_STATE_DIR="$release_dir/$STATE_DIR_NAME"
      MUSICLIB_RUNS_DIR="$MUSICLIB_STATE_DIR/runs"
      MUSICLIB_TRASH_DIR="$MUSICLIB_STATE_DIR/trash/$MUSICLIB_RUN_ID"
      MUSICLIB_LOG_FILE="$MUSICLIB_RUNS_DIR/$MUSICLIB_RUN_ID.log"
      MUSICLIB_MANIFEST_FILE="$MUSICLIB_RUNS_DIR/$MUSICLIB_RUN_ID.jsonl"
    fi
    return 1
  fi

  if (( MUSICLIB_RUN_ACTIVE )) && [[ "${MUSICLIB_TARGET_ROOT:A}" == "${release_dir:A}" ]]; then
    MUSICLIB_STATE_DIR="$release_dir/$STATE_DIR_NAME"
    MUSICLIB_RUNS_DIR="$MUSICLIB_STATE_DIR/runs"
    MUSICLIB_TRASH_DIR="$MUSICLIB_STATE_DIR/trash/$MUSICLIB_RUN_ID"
    MUSICLIB_LOG_FILE="$MUSICLIB_RUNS_DIR/$MUSICLIB_RUN_ID.log"
    MUSICLIB_MANIFEST_FILE="$MUSICLIB_RUNS_DIR/$MUSICLIB_RUN_ID.jsonl"
  fi

  return 0
}

convert_release_dir() {
  local release_dir="$1"
  local archive_root="$2"
  local cue_file stage_dir archive_dir
  local -a source_files

  source_files=("${(@f)$(convert_find_release_source_files "$release_dir")}")
  (( ${#source_files[@]} > 0 )) || return 0

  stage_dir="$(convert_release_stage_dir "$release_dir")"
  archive_dir="$archive_root/$SOURCE_ARCHIVE_DIR/${release_dir:t}"

  if [[ -e "$archive_dir" ]]; then
    ml_warn "conflict: archived release already exists: $archive_dir"
    ml_record_event "skip" "$release_dir" "$archive_dir" "archived release already exists" "convert_release"
    (( CONVERT_SKIP_COUNT++ ))
    return 0
  fi

  cue_file="$(ml_release_cue_file "$release_dir")"
  if [[ -n "$cue_file" && ${#source_files[@]} == 1 ]]; then
    convert_stage_cue_release "$release_dir" "$source_files[1]" "$cue_file" "$stage_dir" || {
      (( ! MUSICLIB_DRY_RUN )) && rm -rf -- "$stage_dir"
      return 0
    }
  else
    convert_stage_regular_release "$release_dir" "$stage_dir" || {
      (( ! MUSICLIB_DRY_RUN )) && rm -rf -- "$stage_dir"
      return 0
    }
  fi

  convert_install_staged_release "$release_dir" "$stage_dir" "$archive_dir" || return 0
}

convert_loose_source_file() {
  local source_file="$1"
  local artist_root="$2"
  local output_file temp_file artwork_file="" extracted_art="" expect_art=0

  output_file="${$(ml_loose_track_target_path "$source_file" "$artist_root"):r}.m4a"
  temp_file="${output_file:h}/.${output_file:t:r}.tmp.$$.m4a"

  artwork_file="$(convert_find_artwork_file "$source_file" "$artist_root" || true)"
  if [[ -n "$artwork_file" ]]; then
    expect_art=1
  elif convert_source_has_embedded_art "$source_file"; then
    expect_art=1
  fi

  if [[ -e "$output_file" && ! -f "$output_file" ]]; then
    ml_warn "target exists and is not a file: $output_file"
    ml_record_event "skip" "$source_file" "$output_file" "target exists and is not a file" "convert"
    (( CONVERT_SKIP_COUNT++ ))
    return 0
  fi

  if [[ -f "$output_file" ]]; then
    if convert_verify_output "$output_file" "$expect_art"; then
      ml_log "skip: already converted $output_file"
      ml_record_event "skip" "$source_file" "$output_file" "already converted" "convert"
      convert_archive_source "$source_file" "$artist_root"
      (( CONVERT_SKIP_COUNT++ ))
      return 0
    fi

    ml_warn "conflict: existing output blocks conversion: $output_file"
    ml_record_event "skip" "$source_file" "$output_file" "existing output blocks conversion" "convert"
    (( CONVERT_SKIP_COUNT++ ))
    return 0
  fi

  if (( MUSICLIB_DRY_RUN )); then
    if [[ -n "$artwork_file" ]]; then
      ml_log "convert: $source_file -> $output_file (art: $artwork_file)"
    else
      ml_log "convert: $source_file -> $output_file"
    fi
  fi

  convert_audio_only "$source_file" "$temp_file" || {
    ml_warn "conversion failed: $source_file"
    (( ! MUSICLIB_DRY_RUN )) && rm -f -- "$temp_file"
    ml_record_event "skip" "$source_file" "$output_file" "conversion failed" "convert"
    (( CONVERT_SKIP_COUNT++ ))
    return 0
  }

  if [[ -z "$artwork_file" ]] && (( expect_art )); then
    extracted_art="$(convert_extract_embedded_artwork "$source_file" "${temp_file:h}" || true)"
    artwork_file="$extracted_art"
  fi

  convert_process_temp_output "$temp_file" "$output_file" "$source_file" "$artwork_file" "$extracted_art" "$expect_art" || return 0

  if (( ! MUSICLIB_DRY_RUN )); then
    if ! mv -- "$temp_file" "$output_file"; then
      ml_warn "failed to install converted file: $output_file"
      rm -f -- "$temp_file" "$extracted_art"
      (( CONVERT_SKIP_COUNT++ ))
      return 0
    fi
    [[ -n "$extracted_art" ]] && rm -f -- "$extracted_art"
  fi

  convert_archive_source "$source_file" "$artist_root"
}

convert_artist_root() {
  local artist_root="$1"
  local -a release_dirs loose_sources
  local dir source_file

  release_dirs=("${(@f)$(find "$artist_root" -mindepth 1 -maxdepth 1 -type d ! -name '.*' ! -name "$SOURCE_ARCHIVE_DIR" ! -name "$STATE_DIR_NAME" | LC_ALL=C sort)}")
  for dir in "${release_dirs[@]}"; do
    [[ -d "$dir" ]] || continue
    [[ "$(ml_dir_kind "$dir")" == "release" ]] || continue
    convert_release_dir "$dir" "$artist_root"
  done

  loose_sources=("${(@f)$(convert_find_loose_source_files "$artist_root")}")
  for source_file in "${loose_sources[@]}"; do
    [[ -f "$source_file" ]] || continue
    convert_loose_source_file "$source_file" "$artist_root"
  done

  ml_cleanup_empty_dirs "$artist_root"
}

convert_music_main() {
  local root_dir="."
  local arg
  local own_run=0
  local root_type

  # Reset per-run globals so direct calls and wrapper-driven calls behave the
  # same way.
  MUSICLIB_DRY_RUN=0
  CONVERT_CREATED_COUNT=0
  CONVERT_ARCHIVE_COUNT=0
  CONVERT_SKIP_COUNT=0

  while (( $# )); do
    arg="$1"
    case "$arg" in
      --dry-run)
        MUSICLIB_DRY_RUN=1
        ;;
      -h|--help)
        convert_music_usage
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

  ml_need_cmd ffmpeg
  ml_need_cmd ffprobe
  ml_need_cmd exiftool
  ml_need_cmd find
  ml_need_cmd sed
  ml_need_cmd awk

  [[ -d "$root_dir" ]] || { ml_die "directory not found: $root_dir"; return 1; }
  root_dir="${root_dir:A}"

  # Reuse the wrapper's run when available; otherwise create a standalone one
  # so direct usage still leaves behind useful logs and manifests.
  if (( ! MUSICLIB_RUN_ACTIVE )); then
    own_run=1
    ml_start_run "convert" "$root_dir" $(( ! MUSICLIB_DRY_RUN ))
  fi

  root_type="$(ml_classify_root "$root_dir")"
  if [[ "$root_type" == "release_root" ]]; then
    convert_release_dir "$root_dir" "${root_dir:h}"
  else
    convert_artist_root "$root_dir"
  fi

  if (( own_run )); then
    ml_finish_run "success" "Done. converted=$CONVERT_CREATED_COUNT archived=$CONVERT_ARCHIVE_COUNT skipped=$CONVERT_SKIP_COUNT"
    if (( MUSICLIB_DRY_RUN )); then
      ml_log "Dry run only. No filesystem changes were made."
    fi
    MUSICLIB_RUN_ACTIVE=0
  fi
}

if [[ -z "${MUSICLIB_SOURCE_ONLY:-}" && "${ZSH_EVAL_CONTEXT:-}" == "toplevel" ]]; then
  convert_music_main "$@"
fi
