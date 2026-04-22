#!/usr/bin/env zsh
#
# cleanup_music.zsh
# Purpose: Cleanup and deduplication commands for musicpipeline.

cleanup_music_delete_source() {
  local target="$1"
  local root_type="$2"
  local confirm_phrase="DELETE $SOURCE_ARCHIVE_DIR"
  local reply=""
  local -a archive_dirs
  local dir count=0 total_bytes=0 bytes

  case "$root_type" in
    archive_lossless|archive_lossy|batch_root|artist_root)
      ;;
    *)
      ml_die "delete-source requires an archive root, batch root, or artist root"
      return 1
      ;;
  esac

  archive_dirs=("${(@f)$(ml_find_source_archive_dirs "$target")}")
  if (( ${#archive_dirs[@]} == 0 )); then
    ml_log_scope "delete-source" "$target"
    ml_log "No $SOURCE_ARCHIVE_DIR directories found."
    return 0
  fi

  ml_log_scope "delete-source" "$target"
  ml_log "This permanently deletes archived source material."
  ml_log ""

  for dir in "${archive_dirs[@]}"; do
    [[ -d "$dir" ]] || continue
    bytes="$(ml_archive_dir_bytes "$dir")"
    (( count++ ))
    (( total_bytes += bytes ))
    ml_log "  - $(ml_display_path "$dir") ($(ml_human_bytes "$bytes"))"
  done

  ml_log ""
  ml_log "folders: $count"
  ml_log "size:    $(ml_human_bytes "$total_bytes")"

  if (( musicpipeline_DRY_RUN )); then
    ml_log ""
    ml_log "Dry run only. No filesystem changes were made."
    return 0
  fi

  [[ -t 0 ]] || {
    ml_die "delete-source requires an interactive terminal confirmation"
    return 1
  }

  ml_log ""
  print -r -- "Type exactly: $confirm_phrase"
  read "reply?Confirm: "
  if [[ "$reply" != "$confirm_phrase" ]]; then
    ml_die "confirmation did not match; aborting delete-source"
    return 1
  fi

  ml_start_run "delete-source" "$target" 1
  ml_record_event "root_type" "$target" "" "$root_type" ""

  for dir in "${archive_dirs[@]}"; do
    [[ -d "$dir" ]] || continue
    ml_log_step "delete" "$(ml_display_path "$dir")"
    rm -rf -- "$dir"
    ml_record_event "cleanup_originals" "$dir" "" "delete archived source tree" ""
  done

  ml_cleanup_empty_dirs "$target"
  ml_finish_run "success" "Cleanup complete. deleted=$count size=$(ml_human_bytes "$total_bytes")"
  MUSICLIB_RUN_ACTIVE=0
  return 0
}

cleanup_music_delete_empty_dirs() {
  local target="$1"
  local removed dir

  ml_log_scope "delete-empty-dirs" "$target"

  if (( ! musicpipeline_DRY_RUN )); then
    ml_start_run "delete-empty-dirs" "$target" 1
  fi

  if whence -w ml_cleanup_all_empty_dirs >/dev/null 2>&1; then
    ml_cleanup_all_empty_dirs "$target"
    removed="$MUSICLIB_LAST_EMPTY_DIR_CLEANUP_COUNT"
  else
    removed=0
    if (( MUSICLIB_DRY_RUN )); then
      while IFS= read -r dir; do
        [[ -n "$dir" ]] || continue
        ml_log_step "rmdir" "$(ml_display_path "$dir")"
        (( removed++ ))
      done < <(find "$target" -depth -mindepth 1 -type d -empty | LC_ALL=C sort)
    else
      while IFS= read -r dir; do
        [[ -n "$dir" ]] || continue
        if rmdir -- "$dir" 2>/dev/null; then
          ml_log_step "rmdir" "$(ml_display_path "$dir")"
          ml_record_event "cleanup_empty_dir" "" "$dir" "remove empty directory" ""
          (( removed++ ))
        fi
      done < <(find "$target" -depth -mindepth 1 -type d -empty | LC_ALL=C sort)
    fi
  fi

  if (( musicpipeline_DRY_RUN )); then
    ml_log "Dry run only. No filesystem changes were made."
    ml_log "empty directories found=$removed"
    return 0
  fi

  ml_finish_run "success" "Cleanup complete. removed=$removed"
  MUSICLIB_RUN_ACTIVE=0
  return 0
}

cleanup_music_delete_state_dirs() {
  local target="$1"
  local confirm_phrase="DELETE STATE DIRS"
  local reply=""
  local dir count=0 total_bytes=0 bytes
  local -a state_dirs

  state_dirs=("${(@f)$(find "$target" -type d -name "$STATE_DIR_NAME" ! -path '*/.*/*' | LC_ALL=C sort)}")
  if (( ${#state_dirs[@]} == 0 )); then
    ml_log_scope "delete-state-dirs" "$target"
    ml_log "No $STATE_DIR_NAME directories found."
    return 0
  fi

  ml_log_scope "delete-state-dirs" "$target"
  ml_log "This permanently deletes all $STATE_DIR_NAME directories under the target."
  ml_log ""

  for dir in "${state_dirs[@]}"; do
    [[ -d "$dir" ]] || continue
    bytes="$(ml_archive_dir_bytes "$dir")"
    (( count++ ))
    (( total_bytes += bytes ))
    ml_log "  - $(ml_display_path "$dir") ($(ml_human_bytes "$bytes"))"
  done

  ml_log ""
  ml_log "folders: $count"
  ml_log "size:    $(ml_human_bytes "$total_bytes")"

  if (( musicpipeline_DRY_RUN )); then
    ml_log ""
    ml_log "Dry run only. No filesystem changes were made."
    return 0
  fi

  [[ -t 0 ]] || {
    ml_die "delete-state-dirs requires an interactive terminal confirmation"
    return 1
  }

  ml_log ""
  print -r -- "Type exactly: $confirm_phrase"
  read "reply?Confirm: "
  if [[ "$reply" != "$confirm_phrase" ]]; then
    ml_die "confirmation did not match; aborting delete-state-dirs"
    return 1
  fi

  for dir in "${state_dirs[@]}"; do
    [[ -d "$dir" ]] || continue
    ml_log_step "delete" "$(ml_display_path "$dir")"
    rm -rf -- "$dir"
  done

  ml_log "Cleanup complete. deleted=$count size=$(ml_human_bytes "$total_bytes")"
  return 0
}

cleanup_music_collect_audio() {
  local source_root="$1"
  local output_root="$2"
  local move_mode="${3:-1}"
  local state_root="$output_root"
  local action_word="moved"
  local file dst bucket bucket_name bucket_label
  local dir
  local collected_count=0 non_audio_count=0 removed_dirs=0
  local -A bucket_counts=()
  local -a source_files=()

  [[ -n "$source_root" ]] || return 1
  [[ -n "$output_root" ]] || output_root="$source_root"
  (( move_mode )) || action_word="copied"

  ml_log_scope "audio-scrape" "$source_root"
  [[ "${output_root:A}" != "${source_root:A}" ]] && ml_log "output: $(ml_display_path "$output_root")"
  ml_log "mode:   $( (( move_mode )) && print move || print copy )"

  if (( ! musicpipeline_DRY_RUN )); then
    ml_start_run "audio-scrape" "$state_root" 1
    ml_log "source: $(ml_display_path "$source_root")"
    ml_log "output: $(ml_display_path "$output_root")"
  fi

  source_files=("${(@f)$(find "$source_root" -type f | LC_ALL=C sort)}")
  for file in "${source_files[@]}"; do
    [[ -f "$file" ]] || continue
    ml_path_has_hidden_or_state_segment "$file" "$source_root" && continue
    if [[ "${output_root:A}" != "${source_root:A}" && "${file:A}" == "${output_root:A}/"* ]]; then
      continue
    fi

    if bucket="$(ml_audio_collection_bucket_name "$file")"; then
      dst="$(ml_audio_scrape_target_path "$file" "$source_root" "$output_root")"
      if (( move_mode )); then
        ml_move_path "$file" "$dst" "collect_audio" "collect audio to bucket _$bucket" || continue
      else
        ml_copy_file "$file" "$dst" "collect_audio_copy" "copy audio to bucket _$bucket" || continue
      fi
      if (( ! MUSICLIB_DRY_RUN )); then
        ml_log_step "audio-scrape" "$(ml_display_path "$file") -> $(ml_display_path "$dst")"
      fi
      (( collected_count++ ))
      bucket_counts["$bucket"]=$(( ${bucket_counts["$bucket"]:-0} + 1 ))
      continue
    fi

    dst="$(ml_output_not_audio_target_path "$file" "$source_root" "$output_root")" || continue
    if (( move_mode )); then
      ml_move_path "$file" "$dst" "collect_audio" "collect non-audio to _NotAudio" || continue
    else
      ml_copy_file "$file" "$dst" "collect_audio_copy" "copy non-audio to _NotAudio" || continue
    fi
    if (( ! MUSICLIB_DRY_RUN )); then
      ml_log_step "audio-scrape" "$(ml_display_path "$file") -> $(ml_display_path "$dst")"
    fi
    (( non_audio_count++ ))
  done

  if (( move_mode )); then
    ml_cleanup_empty_recoverable_dirs "$source_root"
    removed_dirs="$MUSICLIB_LAST_EMPTY_DIR_CLEANUP_COUNT"
  fi

  ml_log ""
  ml_log "Audio scrape summary:"
  ml_log "  audio files ${action_word}: ${collected_count}"
  if (( ${#bucket_counts[@]} > 0 )); then
    for bucket_name in ${(k)bucket_counts}; do
      bucket_label="${bucket_name//\"/}"
      ml_log "  bucket _${bucket_label}: ${bucket_counts[$bucket_name]}"
    done
  fi
  ml_log "  non-audio ${action_word}:  ${non_audio_count}"
  ml_log "  output root:          $(ml_display_path "$output_root")"
  if (( move_mode )); then
    ml_log "  empty dirs removed:   $removed_dirs"
  fi

  if (( musicpipeline_DRY_RUN )); then
    ml_log "Dry run only. No filesystem changes were made."
    ml_log "audio files processed=$collected_count"
    ml_log "non-audio files processed=$non_audio_count"
    (( move_mode )) && ml_log "empty directories found=$removed_dirs"
    return 0
  fi

  ml_finish_run "success" "Audio scrape complete. audio_${action_word}=$collected_count non_audio_${action_word}=$non_audio_count output=$(ml_display_path "$output_root") empty_dirs_removed=$removed_dirs"
  MUSICLIB_RUN_ACTIVE=0
  return 0
}

cleanup_music_collect_mp3() {
  cleanup_music_collect_audio "$@"
}

cleanup_music_dedup() {
  local target="$1"
  local file hash size key dst kept duplicate_count=0 candidate_count=0
  local pairwise_checks=0
  local -A first_by_key=()
  local -a summary_lines=()

  ml_need_cmd shasum
  ml_log_scope "dedup" "$target"

  if (( ! musicpipeline_DRY_RUN )); then
    ml_start_run "dedup" "$target" 1
  fi

  while IFS= read -r file; do
    [[ -f "$file" ]] || continue
    (( candidate_count++ ))
    size="$(wc -c < "$file" | tr -d '[:space:]')"
    hash="$(shasum -a 256 -- "$file" | awk '{print $1}')"
    [[ -n "$hash" ]] || continue
    key="${size}:${hash}"

    if [[ -z "${first_by_key["$key"]:-}" ]]; then
      first_by_key["$key"]="$file"
      continue
    fi

    kept="${first_by_key["$key"]}"
    dst="$(ml_duplicate_stash_path "$file" "$target")"
    if ml_move_path "$file" "$dst" "dedupe_move" "exact duplicate of $kept"; then
      ml_log_step "dedup" "$(ml_display_path "$file") -> $(ml_display_path "$dst")"
      summary_lines+=("$(ml_display_path "$file") -> $(ml_display_path "$dst") (matched $(ml_display_path "$kept"))")
      (( duplicate_count++ ))
    fi
  done < <(ml_find_dedupe_candidate_files "$target")

  if (( candidate_count > 1 )); then
    pairwise_checks=$(( (candidate_count * (candidate_count - 1)) / 2 ))
  fi

  if (( duplicate_count > 0 )); then
    ml_log ""
    ml_log "duplicates moved:"
    for file in "${summary_lines[@]}"; do
      ml_log "  - $file"
    done
  fi

  ml_log ""
  ml_log "Dedup summary:"
  ml_log "  candidate files:      $candidate_count"
  ml_log "  equivalent checks:    $pairwise_checks"
  ml_log "  duplicates moved:     $duplicate_count"

  if (( musicpipeline_DRY_RUN )); then
    ml_log "Dry run only. No filesystem changes were made."
    ml_log "duplicates found=$duplicate_count"
    return 0
  fi

  ml_cleanup_empty_dirs "$target"
  ml_finish_run "success" "Dedup complete. candidates=$candidate_count equivalent_checks=$pairwise_checks moved=$duplicate_count"
  MUSICLIB_RUN_ACTIVE=0
  return 0
}

cleanup_music_delete_duplicates() {
  local target="$1"
  local state_dir="$target/$STATE_DIR_NAME"
  local duplicates_root="$state_dir/duplicates"
  local runs_dir="$state_dir/runs"
  local last_run_file="$state_dir/last_successful_run"
  local confirm_phrase="DELETE DUPLICATES"
  local reply=""
  local dir run_id manifest_file log_file count=0 total_bytes=0 bytes last_manifest=""
  local -a duplicate_dirs

  duplicate_dirs=("${(@f)$(find "$duplicates_root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | LC_ALL=C sort)}")
  if (( ${#duplicate_dirs[@]} == 0 )); then
    ml_log_scope "dedup-delete" "$target"
    ml_log "No duplicate stash directories found."
    return 0
  fi

  ml_log_scope "dedup-delete" "$target"
  ml_log "This permanently deletes stashed duplicates and their dedup manifests."
  ml_log ""

  for dir in "${duplicate_dirs[@]}"; do
    [[ -d "$dir" ]] || continue
    bytes="$(ml_archive_dir_bytes "$dir")"
    (( count++ ))
    (( total_bytes += bytes ))
    ml_log "  - $(ml_display_path "$dir") ($(ml_human_bytes "$bytes"))"
  done

  ml_log ""
  ml_log "folders: $count"
  ml_log "size:    $(ml_human_bytes "$total_bytes")"

  if (( musicpipeline_DRY_RUN )); then
    ml_log ""
    ml_log "Dry run only. No filesystem changes were made."
    return 0
  fi

  [[ -t 0 ]] || {
    ml_die "dedup-delete requires an interactive terminal confirmation"
    return 1
  }

  ml_log ""
  print -r -- "Type exactly: $confirm_phrase"
  read "reply?Confirm: "
  if [[ "$reply" != "$confirm_phrase" ]]; then
    ml_die "confirmation did not match; aborting dedup-delete"
    return 1
  fi

  ml_start_run "dedup-delete" "$target" 1
  [[ -f "$last_run_file" ]] && last_manifest="$(<"$last_run_file")"

  for dir in "${duplicate_dirs[@]}"; do
    [[ -d "$dir" ]] || continue
    run_id="${dir:t}"
    manifest_file="$runs_dir/$run_id.jsonl"
    log_file="$runs_dir/$run_id.log"

    ml_log_step "delete" "$(ml_display_path "$dir")"
    rm -rf -- "$dir"
    ml_record_event "cleanup_duplicates" "$dir" "" "delete duplicate stash tree" ""

    if [[ -f "$manifest_file" ]]; then
      ml_log_step "delete" "$(ml_display_path "$manifest_file")"
      rm -f -- "$manifest_file"
      ml_record_event "cleanup_duplicates_manifest" "$manifest_file" "" "delete dedup manifest" ""
      if [[ -n "$last_manifest" && "${manifest_file:A}" == "${last_manifest:A}" ]]; then
        rm -f -- "$last_run_file"
        last_manifest=""
        ml_record_event "cleanup_duplicates_last_run" "$last_run_file" "" "clear last successful run pointer" ""
      fi
    fi

    if [[ -f "$log_file" ]]; then
      ml_log_step "delete" "$(ml_display_path "$log_file")"
      rm -f -- "$log_file"
      ml_record_event "cleanup_duplicates_log" "$log_file" "" "delete dedup log" ""
    fi
  done

  ml_cleanup_empty_dirs "$target"
  ml_cleanup_empty_aux_dirs "$target"
  ml_finish_run "success" "Cleanup complete. deleted=$count size=$(ml_human_bytes "$total_bytes")"
  MUSICLIB_RUN_ACTIVE=0
  return 0
}
