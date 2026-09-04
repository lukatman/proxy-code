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

proxycode_error() {
  printf 'proxycode: %s\n' "$1" >&2
  return "${2:-1}"
}

proxycode_write_private() {
  local target=$1 temporary=${1}.new.$$
  if ! cat >"$temporary" || ! chmod 600 "$temporary" || ! mv -f -- "$temporary" "$target"; then
    rm -f -- "$temporary"
    return 1
  fi
}

proxycode_read_setting() {
  awk -F= -v key="$2" '$1 == key { print substr($0, length(key) + 2); exit }' "$1"
}

proxycode_prepare_storage() {
  proxycode_init_paths || return
  mkdir -p "$PROXYCODE_CONFIG_DIR" "$PROXYCODE_DATA_DIR/profiles" || return 1
  chmod 700 "$PROXYCODE_CONFIG_DIR" "$PROXYCODE_DATA_DIR" "$PROXYCODE_DATA_DIR/profiles" || return 1
  if [[ ! -e $PROXYCODE_CONFIG_DIR/settings ]]; then
    proxycode_write_private "$PROXYCODE_CONFIG_DIR/settings" <<'EOF' || return 1
HTTP_PORT=25345
SOCKS_PORT=25344
DEFAULT_PROFILE=
EOF
  fi
}

proxycode_load_global_settings() {
  proxycode_prepare_storage || return
  PROXYCODE_HTTP_PORT=$(proxycode_read_setting "$PROXYCODE_CONFIG_DIR/settings" HTTP_PORT)
  PROXYCODE_SOCKS_PORT=$(proxycode_read_setting "$PROXYCODE_CONFIG_DIR/settings" SOCKS_PORT)
  PROXYCODE_DEFAULT_PROFILE=$(proxycode_read_setting "$PROXYCODE_CONFIG_DIR/settings" DEFAULT_PROFILE)
  proxycode_validate_port "$PROXYCODE_HTTP_PORT" && proxycode_validate_port "$PROXYCODE_SOCKS_PORT" &&
    [[ $PROXYCODE_HTTP_PORT != "$PROXYCODE_SOCKS_PORT" ]] || proxycode_error 'global settings are invalid; repair or remove the settings file'
}

proxycode_save_global_settings() {
  proxycode_write_private "$PROXYCODE_CONFIG_DIR/settings" <<EOF
HTTP_PORT=$PROXYCODE_HTTP_PORT
SOCKS_PORT=$PROXYCODE_SOCKS_PORT
DEFAULT_PROFILE=$PROXYCODE_DEFAULT_PROFILE
EOF
}

proxycode_validate_profile_name() {
  local LC_ALL=C
  [[ $1 =~ ^[A-Za-z0-9]([A-Za-z0-9._-]{0,62}[A-Za-z0-9])?$ ]]
}

proxycode_profile_path() {
  proxycode_validate_profile_name "$1" || return 2
  printf '%s/%s' "$PROXYCODE_DATA_DIR/profiles" "$1"
}

proxycode_profile_list() {
  local profile LC_ALL=C
  proxycode_prepare_storage || return
  for profile in "$PROXYCODE_DATA_DIR"/profiles/*; do
    [[ -d $profile ]] && printf '%s\n' "${profile##*/}"
  done
  return 0
}

proxycode_profile_show() {
  local name=$1 profile
  proxycode_load_global_settings || return
  profile=$(proxycode_profile_path "$name") || { proxycode_error "invalid Tunnel Profile name '$name'" 2; return; }
  [[ -d $profile ]] || { proxycode_error "Tunnel Profile '$name' does not exist" 2; return; }
  printf 'Name: %s\n' "$name"
  [[ $PROXYCODE_DEFAULT_PROFILE == "$name" ]] && printf 'Default: yes\n' || printf 'Default: no\n'
  proxycode_profile_settings_show "$name"
}

proxycode_settings_show() {
  proxycode_load_global_settings || return
  printf 'HTTP port: %s\nSOCKS port: %s\n' "$PROXYCODE_HTTP_PORT" "$PROXYCODE_SOCKS_PORT"
}

proxycode_validate_port() {
  [[ $1 =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535))
}

proxycode_settings_update() {
  local http_port=$1 socks_port=$2 profile staged backup committed=0 index failed=false
  local -a staged_configs=() backups=() profiles=()
  proxycode_load_global_settings || return
  [[ -z $http_port ]] || { proxycode_validate_port "$http_port" || { proxycode_error 'HTTP port must be an integer in 1..65535' 2; return; }; PROXYCODE_HTTP_PORT=$((10#$http_port)); }
  [[ -z $socks_port ]] || { proxycode_validate_port "$socks_port" || { proxycode_error 'SOCKS port must be an integer in 1..65535' 2; return; }; PROXYCODE_SOCKS_PORT=$((10#$socks_port)); }
  [[ $PROXYCODE_HTTP_PORT != "$PROXYCODE_SOCKS_PORT" ]] || { proxycode_error 'HTTP and SOCKS ports must be distinct' 2; return; }

  for profile in "$PROXYCODE_DATA_DIR"/profiles/*; do
    [[ -d $profile ]] || continue
    staged=$profile/wireproxy.conf.new.$$
    backup=$profile/wireproxy.conf.old.$$
    proxycode_generate_wireproxy_config "$profile" "$staged" || { failed=true; break; }
    cp -p -- "$profile/wireproxy.conf" "$backup" || { failed=true; break; }
    profiles+=("$profile")
    staged_configs+=("$staged")
    backups+=("$backup")
  done
  if $failed; then
    rm -f -- "${staged_configs[@]}" "${backups[@]}" "$staged" "$backup"
    proxycode_error 'could not prepare updated WireProxy configurations'
    return
  fi
  for index in "${!profiles[@]}"; do
    if ! mv -f -- "${staged_configs[index]}" "${profiles[index]}/wireproxy.conf"; then
      for ((index = committed - 1; index >= 0; index--)); do
        mv -f -- "${backups[index]}" "${profiles[index]}/wireproxy.conf" ||
          proxycode_error 'could not restore a generated configuration; its private backup was retained'
      done
      rm -f -- "${staged_configs[@]}" "${backups[@]:committed}" ||
        proxycode_error 'could not clean up redundant configuration backups'
      proxycode_error 'could not update WireProxy configurations'
      return
    fi
    committed=$((committed + 1))
  done
  if ! proxycode_save_global_settings; then
    for index in "${!profiles[@]}"; do
      mv -f -- "${backups[index]}" "${profiles[index]}/wireproxy.conf" ||
        proxycode_error 'could not restore a generated configuration; its private backup was retained'
    done
    proxycode_error 'could not save global settings'
    return
  fi
  rm -f -- "${backups[@]}"
  proxycode_settings_show
}

proxycode_profile_settings_show() {
  local name=$1 profile probe expectation url status contains
  proxycode_prepare_storage || return
  profile=$(proxycode_profile_path "$name") || { proxycode_error "invalid Tunnel Profile name '$name'" 2; return; }
  [[ -d $profile ]] || { proxycode_error "Tunnel Profile '$name' does not exist" 2; return; }
  probe=$(proxycode_read_setting "$profile/settings" PROBE)
  expectation=$(proxycode_read_setting "$profile/settings" EXPECT_LOCATION)
  printf 'Probe: %s\n' "$probe"
  case $probe in
    cloudflare|mullvad) printf 'Expected location: %s\n' "${expectation:-any}" ;;
    custom)
      url=$(proxycode_read_setting "$profile/settings" URL)
      status=$(proxycode_read_setting "$profile/settings" STATUS)
      contains=$(proxycode_read_setting "$profile/settings" CONTAINS)
      printf 'URL: %s\nStatus: %s\nContains: %s\n' "$url" "$status" "$([[ -n $contains ]] && printf configured || printf any)"
      ;;
    *) proxycode_error "Tunnel Profile '$name' has invalid probe settings" ;;
  esac
}

proxycode_profile_settings_update() {
  local name=$1 probe=$2 expectation=$3 url=$4 status=$5 contains=$6 profile authority url_port LC_ALL=C
  proxycode_prepare_storage || return
  profile=$(proxycode_profile_path "$name") || { proxycode_error "invalid Tunnel Profile name '$name'" 2; return; }
  [[ -d $profile ]] || { proxycode_error "Tunnel Profile '$name' does not exist" 2; return; }
  [[ ${expectation}${url}${contains} != *[$'\r\n']* ]] || { proxycode_error 'probe settings must be single-line values' 2; return; }
  case $probe in
    cloudflare)
      [[ -z $url && -z $status && -z $contains ]] || { proxycode_error 'Cloudflare accepts only --expect-location' 2; return; }
      [[ -z $expectation || $expectation =~ ^[A-Z]{2}$ ]] || { proxycode_error 'Cloudflare location must be two uppercase ASCII letters' 2; return; }
      ;;
    mullvad)
      [[ -z $url && -z $status && -z $contains ]] || { proxycode_error 'Mullvad accepts only --expect-location' 2; return; }
      ;;
    custom)
      [[ -z $expectation ]] || { proxycode_error 'custom probes use --contains, not --expect-location' 2; return; }
      [[ $url == https://* ]] || { proxycode_error 'custom probe URL must use HTTPS' 2; return; }
      [[ $url != *[[:space:]]* ]] || { proxycode_error 'custom probe URL must not contain whitespace' 2; return; }
      authority=${url#https://}
      authority=${authority%%[/?#]*}
      [[ $authority != *@* && $authority =~ ^([A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?|\[[0-9A-Fa-f:.]+\])(:[0-9]{1,5})?$ ]] || { proxycode_error 'custom probe URL must have a valid host and no credentials' 2; return; }
      if [[ $authority =~ :([0-9]+)$ ]]; then
        url_port=${BASH_REMATCH[1]}
        proxycode_validate_port "$url_port" || { proxycode_error 'custom probe URL port must be in 1..65535' 2; return; }
      fi
      [[ $status =~ ^[1-5][0-9][0-9]$ ]] || { proxycode_error 'custom probe status must be an HTTP status from 100 to 599' 2; return; }
      ;;
    *) proxycode_error "unknown probe '$probe'" 2; return ;;
  esac
  proxycode_write_private "$profile/settings" <<EOF || return 1
PROBE=$probe
EXPECT_LOCATION=$expectation
URL=$url
STATUS=$status
CONTAINS=$contains
EOF
  proxycode_profile_settings_show "$name"
}

proxycode_generate_password() {
  local uuid password= count
  for count in 1 2 3; do
    IFS= read -r uuid </proc/sys/kernel/random/uuid || return 1
    [[ $uuid =~ ^[0-9a-f-]{36}$ ]] || return 1
    password+=${uuid//-/}
  done
  printf '%s' "$password"
}

proxycode_generate_wireproxy_config() {
  local profile=$1 target=${2:-$1/wireproxy.conf} username password
  username=$(proxycode_read_setting "$profile/proxy-credential" USERNAME) || return 1
  password=$(proxycode_read_setting "$profile/proxy-credential" PASSWORD) || return 1
  [[ $username == proxy-code && -n $password ]] || return 1
  proxycode_write_private "$target" <<EOF
WGConfig = wireguard.conf

[Socks5]
BindAddress = 127.0.0.1:$PROXYCODE_SOCKS_PORT
Username = $username
Password = $password

[HTTP]
BindAddress = 127.0.0.1:$PROXYCODE_HTTP_PORT
Username = $username
Password = $password
EOF
}

proxycode_confirm() {
  local yes=$1 prompt=$2 answer
  $yes && return
  if [[ ! -t 0 ]]; then
    proxycode_error 'confirmation requires a terminal; pass --yes for automation' 2
    return
  fi
  IFS= read -r -p "$prompt [y/N] " answer
  [[ $answer == y || $answer == Y ]] || { proxycode_error 'cancelled' 2; return; }
}

proxycode_profile_default() {
  local name=$1 profile
  proxycode_load_global_settings || return
  profile=$(proxycode_profile_path "$name") || { proxycode_error "invalid Tunnel Profile name '$name'" 2; return; }
  [[ -d $profile ]] || { proxycode_error "Tunnel Profile '$name' does not exist" 2; return; }
  PROXYCODE_DEFAULT_PROFILE=$name
  proxycode_save_global_settings || return
  printf 'Default Tunnel Profile: %s\n' "$name"
}

proxycode_profile_remove() {
  local name=$1 yes=$2 profile
  proxycode_load_global_settings || return
  profile=$(proxycode_profile_path "$name") || { proxycode_error "invalid Tunnel Profile name '$name'" 2; return; }
  [[ -d $profile ]] || { proxycode_error "Tunnel Profile '$name' does not exist" 2; return; }
  proxycode_confirm "$yes" "Remove Tunnel Profile '$name'?" || return
  if [[ $PROXYCODE_DEFAULT_PROFILE == "$name" ]]; then
    PROXYCODE_DEFAULT_PROFILE=
    proxycode_save_global_settings || return
  fi
  rm -rf -- "$profile" "$PROXYCODE_STATE_DIR/logs/$name" || return 1
  printf 'Removed Tunnel Profile: %s\n' "$name"
}

proxycode_profile_import() {
  local source_file=$1 name=$2 make_default=$3 replace=$4 yes=$5 profile stage password backup existed=false
  proxycode_load_global_settings || return
  profile=$(proxycode_profile_path "$name") || { proxycode_error "invalid Tunnel Profile name '$name'" 2; return; }
  [[ -f $source_file && -r $source_file ]] || { proxycode_error "cannot read WireGuard configuration '$source_file'" 2; return; }
  if [[ -e $profile ]]; then
    $replace || { proxycode_error "Tunnel Profile '$name' already exists; use --replace" 2; return; }
    proxycode_confirm "$yes" "Replace Tunnel Profile '$name'?" || return
    existed=true
  fi

  stage=$(mktemp -d "$PROXYCODE_DATA_DIR/profiles/.${name}.new.XXXXXX") || return 1
  chmod 700 "$stage" || { rm -rf -- "$stage"; return 1; }
  if ! cp -- "$source_file" "$stage/wireguard.conf" || ! chmod 600 "$stage/wireguard.conf"; then
    rm -rf -- "$stage"
    proxycode_error 'could not copy the WireGuard configuration'
    return
  fi
  if $existed; then
    cp -- "$profile/proxy-credential" "$profile/settings" "$stage/" &&
      chmod 600 "$stage/proxy-credential" "$stage/settings" || { rm -rf -- "$stage"; return 1; }
  else
    password=$(proxycode_generate_password) || { rm -rf -- "$stage"; proxycode_error 'secure password generation failed'; return; }
    proxycode_write_private "$stage/proxy-credential" <<EOF || { rm -rf -- "$stage"; return 1; }
USERNAME=proxy-code
PASSWORD=$password
EOF
    proxycode_write_private "$stage/settings" <<'EOF' || { rm -rf -- "$stage"; return 1; }
PROBE=cloudflare
EXPECT_LOCATION=
URL=
STATUS=
CONTAINS=
EOF
  fi
  proxycode_generate_wireproxy_config "$stage" || { rm -rf -- "$stage"; return 1; }
  if ! "$PROXYCODE_DATA_DIR/bin/wireproxy" --config "$stage/wireproxy.conf" --configtest >/dev/null 2>&1; then
    rm -rf -- "$stage"
    proxycode_error 'WireGuard configuration validation failed'
    return
  fi
  if $existed; then
    backup=$PROXYCODE_DATA_DIR/profiles/.${name}.old.$$
    mv -- "$profile" "$backup" || { rm -rf -- "$stage"; return 1; }
    if ! mv -- "$stage" "$profile"; then
      mv -- "$backup" "$profile"
      rm -rf -- "$stage"
      return 1
    fi
  else
    mv -- "$stage" "$profile" || { rm -rf -- "$stage"; return 1; }
  fi

  if $make_default; then
    PROXYCODE_DEFAULT_PROFILE=$name
    if ! proxycode_save_global_settings; then
      rm -rf -- "$profile"
      $existed && mv -- "$backup" "$profile"
      return 1
    fi
  fi
  if $existed; then
    rm -rf -- "$backup"
    printf 'Replaced Tunnel Profile: %s\n' "$name"
  else
    printf 'Imported Tunnel Profile: %s\n' "$name"
  fi
  $make_default && printf 'Default Tunnel Profile: %s\n' "$name"
  return 0
}
