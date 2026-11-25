#!/bin/bash
# Launcher for T3 Code.
#
# Electron does not always pick a Wayland backend on its own. When a Wayland
# session is detected, request the Wayland backend explicitly unless
# overridden on the command line or in the flags file (or when invoked as a
# Node runtime via ELECTRON_RUN_AS_NODE).
#
# Extra flags can be placed in $XDG_CONFIG_HOME/t3code-flags.conf
# (default ~/.config/t3code-flags.conf), one or more per line, with '#'
# starting a comment.
set -euo pipefail

if [[ -n ${ELECTRON_RUN_AS_NODE:-} ]]; then
  exec /usr/lib/t3code/t3code "$@"
fi

flags=()
conf="${XDG_CONFIG_HOME:-${HOME:-}/.config}/t3code-flags.conf"
if [[ -r $conf ]]; then
  while IFS= read -r line || [[ -n $line ]]; do
    line="${line%%#*}"
    [[ -n ${line//[[:space:]]/} ]] || continue
    read -r -a words <<<"$line"
    flags+=("${words[@]}")
  done <"$conf"
fi

platform=()
if [[ -n ${WAYLAND_DISPLAY:-} || ${XDG_SESSION_TYPE:-} == wayland ]]; then
  platform=(--ozone-platform=wayland)
  for f in "${flags[@]}" "$@"; do
    case $f in
      --ozone-platform=* | --ozone-platform-hint=*) platform=() ;;
    esac
  done
fi

exec /usr/lib/t3code/t3code "${platform[@]}" "${flags[@]}" "$@"
