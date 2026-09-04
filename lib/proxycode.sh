#!/usr/bin/env bash

PROXYCODE_VERSION=1.0.0

proxycode_init_paths() {
  if [[ ${HOME:-} != /* || $HOME == / ]]; then
    printf 'proxycode: HOME must be an absolute user directory\n' >&2
    return 1
  fi

  PROXYCODE_BIN_DIR=$HOME/.local/bin
  PROXYCODE_CONFIG_DIR=$(proxycode_xdg_path "${XDG_CONFIG_HOME:-}" "$HOME/.config")/proxycode
  PROXYCODE_DATA_DIR=$(proxycode_xdg_path "${XDG_DATA_HOME:-}" "$HOME/.local/share")/proxycode
  PROXYCODE_STATE_DIR=$(proxycode_xdg_path "${XDG_STATE_HOME:-}" "$HOME/.local/state")/proxycode
  if [[ ${XDG_RUNTIME_DIR:-} == /* && $XDG_RUNTIME_DIR != / ]]; then
    PROXYCODE_RUNTIME_DIR=$XDG_RUNTIME_DIR/proxycode
  else
    PROXYCODE_RUNTIME_DIR=$PROXYCODE_STATE_DIR
  fi
}

proxycode_xdg_path() {
  if [[ $1 == /* && $1 != / ]]; then
    printf '%s' "$1"
  else
    printf '%s' "$2"
  fi
}

proxycode_help() {
  cat <<'EOF'
Usage:
  proxycode
  proxycode [--profile NAME] COMMAND [ARG...]
  proxycode help|version|status|check|start|stop|switch|profile|settings|upgrade ...

Commands:
  help                       Show this help
  version                    Show the installed version
  status                     Show local Toolkit state
  check                      Check the Active Tunnel Profile
  start [NAME]               Start a Tunnel Profile
  stop                       Stop the Active Tunnel Profile
  switch NAME [--yes]        Switch the Active Tunnel Profile
  profile ...                Manage Tunnel Profiles
  settings ...               Manage listener settings
  upgrade [--yes]            Upgrade the Toolkit
EOF
}
