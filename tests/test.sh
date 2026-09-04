#!/usr/bin/env bash

set -u

ROOT=$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)
SYSTEM_PATH=$PATH
TESTS=0
FAILURES=0
TEST_HOMES=()

cleanup_tests() {
  local directory
  for directory in "${TEST_HOMES[@]}"; do
    rm -rf -- "$directory"
  done
}
trap cleanup_tests EXIT

fail() {
  printf 'not ok %d - %s\n' "$TESTS" "$1"
  FAILURES=$((FAILURES + 1))
}

assert_eq() {
  local expected=$1 actual=$2 message=$3
  [[ $actual == "$expected" ]] || fail "$message (expected '$expected', got '$actual')"
}

assert_mode() {
  assert_eq "$2" "$(stat -c '%a' "$1")" "$1 mode"
}

assert_status() {
  local expected=$1 message=$2 actual
  shift 2
  "$@" >/dev/null 2>&1
  actual=$?
  assert_eq "$expected" "$actual" "$message"
}

new_home() {
  TEST_HOME=$(mktemp -d)
  TEST_HOMES+=("$TEST_HOME")
  export PATH=$SYSTEM_PATH
  export HOME=$TEST_HOME/home
  export XDG_CONFIG_HOME=$TEST_HOME/config
  export XDG_DATA_HOME=$TEST_HOME/data
  export XDG_STATE_HOME=$TEST_HOME/state
  export XDG_RUNTIME_DIR=$TEST_HOME/runtime
  mkdir -p "$HOME" "$XDG_RUNTIME_DIR"
}

installation_digest() {
  /usr/bin/sha256sum \
    "$HOME/.local/bin/proxycode" \
    "$XDG_DATA_HOME/proxycode/bin/wireproxy" \
    "$XDG_DATA_HOME/proxycode/lib/proxycode.sh" \
    "$XDG_DATA_HOME/proxycode/licenses/wireproxy.LICENSE" \
    "$XDG_STATE_HOME/proxycode/install"
}

fake_wireproxy() {
  local target=$1 version=${2:-1.1.3}
  mkdir -p "${target%/*}"
  cat >"$target" <<EOF
#!/usr/bin/env bash
case \${1:-} in
  --version) printf 'wireproxy v${version}\\n' ;;
  --help) printf '%s\\n' 'Usage: wireproxy --config FILE [--configtest]' ;;
  --config) [[ -n \${WIREPROXY_CONFIGTEST_FAIL:-} ]] && { printf 'PrivateKey = must-not-print\\n' >&2; exit 1; }; printf 'Config OK\\n' ;;
  *) exit 2 ;;
esac
EOF
  chmod 700 "$target"
}

install_custom_binary() {
  fake_wireproxy "$TEST_HOME/custom/wireproxy"
  bash "$ROOT/install.sh" --install-only --wireproxy-bin "$TEST_HOME/custom/wireproxy"
}

write_wireguard_config() {
  mkdir -p "${1%/*}"
  cat >"$1" <<'EOF'
[Interface]
PrivateKey = test-input-is-data
Address = 192.0.2.2/32

[Peer]
PublicKey = test-peer
Endpoint = 192.0.2.1:51820
AllowedIPs = 0.0.0.0/0
# $(touch "$HOME/proxycode-must-not-evaluate-input")
EOF
  chmod 600 "$1"
}

test_custom_install_and_cli() {
  TESTS=$((TESTS + 1))
  new_home

  local output
  output=$(install_custom_binary) || { fail 'custom install succeeds'; return; }
  [[ $output == *'Installed proxycode 1.0.0.'* ]] || fail 'install reports Toolkit version'
  [[ $output == *'custom WireProxy v1.1.3'* ]] || fail 'install identifies custom WireProxy'

  local cli=$HOME/.local/bin/proxycode
  assert_eq 'proxycode 1.0.0' "$("$cli" version)" 'version output'
  [[ $("$cli" help) == Usage:* ]] || fail 'help output starts with usage'
  assert_mode "$cli" 700
  assert_mode "$XDG_DATA_HOME/proxycode/bin/wireproxy" 700
  assert_mode "$XDG_DATA_HOME/proxycode/lib/proxycode.sh" 600
  assert_mode "$XDG_DATA_HOME/proxycode/licenses/wireproxy.LICENSE" 600
  assert_mode "$XDG_STATE_HOME/proxycode/install" 600
  assert_mode "$XDG_DATA_HOME/proxycode" 700
  grep -q '^WIREPROXY_SOURCE=custom$' "$XDG_STATE_HOME/proxycode/install" || fail 'custom source is recorded'
  grep -q '^Copyright (c) 2026 Tsz Fung Wong' "$XDG_DATA_HOME/proxycode/licenses/wireproxy.LICENSE" || fail 'upstream notice is preserved'
}

test_profile_import_default_and_show() {
  TESTS=$((TESTS + 1))
  new_home
  install_custom_binary >/dev/null || { fail 'Profile test install succeeds'; return; }
  local source=$TEST_HOME/source/work.conf cli=$HOME/.local/bin/proxycode output password source_hash
  write_wireguard_config "$source"
  source_hash=$(/usr/bin/sha256sum "$source")

  output=$("$cli" profile import "$source" --name work --default) || { fail 'Profile import succeeds'; return; }
  assert_eq $'Imported Tunnel Profile: work\nDefault Tunnel Profile: work' "$output" 'Profile import output'
  assert_eq 'work' "$("$cli" profile list)" 'Profile list output'
  assert_eq $'Name: work\nDefault: yes\nProbe: cloudflare\nExpected location: any' "$("$cli" profile show work)" 'Profile show output'
  assert_eq $'HTTP port: 25345\nSOCKS port: 25344' "$("$cli" settings)" 'default listener settings'

  local profile=$XDG_DATA_HOME/proxycode/profiles/work
  assert_eq "$source_hash" "$(/usr/bin/sha256sum "$source")" 'import leaves the source unchanged'
  cmp -s "$source" "$profile/wireguard.conf" || fail 'import copies the source unchanged'
  [[ -e $HOME/proxycode-must-not-evaluate-input ]] && fail 'import evaluates WireGuard input'
  assert_mode "$XDG_CONFIG_HOME/proxycode" 700
  assert_mode "$XDG_CONFIG_HOME/proxycode/settings" 600
  assert_mode "$profile" 700
  assert_mode "$profile/wireguard.conf" 600
  assert_mode "$profile/wireproxy.conf" 600
  assert_mode "$profile/settings" 600
  assert_mode "$profile/proxy-credential" 600
  grep -q '^WGConfig = wireguard.conf$' "$profile/wireproxy.conf" || fail 'generated config uses the private copy'
  grep -q '^BindAddress = 127.0.0.1:25344$' "$profile/wireproxy.conf" || fail 'SOCKS listener is loopback-only'
  grep -q '^BindAddress = 127.0.0.1:25345$' "$profile/wireproxy.conf" || fail 'HTTP listener is loopback-only'
  grep -q '^USERNAME=proxy-code$' "$profile/proxy-credential" || fail 'credential has the fixed username'
  password=$(sed -n 's/^PASSWORD=//p' "$profile/proxy-credential")
  [[ $password =~ ^[0-9a-f]{96}$ ]] || fail 'credential has a URL-safe generated password'
  [[ $(grep -c '^Username = proxy-code$' "$profile/wireproxy.conf") == 2 ]] || fail 'both listeners use the fixed username'
  [[ $(grep -c "^Password = $password$" "$profile/wireproxy.conf") == 2 ]] || fail 'both listeners use the stored password'
  [[ $output != *"$password"* ]] || fail 'import output exposes the credential'
}

test_profile_replacement_and_validation_rollback() {
  TESTS=$((TESTS + 1))
  new_home
  install_custom_binary >/dev/null || { fail 'replacement test install succeeds'; return; }
  local cli=$HOME/.local/bin/proxycode source=$TEST_HOME/source/work.conf profile before credential output status
  write_wireguard_config "$source"
  output=$(WIREPROXY_CONFIGTEST_FAIL=1 "$cli" profile import "$source" --name rejected 2>&1)
  status=$?
  assert_eq 1 "$status" 'new Profile validation failure status'
  [[ ! -e $XDG_DATA_HOME/proxycode/profiles/rejected ]] || fail 'failed validation leaves a new Profile behind'
  "$cli" profile import "$source" --name work --default >/dev/null || { fail 'baseline Profile import succeeds'; return; }
  profile=$XDG_DATA_HOME/proxycode/profiles/work
  "$cli" profile settings work --probe mullvad --expect-location Singapore >/dev/null || { fail 'replacement setup preserves health settings'; return; }
  credential=$(<"$profile/proxy-credential")

  printf '\n# replacement\n' >>"$source"
  output=$("$cli" profile import "$source" --name work 2>&1)
  status=$?
  assert_eq 2 "$status" 'duplicate import requires replacement'
  [[ $output == *'use --replace'* ]] || fail 'duplicate import gives replacement guidance'

  output=$("$cli" profile import "$source" --name work --replace 2>&1)
  status=$?
  assert_eq 2 "$status" 'non-interactive replacement requires consent'
  before=$(/usr/bin/sha256sum "$profile/"*)
  output=$(WIREPROXY_CONFIGTEST_FAIL=1 "$cli" profile import "$source" --name work --replace --yes 2>&1)
  status=$?
  assert_eq 1 "$status" 'replacement validation failure status'
  [[ $output == *'validation failed'* ]] || fail 'replacement validation failure is safe and actionable'
  [[ $output != *'must-not-print'* ]] || fail 'replacement prints raw validation output'
  assert_eq "$before" "$(/usr/bin/sha256sum "$profile/"*)" 'failed replacement preserves the Profile'

  output=$("$cli" profile import "$source" --name work --replace --yes) || { fail 'confirmed replacement succeeds'; return; }
  assert_eq 'Replaced Tunnel Profile: work' "$output" 'replacement output'
  cmp -s "$source" "$profile/wireguard.conf" || fail 'replacement installs the new private copy'
  assert_eq "$credential" "$(<"$profile/proxy-credential")" 'replacement preserves the Proxy credential'
  assert_eq $'Probe: mullvad\nExpected location: Singapore' "$("$cli" profile settings work)" 'replacement preserves health settings'
  assert_eq 'work' "$(sed -n 's/^DEFAULT_PROFILE=//p' "$XDG_CONFIG_HOME/proxycode/settings")" 'replacement preserves the Default'
}

test_global_and_profile_settings() {
  TESTS=$((TESTS + 1))
  new_home
  install_custom_binary >/dev/null || { fail 'settings test install succeeds'; return; }
  local cli=$HOME/.local/bin/proxycode source=$TEST_HOME/source/work.conf profile broken output status settings_before config_before travel_before
  write_wireguard_config "$source"
  "$cli" profile import "$source" --name work >/dev/null || { fail 'settings test import succeeds'; return; }
  profile=$XDG_DATA_HOME/proxycode/profiles/work

  assert_eq $'Probe: cloudflare\nExpected location: any' "$("$cli" profile settings work)" 'default Profile probe settings'
  assert_eq $'Probe: mullvad\nExpected location: Singapore' "$("$cli" profile settings work --probe mullvad --expect-location Singapore)" 'Mullvad probe settings'
  assert_eq $'Probe: custom\nURL: https://example.test/health\nStatus: 204\nContains: configured' "$("$cli" profile settings work --probe custom --url https://example.test/health --status 204 --contains ready)" 'custom probe settings'
  grep -q '^CONTAINS=ready$' "$profile/settings" || fail 'custom literal is stored privately'

  output=$("$cli" profile settings work --probe cloudflare --expect-location Singapore 2>&1)
  status=$?
  assert_eq 2 "$status" 'invalid Cloudflare country status'
  [[ $output == *'two uppercase ASCII letters'* ]] || fail 'invalid Cloudflare country is explained'
  assert_eq $'Probe: custom\nURL: https://example.test/health\nStatus: 204\nContains: configured' "$("$cli" profile settings work)" 'invalid probe update changes nothing'
  output=$("$cli" profile settings work --probe custom --url http://example.test --status 200 2>&1)
  status=$?
  assert_eq 2 "$status" 'non-HTTPS custom probe status'
  [[ $output == *'must use HTTPS'* ]] || fail 'non-HTTPS custom probe is explained'
  output=$("$cli" profile settings work --probe custom --url https://user@example.test --status 200 2>&1)
  status=$?
  assert_eq 2 "$status" 'credential-bearing custom probe status'
  [[ $output == *'no credentials'* ]] || fail 'credential-bearing custom probe is explained'
  for invalid_url in 'https://example.test/a b' https://example.test:99999; do
    output=$("$cli" profile settings work --probe custom --url "$invalid_url" --status 200 2>&1)
    status=$?
    assert_eq 2 "$status" "invalid custom probe URL status: $invalid_url"
  done

  "$cli" profile import "$source" --name broken >/dev/null || { fail 'rollback setup import succeeds'; return; }
  broken=$XDG_DATA_HOME/proxycode/profiles/broken
  rm "$broken/proxy-credential"
  settings_before=$(/usr/bin/sha256sum "$XDG_CONFIG_HOME/proxycode/settings")
  config_before=$(/usr/bin/sha256sum "$profile/wireproxy.conf")
  output=$("$cli" settings --http-port 32080 --socks-port 32081 2>&1)
  status=$?
  assert_eq 1 "$status" 'failed Profile regeneration status'
  [[ $output == *'could not prepare updated WireProxy configurations'* ]] || fail 'failed Profile regeneration is explained'
  assert_eq "$settings_before" "$(/usr/bin/sha256sum "$XDG_CONFIG_HOME/proxycode/settings")" 'failed regeneration preserves global settings'
  assert_eq "$config_before" "$(/usr/bin/sha256sum "$profile/wireproxy.conf")" 'failed regeneration preserves existing Profile configs'
  rm -rf "$broken"

  "$cli" profile import "$source" --name travel >/dev/null || { fail 'mid-commit rollback setup import succeeds'; return; }
  mkdir -p "$TEST_HOME/failing-path"
  cat >"$TEST_HOME/failing-path/mv" <<'EOF'
#!/usr/bin/env bash
target=${!#}
[[ $target == */profiles/work/wireproxy.conf ]] && exit 1
exec /usr/bin/mv "$@"
EOF
  chmod 700 "$TEST_HOME/failing-path/mv"
  travel_before=$(/usr/bin/sha256sum "$XDG_DATA_HOME/proxycode/profiles/travel/wireproxy.conf")
  output=$(PATH="$TEST_HOME/failing-path:$PATH" "$cli" settings --http-port 32080 --socks-port 32081 2>&1)
  status=$?
  assert_eq 1 "$status" 'mid-commit failure status'
  [[ $output == *'could not update WireProxy configurations'* ]] || fail 'mid-commit failure is explained'
  assert_eq "$settings_before" "$(/usr/bin/sha256sum "$XDG_CONFIG_HOME/proxycode/settings")" 'mid-commit failure preserves global settings'
  assert_eq "$config_before" "$(/usr/bin/sha256sum "$profile/wireproxy.conf")" 'mid-commit failure restores committed Profile configs'
  assert_eq "$travel_before" "$(/usr/bin/sha256sum "$XDG_DATA_HOME/proxycode/profiles/travel/wireproxy.conf")" 'mid-commit failure preserves uncommitted Profile configs'
  ! compgen -G "$XDG_DATA_HOME/proxycode/profiles/*/wireproxy.conf.old.*" >/dev/null || fail 'mid-commit failure leaves redundant backups'
  "$cli" profile remove travel --yes >/dev/null || { fail 'mid-commit rollback cleanup succeeds'; return; }

  assert_eq $'HTTP port: 31080\nSOCKS port: 31081' "$("$cli" settings --http-port 31080 --socks-port 31081)" 'global port update'
  grep -q '^BindAddress = 127.0.0.1:31080$' "$profile/wireproxy.conf" || fail 'HTTP port update regenerates Profile config'
  grep -q '^BindAddress = 127.0.0.1:31081$' "$profile/wireproxy.conf" || fail 'SOCKS port update regenerates Profile config'
  ! grep -q '_PORT=' "$profile/settings" || fail 'global ports are stored per Profile'
  output=$("$cli" settings --http-port 31081 2>&1)
  status=$?
  assert_eq 2 "$status" 'duplicate listener port status'
  [[ $output == *'must be distinct'* ]] || fail 'duplicate listener ports are explained'
  output=$("$cli" settings --http-port 65536 2>&1)
  status=$?
  assert_eq 2 "$status" 'out-of-range listener port status'
  output=$("$cli" settings --http-port 18446744073709551617 2>&1)
  status=$?
  assert_eq 2 "$status" 'overflowing listener port status'
  assert_eq $'HTTP port: 31080\nSOCKS port: 31081' "$("$cli" settings)" 'invalid port update changes nothing'
}

test_profile_default_name_validation_and_removal() {
  TESTS=$((TESTS + 1))
  new_home
  install_custom_binary >/dev/null || { fail 'removal test install succeeds'; return; }
  local cli=$HOME/.local/bin/proxycode source=$TEST_HOME/source/work.conf output status
  write_wireguard_config "$source"

  assert_status 2 'missing Profile show status' "$cli" profile show missing
  assert_status 2 'missing Profile settings show status' "$cli" profile settings missing
  assert_status 2 'missing Profile settings update status' "$cli" profile settings missing --probe cloudflare
  assert_status 2 'missing Profile default status' "$cli" profile default missing
  assert_status 2 'missing Profile removal status' "$cli" profile remove missing --yes
  assert_status 2 'unreadable import source status' "$cli" profile import "$TEST_HOME/missing.conf" --name missing

  "$cli" profile import "$source" --name work >/dev/null || { fail 'non-Default Profile import succeeds'; return; }
  assert_eq $'Name: work\nDefault: no\nProbe: cloudflare\nExpected location: any' "$("$cli" profile show work)" 'first Profile is not implicitly Default'
  assert_eq 'Default Tunnel Profile: work' "$("$cli" profile default work)" 'explicit Default selection'

  output=$("$cli" profile import "$source" --name ../escape 2>&1)
  status=$?
  assert_eq 2 "$status" 'unsafe Profile name status'
  [[ $output == *'invalid Tunnel Profile name'* ]] || fail 'unsafe Profile name is explained'
  [[ ! -e $XDG_DATA_HOME/proxycode/escape ]] || fail 'unsafe Profile name escapes the store'

  output=$("$cli" profile remove work 2>&1)
  status=$?
  assert_eq 2 "$status" 'non-interactive removal requires consent'
  [[ -d $XDG_DATA_HOME/proxycode/profiles/work ]] || fail 'unconfirmed removal changes the Profile'
  assert_eq 'Removed Tunnel Profile: work' "$("$cli" profile remove work --yes)" 'confirmed removal output'
  output=$("$cli" profile list)
  status=$?
  assert_eq 0 "$status" 'empty Profile list status'
  assert_eq '' "$output" 'removed Profile is absent from list'
  assert_eq '' "$(sed -n 's/^DEFAULT_PROFILE=//p' "$XDG_CONFIG_HOME/proxycode/settings")" 'removing Default clears it without choosing another'
  [[ -f $source ]] || fail 'Profile removal touches the source configuration'
}

make_release_fakes() {
  local arch=$1 digest_mode=${2:-valid}
  mkdir -p "$TEST_HOME/fakes"
  fake_wireproxy "$TEST_HOME/release-wireproxy"
  export FAKE_WIREPROXY=$TEST_HOME/release-wireproxy
  cat >"$TEST_HOME/fakes/uname" <<EOF
#!/usr/bin/env bash
[[ \${1:-} == -s ]] && printf 'Linux\\n' || printf '${arch}\\n'
EOF
  cat >"$TEST_HOME/fakes/curl" <<'EOF'
#!/usr/bin/env bash
for ((i=1; i<=$#; i++)); do
  if [[ ${!i} == -o ]]; then
    j=$((i + 1)); output=${!j}
  fi
done
printf '%s\n' "${!#}" >"$CURL_URL_LOG"
printf 'archive' >"$output"
EOF
  cat >"$TEST_HOME/fakes/tar" <<'EOF'
#!/usr/bin/env bash
case $1 in
  -tzf) printf 'wireproxy\n' ;;
  -xzf)
    while (($#)); do
      [[ $1 == -C ]] && { shift; destination=$1; break; }
      shift
    done
    mkdir -p "$destination"
    cp "$FAKE_WIREPROXY" "$destination/wireproxy"
    chmod 700 "$destination/wireproxy"
    ;;
  *) exit 2 ;;
esac
EOF
  cat >"$TEST_HOME/fakes/sha256sum" <<EOF
#!/usr/bin/env bash
case '${arch}:${digest_mode}' in
  x86_64:valid) digest=e88c1d090740373fc606c1bafd81d9a5eadc642cce5667616e20e9d7a444f51c ;;
  aarch64:valid) digest=370e00bd2167960d1ecd1c3c1439715bbaa94a0a110a2040468670c9af6021b6 ;;
  *) digest=bad ;;
esac
printf '%s  %s\\n' "\$digest" "\$1"
EOF
  chmod 700 "$TEST_HOME/fakes/"*
  export CURL_URL_LOG=$TEST_HOME/curl-url
  export PATH=$TEST_HOME/fakes:/usr/bin:/bin
}

test_pinned_architectures() {
  local arch asset
  for arch in x86_64 aarch64; do
    TESTS=$((TESTS + 1))
    new_home
    make_release_fakes "$arch"
    [[ $arch == x86_64 ]] && asset=amd64 || asset=arm64

    bash "$ROOT/install.sh" --install-only >/dev/null || { fail "$arch pinned install succeeds"; continue; }
    assert_eq "https://github.com/windtf/wireproxy/releases/download/v1.1.3/wireproxy_linux_${asset}.tar.gz" "$(<"$CURL_URL_LOG")" "$arch uses pinned asset"
    grep -q '^WIREPROXY_SOURCE=pinned$' "$XDG_STATE_HOME/proxycode/install" || fail "$arch pinned source is recorded"
  done
}

test_verification_failure_preserves_installation() {
  TESTS=$((TESTS + 1))
  new_home
  install_custom_binary >/dev/null || { fail 'baseline install succeeds'; return; }
  local before after output status
  before=$(installation_digest)
  make_release_fakes x86_64 invalid

  output=$(bash "$ROOT/install.sh" --install-only 2>&1)
  status=$?
  after=$(installation_digest)
  assert_eq 1 "$status" 'checksum failure status'
  [[ $output == *'checksum mismatch'* ]] || fail 'checksum failure is explained'
  assert_eq "$before" "$after" 'checksum failure preserves installed files'
  grep -q '^WIREPROXY_SOURCE=custom$' "$XDG_STATE_HOME/proxycode/install" || fail 'checksum failure preserves metadata'
}

test_commit_failure_rolls_back() {
  TESTS=$((TESTS + 1))
  new_home
  install_custom_binary >/dev/null || { fail 'baseline install succeeds'; return; }
  local before after output status
  before=$(installation_digest)
  fake_wireproxy "$TEST_HOME/custom/new-wireproxy" 1.2.0
  mkdir -p "$TEST_HOME/failing-path"
  export MV_COUNT_FILE=$TEST_HOME/mv-count
  cat >"$TEST_HOME/failing-path/mv" <<'EOF'
#!/usr/bin/env bash
count=0
[[ -f $MV_COUNT_FILE ]] && count=$(<"$MV_COUNT_FILE")
count=$((count + 1))
printf '%s\n' "$count" >"$MV_COUNT_FILE"
((count == 3)) && exit 1
exec /usr/bin/mv "$@"
EOF
  chmod 700 "$TEST_HOME/failing-path/mv"
  PATH=$TEST_HOME/failing-path:$SYSTEM_PATH

  output=$(bash "$ROOT/install.sh" --install-only --wireproxy-bin "$TEST_HOME/custom/new-wireproxy" 2>&1)
  status=$?
  after=$(installation_digest)
  assert_eq 1 "$status" 'commit failure status'
  [[ $output == *'cannot install wireproxy.LICENSE'* ]] || fail 'commit failure is reported'
  assert_eq "$before" "$after" 'commit failure restores every installed file'
}

test_unsupported_platform_changes_nothing() {
  TESTS=$((TESTS + 1))
  new_home
  make_release_fakes riscv64

  local output status
  output=$(bash "$ROOT/install.sh" --install-only 2>&1)
  status=$?
  assert_eq 1 "$status" 'unsupported architecture status'
  [[ $output == *'unsupported platform: Linux/riscv64'* ]] || fail 'unsupported architecture is reported'
  [[ ! -e $XDG_DATA_HOME/proxycode ]] || fail 'unsupported platform writes no Toolkit data'
}

test_missing_dependencies_change_nothing() {
  TESTS=$((TESTS + 1))
  new_home
  local original_path=$PATH output status
  mkdir -p "$TEST_HOME/empty-path"
  PATH=$TEST_HOME/empty-path

  output=$(/usr/bin/bash "$ROOT/install.sh" --install-only 2>&1)
  status=$?
  PATH=$original_path
  assert_eq 1 "$status" 'missing dependency status'
  [[ $output == *'missing required commands: curl flock tar sha256sum timeout mktemp readlink stat nohup awk grep sed'* ]] || fail 'all missing dependencies are reported together'
  [[ ! -e $XDG_DATA_HOME/proxycode ]] || fail 'missing dependencies write no Toolkit data'
}

test_custom_install_and_cli
test_profile_import_default_and_show
test_profile_replacement_and_validation_rollback
test_global_and_profile_settings
test_profile_default_name_validation_and_removal
test_pinned_architectures
test_verification_failure_preserves_installation
test_commit_failure_rolls_back
test_unsupported_platform_changes_nothing
test_missing_dependencies_change_nothing

if ((FAILURES)); then
  printf '%d of %d tests failed\n' "$FAILURES" "$TESTS" >&2
  exit 1
fi
printf 'ok - %d tests passed\n' "$TESTS"
