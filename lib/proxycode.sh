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
DEFAULT_PROFILE=
EOF
  fi
}

proxycode_load_global_settings() {
  proxycode_prepare_storage || return
  PROXYCODE_HTTP_PORT=$(proxycode_read_setting "$PROXYCODE_CONFIG_DIR/settings" HTTP_PORT)
  PROXYCODE_DEFAULT_PROFILE=$(proxycode_read_setting "$PROXYCODE_CONFIG_DIR/settings" DEFAULT_PROFILE)
  proxycode_validate_port "$PROXYCODE_HTTP_PORT" || proxycode_error 'global settings are invalid; repair or remove the settings file'
}

proxycode_save_global_settings() {
  proxycode_write_private "$PROXYCODE_CONFIG_DIR/settings" <<EOF
HTTP_PORT=$PROXYCODE_HTTP_PORT
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
  printf 'HTTP port: %s\n' "$PROXYCODE_HTTP_PORT"
}

proxycode_validate_port() {
  [[ $1 =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535))
}

proxycode_settings_update() {
  local http_port=$1
  proxycode_load_global_settings || return
  if [[ -n $http_port ]]; then
    proxycode_validate_port "$http_port" || { proxycode_error 'HTTP port must be an integer in 1..65535' 2; return; }
    http_port=$((10#$http_port))
    if [[ $http_port != "$PROXYCODE_HTTP_PORT" ]]; then
      proxycode_inspect_active || return
      [[ $PROXYCODE_ACTIVE_STATUS == stopped ]] || { proxycode_error 'a Tunnel Profile is active or unresolved; stop it first'; return; }
      PROXYCODE_HTTP_PORT=$http_port
    fi
  fi
  proxycode_save_global_settings || return
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
  proxycode_inspect_active || return
  if [[ $PROXYCODE_ACTIVE_STATUS == ambiguous ]]; then
    proxycode_error 'active process identity is ambiguous; refusing to remove a Tunnel Profile'
    proxycode_ambiguous_guidance
    return 1
  fi
  if [[ $PROXYCODE_ACTIVE_STATUS != stopped && $PROXYCODE_ACTIVE_PROFILE == "$name" ]]; then
    proxycode_stop_locked || return
  fi
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
    proxycode_inspect_active || { rm -rf -- "$stage"; return; }
    if [[ $PROXYCODE_ACTIVE_STATUS != stopped && $PROXYCODE_ACTIVE_PROFILE == "$name" ]]; then
      proxycode_stop_locked || { rm -rf -- "$stage"; return; }
    fi
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

proxycode_prepare_lifecycle() {
  proxycode_load_global_settings || return
  mkdir -p "$PROXYCODE_RUNTIME_DIR" "$PROXYCODE_STATE_DIR/logs" || return 1
  chmod 700 "$PROXYCODE_RUNTIME_DIR" "$PROXYCODE_STATE_DIR" "$PROXYCODE_STATE_DIR/logs" || return 1
  : >"$PROXYCODE_RUNTIME_DIR/lifecycle.lock" || return 1
  chmod 600 "$PROXYCODE_RUNTIME_DIR/lifecycle.lock"
}

proxycode_with_lifecycle_lock() {
  local operation=$1
  shift
  proxycode_prepare_lifecycle || return
  exec {PROXYCODE_LOCK_FD}>"$PROXYCODE_RUNTIME_DIR/lifecycle.lock" || return 1
  flock -x "$PROXYCODE_LOCK_FD" || return 1
  "$operation" "$@"
}

proxycode_process_start_time() {
  local stat rest
  [[ $1 =~ ^[0-9]+$ ]] || return 1
  IFS= read -r stat <"/proc/$1/stat" 2>/dev/null || return 1
  rest=${stat##*) }
  set -- $rest
  (($# >= 20)) || return 1
  printf '%s' "${20}"
}

proxycode_process_state() {
  local stat rest
  [[ $1 =~ ^[0-9]+$ ]] || return 1
  IFS= read -r stat <"/proc/$1/stat" 2>/dev/null || return 1
  rest=${stat##*) }
  set -- $rest
  printf '%s' "$1"
}

proxycode_process_matches() {
  local pid=$1 started=$2 executable=$3 config=$4 actual argument previous=
  [[ $(proxycode_process_start_time "$pid") == "$started" ]] || return 1
  actual=$(readlink -f "/proc/$pid/exe" 2>/dev/null) || return 1
  [[ $actual == "$executable" ]] || return 1
  while IFS= read -r -d '' argument; do
    [[ $previous == --config && $argument == "$config" ]] && return 0
    previous=$argument
  done <"/proc/$pid/cmdline" 2>/dev/null
  return 1
}

proxycode_wait_for_process_match() {
  local attempt
  for attempt in {1..10}; do
    proxycode_process_matches "$@" && return 0
    sleep 0.1
  done
  return 1
}

proxycode_inspect_active() {
  local state=$PROXYCODE_RUNTIME_DIR/active expected_executable expected_config observed_start ready
  PROXYCODE_ACTIVE_STATUS=stopped
  PROXYCODE_ACTIVE_PROFILE= PROXYCODE_ACTIVE_PID= PROXYCODE_ACTIVE_STARTED=
  [[ -e $state ]] || return 0
  [[ -f $state && -r $state ]] || { PROXYCODE_ACTIVE_STATUS=ambiguous; return 0; }
  expected_executable=$(readlink -f "$PROXYCODE_DATA_DIR/bin/wireproxy") || { PROXYCODE_ACTIVE_STATUS=ambiguous; return 0; }
  PROXYCODE_ACTIVE_PROFILE=$(proxycode_read_setting "$state" PROFILE)
  PROXYCODE_ACTIVE_PID=$(proxycode_read_setting "$state" PID)
  PROXYCODE_ACTIVE_STARTED=$(proxycode_read_setting "$state" START_TIME)
  ready=$(proxycode_read_setting "$state" READY)
  if ! proxycode_validate_profile_name "$PROXYCODE_ACTIVE_PROFILE" ||
    [[ ! $PROXYCODE_ACTIVE_PID =~ ^[0-9]+$ || ! $PROXYCODE_ACTIVE_STARTED =~ ^[0-9]+$ ]]; then
    PROXYCODE_ACTIVE_STATUS=ambiguous
    return 0
  fi
  expected_config=$(proxycode_profile_path "$PROXYCODE_ACTIVE_PROFILE" 2>/dev/null)/wireproxy.conf || {
    PROXYCODE_ACTIVE_STATUS=ambiguous
    return 0
  }
  if [[ ! -e /proc/$PROXYCODE_ACTIVE_PID || $(proxycode_process_state "$PROXYCODE_ACTIVE_PID") == Z ]]; then
    rm -f -- "$state"
    PROXYCODE_ACTIVE_PROFILE= PROXYCODE_ACTIVE_PID= PROXYCODE_ACTIVE_STARTED=
    return 0
  fi
  if proxycode_process_matches "$PROXYCODE_ACTIVE_PID" "$PROXYCODE_ACTIVE_STARTED" "$expected_executable" "$expected_config"; then
    [[ $ready == 1 ]] && PROXYCODE_ACTIVE_STATUS=active || PROXYCODE_ACTIVE_STATUS=starting
  else
    observed_start=$(proxycode_process_start_time "$PROXYCODE_ACTIVE_PID") || {
      PROXYCODE_ACTIVE_STATUS=ambiguous
      return 0
    }
    if [[ $observed_start == "$PROXYCODE_ACTIVE_STARTED" ]]; then
      PROXYCODE_ACTIVE_STATUS=ambiguous
      return 0
    fi
    rm -f -- "$state"
    PROXYCODE_ACTIVE_PROFILE= PROXYCODE_ACTIVE_PID= PROXYCODE_ACTIVE_STARTED=
  fi
}

proxycode_rotate_log() {
  local name=$1 directory log size
  [[ -n $name ]] || return 0
  directory=$PROXYCODE_STATE_DIR/logs/$name
  log=$directory/wireproxy.log
  [[ -f $log ]] || return 0
  size=$(stat -c %s "$log" 2>/dev/null) || return 1
  if ((size >= 10485760)); then
    cp -p -- "$log" "$directory/wireproxy.log.old" && : >"$log" || return 1
    chmod 600 "$directory/wireproxy.log.old" "$log" || return 1
  fi
}

proxycode_ambiguous_guidance() {
  printf "Confirm no WireProxy process owns the configured ports, then remove '%s' and retry.\n" "$PROXYCODE_RUNTIME_DIR/active" >&2
}

proxycode_probe_once() {
  local profile=$1 timeout_seconds=$2 probe expectation url expected_status contains body http_status curl_status location=
  probe=$(proxycode_read_setting "$profile/settings" PROBE)
  expectation=$(proxycode_read_setting "$profile/settings" EXPECT_LOCATION)
  case $probe in
    cloudflare) url=https://cloudflare.com/cdn-cgi/trace; expected_status=2xx ;;
    mullvad) url=https://ipv4.am.i.mullvad.net/json; expected_status=2xx ;;
    custom)
      url=$(proxycode_read_setting "$profile/settings" URL)
      expected_status=$(proxycode_read_setting "$profile/settings" STATUS)
      contains=$(proxycode_read_setting "$profile/settings" CONTAINS)
      ;;
    *) return 1 ;;
  esac
  body=$(mktemp "$PROXYCODE_RUNTIME_DIR/probe.XXXXXX") || return 1
  chmod 600 "$body" || { rm -f -- "$body"; return 1; }
  if http_status=$(curl --disable --silent --max-filesize 65536 --max-time "$timeout_seconds" --output "$body" --write-out '%{http_code}' "$url" 2>/dev/null); then
    :
  else
    curl_status=$?
    rm -f -- "$body"
    case $curl_status in
      5|6|7|18|28|35|52|55|56|92) return 75 ;;
      *) return 1 ;;
    esac
  fi
  if [[ $expected_status == 2xx ]]; then
    [[ $http_status =~ ^2[0-9][0-9]$ ]] || { rm -f -- "$body"; [[ $http_status == 408 || $http_status == 429 || $http_status == 5* ]] && return 75 || return 1; }
  elif [[ $http_status != "$expected_status" ]]; then
    rm -f -- "$body"
    [[ $http_status == 408 || $http_status == 429 || $http_status == 5* ]] && return 75 || return 1
  fi
  case $probe in
    cloudflare)
      grep -q '^ip=.' "$body" || { rm -f -- "$body"; return 1; }
      location=$(sed -n 's/^loc=//p' "$body" | sed -n '1p')
      PROXYCODE_PROBE_LOCATION=$location
      [[ -z $expectation || $location == "$expectation" ]] || { rm -f -- "$body"; return 1; }
      ;;
    mullvad)
      grep -Eq '"mullvad_exit_ip"[[:space:]]*:[[:space:]]*true' "$body" || { rm -f -- "$body"; return 1; }
      location=$(sed -n 's/.*"country"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$body" | sed -n '1p')
      PROXYCODE_PROBE_LOCATION=$location
      [[ -z $expectation || $location == "$expectation" ]] || { rm -f -- "$body"; return 1; }
      ;;
    custom) [[ -z $contains ]] || grep -Fq -- "$contains" "$body" || { rm -f -- "$body"; return 1; } ;;
  esac
  rm -f -- "$body"
  PROXYCODE_PROBE_LOCATION=$location
}

proxycode_run_probe() {
  local profile=$1 total=$2 attempt=$3 retry=$4 started=$SECONDS status username password proxy_url remaining
  username=$(proxycode_read_setting "$profile/proxy-credential" USERNAME) || return 1
  password=$(proxycode_read_setting "$profile/proxy-credential" PASSWORD) || return 1
  proxy_url=http://$username:$password@127.0.0.1:$PROXYCODE_HTTP_PORT
  while :; do
    remaining=$((total - (SECONDS - started)))
    ((remaining > 0)) || return 1
    ((attempt < remaining)) || attempt=$remaining
    PROXYCODE_PROBE_LOCATION=
    http_proxy=$proxy_url https_proxy=$proxy_url all_proxy=$proxy_url HTTP_PROXY=$proxy_url HTTPS_PROXY=$proxy_url ALL_PROXY=$proxy_url NO_PROXY= no_proxy= \
      proxycode_probe_once "$profile" "$attempt"
    status=$?
    ((status == 0)) && return 0
    [[ $retry == true ]] || return 1
    ((status != 75 || SECONDS - started >= total - 1)) && return 1
    sleep 1
  done
}

proxycode_port_in_use() {
  timeout 1 bash -c 'exec 3<>/dev/tcp/127.0.0.1/$1' _ "$1" 2>/dev/null
}

proxycode_start_locked() {
  local name=$1 profile config executable log_directory log pid started attempt
  name=${name:-$PROXYCODE_DEFAULT_PROFILE}
  [[ -n $name ]] || { proxycode_error 'no Tunnel Profile was selected and no Default is configured' 2; return; }
  profile=$(proxycode_profile_path "$name") || { proxycode_error "invalid Tunnel Profile name '$name'" 2; return; }
  [[ -d $profile ]] || { proxycode_error "Tunnel Profile '$name' does not exist" 2; return; }
  proxycode_inspect_active || return
  proxycode_rotate_log "$PROXYCODE_ACTIVE_PROFILE" || { proxycode_error 'could not rotate the WireProxy log'; return; }
  case $PROXYCODE_ACTIVE_STATUS in
    active)
      [[ $PROXYCODE_ACTIVE_PROFILE == "$name" ]] && { printf 'Tunnel Profile already active: %s\n' "$name"; return; }
      proxycode_error "Tunnel Profile '$PROXYCODE_ACTIVE_PROFILE' is active; stop it first"
      return
      ;;
    ambiguous)
      proxycode_error 'active process identity is ambiguous; refusing to start or signal it'
      proxycode_ambiguous_guidance
      return 1
      ;;
    starting)
      proxycode_stop_locked || return
      ;;
  esac
  if proxycode_port_in_use "$PROXYCODE_HTTP_PORT"; then
    proxycode_error 'a configured proxy port is already in use; refusing to replace an unknown listener'
    return
  fi
  config=$profile/wireproxy.conf
  proxycode_generate_wireproxy_config "$profile" "$config" || { proxycode_error 'could not regenerate the WireProxy configuration'; return; }
  executable=$(readlink -f "$PROXYCODE_DATA_DIR/bin/wireproxy") || { proxycode_error 'installed WireProxy executable is missing'; return; }
  "$executable" --config "$config" --configtest >/dev/null 2>&1 || { proxycode_error 'WireGuard configuration validation failed'; return; }
  log_directory=$PROXYCODE_STATE_DIR/logs/$name
  log=$log_directory/wireproxy.log
  mkdir -p "$log_directory" || return 1
  chmod 700 "$log_directory" || return 1
  touch "$log" && chmod 600 "$log" || return 1
  proxycode_rotate_log "$name" || { proxycode_error 'could not rotate the WireProxy log'; return; }
  if ! proxycode_write_private "$PROXYCODE_RUNTIME_DIR/active" <<EOF
PROFILE=$name
PID=unavailable
START_TIME=unavailable
READY=0
EOF
  then
    proxycode_error 'could not reserve active process state'
    return
  fi
  (
    cd "$profile" || exit
    exec {PROXYCODE_LOCK_FD}>&-
    exec nohup "$executable" --config "$config"
  ) >>"$log" 2>&1 &
  pid=$!
  for attempt in {1..10}; do
    started=$(proxycode_process_start_time "$pid") && break
    sleep 0.1
  done
  if [[ -z ${started:-} ]]; then
    [[ -e /proc/$pid ]] || rm -f -- "$PROXYCODE_RUNTIME_DIR/active"
    proxycode_error 'WireProxy process identity could not be read; ambiguous state was retained if it may still be running'
    return
  fi
  if ! proxycode_write_private "$PROXYCODE_RUNTIME_DIR/active" <<EOF
PROFILE=$name
PID=$pid
START_TIME=$started
READY=0
EOF
  then
    if proxycode_wait_for_process_match "$pid" "$started" "$executable" "$config" &&
      proxycode_terminate_verified "$pid" "$started" "$executable" "$config"; then
      rm -f -- "$PROXYCODE_RUNTIME_DIR/active"
    else
      proxycode_error 'could not record or safely clean up the new WireProxy process; ambiguous state was retained'
    fi
    return 1
  fi
  if ! proxycode_wait_for_process_match "$pid" "$started" "$executable" "$config"; then
    proxycode_error 'WireProxy process identity could not be verified; ambiguous state was retained'
    return
  fi
  if ! proxycode_run_probe "$profile" 30 5 true; then
    printf 'Location: %s\n' "${PROXYCODE_PROBE_LOCATION:-unavailable}"
    if proxycode_terminate_verified "$pid" "$started" "$executable" "$config"; then
      rm -f -- "$PROXYCODE_RUNTIME_DIR/active"
      proxycode_error 'Tunnel Profile health check failed; WireProxy was stopped'
    else
      proxycode_error 'Tunnel Profile health check failed; cleanup could not be verified and active state was retained'
    fi
    printf "Run 'proxycode status', then retry 'proxycode start %s'.\n" "$name" >&2
    return 1
  fi
  if ! proxycode_process_matches "$pid" "$started" "$executable" "$config"; then
    proxycode_error 'WireProxy process identity changed after the health check; provisional state was retained'
    return
  fi
  if ! proxycode_write_private "$PROXYCODE_RUNTIME_DIR/active" <<EOF
PROFILE=$name
PID=$pid
START_TIME=$started
READY=1
EOF
  then
    if proxycode_terminate_verified "$pid" "$started" "$executable" "$config"; then
      rm -f -- "$PROXYCODE_RUNTIME_DIR/active"
    else
      proxycode_error 'could not finalize activation; ambiguous state was retained'
    fi
    return 1
  fi
  printf 'Started Tunnel Profile: %s\nLocation: %s\n' "$name" "${PROXYCODE_PROBE_LOCATION:-unavailable}"
}

proxycode_prepare_wrapped_command_locked() {
  local name=$1 profile username password
  name=${name:-$PROXYCODE_DEFAULT_PROFILE}
  proxycode_start_locked "$name" >/dev/null || return
  profile=$(proxycode_profile_path "$name") || return 1
  if ! username=$(proxycode_read_setting "$profile/proxy-credential" USERNAME) ||
    ! password=$(proxycode_read_setting "$profile/proxy-credential" PASSWORD) ||
    [[ $username != proxy-code || -z $password ]]; then
    proxycode_error "Tunnel Profile '$name' Proxy credential is invalid"
    return
  fi
  PROXYCODE_WRAPPED_PROXY=http://$username:$password@127.0.0.1:$PROXYCODE_HTTP_PORT
}

proxycode_switch_locked() {
  local name=$1 yes=$2 profile
  profile=$(proxycode_profile_path "$name") || { proxycode_error "invalid Tunnel Profile name '$name'" 2; return; }
  [[ -d $profile ]] || { proxycode_error "Tunnel Profile '$name' does not exist" 2; return; }
  proxycode_inspect_active || return
  if [[ $PROXYCODE_ACTIVE_STATUS == active && $PROXYCODE_ACTIVE_PROFILE != "$name" ]]; then
    proxycode_confirm "$yes" "Switch from Tunnel Profile '$PROXYCODE_ACTIVE_PROFILE' to '$name'?" || return
    proxycode_stop_locked || return
  fi
  proxycode_start_locked "$name"
}

proxycode_wait_until_stopped() {
  local pid=$1 deadline=$((SECONDS + $2))
  while [[ -e /proc/$pid && $(proxycode_process_state "$pid") != Z ]]; do
    ((SECONDS < deadline)) || return 1
    sleep 0.1
  done
}

proxycode_terminate_verified() {
  local pid=$1 started=$2 executable=$3 config=$4
  proxycode_process_matches "$pid" "$started" "$executable" "$config" || return 1
  kill -TERM "$pid" 2>/dev/null || return 1
  proxycode_wait_until_stopped "$pid" 5 && return 0
  proxycode_process_matches "$pid" "$started" "$executable" "$config" || return 1
  kill -KILL "$pid" 2>/dev/null || return 1
  proxycode_wait_until_stopped "$pid" 2
}

proxycode_stop_locked() {
  local pid started name config executable
  proxycode_inspect_active || return
  case $PROXYCODE_ACTIVE_STATUS in
    stopped) printf 'Toolkit already stopped.\n'; return ;;
    ambiguous)
      proxycode_error 'active process identity is ambiguous; refusing to signal it'
      proxycode_ambiguous_guidance
      return 1
      ;;
  esac
  pid=$PROXYCODE_ACTIVE_PID started=$PROXYCODE_ACTIVE_STARTED name=$PROXYCODE_ACTIVE_PROFILE
  executable=$(readlink -f "$PROXYCODE_DATA_DIR/bin/wireproxy") || { proxycode_error 'installed WireProxy executable is missing'; return; }
  config=$(proxycode_profile_path "$name")/wireproxy.conf
  proxycode_rotate_log "$name" || { proxycode_error 'could not rotate the WireProxy log'; return; }
  proxycode_terminate_verified "$pid" "$started" "$executable" "$config" || { proxycode_error 'WireProxy could not be stopped without risking another process'; return; }
  rm -f -- "$PROXYCODE_RUNTIME_DIR/active" || return 1
  printf 'Stopped Tunnel Profile: %s\n' "$name"
}

proxycode_status_locked() {
  local profile profiles= active=none
  proxycode_inspect_active || return
  proxycode_rotate_log "$PROXYCODE_ACTIVE_PROFILE" || return
  while IFS= read -r profile; do
    [[ -n $profile ]] && profiles+=${profiles:+,\ }$profile
  done < <(proxycode_profile_list)
  [[ $PROXYCODE_ACTIVE_STATUS == active ]] && active=$PROXYCODE_ACTIVE_PROFILE
  printf 'Default: %s\nActive: %s\nProfiles: %s\n' "${PROXYCODE_DEFAULT_PROFILE:-none}" "$active" "${profiles:-none}"
  case $PROXYCODE_ACTIVE_STATUS in
    active) printf 'Process: running (PID %s)\n' "$PROXYCODE_ACTIVE_PID" ;;
    starting) printf 'Process: starting (PID %s)\n' "$PROXYCODE_ACTIVE_PID"; return 1 ;;
    ambiguous)
      printf 'Process: unknown (refusing to signal)\n'
      proxycode_ambiguous_guidance
      return 1
      ;;
    *) printf 'Process: stopped\n' ;;
  esac
}

proxycode_check_locked() {
  local profile
  proxycode_inspect_active || return
  [[ $PROXYCODE_ACTIVE_STATUS == active ]] || { proxycode_error 'no verified Tunnel Profile is active'; return; }
  proxycode_rotate_log "$PROXYCODE_ACTIVE_PROFILE" || return
  profile=$(proxycode_profile_path "$PROXYCODE_ACTIVE_PROFILE")
  if ! proxycode_run_probe "$profile" 10 10 false; then
    printf 'Location: %s\n' "${PROXYCODE_PROBE_LOCATION:-unavailable}"
    proxycode_error 'Tunnel Profile health check failed'
    return
  fi
  printf 'Tunnel Profile healthy: %s\nLocation: %s\n' "$PROXYCODE_ACTIVE_PROFILE" "${PROXYCODE_PROBE_LOCATION:-unavailable}"
}
