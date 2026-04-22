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
    removed="$(ml_cleanup_all_empty_dirs "$target")"
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

cleanup_music_collect_audio() {
  local target="$1"
  local file base dst bucket bucket_name bucket_label collect_root
  local dir
  local collected_count=0 non_audio_count=0 removed_dirs=0
  local -A bucket_counts=()

  ml_log_scope "audio-scrape" "$target"

  if (( ! musicpipeline_DRY_RUN )); then
    ml_start_run "audio-scrape" "$target" 1
  fi

  while IFS= read -r file; do
    [[ -f "$file" ]] || continue
    ml_path_has_hidden_or_state_segment "$file" "$target" && continue
    if bucket="$(ml_audio_collection_bucket_name "$file")"; then
      collect_root="$target/_$bucket"
      base="${file:t}"
      dst="$collect_root/$base"
      dst="$(ml_unique_destination_path "$dst")"
      if ml_move_path "$file" "$dst" "collect_audio" "collect audio to root bucket _$bucket"; then
        if (( ! MUSICLIB_DRY_RUN )); then
          ml_log_step "audio-scrape" "$(ml_display_path "$file") -> $(ml_display_path "$dst")"
        fi
        (( collected_count++ ))
        bucket_counts["$bucket"]=$(( ${bucket_counts["$bucket"]:-0} + 1 ))
      fi
      continue
    fi

    dst="$(ml_not_audio_target_path "$file" "$target")" || continue
    if ml_move_path "$file" "$dst" "collect_audio" "collect non-audio to root not-audio bucket"; then
      if (( ! MUSICLIB_DRY_RUN )); then
        ml_log_step "audio-scrape" "$(ml_display_path "$file") -> $(ml_display_path "$dst")"
      fi
      (( non_audio_count++ ))
    fi
  done < <(find "$target" -type f -print | LC_ALL=C sort)

  if (( musicpipeline_DRY_RUN )); then
    while IFS= read -r dir; do
      [[ -n "$dir" ]] || continue
      ml_path_has_hidden_or_state_segment "$dir" "$target" && continue
      ml_log_step "rmdir" "$(ml_display_path "$dir")"
      (( removed_dirs++ ))
    done < <(find "$target" -depth -mindepth 1 -type d -empty | LC_ALL=C sort)
  else
    while IFS= read -r dir; do
      [[ -n "$dir" ]] || continue
      ml_path_has_hidden_or_state_segment "$dir" "$target" && continue
      if rmdir -- "$dir" 2>/dev/null; then
        ml_log_step "rmdir" "$(ml_display_path "$dir")"
        ml_record_event "cleanup_empty_dir" "" "$dir" "remove empty directory" ""
        (( removed_dirs++ ))
      fi
    done < <(find "$target" -depth -mindepth 1 -type d -empty | LC_ALL=C sort)
  fi

  ml_log ""
  ml_log "Audio collection summary:"
  ml_log "  audio files moved:   $collected_count"
  if (( ${#bucket_counts[@]} > 0 )); then
    for bucket_name in ${(k)bucket_counts}; do
      bucket_label="${bucket_name//\"/}"
      ml_log "  bucket _${bucket_label}: ${bucket_counts[$bucket_name]}"
    done
  fi
  ml_log "  non-audio moved:     $non_audio_count"
  ml_log "  empty dirs removed:  $removed_dirs"

  if (( musicpipeline_DRY_RUN )); then
    ml_log "Dry run only. No filesystem changes were made."
    ml_log "audio files collected=$collected_count"
    ml_log "non-audio files moved=$non_audio_count"
    ml_log "empty directories found=$removed_dirs"
    return 0
  fi

  ml_finish_run "success" "Audio collection complete. audio_moved=$collected_count non_audio_moved=$non_audio_count empty_dirs_removed=$removed_dirs"
  MUSICLIB_RUN_ACTIVE=0
  return 0
}

cleanup_music_collect_mp3() {
  cleanup_music_collect_audio "$@"
}

cleanup_music_dedup() {
  local target="$1"
  local file hash size key dst kept duplicate_count=0
  local -A first_by_key=()
  local -a summary_lines=()

  ml_need_cmd shasum
  ml_log_scope "dedup" "$target"

  if (( ! musicpipeline_DRY_RUN )); then
    ml_start_run "dedup" "$target" 1
  fi

  while IFS= read -r file; do
    [[ -f "$file" ]] || continue
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

  if (( duplicate_count > 0 )); then
    ml_log ""
    ml_log "duplicates moved:"
    for file in "${summary_lines[@]}"; do
      ml_log "  - $file"
    done
  fi

  if (( musicpipeline_DRY_RUN )); then
    ml_log "Dry run only. No filesystem changes were made."
    ml_log "duplicates found=$duplicate_count"
    return 0
  fi

  ml_cleanup_empty_dirs "$target"
  ml_finish_run "success" "Dedup complete. moved=$duplicate_count"
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
