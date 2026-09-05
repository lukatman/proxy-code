#!/usr/bin/env bash

set -u
set -o pipefail
umask 077

WIREPROXY_VERSION=1.1.3
WIREPROXY_AMD64_SHA256=e88c1d090740373fc606c1bafd81d9a5eadc642cce5667616e20e9d7a444f51c
WIREPROXY_ARM64_SHA256=370e00bd2167960d1ecd1c3c1439715bbaa94a0a110a2040468670c9af6021b6
WIREPROXY_RELEASE=https://github.com/windtf/wireproxy/releases/download/v1.1.3

die() {
  printf 'proxycode installer: %s\n' "$1" >&2
  exit "${2:-1}"
}

usage() {
  cat <<'EOF'
Usage:
  ./install.sh --install-only [--wireproxy-bin FILE]
  ./install.sh --uninstall [--yes]
  ./install.sh --purge [--yes]
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
yes=false
while (($#)); do
  case $1 in
    --install-only|--uninstall|--purge)
      [[ -z $mode ]] || die 'choose exactly one of --install-only, --uninstall, or --purge' 2
      mode=${1#--}
      ;;
    --wireproxy-bin)
      (($# >= 2)) || die '--wireproxy-bin requires a file' 2
      custom_binary=$2
      shift
      ;;
    --yes) yes=true ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown option '$1'" 2 ;;
  esac
  shift
done
[[ -n $mode ]] || die 'this release requires --install-only, --uninstall, or --purge' 2
if [[ $mode == install-only ]]; then
  $yes && die '--yes is only valid with --uninstall or --purge' 2
else
  [[ -z $custom_binary ]] || die '--wireproxy-bin is only valid with --install-only' 2
fi

if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4))); then
  die 'Bash 4.4 or newer is required'
fi

missing=()
if [[ $mode == install-only ]]; then
  required_commands=(curl flock tar sha256sum timeout mktemp readlink stat nohup awk grep sed)
else
  required_commands=(flock readlink stat awk)
fi
for command_name in "${required_commands[@]}"; do
  command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
done
((${#missing[@]} == 0)) || die "missing required commands: ${missing[*]}. Install them with your distribution package manager."

script_path=$(readlink -f "${BASH_SOURCE[0]}") || die 'cannot resolve installer path'
source_root=${script_path%/*}
[[ -r $source_root/lib/proxycode.sh && -r $source_root/bin/proxycode ]] || die 'source files are missing; run the installer from a complete release'
# shellcheck source=lib/proxycode.sh
source "$source_root/lib/proxycode.sh"
proxycode_init_paths || exit 1

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

if [[ $mode != install-only ]]; then
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
  "$work_dir/payload/install"
)
targets=(
  "$PROXYCODE_DATA_DIR/bin/wireproxy"
  "$PROXYCODE_DATA_DIR/lib/proxycode.sh"
  "$PROXYCODE_DATA_DIR/licenses/wireproxy.LICENSE"
  "$PROXYCODE_BIN_DIR/proxycode"
  "$PROXYCODE_STATE_DIR/install"
)
modes=(700 600 600 700 600)
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
case :$PATH: in
  *:"$PROXYCODE_BIN_DIR":*) ;;
  *) printf 'Add proxycode to PATH: export PATH="$HOME/.local/bin:$PATH"\n' ;;
esac
