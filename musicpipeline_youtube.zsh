#!/usr/bin/env zsh
#
# musicpipeline_youtube.zsh
# Sourceable zsh shim for the Python YouTube downloader helper.

typeset -g MUSICPIPELINE_REPO_ROOT="${${(%):-%x}:A:h}"

_musicpipelineyt_python() {
  emulate -L zsh
  setopt pipe_fail no_unset

  local repo_root="${MUSICPIPELINE_REPO_ROOT:-${${(%):-%x}:A:h}}"
  PYTHONPATH="$repo_root${PYTHONPATH:+:$PYTHONPATH}" command python3 -m musicpipeline.youtube "$@"
}

musicpipelineyt() {
  _musicpipelineyt_python "$@"
}

musiclibyt() {
  _musicpipelineyt_python "$@"
}

if [[ "${ZSH_EVAL_CONTEXT:-}" == "toplevel" ]]; then
  musicpipelineyt "$@"
fi
