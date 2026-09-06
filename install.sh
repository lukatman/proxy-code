#!/usr/bin/env bash

set -u
set -o pipefail
umask 077

PROXYCODE_VERSION=1.0.0
WIREPROXY_VERSION=1.1.3
WIREPROXY_AMD64_SHA256=e88c1d090740373fc606c1bafd81d9a5eadc642cce5667616e20e9d7a444f51c
WIREPROXY_ARM64_SHA256=370e00bd2167960d1ecd1c3c1439715bbaa94a0a110a2040468670c9af6021b6
WIREPROXY_RELEASE=https://github.com/windtf/wireproxy/releases/download/v1.1.3
PROXYCODE_BUNDLE_ROOT=proxycode-$PROXYCODE_VERSION
PROXYCODE_BUNDLE=$PROXYCODE_BUNDLE_ROOT.tar.gz
PROXYCODE_RELEASE=https://github.com/lukatman/proxy-code/releases/download/v$PROXYCODE_VERSION
original_arguments=("$@")

die() {
  printf 'proxycode installer: %s\n' "$1" >&2
  exit "${2:-1}"
}

usage() {
  cat <<'EOF'
Usage:
  ./install.sh
  ./install.sh --install-only [--wireproxy-bin FILE]
  ./install.sh --wg-config FILE --name NAME [--default] [SETUP OPTIONS]
  ./install.sh --uninstall [--yes]
  ./install.sh --purge [--yes]

Setup options:
  --wireproxy-bin FILE
  --http-port PORT
  --probe cloudflare [--expect-location CC]
  --probe mullvad [--expect-location NAME]
  --probe custom --url HTTPS_URL --status CODE [--contains TEXT]
  --replace [--yes]
EOF
}

version_is_newer() {
  local left_major left_minor left_patch right_major right_minor right_patch
  IFS=. read -r left_major left_minor left_patch <<<"$1"
  IFS=. read -r right_major right_minor right_patch <<<"$2"
  ((10#$left_major > 10#$right_major ||
    (10#$left_major == 10#$right_major && 10#$left_minor > 10#$right_minor) ||
    (10#$left_major == 10#$right_major && 10#$left_minor == 10#$right_minor && 10#$left_patch > 10#$right_patch)))
}

mode=
custom_binary=
wg_config=
name=
http_port=
probe=
expectation=
url=
expected_status=
contains=
make_default=false
replace=false
yes=false
had_arguments=false
if (($#)); then had_arguments=true; fi
while (($#)); do
  case $1 in
    --install-only|--uninstall|--purge)
      [[ -z $mode ]] || die 'choose exactly one of --install-only, --uninstall, or --purge' 2
      mode=${1#--}
      ;;
    --wireproxy-bin|--wg-config|--name|--http-port|--probe|--expect-location|--url|--status|--contains)
      (($# >= 2)) || die "$1 requires a value" 2
      case $1 in
        --wireproxy-bin) custom_binary=$2 ;;
        --wg-config) wg_config=$2 ;;
        --name) name=$2 ;;
        --http-port) http_port=$2 ;;
        --probe) probe=$2 ;;
        --expect-location) expectation=$2 ;;
        --url) url=$2 ;;
        --status) expected_status=$2 ;;
        --contains) contains=$2 ;;
      esac
      shift
      ;;
    --default) make_default=true ;;
    --replace) replace=true ;;
    --yes) yes=true ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown option '$1'" 2 ;;
  esac
  shift
done
if [[ -z $mode && ( -n $wg_config || -n $name ) ]]; then
  mode=profile
fi
if [[ -z $mode ]] && $had_arguments; then
  die 'choose --install-only or provide --wg-config FILE --name NAME' 2
fi
case $mode in
  install-only)
    if [[ -n ${wg_config}${name}${http_port}${probe}${expectation}${url}${expected_status}${contains} ]] || $make_default || $replace; then
      die '--install-only cannot be combined with Profile setup options' 2
    fi
    $yes && die '--yes is only valid with replacement, uninstall, or purge' 2
    ;;
  profile)
    [[ -n $wg_config && -n $name ]] || die '--wg-config and --name are required together' 2
    $yes && ! $replace && die '--yes requires --replace for Profile setup' 2
    ;;
  uninstall|purge)
    if [[ -n ${custom_binary}${wg_config}${name}${http_port}${probe}${expectation}${url}${expected_status}${contains} ]] || $make_default || $replace; then
      die "--$mode cannot be combined with setup options" 2
    fi
    ;;
  '') ;;
esac

if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4))); then
  die 'Bash 4.4 or newer is required'
fi

missing=()
if [[ $mode == install-only || $mode == profile || -z $mode ]]; then
  required_commands=(curl flock tar sha256sum timeout mktemp readlink stat nohup awk grep sed)
else
  required_commands=(flock readlink stat awk)
fi
for command_name in "${required_commands[@]}"; do
  command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
done
((${#missing[@]} == 0)) || die "missing required commands: ${missing[*]}. Install them with your distribution package manager."

script_path=$(readlink -f "${BASH_SOURCE[0]:-/dev/stdin}" 2>/dev/null) || script_path=
source_root=${script_path%/*}
if [[ ! -r $source_root/lib/proxycode.sh || ! -r $source_root/bin/proxycode ]]; then
  if [[ -z $mode ]] && ! { exec {TERMINAL_CHECK_FD}<>/dev/tty; } 2>/dev/null; then
    die 'no terminal is available; use complete setup flags such as --install-only or --wg-config FILE --name NAME' 2
  fi
  [[ -z ${TERMINAL_CHECK_FD:-} ]] || exec {TERMINAL_CHECK_FD}>&-
  bootstrap_dir=$(mktemp -d "${TMPDIR:-/tmp}/proxycode-bootstrap.XXXXXX") || die 'cannot create private bootstrap directory'
  bootstrap_cleanup() { rm -rf -- "$bootstrap_dir"; }
  trap bootstrap_cleanup EXIT
  curl --proto '=https' --tlsv1.2 -fL --retry 2 -o "$bootstrap_dir/$PROXYCODE_BUNDLE" "$PROXYCODE_RELEASE/$PROXYCODE_BUNDLE" || die 'Toolkit bundle download failed'
  curl --proto '=https' --tlsv1.2 -fL --retry 2 -o "$bootstrap_dir/$PROXYCODE_BUNDLE.sha256" "$PROXYCODE_RELEASE/$PROXYCODE_BUNDLE.sha256" || die 'Toolkit checksum download failed'
  grep -Eq "^[0-9a-f]{64}  $PROXYCODE_BUNDLE$" "$bootstrap_dir/$PROXYCODE_BUNDLE.sha256" || die 'Toolkit checksum file is invalid'
  (cd "$bootstrap_dir" && sha256sum -c "$PROXYCODE_BUNDLE.sha256" >/dev/null) || die 'Toolkit bundle checksum mismatch'
  members=$(tar -tzf "$bootstrap_dir/$PROXYCODE_BUNDLE") || die 'Toolkit bundle is unreadable'
  while IFS= read -r member; do
    case $member in
      "$PROXYCODE_BUNDLE_ROOT/"|"$PROXYCODE_BUNDLE_ROOT/install.sh"|"$PROXYCODE_BUNDLE_ROOT/bin/"|"$PROXYCODE_BUNDLE_ROOT/bin/proxycode"|"$PROXYCODE_BUNDLE_ROOT/lib/"|"$PROXYCODE_BUNDLE_ROOT/lib/proxycode.sh"|"$PROXYCODE_BUNDLE_ROOT/README.md"|"$PROXYCODE_BUNDLE_ROOT/LICENSE") ;;
      *) die 'Toolkit bundle contains unsafe or unexpected members' ;;
    esac
  done <<<"$members"
  for member in "$PROXYCODE_BUNDLE_ROOT/install.sh" "$PROXYCODE_BUNDLE_ROOT/bin/proxycode" "$PROXYCODE_BUNDLE_ROOT/lib/proxycode.sh"; do
    grep -Fxq "$member" <<<"$members" || die 'Toolkit bundle is incomplete'
  done
  tar -xzf "$bootstrap_dir/$PROXYCODE_BUNDLE" -C "$bootstrap_dir" || die 'Toolkit bundle extraction failed'
  for member in install.sh bin/proxycode lib/proxycode.sh; do
    [[ -f $bootstrap_dir/$PROXYCODE_BUNDLE_ROOT/$member && ! -L $bootstrap_dir/$PROXYCODE_BUNDLE_ROOT/$member ]] || die 'Toolkit bundle contains invalid source files'
  done
  bash "$bootstrap_dir/$PROXYCODE_BUNDLE_ROOT/install.sh" "${original_arguments[@]}"
  bootstrap_status=$?
  bootstrap_cleanup
  trap - EXIT
  exit "$bootstrap_status"
fi
# shellcheck source=lib/proxycode.sh
source "$source_root/lib/proxycode.sh"
proxycode_init_paths || exit 1
live_home=$HOME
live_xdg_config=${XDG_CONFIG_HOME:-}
live_xdg_data=${XDG_DATA_HOME:-}
live_xdg_state=${XDG_STATE_HOME:-}
live_xdg_runtime=${XDG_RUNTIME_DIR:-}
live_config_dir=$PROXYCODE_CONFIG_DIR
live_data_dir=$PROXYCODE_DATA_DIR
live_state_dir=$PROXYCODE_STATE_DIR
live_runtime_dir=$PROXYCODE_RUNTIME_DIR

acquire_lifecycle_lock() {
  mkdir -p "${PROXYCODE_RUNTIME_DIR%/*}" || die 'cannot create the lifecycle lock directory'
  exec {INSTALL_LOCK_FD}<"${PROXYCODE_RUNTIME_DIR%/*}" || die 'cannot open the lifecycle lock'
  flock -x "$INSTALL_LOCK_FD" || die 'cannot acquire the lifecycle lock'
  if [[ -e $PROXYCODE_RUNTIME_DIR/lifecycle.lock || -e $PROXYCODE_BIN_DIR/proxycode || -e $PROXYCODE_DATA_DIR/lib/proxycode.sh ]]; then
    mkdir -p "$PROXYCODE_RUNTIME_DIR" || die 'cannot create the lifecycle directory'
    chmod 700 "$PROXYCODE_RUNTIME_DIR" || die 'cannot secure the lifecycle directory'
    exec {INSTALL_LEGACY_LOCK_FD}>"$PROXYCODE_RUNTIME_DIR/lifecycle.lock" || die 'cannot open the legacy lifecycle lock'
    chmod 600 "$PROXYCODE_RUNTIME_DIR/lifecycle.lock" || die 'cannot secure the legacy lifecycle lock'
    flock -x "$INSTALL_LEGACY_LOCK_FD" || die 'cannot acquire the legacy lifecycle lock'
  fi
}

if [[ $mode == uninstall || $mode == purge ]]; then
  acquire_lifecycle_lock
  proxycode_inspect_active || die 'cannot inspect lifecycle state'
  if [[ $PROXYCODE_ACTIVE_STATUS == ambiguous ]]; then
    proxycode_ambiguous_guidance
    die 'active process identity is ambiguous; refusing maintenance'
  fi

  if [[ $mode == purge ]]; then
    profiles=()
    for profile in "$PROXYCODE_DATA_DIR"/profiles/*; do
      [[ -d $profile ]] && profiles+=("${profile##*/}")
    done
    printf 'Tunnel Profiles to purge: %s\n' "${profiles[*]:-none}"
    proxycode_confirm "$yes" 'Purge all Toolkit data?' || exit
  else
    proxycode_confirm "$yes" 'Uninstall the Toolkit?' || exit
  fi

  [[ $PROXYCODE_ACTIVE_STATUS == stopped ]] || proxycode_stop_locked || die 'could not safely stop the Active Tunnel Profile'
  rm -f -- "$PROXYCODE_BIN_DIR/proxycode" || die 'could not remove the Toolkit command'
  if [[ $mode == purge ]]; then
    rm -rf -- "$PROXYCODE_CONFIG_DIR" "$PROXYCODE_DATA_DIR" "$PROXYCODE_STATE_DIR" "$PROXYCODE_RUNTIME_DIR" || die 'could not purge Toolkit data'
  else
    rm -rf -- "$PROXYCODE_DATA_DIR/bin" "$PROXYCODE_DATA_DIR/lib" "$PROXYCODE_DATA_DIR/licenses" "$PROXYCODE_STATE_DIR" "$PROXYCODE_RUNTIME_DIR" || die 'could not remove installed Toolkit files'
  fi
  if [[ $mode == purge ]]; then
    printf 'Purged the Toolkit.\n'
  else
    printf 'Uninstalled the Toolkit; Tunnel Profiles, Proxy credentials, and settings were preserved.\n'
  fi
  exit 0
fi

interactive=false
start_after=false
if [[ -z $mode ]]; then
  if ! exec 0<>/dev/tty 1>/dev/tty; then
    if [[ ! -x $PROXYCODE_BIN_DIR/proxycode || ! -r $PROXYCODE_STATE_DIR/install ]]; then
      die 'no terminal is available; use --install-only or provide --wg-config FILE --name NAME' 2
    fi
    printf 'Existing installation found; reinstalling without changing Profiles or settings.\n'
    mode=install-only
  else
    interactive=true
    printf '\033[?25l\n%s%s◆ ProxyCode%s  setup\n\n' "$PROXYCODE_PURPLE" "$PROXYCODE_BOLD" "$PROXYCODE_RESET"
    trap 'printf "\033[?25h"' EXIT
    proxycode_choose 'What would you like to do?' \
      'Install and set up a Tunnel Profile' \
      'Install Toolkit only' \
      'Cancel' || exit 2
    case $PROXYCODE_CHOICE in
      2) mode=install-only ;;
      3) printf 'Cancelled. No changes were made.\n'; exit 0 ;;
      *) mode=profile ;;
    esac

    if [[ $mode == profile ]]; then
      proxycode_choose 'Do you have a WireGuard configuration?' \
        'Yes — choose the file' \
        "No — Mullvad recommended" \
        'Install Toolkit only' || exit 2
      case $PROXYCODE_CHOICE in
        2)
          printf 'Generate and download a standard WireGuard configuration from:\nhttps://mullvad.net/en/account/wireguard-config\n\n'
          printf 'After downloading it, run the installer again.\n'
          exit 0
          ;;
        3) mode=install-only ;;
      esac
    fi

    if [[ $mode == profile ]]; then
      while :; do
        proxycode_prompt 'WireGuard configuration file' '' 'enter here' || exit 2
        wg_config=${PROXYCODE_ANSWER/#\~/$HOME}
        [[ -f $wg_config && -r $wg_config ]] && break
        proxycode_error "cannot read WireGuard configuration '$wg_config'" 2
      done
      suggested_name=$(proxycode_suggest_profile_name "$wg_config")
      while :; do
        proxycode_prompt 'Tunnel Profile name' "$suggested_name" || exit 2
        name=$PROXYCODE_ANSWER
        if ! proxycode_validate_profile_name "$name"; then
          proxycode_error "invalid Tunnel Profile name '$name'" 2
          suggested_name=
          continue
        fi
        [[ -e $PROXYCODE_DATA_DIR/profiles/$name ]] || break
        proxycode_choose "Tunnel Profile '$name' already exists" \
          'Choose another name' \
          'Replace existing Profile' \
          'Cancel' || exit 2
        case $PROXYCODE_CHOICE in
          1) suggested_name= ;;
          2) replace=true; break ;;
          3) printf 'Cancelled. No changes were made.\n'; exit 0 ;;
        esac
      done
      proxycode_choose "Make '$name' the Default Tunnel Profile?" 'Yes' 'No' || exit 2
      [[ $PROXYCODE_CHOICE == 1 ]] && make_default=true
      proxycode_choose 'Start and check this Profile after installation?' 'Yes' 'No' || exit 2
      [[ $PROXYCODE_CHOICE == 1 ]] && start_after=true
      proxycode_choose 'Configure advanced settings?' 'Use settled defaults' 'Configure advanced settings' || exit 2
      if [[ $PROXYCODE_CHOICE == 2 ]]; then
        proxycode_choose 'WireProxy source' 'Pinned WireProxy v1.1.3' 'Custom executable' || exit 2
        if [[ $PROXYCODE_CHOICE == 2 ]]; then
          proxycode_prompt 'Custom WireProxy executable' || exit 2
          custom_binary=${PROXYCODE_ANSWER/#\~/$HOME}
        fi
        proxycode_prompt 'HTTP listener port' 25345 || exit 2
        http_port=$PROXYCODE_ANSWER
        proxycode_choose 'Health probe' 'Cloudflare' 'Mullvad' 'Custom HTTPS URL' || exit 2
        case $PROXYCODE_CHOICE in
          1)
            probe=cloudflare
            proxycode_prompt 'Expected country code, or blank for any' || exit 2
            expectation=$PROXYCODE_ANSWER
            ;;
          2)
            probe=mullvad
            proxycode_prompt 'Expected location, or blank for any' || exit 2
            expectation=$PROXYCODE_ANSWER
            ;;
          3)
            probe=custom
            proxycode_prompt 'HTTPS probe URL' || exit 2; url=$PROXYCODE_ANSWER
            proxycode_prompt 'Expected HTTP status' 200 || exit 2; expected_status=$PROXYCODE_ANSWER
            proxycode_prompt 'Required response text, or blank for any' || exit 2; contains=$PROXYCODE_ANSWER
            ;;
        esac
      fi
    else
      proxycode_choose 'WireProxy source' 'Pinned WireProxy v1.1.3' 'Custom executable' || exit 2
      if [[ $PROXYCODE_CHOICE == 2 ]]; then
        proxycode_prompt 'Custom WireProxy executable' || exit 2
        custom_binary=${PROXYCODE_ANSWER/#\~/$HOME}
      fi
    fi
  fi
fi
if $interactive; then
  printf '\033[?25h'
  trap - EXIT
fi

os=$(uname -s)
machine=$(uname -m)
if [[ $os != Linux ]]; then
  die "unsupported platform: $os/$machine (supported: Linux x86_64, aarch64, arm64)"
fi
case $machine in
  x86_64)
    wireproxy_arch=amd64
    expected_digest=$WIREPROXY_AMD64_SHA256
    ;;
  aarch64|arm64)
    wireproxy_arch=arm64
    expected_digest=$WIREPROXY_ARM64_SHA256
    ;;
  *) die "unsupported platform: $os/$machine (supported: Linux x86_64, aarch64, arm64)" ;;
esac

if [[ -n $custom_binary ]]; then
  [[ -f $custom_binary && -x $custom_binary && ! -L $custom_binary ]] || die 'custom WireProxy must be a regular executable file, not a symlink'
fi

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/proxycode-install.XXXXXX") || die 'cannot create private staging directory'
cleanup() {
  $interactive && printf '\033[?25h'
  [[ -n ${work_dir:-} && -d $work_dir ]] && rm -rf -- "$work_dir"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
mkdir -p "$work_dir/payload"

wireproxy_source=pinned
if [[ -n $custom_binary ]]; then
  cp -- "$custom_binary" "$work_dir/payload/wireproxy" || die 'cannot copy custom WireProxy'
  wireproxy_source=custom
else
  archive=$work_dir/wireproxy.tar.gz
  asset=wireproxy_linux_${wireproxy_arch}.tar.gz
  curl --proto '=https' --tlsv1.2 -fL --retry 2 -o "$archive" "$WIREPROXY_RELEASE/$asset" || die 'WireProxy download failed'
  actual_digest=$(sha256sum "$archive") || die 'cannot calculate WireProxy checksum'
  actual_digest=${actual_digest%% *}
  [[ $actual_digest == "$expected_digest" ]] || die "WireProxy checksum mismatch (expected $expected_digest, got $actual_digest)"

  members=$(tar -tzf "$archive") || die 'WireProxy archive is unreadable'
  [[ $members == wireproxy ]] || die 'WireProxy archive contains unsafe or unexpected members'
  tar -xzf "$archive" -C "$work_dir/payload" -- wireproxy || die 'WireProxy archive extraction failed'
  [[ -f $work_dir/payload/wireproxy && ! -L $work_dir/payload/wireproxy ]] || die 'WireProxy archive did not contain a regular binary'
fi
chmod 700 "$work_dir/payload/wireproxy" || die 'cannot secure staged WireProxy'

version_output=$("$work_dir/payload/wireproxy" --version 2>&1) || die 'WireProxy version check failed'
if [[ $version_output =~ v?([0-9]+\.[0-9]+\.[0-9]+) ]]; then
  installed_wireproxy_version=${BASH_REMATCH[1]}
else
  die 'WireProxy returned an unrecognized version'
fi
[[ $wireproxy_source == custom || $installed_wireproxy_version == "$WIREPROXY_VERSION" ]] || die "WireProxy version mismatch (expected $WIREPROXY_VERSION, got $installed_wireproxy_version)"
help_output=$("$work_dir/payload/wireproxy" --help 2>&1) || die 'WireProxy help check failed'
[[ $help_output == *--configtest* ]] || die 'WireProxy is incompatible: --configtest is unavailable'
cat >"$work_dir/compatibility.conf" <<'EOF'
[Interface]
Address = 192.0.2.1/32
PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=

[Peer]
PublicKey = AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=
Endpoint = 127.0.0.1:1
AllowedIPs = 0.0.0.0/0

[HTTP]
BindAddress = 127.0.0.1:25345
Username = proxycode
Password = compatibility-check
EOF
"$work_dir/payload/wireproxy" --config "$work_dir/compatibility.conf" --configtest >/dev/null 2>&1 || die 'WireProxy configuration compatibility check failed'
wireproxy_digest=$(sha256sum "$work_dir/payload/wireproxy") || die 'cannot calculate WireProxy binary digest'
wireproxy_digest=${wireproxy_digest%% *}

while IFS= read -r line || [[ -n $line ]]; do
  if [[ $line == 'library=@PROXYCODE_LIBRARY@' ]]; then
    printf 'library=%q\n' "$PROXYCODE_DATA_DIR/lib/proxycode.sh"
  else
    printf '%s\n' "$line"
  fi
done <"$source_root/bin/proxycode" >"$work_dir/payload/proxycode" || die 'cannot stage proxycode'
cp -- "$source_root/lib/proxycode.sh" "$work_dir/payload/proxycode.sh" || die 'cannot stage Toolkit library'
cat >"$work_dir/payload/wireproxy.LICENSE" <<'EOF'
Copyright (c) 2026 Tsz Fung Wong <im@windtfw.com>

Permission to use, copy, modify, and distribute this software for any
purpose with or without fee is hereby granted, provided that the above
copyright notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
EOF
cat >"$work_dir/payload/install" <<EOF
PROXYCODE_VERSION=$PROXYCODE_VERSION
WIREPROXY_VERSION=$installed_wireproxy_version
WIREPROXY_SHA256=$wireproxy_digest
WIREPROXY_SOURCE=$wireproxy_source
EOF
chmod 700 "$work_dir/payload/proxycode"
chmod 600 "$work_dir/payload/proxycode.sh" "$work_dir/payload/wireproxy.LICENSE" "$work_dir/payload/install"
bash -n "$work_dir/payload/proxycode" "$work_dir/payload/proxycode.sh" || die 'staged Toolkit validation failed'

acquire_lifecycle_lock
installation_present=false
installation_complete=true
for installed_path in "$PROXYCODE_BIN_DIR/proxycode" "$PROXYCODE_DATA_DIR/bin/wireproxy" "$PROXYCODE_DATA_DIR/lib/proxycode.sh" "$PROXYCODE_DATA_DIR/licenses/wireproxy.LICENSE" "$PROXYCODE_STATE_DIR/install"; do
  [[ -e $installed_path ]] && installation_present=true
  [[ -e $installed_path ]] || installation_complete=false
done
proxycode_inspect_active || die 'cannot inspect lifecycle state'
case $PROXYCODE_ACTIVE_STATUS in
  active|starting) die "Tunnel Profile '$PROXYCODE_ACTIVE_PROFILE' is active; run 'proxycode stop' before reinstalling" ;;
  ambiguous)
    proxycode_ambiguous_guidance
    die 'active process identity is ambiguous; refusing to reinstall'
    ;;
esac

if $installation_present; then
  current_toolkit_version= current_wireproxy_version= current_wireproxy_digest= current_wireproxy_source=
  if [[ -r $PROXYCODE_STATE_DIR/install ]]; then
    current_toolkit_version=$(proxycode_read_setting "$PROXYCODE_STATE_DIR/install" PROXYCODE_VERSION)
    current_wireproxy_version=$(proxycode_read_setting "$PROXYCODE_STATE_DIR/install" WIREPROXY_VERSION)
    current_wireproxy_digest=$(proxycode_read_setting "$PROXYCODE_STATE_DIR/install" WIREPROXY_SHA256)
    current_wireproxy_source=$(proxycode_read_setting "$PROXYCODE_STATE_DIR/install" WIREPROXY_SOURCE)
  fi
  if [[ $current_toolkit_version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && version_is_newer "$current_toolkit_version" "$PROXYCODE_VERSION"; then
    die "installed Toolkit has newer Toolkit version $current_toolkit_version; refusing to downgrade to $PROXYCODE_VERSION"
  fi
  if ! $installation_complete ||
    [[ ! $current_toolkit_version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ! $current_wireproxy_version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ! $current_wireproxy_digest =~ ^[0-9a-f]{64}$ || ! $current_wireproxy_source =~ ^(pinned|custom)$ ]]; then
    printf 'Detected an incomplete installation; repairing it. If interrupted, rerun this fixed-version installer.\n'
  fi
fi

replacing_profile=false
if [[ $mode == profile ]]; then
  proxycode_validate_profile_name "$name" || die "invalid Tunnel Profile name '$name'" 2
  [[ -f $wg_config && -r $wg_config ]] || die "cannot read WireGuard configuration '$wg_config'" 2
  source_file=$(readlink -f "$wg_config") || die 'cannot resolve the WireGuard configuration' 2
  for managed_root in "$live_config_dir" "$live_data_dir" "$live_state_dir" "$live_runtime_dir"; do
    managed_root=$(readlink -m "$managed_root") || die 'cannot resolve a Toolkit directory'
    case $source_file in
      "$managed_root"|"$managed_root"/*) die 'the original WireGuard configuration must be outside Toolkit-managed directories' 2 ;;
    esac
  done
  live_profile=$live_data_dir/profiles/$name
  if [[ -e $live_profile ]]; then
    replacing_profile=true
    $replace || die "Tunnel Profile '$name' already exists; use --replace" 2
  fi

  export HOME=$work_dir/setup/home
  export XDG_CONFIG_HOME=$work_dir/setup/config XDG_DATA_HOME=$work_dir/setup/data XDG_STATE_HOME=$work_dir/setup/state XDG_RUNTIME_DIR=$work_dir/setup/runtime
  mkdir -p "$HOME" "$XDG_RUNTIME_DIR" || die 'cannot prepare Profile staging'
  proxycode_init_paths || die 'cannot initialize Profile staging'
  proxycode_prepare_storage || die 'cannot prepare Profile staging'
  mkdir -p "$PROXYCODE_DATA_DIR/bin" "$PROXYCODE_STATE_DIR" "$PROXYCODE_RUNTIME_DIR" || die 'cannot prepare Profile staging'
  chmod 700 "$PROXYCODE_DATA_DIR/bin" "$PROXYCODE_STATE_DIR" "$PROXYCODE_RUNTIME_DIR" || die 'cannot secure Profile staging'
  cp -- "$work_dir/payload/wireproxy" "$PROXYCODE_DATA_DIR/bin/wireproxy" || die 'cannot stage WireProxy for Profile validation'
  if [[ -r $live_config_dir/settings ]]; then
    cp -- "$live_config_dir/settings" "$PROXYCODE_CONFIG_DIR/settings" || die 'cannot stage listener settings'
  fi
  if [[ -d $live_profile ]]; then
    cp -R -- "$live_profile" "$PROXYCODE_DATA_DIR/profiles/$name" || die 'cannot stage the existing Tunnel Profile'
  fi
  [[ -z $http_port ]] || proxycode_settings_update "$http_port" >/dev/null || die 'invalid HTTP listener settings' 2
  proxycode_profile_import "$source_file" "$name" "$make_default" "$replace" true >/dev/null || die 'WireGuard configuration validation failed'
  if [[ -n $probe ]]; then
    proxycode_profile_settings_update "$name" "$probe" "$expectation" "$url" "$expected_status" "$contains" >/dev/null || die 'invalid probe settings' 2
  elif [[ -n $expectation$url$expected_status$contains ]]; then
    die '--expect-location, --url, --status, and --contains require --probe' 2
  fi
  setup_profile=$PROXYCODE_DATA_DIR/profiles/$name
  setup_settings=$PROXYCODE_CONFIG_DIR/settings
  review_http_port=$(proxycode_read_setting "$PROXYCODE_CONFIG_DIR/settings" HTTP_PORT)
  review_default_profile=$(proxycode_read_setting "$PROXYCODE_CONFIG_DIR/settings" DEFAULT_PROFILE)
  review_probe=$(proxycode_read_setting "$setup_profile/settings" PROBE)
  review_expectation=$(proxycode_read_setting "$setup_profile/settings" EXPECT_LOCATION)
  review_url=$(proxycode_read_setting "$setup_profile/settings" URL)
  review_status=$(proxycode_read_setting "$setup_profile/settings" STATUS)
  review_contains=$(proxycode_read_setting "$setup_profile/settings" CONTAINS)
  export HOME=$live_home XDG_CONFIG_HOME=$live_xdg_config XDG_DATA_HOME=$live_xdg_data XDG_STATE_HOME=$live_xdg_state XDG_RUNTIME_DIR=$live_xdg_runtime
  proxycode_init_paths || exit 1
fi

if $interactive; then
  printf '\033[?25l\n%s%s◆ ProxyCode%s  review\n\n' "$PROXYCODE_PURPLE" "$PROXYCODE_BOLD" "$PROXYCODE_RESET"
else
  printf 'Review installation:\n'
fi
printf '  Mode: %s\n' "$([[ $mode == profile ]] && printf 'install and set up a Tunnel Profile' || printf 'install only')"
printf '  WireProxy: %s v%s\n' "$wireproxy_source" "$installed_wireproxy_version"
[[ $wireproxy_source != custom ]] || printf '  WireProxy executable: %s\n' "$custom_binary"
if [[ $mode == profile ]]; then
  [[ $review_default_profile == "$name" ]] && review_default=yes || review_default=no
  $start_after && review_start=yes || review_start=no
  printf '  WireGuard configuration: %s\n  Profile: %s\n  Default: %s\n  Start and check: %s\n  HTTP port: %s\n  Probe: %s\n' \
    "$source_file" "$name" "$review_default" "$review_start" "$review_http_port" "$review_probe"
  case $review_probe in
    cloudflare|mullvad) printf '  Expected location: %s\n' "${review_expectation:-any}" ;;
    custom)
      printf '  Probe URL: %s\n  Expected status: %s\n  Required response text: %s\n' \
        "$review_url" "$review_status" "${review_contains:-any}"
      ;;
  esac
fi
if $interactive; then
  printf '\n%s◇ Ready to install%s\n\n%s[Enter] install  ·  [R] restart%s\n' \
    "$PROXYCODE_GREEN" "$PROXYCODE_RESET" "$PROXYCODE_MUTED" "$PROXYCODE_RESET"
  review_confirmed=false
  while IFS= read -rsN1 review_key; do
    case $review_key in
      $'\n'|$'\r') printf '\033[?25h'; review_confirmed=true; break ;;
      r|R)
        printf '\033[?25h'
        [[ -z ${INSTALL_LEGACY_LOCK_FD:-} ]] || exec {INSTALL_LEGACY_LOCK_FD}>&-
        exec {INSTALL_LOCK_FD}>&-
        cleanup
        exec bash "$script_path"
        die 'could not restart setup'
        ;;
    esac
  done
  if ! $review_confirmed; then
    printf '\033[?25h'
    printf 'Cancelled. No changes were made.\n'
    exit 0
  fi
fi
if $replacing_profile && ! $interactive; then
  proxycode_confirm "$yes" "Replace Tunnel Profile '$name'?" || exit
fi

directories=(
  "$PROXYCODE_BIN_DIR"
  "$PROXYCODE_CONFIG_DIR"
  "$PROXYCODE_DATA_DIR"
  "$PROXYCODE_DATA_DIR/bin"
  "$PROXYCODE_DATA_DIR/lib"
  "$PROXYCODE_DATA_DIR/licenses"
  "$PROXYCODE_DATA_DIR/profiles"
  "$PROXYCODE_STATE_DIR"
)
sources=(
  "$work_dir/payload/wireproxy"
  "$work_dir/payload/proxycode.sh"
  "$work_dir/payload/wireproxy.LICENSE"
  "$work_dir/payload/proxycode"
)
targets=(
  "$PROXYCODE_DATA_DIR/bin/wireproxy"
  "$PROXYCODE_DATA_DIR/lib/proxycode.sh"
  "$PROXYCODE_DATA_DIR/licenses/wireproxy.LICENSE"
  "$PROXYCODE_BIN_DIR/proxycode"
)
modes=(700 600 600 700)
if [[ $mode == profile ]]; then
  directories+=("$PROXYCODE_DATA_DIR/profiles/$name")
  for profile_file in wireguard.conf wireproxy.conf settings proxy-credential; do
    sources+=("$setup_profile/$profile_file")
    targets+=("$PROXYCODE_DATA_DIR/profiles/$name/$profile_file")
    modes+=(600)
  done
  sources+=("$setup_settings")
  targets+=("$PROXYCODE_CONFIG_DIR/settings")
  modes+=(600)
fi
sources+=("$work_dir/payload/install")
targets+=("$PROXYCODE_STATE_DIR/install")
modes+=(600)
new_directories=()
temporaries=()
existed=()
commit_count=0
commit_complete=false
rollback_install() {
  local index restore failed=false
  for ((index = commit_count - 1; index >= 0; index--)); do
    if ${existed[index]}; then
      restore=${targets[index]}.restore.$$
      cp -p -- "$work_dir/backups/$index" "$restore" && mv -f -- "$restore" "${targets[index]}" || failed=true
    else
      rm -f -- "${targets[index]}" || failed=true
    fi
  done
  for temporary in "${temporaries[@]}"; do
    rm -f -- "$temporary"
  done
  for ((index = ${#new_directories[@]} - 1; index >= 0; index--)); do
    rmdir -- "${new_directories[index]}" 2>/dev/null || true
  done
  $failed && printf 'proxycode installer: rollback was incomplete; rerun this fixed-version installer\n' >&2
}
finish() {
  $commit_complete || rollback_install
  cleanup
}
trap finish EXIT

for directory in "${directories[@]}"; do
  [[ -d $directory ]] || new_directories+=("$directory")
  mkdir -p "$directory" || die "cannot create $directory"
done
chmod 700 "${directories[@]:1}" || die 'cannot secure Toolkit directories'

mkdir "$work_dir/backups"
for index in "${!targets[@]}"; do
  temporary=${targets[index]}.new.$$
  temporaries+=("$temporary")
  cp -- "${sources[index]}" "$temporary" || die "cannot stage ${targets[index]##*/} beside its destination"
  chmod "${modes[index]}" "$temporary" || die "cannot secure ${targets[index]##*/}"
  if [[ -e ${targets[index]} ]]; then
    cp -p -- "${targets[index]}" "$work_dir/backups/$index" || die "cannot preserve ${targets[index]##*/}"
    existed+=(true)
  else
    existed+=(false)
  fi
done

for index in "${!targets[@]}"; do
  mv -f -- "${temporaries[index]}" "${targets[index]}" || die "cannot install ${targets[index]##*/}"
  commit_count=$((commit_count + 1))
done
commit_complete=true

printf 'Installed proxycode %s.\n' "$PROXYCODE_VERSION"
printf 'Installed %s WireProxy v%s.\n' "$wireproxy_source" "$installed_wireproxy_version"
if [[ $mode == profile ]]; then
  $replacing_profile && printf 'Replaced Tunnel Profile: %s\n' "$name" || printf 'Imported Tunnel Profile: %s\n' "$name"
  $make_default && printf 'Default Tunnel Profile: %s\n' "$name"
fi
case :$PATH: in
  *:"$PROXYCODE_BIN_DIR":*) ;;
  *) printf 'Add proxycode to PATH: export PATH="$HOME/.local/bin:$PATH"\n' ;;
esac
if $start_after; then
  [[ -z ${INSTALL_LEGACY_LOCK_FD:-} ]] || exec {INSTALL_LEGACY_LOCK_FD}>&-
  exec {INSTALL_LOCK_FD}>&-
  proxycode_with_lifecycle_lock proxycode_start_locked "$name" || exit
elif [[ $mode == install-only ]] && { [[ ! -d $PROXYCODE_DATA_DIR/profiles ]] || ! compgen -G "$PROXYCODE_DATA_DIR/profiles/*" >/dev/null; }; then
  printf 'No Tunnel Profile configured. Resume with: proxycode profile import FILE --name NAME [--default]\n'
fi
