#!/usr/bin/env zsh
#
# musicpipeline.zsh
# Sourceable zsh shim for the Python MusicPipeline CLI.

typeset -g MUSICPIPELINE_REPO_ROOT="${${(%):-%x}:A:h}"

_musicpipeline_python() {
  emulate -L zsh
  setopt pipe_fail no_unset

  local repo_root="${MUSICPIPELINE_REPO_ROOT:-${${(%):-%x}:A:h}}"
  local cwd="$PWD"
  local command_name=""
  local saw_root_flag=0
  local saw_help_flag=0
  local positional_root=""
  local audio_scrape_source=""
  local output_root=""
  local -a translated=()

  if (( $# == 0 )); then
    PYTHONPATH="$repo_root${PYTHONPATH:+:$PYTHONPATH}" command python3 -m musicpipeline --help
    return $?
  fi

  command_name="$1"
  shift

  case "$command_name" in
    audit|sort|convert|both|delete-empty-dirs|delete-source|undo|retag|retag-apply)
      while (( $# )); do
        case "$1" in
          --root)
            saw_root_flag=1
            translated+=("$1")
            shift
            (( $# )) || { print -ru2 -- "error: --root requires a directory argument"; return 1; }
            translated+=("$1")
            ;;
          -h|--help)
            saw_help_flag=1
            translated+=("$1")
            ;;
          --dry-run|--yes|--run-id|--provider|--manifest|--acoustid-client)
            translated+=("$1")
            if [[ "$1" == "--run-id" || "$1" == "--provider" || "$1" == "--manifest" || "$1" == "--acoustid-client" ]]; then
              shift
              (( $# )) || { print -ru2 -- "error: $translated[-1] requires an argument"; return 1; }
              translated+=("$1")
            fi
            ;;
          --)
            ;;
          -*)
            translated+=("$1")
            ;;
          *)
            if [[ -z "$positional_root" ]]; then
              positional_root="$1"
            else
              translated+=("$1")
            fi
            ;;
        esac
        shift
      done
      if (( ! saw_root_flag && ! saw_help_flag )); then
        translated+=(--root "${positional_root:-$cwd}")
      elif [[ -n "$positional_root" ]]; then
        translated+=("$positional_root")
      fi
      ;;
    audio-scrape)
      while (( $# )); do
        case "$1" in
          --destination)
            saw_root_flag=1
            translated+=("$1")
            shift
            (( $# )) || { print -ru2 -- "error: --destination requires a directory argument"; return 1; }
            translated+=("$1")
            ;;
          --root)
            saw_root_flag=1
            translated+=(--destination)
            shift
            (( $# )) || { print -ru2 -- "error: --root requires a directory argument"; return 1; }
            translated+=("$1")
            ;;
          --output)
            shift
            (( $# )) || { print -ru2 -- "error: --output requires a directory argument"; return 1; }
            output_root="$1"
            ;;
          -h|--help)
            saw_help_flag=1
            translated+=("$1")
            ;;
          --dry-run|--move|--bucket-by-format)
            translated+=("$1")
            ;;
          --)
            ;;
          -*)
            translated+=("$1")
            ;;
          *)
            if [[ -z "$audio_scrape_source" ]]; then
              audio_scrape_source="$1"
            else
              translated+=("$1")
            fi
            ;;
        esac
        shift
      done
      if [[ -n "$output_root" && ! "$translated[*]" == *"--destination"* ]]; then
        translated+=(--destination "$output_root")
      elif (( ! saw_root_flag && ! saw_help_flag )); then
        translated+=(--destination "$cwd")
      fi
      if [[ -n "$audio_scrape_source" ]]; then
        translated+=("$audio_scrape_source")
      fi
      ;;
    *)
      print -ru2 -- "error: unsupported command: $command_name"
      PYTHONPATH="$repo_root${PYTHONPATH:+:$PYTHONPATH}" command python3 -m musicpipeline --help
      return 1
      ;;
  esac

  PYTHONPATH="$repo_root${PYTHONPATH:+:$PYTHONPATH}" command python3 -m musicpipeline "$command_name" "${translated[@]}"
}

musicpipeline() {
  _musicpipeline_python "$@"
}

if [[ "${ZSH_EVAL_CONTEXT:-}" == "toplevel" ]]; then
  musicpipeline "$@"
fi
