#!/usr/bin/env bash

set -u

ROOT=$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)
SYSTEM_PATH=$PATH
TESTS=0
FAILURES=0
TEST_HOMES=()
DOWN=$'\033[B'
ESCAPE=$'\033'
BACKSPACE=$'\177'

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
  unset EXPECTED_PROXY_URL EXPECTED_WIREPROXY_EXE FAKE_CURL_BODY FAKE_CURL_CALLS FAKE_CURL_DELAY
  unset FAKE_CURL_EXIT FAKE_CURL_FAIL_EXIT FAKE_CURL_FAILS FAKE_CURL_STATUS FAKE_READLINK_EXE
  unset WIREPROXY_CONFIGTEST_FAIL WIREPROXY_PROFILE_CONFIGTEST_FAIL WIREPROXY_START_LOG
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
  --config)
    config=\$2
    for argument in "\$@"; do
      if [[ \$argument == --configtest ]]; then
        [[ -n \${WIREPROXY_CONFIGTEST_FAIL:-} ]] && { printf 'PrivateKey = must-not-print\\n' >&2; exit 1; }
        [[ -n \${WIREPROXY_PROFILE_CONFIGTEST_FAIL:-} && \$config != *compatibility.conf ]] && exit 1
        printf 'Config OK\\n'
        exit
      fi
    done
    [[ -n \${WIREPROXY_START_LOG:-} ]] && printf '%s\\n' "\$\$" >>"\$WIREPROXY_START_LOG"
    trap 'exit 0' TERM INT
    while :; do sleep 1; done
    ;;
  *) exit 2 ;;
esac
EOF
  chmod 700 "$target"
}

run_tty() {
  local input=$1 character index
  shift
  for ((index = 0; index < ${#input}; index++)); do
    character=${input:index:1}
    [[ $character == "$BACKSPACE" ]] && sleep 0.05
    printf '%s' "$character"
    if [[ $character == $'\n' || $character == B ]]; then
      sleep 0.05
    fi
  done | script -qec "$(printf '%q ' "$@")" /dev/null
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

install_lifecycle_fakes() {
  mkdir -p "$TEST_HOME/lifecycle-fakes"
  cat >"$TEST_HOME/lifecycle-fakes/curl" <<'EOF'
#!/usr/bin/env bash
output=
saw_limit=false
for ((index = 1; index <= $#; index++)); do
  if [[ ${!index} == --output ]]; then
    next=$((index + 1))
    output=${!next}
  fi
  if [[ ${!index} == --max-filesize ]]; then
    next=$((index + 1))
    [[ ${!next} == 65536 ]] && saw_limit=true
  fi
done
[[ -z ${EXPECTED_PROXY_URL:-} || ${https_proxy:-} == "$EXPECTED_PROXY_URL" && ${HTTPS_PROXY:-} == "$EXPECTED_PROXY_URL" ]] || exit 90
[[ -n $output ]] || exit 91
$saw_limit || exit 92
[[ -z ${FAKE_CURL_DELAY:-} ]] || sleep "$FAKE_CURL_DELAY"
calls=0
[[ -f $FAKE_CURL_CALLS ]] && calls=$(<"$FAKE_CURL_CALLS")
calls=$((calls + 1))
printf '%s\n' "$calls" >"$FAKE_CURL_CALLS"
if ((calls <= ${FAKE_CURL_FAILS:-0})); then
  exit "${FAKE_CURL_FAIL_EXIT:-7}"
fi
printf '%s' "${FAKE_CURL_BODY:-ip=203.0.113.1
loc=SG
}" >"$output"
printf '%s' "${FAKE_CURL_STATUS:-200}"
exit "${FAKE_CURL_EXIT:-0}"
EOF
  cat >"$TEST_HOME/lifecycle-fakes/readlink" <<'EOF'
#!/usr/bin/env bash
target=${!#}
if [[ $target == /proc/*/exe ]]; then
  if [[ -n ${FAKE_READLINK_EXE:-} ]]; then
    printf '%s\n' "$FAKE_READLINK_EXE"
  elif /usr/bin/grep -aFq "$EXPECTED_WIREPROXY_EXE" "${target%/exe}/cmdline"; then
    printf '%s\n' "$EXPECTED_WIREPROXY_EXE"
  else
    exec /usr/bin/readlink "$@"
  fi
else
  exec /usr/bin/readlink "$@"
fi
EOF
  cat >"$TEST_HOME/lifecycle-fakes/timeout" <<'EOF'
#!/usr/bin/env bash
if [[ -n ${FAKE_PORT_BUSY:-} && ${1:-} == 1 && ${2:-} == bash ]]; then
  exit 0
fi
exec /usr/bin/timeout "$@"
EOF
  chmod 700 "$TEST_HOME/lifecycle-fakes/"*
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
  assert_eq 'HTTP port: 25345' "$("$cli" settings)" 'default listener settings'

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
  assert_eq 1 "$(grep -c '^\[' "$profile/wireproxy.conf")" 'generated config has one listener'
  grep -q '^BindAddress = 127.0.0.1:25345$' "$profile/wireproxy.conf" || fail 'HTTP listener is loopback-only'
  grep -q '^USERNAME=proxy-code$' "$profile/proxy-credential" || fail 'credential has the fixed username'
  password=$(sed -n 's/^PASSWORD=//p' "$profile/proxy-credential")
  [[ $password =~ ^[0-9a-f]{96}$ ]] || fail 'credential has a URL-safe generated password'
  grep -q '^Username = proxy-code$' "$profile/wireproxy.conf" || fail 'HTTP listener uses the fixed username'
  grep -q "^Password = $password$" "$profile/wireproxy.conf" || fail 'HTTP listener uses the stored password'
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
  local cli=$HOME/.local/bin/proxycode source=$TEST_HOME/source/work.conf profile output status config_before
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

  config_before=$(/usr/bin/sha256sum "$profile/wireproxy.conf")
  assert_eq 'HTTP port: 31080' "$("$cli" settings --http-port 31080)" 'global port update'
  assert_eq "$config_before" "$(/usr/bin/sha256sum "$profile/wireproxy.conf")" 'port update leaves derived Profile config for activation to regenerate'
  ! grep -q '_PORT=' "$profile/settings" || fail 'Profile settings duplicate the global port'
  output=$("$cli" settings --http-port 65536 2>&1)
  status=$?
  assert_eq 2 "$status" 'out-of-range listener port status'
  output=$("$cli" settings --http-port 18446744073709551617 2>&1)
  status=$?
  assert_eq 2 "$status" 'overflowing listener port status'
  assert_eq 'HTTP port: 31080' "$("$cli" settings)" 'invalid port update changes nothing'
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

test_lifecycle_start_status_and_stop() {
  TESTS=$((TESTS + 1))
  new_home
  mkdir -p "$TEST_HOME/real-data"
  ln -s "$TEST_HOME/real-data" "$XDG_DATA_HOME"
  install_custom_binary >/dev/null || { fail 'lifecycle test install succeeds'; return; }
  local cli=$HOME/.local/bin/proxycode source=$TEST_HOME/source/work.conf profile password output status pid calls fd log
  write_wireguard_config "$source"
  "$cli" profile import "$source" --name work --default >/dev/null || { fail 'lifecycle Profile import succeeds'; return; }
  "$cli" profile import "$source" --name travel >/dev/null || { fail 'second lifecycle Profile import succeeds'; return; }
  "$cli" settings --http-port 31080 >/dev/null || { fail 'lifecycle port setup succeeds'; return; }
  profile=$XDG_DATA_HOME/proxycode/profiles/work
  printf 'stale generated config\n' >"$profile/wireproxy.conf"

  install_lifecycle_fakes
  EXPECTED_WIREPROXY_EXE=$(readlink -f "$XDG_DATA_HOME/proxycode/bin/wireproxy")
  export EXPECTED_WIREPROXY_EXE
  password=$(sed -n 's/^PASSWORD=//p' "$profile/proxy-credential")
  export EXPECTED_PROXY_URL=http://proxy-code:$password@127.0.0.1:31080
  export FAKE_CURL_CALLS=$TEST_HOME/curl-calls
  export WIREPROXY_START_LOG=$TEST_HOME/wireproxy-starts
  PATH=$TEST_HOME/lifecycle-fakes:$SYSTEM_PATH

  output=$("$cli" start)
  status=$?
  assert_eq 0 "$status" 'Default Tunnel Profile starts'
  assert_eq $'Started Tunnel Profile: work\nLocation: SG' "$output" 'start output'
  grep -q '^BindAddress = 127.0.0.1:31080$' "$profile/wireproxy.conf" || fail 'start regenerates the HTTP listener from global settings'
  assert_mode "$XDG_RUNTIME_DIR/proxycode" 700
  assert_mode "$XDG_RUNTIME_DIR/proxycode/active" 600
  assert_mode "$XDG_STATE_HOME/proxycode/logs/work" 700
  assert_mode "$XDG_STATE_HOME/proxycode/logs/work/wireproxy.log" 600
  pid=$(sed -n 's/^PID=//p' "$XDG_RUNTIME_DIR/proxycode/active")
  [[ $pid =~ ^[0-9]+$ && -d /proc/$pid ]] || fail 'start records a running process'
  grep -q '^READY=1$' "$XDG_RUNTIME_DIR/proxycode/active" || fail 'successful activation marks state ready'
  for fd in /proc/$pid/fd/*; do
    [[ $(readlink "$fd" 2>/dev/null) != "$XDG_RUNTIME_DIR" ]] || fail 'WireProxy inherits the lifecycle lock'
    [[ $(readlink "$fd" 2>/dev/null) != "$XDG_RUNTIME_DIR/proxycode/lifecycle.lock" ]] || fail 'WireProxy inherits the legacy lifecycle lock'
  done

  output=$("$cli" status)
  [[ $output == $'Default: work\nActive: work\nProfiles: travel, work\nProcess: running (PID '*')' ]] || fail 'status reports local lifecycle state'
  calls=$(<"$FAKE_CURL_CALLS")
  output=$("$cli" start work)
  assert_eq 'Tunnel Profile already active: work' "$output" 'starting the Active Profile is idempotent'
  assert_eq "$calls" "$(<"$FAKE_CURL_CALLS")" 'idempotent start does not repeat health'

  sed -i 's/^READY=1$/READY=0/' "$XDG_RUNTIME_DIR/proxycode/active"
  output=$("$cli" status 2>&1)
  status=$?
  assert_eq 1 "$status" 'incomplete activation status'
  [[ $output == *$'Active: none\n'* && $output == *'Process: starting'* ]] || fail 'incomplete activation is reported without claiming Active'
  output=$("$cli" start work)
  assert_eq $'Stopped Tunnel Profile: work\nStarted Tunnel Profile: work\nLocation: SG' "$output" 'start recovers a verified incomplete activation'
  [[ ! -e /proc/$pid ]] || fail 'incomplete activation recovery leaves the old process running'
  pid=$(sed -n 's/^PID=//p' "$XDG_RUNTIME_DIR/proxycode/active")

  export FAKE_READLINK_EXE=/usr/bin/not-wireproxy
  output=$("$cli" stop 2>&1)
  status=$?
  assert_eq 1 "$status" 'wrong-executable stop refusal status'
  [[ $output == *'identity is ambiguous'* && -e /proc/$pid ]] || fail 'wrong-executable state is not signaled'
  unset FAKE_READLINK_EXE

  calls=$(<"$FAKE_CURL_CALLS")
  "$cli" profile settings work --probe cloudflare --expect-location SG >/dev/null
  export FAKE_CURL_BODY=$'ip=203.0.113.1\nloc=US\n'
  output=$("$cli" check 2>&1)
  status=$?
  assert_eq 1 "$status" 'explicit health failure status'
  [[ $output == *'health check failed'* && $output == *'Location: US'* && $output != *'203.0.113.1'* ]] || fail 'location mismatch is safe and explained'
  assert_eq "$((calls + 1))" "$(<"$FAKE_CURL_CALLS")" 'explicit check makes exactly one request'
  [[ -e /proc/$pid && -e $XDG_RUNTIME_DIR/proxycode/active ]] || fail 'explicit health failure mutates lifecycle state'
  unset FAKE_CURL_BODY

  "$cli" profile settings work --probe mullvad --expect-location Singapore >/dev/null
  export FAKE_CURL_BODY='{"mullvad_exit_ip": true, "country": "Singapore"}'
  assert_eq $'Tunnel Profile healthy: work\nLocation: Singapore' "$("$cli" check)" 'Mullvad health contract'
  "$cli" profile settings work --probe custom --url https://example.test/health --status 204 --contains ready >/dev/null
  export FAKE_CURL_BODY='ready' FAKE_CURL_STATUS=204
  assert_eq $'Tunnel Profile healthy: work\nLocation: unavailable' "$("$cli" check)" 'custom health contract'
  unset FAKE_CURL_BODY FAKE_CURL_STATUS

  log=$XDG_STATE_HOME/proxycode/logs/work/wireproxy.log
  truncate -s 10485760 "$log"
  "$cli" start work >/dev/null || fail 'idempotent start rotates an oversized log'
  assert_eq 10485760 "$(stat -c %s "$log.old")" 'rotation keeps one complete backup'
  assert_eq 0 "$(stat -c %s "$log")" 'rotation truncates the active log in place'
  assert_mode "$log.old" 600

  output=$("$cli" start travel 2>&1)
  status=$?
  assert_eq 1 "$status" 'start refuses to replace the Active Profile'
  [[ $output == *"Tunnel Profile 'work' is active; stop it first"* ]] || fail 'different Active Profile refusal is actionable'
  assert_eq 'Stopped Tunnel Profile: work' "$("$cli" stop)" 'stop output'
  [[ ! -e $XDG_RUNTIME_DIR/proxycode/active ]] || fail 'stop clears active state'
  [[ ! -e /proc/$pid ]] || fail 'stop terminates the managed process'
  assert_eq $'Default: work\nActive: none\nProfiles: travel, work\nProcess: stopped' "$("$cli" status)" 'stopped status output'
  assert_eq 'Toolkit already stopped.' "$("$cli" stop)" 'stop is idempotent'

}

test_lifecycle_failed_start_cleanup() {
  TESTS=$((TESTS + 1))
  new_home
  install_custom_binary >/dev/null || { fail 'failed-start test install succeeds'; return; }
  local cli=$HOME/.local/bin/proxycode source=$TEST_HOME/source/work.conf profile password output status pid
  write_wireguard_config "$source"
  "$cli" profile import "$source" --name work --default >/dev/null || { fail 'failed-start Profile import succeeds'; return; }
  profile=$XDG_DATA_HOME/proxycode/profiles/work
  install_lifecycle_fakes
  EXPECTED_WIREPROXY_EXE=$(readlink -f "$XDG_DATA_HOME/proxycode/bin/wireproxy")
  export EXPECTED_WIREPROXY_EXE
  password=$(sed -n 's/^PASSWORD=//p' "$profile/proxy-credential")
  export EXPECTED_PROXY_URL=http://proxy-code:$password@127.0.0.1:25345
  export FAKE_CURL_CALLS=$TEST_HOME/curl-calls WIREPROXY_START_LOG=$TEST_HOME/wireproxy-starts
  export FAKE_CURL_EXIT=60
  PATH=$TEST_HOME/lifecycle-fakes:$SYSTEM_PATH

  output=$("$cli" start 2>&1)
  status=$?
  assert_eq 1 "$status" 'failed activation status'
  [[ $output == *'health check failed'* && $output == *'proxycode status'* && $output == *'proxycode start work'* ]] || fail 'failed activation is safe and actionable'
  [[ ! -e $XDG_RUNTIME_DIR/proxycode/active ]] || fail 'failed activation leaves active state'
  assert_eq 1 "$(<"$FAKE_CURL_CALLS")" 'permanent client failure is not retried'
  pid=$(sed -n '1p' "$WIREPROXY_START_LOG")
  for _ in {1..20}; do
    [[ ! -e /proc/$pid ]] && break
    sleep 0.1
  done
  [[ ! -e /proc/$pid ]] || fail 'failed activation leaves WireProxy running'
  unset FAKE_CURL_EXIT

  export FAKE_READLINK_EXE=/usr/bin/not-wireproxy
  output=$("$cli" start 2>&1)
  status=$?
  assert_eq 1 "$status" 'unverified startup status'
  [[ $output == *'ambiguous state was retained'* ]] || fail 'unverified startup explains retained state'
  pid=$(sed -n '2p' "$WIREPROXY_START_LOG")
  grep -q '^READY=0$' "$XDG_RUNTIME_DIR/proxycode/active" || fail 'unverified startup loses its provisional state'
  output=$("$cli" status 2>&1)
  status=$?
  assert_eq 1 "$status" 'ambiguous status reports runtime failure'
  [[ $output == *'Process: unknown'* && $output == *'Confirm no WireProxy process'* && -e /proc/$pid ]] || fail 'ambiguous status claims a trusted process or lacks recovery guidance'
  unset FAKE_READLINK_EXE
  kill -TERM "$pid"
  for _ in {1..20}; do
    [[ ! -e /proc/$pid ]] && break
    sleep 0.1
  done
  "$cli" status >/dev/null || fail 'dead provisional state recovers'
}

test_lifecycle_stale_and_ambiguous_state() {
  TESTS=$((TESTS + 1))
  new_home
  install_custom_binary >/dev/null || { fail 'state safety test install succeeds'; return; }
  local cli=$HOME/.local/bin/proxycode source=$TEST_HOME/source/work.conf state output status stat rest shell_started
  write_wireguard_config "$source"
  "$cli" profile import "$source" --name work --default >/dev/null || { fail 'state safety Profile import succeeds'; return; }
  install_lifecycle_fakes
  EXPECTED_WIREPROXY_EXE=$(readlink -f "$XDG_DATA_HOME/proxycode/bin/wireproxy")
  export EXPECTED_WIREPROXY_EXE
  PATH=$TEST_HOME/lifecycle-fakes:$SYSTEM_PATH
  "$cli" status >/dev/null
  state=$XDG_RUNTIME_DIR/proxycode/active

  printf 'PROFILE=work\nPID=999999999\nSTART_TIME=1\n' >"$state"
  chmod 600 "$state"
  output=$("$cli" status)
  [[ $output == *$'Active: none\n'* && ! -e $state ]] || fail 'dead-PID stale state is recovered locally'

  printf 'PROFILE=work\nPID=%s\nSTART_TIME=0\n' "$$" >"$state"
  chmod 600 "$state"
  output=$("$cli" status)
  [[ $output == *$'Active: none\n'* && ! -e $state ]] || fail 'reused-PID stale state is recovered locally'

  IFS= read -r stat <"/proc/$$/stat"
  rest=${stat##*) }
  set -- $rest
  shell_started=${20}
  printf 'PROFILE=work\nPID=%s\nSTART_TIME=%s\n' "$$" "$shell_started" >"$state"
  chmod 600 "$state"
  output=$("$cli" stop 2>&1)
  status=$?
  assert_eq 1 "$status" 'wrong-PID stop refusal status'
  [[ $output == *'identity is ambiguous'* && $output == *"remove '$state'"* ]] || fail 'wrong-PID refusal lacks safe recovery guidance'
  kill -0 $$ || fail 'wrong-PID refusal signals the unrelated process'
  [[ -e $state ]] || fail 'ambiguous state is silently discarded'
}

test_lifecycle_lock_serializes_start() {
  TESTS=$((TESTS + 1))
  new_home
  install_custom_binary >/dev/null || { fail 'locking test install succeeds'; return; }
  local cli=$HOME/.local/bin/proxycode source=$TEST_HOME/source/work.conf profile password first second pid
  write_wireguard_config "$source"
  "$cli" profile import "$source" --name work --default >/dev/null || { fail 'locking Profile import succeeds'; return; }
  profile=$XDG_DATA_HOME/proxycode/profiles/work
  install_lifecycle_fakes
  EXPECTED_WIREPROXY_EXE=$(readlink -f "$XDG_DATA_HOME/proxycode/bin/wireproxy")
  export EXPECTED_WIREPROXY_EXE
  password=$(sed -n 's/^PASSWORD=//p' "$profile/proxy-credential")
  export EXPECTED_PROXY_URL=http://proxy-code:$password@127.0.0.1:25345
  export FAKE_CURL_CALLS=$TEST_HOME/curl-calls WIREPROXY_START_LOG=$TEST_HOME/wireproxy-starts FAKE_CURL_DELAY=1 FAKE_CURL_FAILS=1
  PATH=$TEST_HOME/lifecycle-fakes:$SYSTEM_PATH

  "$cli" start >"$TEST_HOME/first.out" & first=$!
  sleep 0.1
  "$cli" start >"$TEST_HOME/second.out" & second=$!
  wait "$first" || fail 'first serialized start succeeds'
  wait "$second" || fail 'second serialized start succeeds idempotently'
  assert_eq 1 "$(wc -l <"$WIREPROXY_START_LOG")" 'serialized starts launch one WireProxy process'
  assert_eq 2 "$(<"$FAKE_CURL_CALLS")" 'transient activation failure retries once before success'
  pid=$(sed -n 's/^PID=//p' "$XDG_RUNTIME_DIR/proxycode/active")
  unset FAKE_CURL_DELAY FAKE_CURL_FAILS
  "$cli" stop >/dev/null || { kill -TERM "$pid" 2>/dev/null; fail 'locking test cleanup succeeds'; }
}

test_lifecycle_unknown_listener_refusal() {
  TESTS=$((TESTS + 1))
  new_home
  install_custom_binary >/dev/null || { fail 'listener test install succeeds'; return; }
  local cli=$HOME/.local/bin/proxycode source=$TEST_HOME/source/work.conf output status
  write_wireguard_config "$source"
  "$cli" profile import "$source" --name work --default >/dev/null || { fail 'listener Profile import succeeds'; return; }
  install_lifecycle_fakes
  EXPECTED_WIREPROXY_EXE=$(readlink -f "$XDG_DATA_HOME/proxycode/bin/wireproxy")
  export EXPECTED_WIREPROXY_EXE
  export WIREPROXY_START_LOG=$TEST_HOME/wireproxy-starts FAKE_PORT_BUSY=1
  PATH=$TEST_HOME/lifecycle-fakes:$SYSTEM_PATH

  output=$("$cli" start 2>&1)
  status=$?
  assert_eq 1 "$status" 'unknown listener refusal status'
  [[ $output == *'unknown listener'* ]] || fail 'unknown listener refusal is explained'
  [[ ! -e $WIREPROXY_START_LOG && ! -e $XDG_RUNTIME_DIR/proxycode/active ]] || fail 'unknown listener is adopted or replaced'
  unset FAKE_PORT_BUSY
}

test_wrapped_command_environment_and_fidelity() {
  TESTS=$((TESTS + 1))
  new_home
  install_custom_binary >/dev/null || { fail 'Wrapped command test install succeeds'; return; }
  local cli=$HOME/.local/bin/proxycode source=$TEST_HOME/source/work.conf profile password command output status pid
  write_wireguard_config "$source"
  "$cli" profile import "$source" --name work --default >/dev/null || { fail 'Wrapped command Profile import succeeds'; return; }
  "$cli" profile import "$source" --name travel >/dev/null || { fail 'Wrapped command alternate Profile import succeeds'; return; }
  profile=$XDG_DATA_HOME/proxycode/profiles/work
  install_lifecycle_fakes
  EXPECTED_WIREPROXY_EXE=$(readlink -f "$XDG_DATA_HOME/proxycode/bin/wireproxy")
  export EXPECTED_WIREPROXY_EXE
  password=$(sed -n 's/^PASSWORD=//p' "$profile/proxy-credential")
  export EXPECTED_PROXY_URL=http://proxy-code:$password@127.0.0.1:25345
  export FAKE_CURL_CALLS=$TEST_HOME/curl-calls WIREPROXY_START_LOG=$TEST_HOME/wireproxy-starts
  PATH=$TEST_HOME/lifecycle-fakes:$SYSTEM_PATH

  command=$TEST_HOME/wrapped-command
  cat >"$command" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$HTTP_PROXY" "$http_proxy" "$HTTPS_PROXY" "$https_proxy" "$ALL_PROXY" "$all_proxy" "$NO_PROXY" "$no_proxy" >"$WRAPPED_ENV_LOG"
printf '%s\n' "$@" >"$WRAPPED_ARGV_LOG"
pwd >"$WRAPPED_CWD_LOG"
IFS= read -r input
printf '%s\n' "$input" >"$WRAPPED_STDIN_LOG"
for fd in /proc/$$/fd/*; do
  [[ $(readlink "$fd" 2>/dev/null) != "$XDG_RUNTIME_DIR" ]] || exit 98
  [[ $(readlink "$fd" 2>/dev/null) != "$XDG_RUNTIME_DIR/proxycode/lifecycle.lock" ]] || exit 98
done
printf 'wrapped stdout\n'
printf 'wrapped stderr\n' >&2
exit 7
EOF
  chmod 700 "$command"
  export WRAPPED_ENV_LOG=$TEST_HOME/wrapped-env WRAPPED_ARGV_LOG=$TEST_HOME/wrapped-argv
  export WRAPPED_CWD_LOG=$TEST_HOME/wrapped-cwd WRAPPED_STDIN_LOG=$TEST_HOME/wrapped-stdin

  output=$(printf 'wrapped stdin\n' | (cd "$TEST_HOME" && HTTP_PROXY=hostile http_proxy=hostile HTTPS_PROXY=hostile https_proxy=hostile ALL_PROXY=hostile all_proxy=hostile NO_PROXY='*' no_proxy='*' "$cli" --profile work "$command" 'space arg' '' '*.txt' --leading) 2>"$TEST_HOME/wrapped-stderr")
  status=$?
  assert_eq 7 "$status" 'Wrapped command exit status'
  assert_eq 'wrapped stdout' "$output" 'Wrapped command stdout is untouched'
  assert_eq 'wrapped stderr' "$(<"$TEST_HOME/wrapped-stderr")" 'Wrapped command stderr is untouched'
  assert_eq $'space arg\n\n*.txt\n--leading' "$(<"$WRAPPED_ARGV_LOG")" 'Wrapped command argv is unchanged'
  assert_eq "$TEST_HOME" "$(<"$WRAPPED_CWD_LOG")" 'Wrapped command working directory is unchanged'
  assert_eq 'wrapped stdin' "$(<"$WRAPPED_STDIN_LOG")" 'Wrapped command stdin is unchanged'
  assert_eq "$EXPECTED_PROXY_URL" "$(sed -n '1p' "$WRAPPED_ENV_LOG")" 'Wrapped command receives the authenticated proxy'
  [[ $(sed -n '1,6p' "$WRAPPED_ENV_LOG" | sort -u) == "$EXPECTED_PROXY_URL" ]] || fail 'proxy variables are not replaced identically'
  assert_eq $'localhost,127.0.0.1,::1\nlocalhost,127.0.0.1,::1' "$(sed -n '7,8p' "$WRAPPED_ENV_LOG")" 'bypass variables are replaced with local-only values'
  [[ $output != *"$password"* && $(<"$TEST_HOME/wrapped-stderr") != *"$password"* ]] || fail 'Wrapped command launch prints the Proxy credential'
  ! grep -Fq "$password" "$XDG_STATE_HOME/proxycode/logs/work/wireproxy.log" || fail 'WireProxy log exposes the Proxy credential'
  pid=$(sed -n 's/^PID=//p' "$XDG_RUNTIME_DIR/proxycode/active")
  [[ -e /proc/$pid ]] || fail 'WireProxy does not remain active after the Wrapped command exits'

  local calls marker=$TEST_HOME/refused-command-ran
  calls=$(<"$FAKE_CURL_CALLS")
  "$cli" --profile work /usr/bin/true || fail 'Wrapped command reuses its matching Active Tunnel Profile'
  assert_eq "$calls" "$(<"$FAKE_CURL_CALLS")" 'Wrapped command reuse performs no health probe'
  output=$("$cli" --profile travel /usr/bin/touch "$marker" 2>&1)
  status=$?
  assert_eq 1 "$status" 'Wrapped command refuses a different Active Tunnel Profile'
  [[ $output == *"Tunnel Profile 'work' is active; stop it first"* && ! -e $marker ]] || fail 'Wrapped command refusal is unclear or executes the command'
  [[ $(sed -n 's/^PROFILE=//p' "$XDG_RUNTIME_DIR/proxycode/active") == work ]] || fail 'Wrapped command refusal changes the Active Tunnel Profile'
  assert_status 2 'empty explicit Profile selection status' "$cli" --profile '' /usr/bin/touch "$marker"
  [[ ! -e $marker ]] || fail 'empty explicit Profile selection executes the command'

  mv "$profile/proxy-credential" "$profile/proxy-credential.saved"
  output=$("$cli" --profile work /usr/bin/true 2>&1)
  status=$?
  assert_eq 1 "$status" 'missing Proxy credential reuse status'
  [[ $output == *'Proxy credential is invalid'* ]] || fail 'missing Proxy credential reuse fails silently'
  mv "$profile/proxy-credential.saved" "$profile/proxy-credential"
  "$cli" stop >/dev/null || { kill -TERM "$pid" 2>/dev/null; fail 'Wrapped command test cleanup succeeds'; }
}

test_explicit_switch_success_and_failure() {
  TESTS=$((TESTS + 1))
  new_home
  install_custom_binary >/dev/null || { fail 'switch test install succeeds'; return; }
  local cli=$HOME/.local/bin/proxycode source=$TEST_HOME/source/work.conf work_password travel_password output status pid
  write_wireguard_config "$source"
  "$cli" profile import "$source" --name work --default >/dev/null || { fail 'switch source Profile import succeeds'; return; }
  "$cli" profile import "$source" --name travel >/dev/null || { fail 'switch target Profile import succeeds'; return; }
  install_lifecycle_fakes
  EXPECTED_WIREPROXY_EXE=$(readlink -f "$XDG_DATA_HOME/proxycode/bin/wireproxy")
  export EXPECTED_WIREPROXY_EXE
  work_password=$(sed -n 's/^PASSWORD=//p' "$XDG_DATA_HOME/proxycode/profiles/work/proxy-credential")
  travel_password=$(sed -n 's/^PASSWORD=//p' "$XDG_DATA_HOME/proxycode/profiles/travel/proxy-credential")
  export EXPECTED_PROXY_URL=http://proxy-code:$work_password@127.0.0.1:25345
  export FAKE_CURL_CALLS=$TEST_HOME/curl-calls WIREPROXY_START_LOG=$TEST_HOME/wireproxy-starts
  PATH=$TEST_HOME/lifecycle-fakes:$SYSTEM_PATH
  "$cli" start work >/dev/null || { fail 'switch source Profile starts'; return; }

  output=$("$cli" switch travel 2>&1)
  status=$?
  assert_eq 2 "$status" 'non-interactive switch requires consent'
  [[ $output == *'confirmation requires a terminal'* ]] || fail 'unconfirmed switch lacks consent guidance'
  [[ $(sed -n 's/^PROFILE=//p' "$XDG_RUNTIME_DIR/proxycode/active") == work ]] || fail 'unconfirmed switch changes the Active Tunnel Profile'

  export EXPECTED_PROXY_URL=http://proxy-code:$travel_password@127.0.0.1:25345
  output=$("$cli" switch travel --yes) || { fail 'confirmed switch succeeds'; return; }
  assert_eq $'Stopped Tunnel Profile: work\nStarted Tunnel Profile: travel\nLocation: SG' "$output" 'successful switch output'
  [[ $(sed -n 's/^PROFILE=//p' "$XDG_RUNTIME_DIR/proxycode/active") == travel ]] || fail 'successful switch does not activate its target'
  assert_eq 'Tunnel Profile already active: travel' "$("$cli" switch travel)" 'switching to the Active Profile is idempotent without consent'

  export EXPECTED_PROXY_URL=http://proxy-code:$work_password@127.0.0.1:25345 FAKE_CURL_EXIT=60
  output=$("$cli" switch work --yes 2>&1)
  status=$?
  assert_eq 1 "$status" 'failed switch activation status'
  [[ $output == *'Stopped Tunnel Profile: travel'* && $output == *'health check failed'* ]] || fail 'failed switch does not explain stop and activation failure'
  [[ ! -e $XDG_RUNTIME_DIR/proxycode/active ]] || fail 'failed switch does not leave the Toolkit stopped'
  pid=$(sed -n '3p' "$WIREPROXY_START_LOG")
  [[ -z $pid || ! -e /proc/$pid ]] || { kill -TERM "$pid" 2>/dev/null; fail 'failed switch leaves its new WireProxy process running'; }
  unset FAKE_CURL_EXIT
}

test_active_profile_management_constraints() {
  TESTS=$((TESTS + 1))
  new_home
  install_custom_binary >/dev/null || { fail 'Active Profile management test install succeeds'; return; }
  local cli=$HOME/.local/bin/proxycode source=$TEST_HOME/source/work.conf profile password output status pid
  write_wireguard_config "$source"
  "$cli" profile import "$source" --name work --default >/dev/null || { fail 'Active Profile management import succeeds'; return; }
  profile=$XDG_DATA_HOME/proxycode/profiles/work
  install_lifecycle_fakes
  EXPECTED_WIREPROXY_EXE=$(readlink -f "$XDG_DATA_HOME/proxycode/bin/wireproxy")
  export EXPECTED_WIREPROXY_EXE
  password=$(sed -n 's/^PASSWORD=//p' "$profile/proxy-credential")
  export EXPECTED_PROXY_URL=http://proxy-code:$password@127.0.0.1:25345
  export FAKE_CURL_CALLS=$TEST_HOME/curl-calls WIREPROXY_START_LOG=$TEST_HOME/wireproxy-starts
  PATH=$TEST_HOME/lifecycle-fakes:$SYSTEM_PATH
  "$cli" start work >/dev/null || { fail 'Active Profile management source starts'; return; }
  pid=$(sed -n 's/^PID=//p' "$XDG_RUNTIME_DIR/proxycode/active")

  output=$("$cli" settings --http-port 31080 2>&1)
  status=$?
  assert_eq 1 "$status" 'HTTP port change while active status'
  [[ $output == *'stop it first'* ]] || fail 'active HTTP port refusal lacks stop guidance'
  assert_eq 'HTTP port: 25345' "$("$cli" settings)" 'active HTTP port refusal changes settings'

  printf '\n# replacement\n' >>"$source"
  output=$("$cli" profile import "$source" --name work --replace --yes) || { fail 'Active Profile replacement succeeds'; return; }
  assert_eq $'Stopped Tunnel Profile: work\nReplaced Tunnel Profile: work' "$output" 'Active Profile replacement output'
  [[ ! -e $XDG_RUNTIME_DIR/proxycode/active && ! -e /proc/$pid ]] || fail 'Active Profile replacement leaves its old process or state behind'
  cmp -s "$source" "$profile/wireguard.conf" || fail 'Active Profile replacement does not install the new private copy'
  "$cli" start work >/dev/null || { fail 'replaced Active Profile restarts'; return; }
  pid=$(sed -n 's/^PID=//p' "$XDG_RUNTIME_DIR/proxycode/active")

  export FAKE_READLINK_EXE=/usr/bin/not-wireproxy
  output=$("$cli" profile remove work --yes 2>&1)
  status=$?
  assert_eq 1 "$status" 'unverified Active Profile removal status'
  [[ $output == *'identity is ambiguous'* && -d $profile && -e /proc/$pid ]] || fail 'unverified Active Profile removal deletes files or signals the process'
  unset FAKE_READLINK_EXE

  output=$("$cli" profile remove work --yes) || { fail 'verified Active Profile removal succeeds'; return; }
  assert_eq $'Stopped Tunnel Profile: work\nRemoved Tunnel Profile: work' "$output" 'Active Profile removal output'
  [[ ! -e $profile && ! -e $XDG_RUNTIME_DIR/proxycode/active && ! -e /proc/$pid ]] || fail 'Active Profile removal leaves Profile, state, or process behind'
  [[ -f $source ]] || fail 'Active Profile removal touches the source configuration'
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

test_reinstall_preserves_user_data_and_refuses_active() {
  TESTS=$((TESTS + 1))
  new_home
  install_custom_binary >/dev/null || { fail 'reinstall baseline succeeds'; return; }
  local cli=$HOME/.local/bin/proxycode source=$TEST_HOME/source/work.conf profile password before after output status pid
  write_wireguard_config "$source"
  "$cli" profile import "$source" --name work --default >/dev/null || { fail 'reinstall Profile import succeeds'; return; }
  "$cli" profile settings work --probe cloudflare --expect-location SG >/dev/null
  "$cli" settings --http-port 31080 >/dev/null
  profile=$XDG_DATA_HOME/proxycode/profiles/work
  install_lifecycle_fakes
  EXPECTED_WIREPROXY_EXE=$(readlink -f "$XDG_DATA_HOME/proxycode/bin/wireproxy")
  export EXPECTED_WIREPROXY_EXE
  password=$(sed -n 's/^PASSWORD=//p' "$profile/proxy-credential")
  export EXPECTED_PROXY_URL=http://proxy-code:$password@127.0.0.1:31080
  export FAKE_CURL_CALLS=$TEST_HOME/curl-calls WIREPROXY_START_LOG=$TEST_HOME/wireproxy-starts
  PATH=$TEST_HOME/lifecycle-fakes:$SYSTEM_PATH
  "$cli" start work >/dev/null || { fail 'reinstall Active Profile starts'; return; }
  pid=$(sed -n 's/^PID=//p' "$XDG_RUNTIME_DIR/proxycode/active")
  fake_wireproxy "$TEST_HOME/custom/new-wireproxy" 1.2.0

  before=$(installation_digest)
  output=$(bash "$ROOT/install.sh" --install-only --wireproxy-bin "$TEST_HOME/custom/new-wireproxy" 2>&1)
  status=$?
  assert_eq 1 "$status" 'reinstall while Active status'
  [[ $output == *'active'* && $output == *'proxycode stop'* ]] || fail 'active reinstall refusal lacks stop guidance'
  assert_eq "$before" "$(installation_digest)" 'active reinstall changes managed files'
  [[ -e /proc/$pid ]] || fail 'active reinstall stops the managed process'
  "$cli" stop >/dev/null || { kill -TERM "$pid" 2>/dev/null; fail 'reinstall test stop succeeds'; return; }

  before=$(/usr/bin/sha256sum "$XDG_CONFIG_HOME/proxycode/settings" "$profile/"*)
  printf 'stale installed command\n' >"$cli"
  chmod 700 "$cli"
  output=$(bash "$ROOT/install.sh" --install-only --wireproxy-bin "$TEST_HOME/custom/new-wireproxy") || { fail 'stopped reinstall succeeds'; return; }
  after=$(/usr/bin/sha256sum "$XDG_CONFIG_HOME/proxycode/settings" "$profile/"*)
  assert_eq "$before" "$after" 'reinstall changes settings, Profile, or Proxy credential'
  assert_eq 'proxycode 1.0.0' "$("$cli" version)" 'reinstall refreshes the Toolkit command'
  assert_eq 'wireproxy v1.2.0' "$("$XDG_DATA_HOME/proxycode/bin/wireproxy" --version)" 'reinstall refreshes managed WireProxy'
  [[ $output == *'Installed custom WireProxy v1.2.0.'* ]] || fail 'reinstall reports refreshed WireProxy'
}

test_incomplete_installation_recovery_and_downgrade_refusal() {
  TESTS=$((TESTS + 1))
  new_home
  install_custom_binary >/dev/null || { fail 'recovery baseline succeeds'; return; }
  local cli=$HOME/.local/bin/proxycode source=$TEST_HOME/source/work.conf profile before after output status last_target
  write_wireguard_config "$source"
  "$cli" profile import "$source" --name work --default >/dev/null || { fail 'recovery Profile import succeeds'; return; }
  profile=$XDG_DATA_HOME/proxycode/profiles/work
  before=$(/usr/bin/sha256sum "$XDG_CONFIG_HOME/proxycode/settings" "$profile/"*)
  rm -f "$XDG_STATE_HOME/proxycode/install" "$XDG_DATA_HOME/proxycode/lib/proxycode.sh"
  mkdir -p "$TEST_HOME/logging-path"
  export MV_TARGET_LOG=$TEST_HOME/mv-targets
  cat >"$TEST_HOME/logging-path/mv" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${!#}" >>"$MV_TARGET_LOG"
exec /usr/bin/mv "$@"
EOF
  chmod 700 "$TEST_HOME/logging-path/mv"

  output=$(PATH=$TEST_HOME/logging-path:$SYSTEM_PATH bash "$ROOT/install.sh" --install-only --wireproxy-bin "$TEST_HOME/custom/wireproxy") || { fail 'incomplete installation recovery succeeds'; return; }
  [[ $output == *'incomplete installation'* && $output == *'rerun this fixed-version installer'* ]] || fail 'incomplete installation recovery lacks concise rerun guidance'
  assert_eq "$before" "$(/usr/bin/sha256sum "$XDG_CONFIG_HOME/proxycode/settings" "$profile/"*)" 'incomplete recovery changes persistent user data'
  [[ -r $XDG_DATA_HOME/proxycode/lib/proxycode.sh && -r $XDG_STATE_HOME/proxycode/install ]] || fail 'incomplete recovery does not restore managed files and metadata'
  last_target=$(tail -n 1 "$MV_TARGET_LOG")
  assert_eq "$XDG_STATE_HOME/proxycode/install" "$last_target" 'installation metadata is not committed last'

  printf 'PROXYCODE_VERSION=9.0.0\nWIREPROXY_VERSION=1.1.3\nWIREPROXY_SHA256=newer\nWIREPROXY_SOURCE=custom\n' >"$XDG_STATE_HOME/proxycode/install"
  before=$(installation_digest)
  output=$(bash "$ROOT/install.sh" --install-only --wireproxy-bin "$TEST_HOME/custom/wireproxy" 2>&1)
  status=$?
  after=$(installation_digest)
  assert_eq 1 "$status" 'older installer downgrade refusal status'
  [[ $output == *'newer Toolkit version 9.0.0'* ]] || fail 'downgrade refusal is unclear'
  assert_eq "$before" "$after" 'downgrade refusal changes the installation'
}

test_uninstall_preserves_and_purge_deletes() {
  TESTS=$((TESTS + 1))
  new_home
  install_custom_binary >/dev/null || { fail 'removal baseline succeeds'; return; }
  local cli=$HOME/.local/bin/proxycode source=$TEST_HOME/source/work.conf profile password preserved output status pid
  write_wireguard_config "$source"
  "$cli" profile import "$source" --name work --default >/dev/null || { fail 'removal work Profile import succeeds'; return; }
  "$cli" profile import "$source" --name travel >/dev/null || { fail 'removal travel Profile import succeeds'; return; }
  "$cli" profile settings work --probe cloudflare --expect-location SG >/dev/null
  "$cli" settings --http-port 31080 >/dev/null
  profile=$XDG_DATA_HOME/proxycode/profiles/work
  install_lifecycle_fakes
  EXPECTED_WIREPROXY_EXE=$(readlink -f "$XDG_DATA_HOME/proxycode/bin/wireproxy")
  export EXPECTED_WIREPROXY_EXE
  password=$(sed -n 's/^PASSWORD=//p' "$profile/proxy-credential")
  export EXPECTED_PROXY_URL=http://proxy-code:$password@127.0.0.1:31080
  export FAKE_CURL_CALLS=$TEST_HOME/curl-calls WIREPROXY_START_LOG=$TEST_HOME/wireproxy-starts
  PATH=$TEST_HOME/lifecycle-fakes:$SYSTEM_PATH
  "$cli" start work >/dev/null || { fail 'uninstall Active Profile starts'; return; }
  pid=$(sed -n 's/^PID=//p' "$XDG_RUNTIME_DIR/proxycode/active")
  touch "$XDG_RUNTIME_DIR/proxycode/lifecycle.lock"
  chmod 600 "$XDG_RUNTIME_DIR/proxycode/lifecycle.lock"
  preserved=$(/usr/bin/sha256sum "$XDG_CONFIG_HOME/proxycode/settings" "$XDG_DATA_HOME/proxycode/profiles/"*/*)

  output=$(bash "$ROOT/install.sh" --uninstall 2>&1)
  status=$?
  assert_eq 2 "$status" 'non-interactive uninstall consent status'
  [[ $output == *'pass --yes for automation'* ]] || fail 'uninstall lacks automation consent guidance'
  [[ -x $cli && -e /proc/$pid ]] || fail 'unconfirmed uninstall changes files or process'

  output=$(bash "$ROOT/install.sh" --uninstall --yes) || { fail 'confirmed uninstall succeeds'; return; }
  [[ $output == *'Stopped Tunnel Profile: work'* && $output == *'preserved'* ]] || fail 'uninstall does not report verified stop and preservation'
  [[ ! -e /proc/$pid && ! -e $cli && ! -e $XDG_DATA_HOME/proxycode/bin && ! -e $XDG_DATA_HOME/proxycode/lib && ! -e $XDG_DATA_HOME/proxycode/licenses ]] || fail 'uninstall leaves managed executables or libraries'
  [[ ! -e $XDG_STATE_HOME/proxycode && ! -e $XDG_RUNTIME_DIR/proxycode ]] || fail 'uninstall leaves logs, metadata, or runtime state'
  assert_eq "$preserved" "$(/usr/bin/sha256sum "$XDG_CONFIG_HOME/proxycode/settings" "$XDG_DATA_HOME/proxycode/profiles/"*/*)" 'uninstall changes settings, Profiles, or Proxy credentials'
  [[ -f $source ]] || fail 'uninstall touches an original WireGuard source'

  PATH=$SYSTEM_PATH
  bash "$ROOT/install.sh" --install-only --wireproxy-bin "$TEST_HOME/custom/wireproxy" >/dev/null || { fail 'reinstall after uninstall succeeds'; return; }
  cli=$HOME/.local/bin/proxycode
  assert_eq $'travel\nwork' "$("$cli" profile list | sort)" 'reinstall does not restore preserved Profiles'
  assert_eq "$password" "$(sed -n 's/^PASSWORD=//p' "$profile/proxy-credential")" 'reinstall changes the preserved Proxy credential'

  output=$(bash "$ROOT/install.sh" --purge 2>&1)
  status=$?
  assert_eq 2 "$status" 'non-interactive purge consent status'
  [[ $output == *'travel'* && $output == *'work'* && $output == *'pass --yes for automation'* ]] || fail 'purge does not list Profiles and explain consent'
  [[ -x $cli && -d $profile ]] || fail 'unconfirmed purge changes the installation'

  install_lifecycle_fakes
  EXPECTED_WIREPROXY_EXE=$(readlink -f "$XDG_DATA_HOME/proxycode/bin/wireproxy")
  export EXPECTED_WIREPROXY_EXE
  PATH=$TEST_HOME/lifecycle-fakes:$SYSTEM_PATH
  "$cli" start work >/dev/null || { fail 'purge Active Profile starts'; return; }
  pid=$(sed -n 's/^PID=//p' "$XDG_RUNTIME_DIR/proxycode/active")
  touch "$XDG_RUNTIME_DIR/proxycode/lifecycle.lock"
  chmod 600 "$XDG_RUNTIME_DIR/proxycode/lifecycle.lock"
  output=$(bash "$ROOT/install.sh" --purge --yes) || { fail 'confirmed purge succeeds'; return; }
  [[ $output == *'travel'* && $output == *'work'* && $output == *'Stopped Tunnel Profile: work'* ]] || fail 'purge does not report affected Profiles and verified stop'
  [[ ! -e /proc/$pid && ! -e $cli && ! -e $XDG_CONFIG_HOME/proxycode && ! -e $XDG_DATA_HOME/proxycode && ! -e $XDG_STATE_HOME/proxycode && ! -e $XDG_RUNTIME_DIR/proxycode ]] || fail 'purge leaves Toolkit data or process behind'
  [[ -f $source ]] || fail 'purge touches an original WireGuard source'
}

test_maintenance_process_safety_and_binary_drift() {
  TESTS=$((TESTS + 1))
  new_home
  install_custom_binary >/dev/null || { fail 'maintenance safety baseline succeeds'; return; }
  local cli=$HOME/.local/bin/proxycode source=$TEST_HOME/source/work.conf state stat rest shell_started before output status unrelated password pid
  write_wireguard_config "$source"
  "$cli" profile import "$source" --name work --default >/dev/null || { fail 'maintenance safety Profile import succeeds'; return; }
  state=$XDG_RUNTIME_DIR/proxycode/active
  IFS= read -r stat <"/proc/$$/stat"
  rest=${stat##*) }
  set -- $rest
  shell_started=${20}
  printf 'PROFILE=work\nPID=%s\nSTART_TIME=%s\nREADY=1\n' "$$" "$shell_started" >"$state"
  chmod 600 "$state"
  before=$(installation_digest)

  for operation in --uninstall --purge; do
    output=$(bash "$ROOT/install.sh" "$operation" --yes 2>&1)
    status=$?
    assert_eq 1 "$status" "ambiguous $operation status"
    [[ $output == *'identity is ambiguous'* && $output == *'Confirm no WireProxy process'* ]] || fail "ambiguous $operation lacks recovery guidance"
    assert_eq "$before" "$(installation_digest)" "ambiguous $operation changes managed files"
    kill -0 $$ || fail "ambiguous $operation signals the unrelated recorded process"
  done

  rm -f "$state"
  sleep 60 & unrelated=$!
  output=$(bash "$ROOT/install.sh" --uninstall --yes) || { kill -TERM "$unrelated"; fail 'uninstall beside unknown process succeeds'; return; }
  kill -0 "$unrelated" || fail 'uninstall signals an unrelated process without managed state'
  kill -TERM "$unrelated"
  wait "$unrelated" 2>/dev/null || true
  [[ $output == *'preserved'* ]] || fail 'safe uninstall does not report preservation'

  PATH=$SYSTEM_PATH
  bash "$ROOT/install.sh" --install-only --wireproxy-bin "$TEST_HOME/custom/wireproxy" >/dev/null || { fail 'binary drift reinstall succeeds'; return; }
  cli=$HOME/.local/bin/proxycode
  printf '\n# drift\n' >>"$XDG_DATA_HOME/proxycode/bin/wireproxy"
  install_lifecycle_fakes
  EXPECTED_WIREPROXY_EXE=$(readlink -f "$XDG_DATA_HOME/proxycode/bin/wireproxy")
  export EXPECTED_WIREPROXY_EXE
  password=$(sed -n 's/^PASSWORD=//p' "$XDG_DATA_HOME/proxycode/profiles/work/proxy-credential")
  export EXPECTED_PROXY_URL=http://proxy-code:$password@127.0.0.1:25345
  export FAKE_CURL_CALLS=$TEST_HOME/curl-calls WIREPROXY_START_LOG=$TEST_HOME/wireproxy-starts
  PATH=$TEST_HOME/lifecycle-fakes:$SYSTEM_PATH
  output=$("$cli" start work 2>&1)
  status=$?
  assert_eq 1 "$status" 'drifted WireProxy start status'
  [[ $output == *'WireProxy'* && $output == *'rerun the installer'* ]] || fail 'drifted WireProxy refusal lacks reinstall guidance'
  [[ ! -e $WIREPROXY_START_LOG && ! -e $state ]] || { pid=$(sed -n '1p' "$WIREPROXY_START_LOG"); kill -TERM "$pid" 2>/dev/null; fail 'drifted WireProxy is launched'; }
}

test_overlapping_roots_refuse_changes() {
  TESTS=$((TESTS + 1))
  new_home
  export XDG_CONFIG_HOME=$TEST_HOME/shared XDG_DATA_HOME=$TEST_HOME/shared XDG_STATE_HOME=$TEST_HOME/shared XDG_RUNTIME_DIR=$TEST_HOME/shared
  local profile=$TEST_HOME/shared/proxycode/profiles/work output status
  mkdir -p "$profile"
  printf 'preserve me\n' >"$profile/wireguard.conf"
  fake_wireproxy "$TEST_HOME/custom/wireproxy"
  output=$(bash "$ROOT/install.sh" --uninstall --yes 2>&1)
  status=$?
  assert_eq 1 "$status" 'overlapping XDG removal refusal status'
  [[ $output == *'XDG Toolkit directories overlap'* ]] || fail 'overlapping XDG refusal lacks guidance'
  [[ -f $profile/wireguard.conf ]] || fail 'overlapping XDG refusal changes Profile data'
}

test_purge_serializes_queued_cli_without_recreating_data() {
  TESTS=$((TESTS + 1))
  new_home
  install_custom_binary >/dev/null || { fail 'queued-purge baseline succeeds'; return; }
  local cli=$HOME/.local/bin/proxycode purge_pid queued_pid attempt output
  mkdir -p "$TEST_HOME/blocking-path"
  export BLOCK_TARGET=$cli BLOCK_ENTERED=$TEST_HOME/remove-entered BLOCK_RELEASE=$TEST_HOME/remove-release
  cat >"$TEST_HOME/blocking-path/rm" <<'EOF'
#!/usr/bin/env bash
if [[ " $* " == *" $BLOCK_TARGET "* && ! -e $BLOCK_ENTERED ]]; then
  touch "$BLOCK_ENTERED"
  until [[ -e $BLOCK_RELEASE ]]; do sleep 0.05; done
fi
exec /usr/bin/rm "$@"
EOF
  chmod 700 "$TEST_HOME/blocking-path/rm"
  PATH=$TEST_HOME/blocking-path:$SYSTEM_PATH bash "$ROOT/install.sh" --purge --yes >"$TEST_HOME/purge.out" & purge_pid=$!
  for attempt in {1..50}; do
    [[ -e $BLOCK_ENTERED ]] && break
    sleep 0.05
  done
  [[ -e $BLOCK_ENTERED ]] || { kill -TERM "$purge_pid" 2>/dev/null; fail 'purge did not reach the serialized removal'; return; }

  "$cli" status >"$TEST_HOME/queued.out" 2>&1 & queued_pid=$!
  sleep 0.1
  kill -0 "$queued_pid" 2>/dev/null || fail 'CLI did not wait for purge lifecycle lock'
  touch "$BLOCK_RELEASE"
  wait "$purge_pid" || { fail 'serialized purge succeeds'; return; }
  if wait "$queued_pid"; then
    fail 'queued CLI succeeds after its installation was purged'
  fi
  output=$(<"$TEST_HOME/queued.out")
  [[ $output == *'installation changed while waiting'* ]] || fail 'queued CLI lacks maintenance-race guidance'
  [[ ! -e $XDG_CONFIG_HOME/proxycode && ! -e $XDG_DATA_HOME/proxycode && ! -e $XDG_STATE_HOME/proxycode && ! -e $XDG_RUNTIME_DIR/proxycode ]] || fail 'queued CLI recreates Toolkit data during purge'
}

test_reinstall_waits_for_previous_version_lock() {
  TESTS=$((TESTS + 1))
  new_home
  install_custom_binary >/dev/null || { fail 'cross-version lock baseline succeeds'; return; }
  local legacy_lock=$XDG_RUNTIME_DIR/proxycode/lifecycle.lock holder installer attempt
  mkdir -p "${legacy_lock%/*}"
  (
    exec 9>"$legacy_lock"
    flock -x 9
    touch "$TEST_HOME/legacy-entered"
    until [[ -e $TEST_HOME/legacy-release ]]; do sleep 0.05; done
  ) & holder=$!
  for attempt in {1..50}; do
    [[ -e $TEST_HOME/legacy-entered ]] && break
    sleep 0.05
  done
  [[ -e $TEST_HOME/legacy-entered ]] || { kill -TERM "$holder" 2>/dev/null; fail 'previous-version lock holder did not start'; return; }

  bash "$ROOT/install.sh" --install-only --wireproxy-bin "$TEST_HOME/custom/wireproxy" >/dev/null & installer=$!
  sleep 0.1
  kill -0 "$installer" 2>/dev/null || fail 'reinstall bypasses the previous-version lifecycle lock'
  touch "$TEST_HOME/legacy-release"
  wait "$holder"
  wait "$installer" || fail 'reinstall after previous-version lock succeeds'
}

test_symlinked_managed_source_is_rejected_and_preserved() {
  TESTS=$((TESTS + 1))
  new_home
  local real_data=$TEST_HOME/real-data cli source output status
  mkdir -p "$real_data"
  ln -s "$real_data" "$TEST_HOME/data-link"
  export XDG_DATA_HOME=$TEST_HOME/data-link
  install_custom_binary >/dev/null || { fail 'symlinked-data baseline succeeds'; return; }
  cli=$HOME/.local/bin/proxycode
  source=$real_data/proxycode/bin/original.conf
  write_wireguard_config "$source"
  output=$("$cli" profile import "$source" --name rejected 2>&1)
  status=$?
  assert_eq 2 "$status" 'symlinked managed source rejection status'
  [[ $output == *'must be outside Toolkit-managed directories'* ]] || fail 'symlinked managed source is accepted'
  rm -f "$source"
  source=$TEST_HOME/original.conf
  write_wireguard_config "$source"
  bash "$ROOT/install.sh" --purge --yes >/dev/null || { fail 'symlinked-data purge succeeds'; return; }
  [[ -f $source ]] || fail 'purge deletes an original source outside canonical managed roots'
}

test_uninstall_preserves_profiles_nested_under_logs() {
  TESTS=$((TESTS + 1))
  new_home
  export XDG_DATA_HOME=$XDG_STATE_HOME/proxycode/logs
  local profile=$XDG_DATA_HOME/proxycode/profiles/work output status
  mkdir -p "$profile"
  printf 'preserve me\n' >"$profile/wireguard.conf"
  output=$(bash "$ROOT/install.sh" --uninstall --yes 2>&1)
  status=$?
  assert_eq 1 "$status" 'nested XDG removal refusal status'
  [[ $output == *'XDG Toolkit directories overlap'* ]] || fail 'nested XDG refusal lacks guidance'
  [[ -f $profile/wireguard.conf ]] || fail 'nested XDG refusal deletes a Profile'
}

test_invalid_install_and_runtime_residue_cleanup() {
  TESTS=$((TESTS + 1))
  new_home
  local invalid=$TEST_HOME/invalid-wireproxy output status
  printf '#!/usr/bin/env bash\nexit 1\n' >"$invalid"
  chmod 700 "$invalid"
  output=$(bash "$ROOT/install.sh" --install-only --wireproxy-bin "$invalid" 2>&1)
  status=$?
  assert_eq 1 "$status" 'invalid custom binary status'
  [[ ! -e $HOME/.local/bin/proxycode && ! -e $XDG_CONFIG_HOME/proxycode && ! -e $XDG_DATA_HOME/proxycode && ! -e $XDG_STATE_HOME/proxycode && ! -e $XDG_RUNTIME_DIR/proxycode ]] || fail 'failed validation changes live Toolkit state'

  install_custom_binary >/dev/null || { fail 'runtime residue baseline succeeds'; return; }
  mkdir -p "$XDG_RUNTIME_DIR/proxycode"
  printf 'interrupted probe\n' >"$XDG_RUNTIME_DIR/proxycode/probe.abandoned"
  bash "$ROOT/install.sh" --uninstall --yes >/dev/null || { fail 'runtime residue uninstall succeeds'; return; }
  [[ ! -e $XDG_RUNTIME_DIR/proxycode ]] || fail 'uninstall reports success with runtime residue'
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

test_scripted_profile_setup() {
  TESTS=$((TESTS + 1))
  new_home
  local source=$TEST_HOME/source/work.conf binary=$TEST_HOME/custom/wireproxy cli output status
  write_wireguard_config "$source"
  fake_wireproxy "$binary"

  output=$(bash "$ROOT/install.sh" --wg-config "$source" --name work --default \
    --wireproxy-bin "$binary" --http-port 31080 --probe custom \
    --url https://example.test/health --status 204 --contains ready) || {
    fail 'complete scripted Profile setup succeeds'; return;
  }
  cli=$HOME/.local/bin/proxycode
  [[ $output == *'Review installation:'* && $output == *'Profile: work'* ]] || fail 'scripted setup prints one review'
  assert_eq $'Name: work\nDefault: yes\nProbe: custom\nURL: https://example.test/health\nStatus: 204\nContains: configured' "$($cli profile show work)" 'scripted setup stores Profile choices'
  assert_eq 'HTTP port: 31080' "$($cli settings)" 'scripted setup stores listener choice'
  assert_eq $'Default: work\nActive: none\nProfiles: work\nProcess: stopped' "$($cli status)" 'scripted setup leaves the Profile stopped'

  output=$(bash "$ROOT/install.sh" --wg-config "$source" --name work --replace --yes --wireproxy-bin "$binary") || {
    fail 'scripted replacement succeeds'; return;
  }
  [[ $output == *'Default: yes'* && $output == *'Probe URL: https://example.test/health'* && $output == *'Expected status: 204'* && $output == *'Required response text: ready'* ]] || fail 'replacement review shows preserved resulting settings'

  new_home
  write_wireguard_config "$TEST_HOME/source/work.conf"
  fake_wireproxy "$TEST_HOME/custom/wireproxy"
  output=$(bash "$ROOT/install.sh" --wg-config "$TEST_HOME/source/work.conf" --wireproxy-bin "$TEST_HOME/custom/wireproxy" 2>&1)
  status=$?
  assert_eq 2 "$status" 'incomplete scripted setup status'
  [[ $output == *'--wg-config and --name are required together'* ]] || fail 'incomplete scripted setup is explained'
  [[ ! -e $XDG_DATA_HOME/proxycode ]] || fail 'incomplete scripted setup changes data'

  new_home
  source=$TEST_HOME/source/minimal.conf
  binary=$TEST_HOME/custom/wireproxy
  write_wireguard_config "$source"
  fake_wireproxy "$binary"
  bash "$ROOT/install.sh" --wg-config "$source" --name minimal --wireproxy-bin "$binary" >/dev/null || {
    fail 'minimal scripted Profile setup succeeds'; return;
  }
  cli=$HOME/.local/bin/proxycode
  assert_eq $'Name: minimal\nDefault: no\nProbe: cloudflare\nExpected location: any' "$($cli profile show minimal)" 'minimal setup uses settled Profile defaults'
  assert_eq 'HTTP port: 25345' "$($cli settings)" 'minimal setup uses the settled listener default'
}

test_setup_validation_preserves_installation() {
  TESTS=$((TESTS + 1))
  new_home
  install_custom_binary >/dev/null || { fail 'setup rollback baseline succeeds'; return; }
  local source=$TEST_HOME/source/rejected.conf before output status
  write_wireguard_config "$source"
  before=$(installation_digest)

  output=$(WIREPROXY_PROFILE_CONFIGTEST_FAIL=1 bash "$ROOT/install.sh" --wg-config "$source" --name rejected \
    --wireproxy-bin "$TEST_HOME/custom/wireproxy" 2>&1)
  status=$?
  assert_eq 1 "$status" 'staged Profile validation failure status'
  [[ $output == *'WireGuard configuration validation failed'* ]] || fail 'staged Profile failure is explained'
  assert_eq "$before" "$(installation_digest)" 'staged Profile failure changes the installation'
  [[ ! -e $XDG_DATA_HOME/proxycode/profiles/rejected ]] || fail 'staged Profile failure leaves a Profile'
}

test_interactive_setup_cancel_and_activation_failure() {
  TESTS=$((TESTS + 1))
  new_home
  local before output status review_heading source=$TEST_HOME/source/work.conf binary=$TEST_HOME/custom/wireproxy

  output=$(run_tty "$DOWN$DOWN
" bash "$ROOT/install.sh")
  status=$?
  assert_eq 0 "$status" 'interactive cancellation status'
  [[ $output == *'Cancelled. No changes were made.'* ]] || fail 'interactive cancellation is not reported'
  [[ $output == *$'\033[38;2;113;113;122m┌───\033[0m\033[48;2;167;139;250m\033[38;2;9;9;11m\033[1m ProxyCode \033[0m  setup'* ]] || fail 'interactive setup heading does not use the approved bold connected badge'
  [[ $output == *$'\033[38;2;103;232;249m?\033[0m What would you like to do?'* ]] || fail 'interactive setup question does not use the approved cyan accent'
  [[ $output == *$'\033[38;2;167;139;250m❯ Cancel\033[0m'* ]] || fail 'interactive setup does not use the approved selection cursor'
  [[ $output == *'Cancel'*'↑↓ move, enter confirm'* ]] || fail 'interactive setup omits the spaced navigation footer'
  [[ $output == *$'\033[38;2;134;239;172m◇\033[0m What would you like to do?'*$'\033[38;2;134;239;172mCancel\033[0m'* ]] || fail 'interactive setup does not preserve the selected answer as a Clack trail'
  [[ $output == *$'\033[?25l'* && $output == *$'\033[?25h'* ]] || fail 'interactive setup does not hide and restore the native cursor'
  [[ ! -e $XDG_DATA_HOME/proxycode ]] || fail 'interactive cancellation changes data'

  output=$(run_tty $'\n'"$DOWN"$'\n\003' bash "$ROOT/install.sh" 2>/dev/null)
  status=$?
  assert_eq 0 "$status" 'Mullvad recommendation exit status'
  [[ $output == *'https://mullvad.net/en/account/wireguard-config'* && $output == *'run the installer again'* ]] || fail 'Mullvad recommendation lacks download and restart guidance'
  [[ $output != *'WireGuard configuration file'* && ! -e $XDG_DATA_HOME/proxycode ]] || fail 'Mullvad recommendation continues setup or changes data'

  install_custom_binary >/dev/null || { fail 'interactive reinstall baseline succeeds'; return; }
  before=$(installation_digest)
  make_release_fakes x86_64
  output=$(run_tty "$DOWN$DOWN
" bash "$ROOT/install.sh")
  [[ $output == *' ProxyCode '*setup* && $output == *'Cancelled. No changes were made.'* ]] || fail 'no-option terminal reinstall bypasses interactive setup'
  assert_eq "$before" "$(installation_digest)" 'interactive reinstall cancellation changes the installation'

  new_home
  source=$HOME/work.conf
  write_wireguard_config "$source"
  fake_wireproxy "$binary"
  output=$(run_tty "

~/work.conf


$DOWN
$DOWN
$DOWN
$binary



r$DOWN
$DOWN
$binary
r$DOWN$DOWN
" bash "$ROOT/install.sh")
  status=$?
  assert_eq 0 "$status" 'final review restart and cancellation status'
  [[ $output == *$' ProxyCode \033[0m  review'* && $output == *'[Enter] install  ·  [R] restart'* ]] || fail 'interactive review does not match the approved controls'
  [[ $output == *$'\033[38;2;103;232;249m\033[7me\033[0m\033[38;2;113;113;122mnter here\033[0m'* ]] || fail 'WireGuard configuration hint does not begin under the block cursor'
  [[ $output != *'▏'* ]] || fail 'interactive text input still renders a thin cursor'
  review_heading=$' ProxyCode \033[0m  review'
  [[ $output == *"$review_heading"*"$review_heading"* ]] || fail 'restarted setup does not reach a second review'
  [[ $output == *'Cancelled. No changes were made.'* ]] || fail 'restarted setup cannot be cancelled safely'
  [[ ! -e $XDG_DATA_HOME/proxycode ]] || fail 'final review cancellation commits staged changes'

  new_home
  source=$TEST_HOME/source/work.conf
  binary=$TEST_HOME/custom/wireproxy
  write_wireguard_config "$source"
  fake_wireproxy "$binary"
  install_lifecycle_fakes
  export EXPECTED_WIREPROXY_EXE=$XDG_DATA_HOME/proxycode/bin/wireproxy
  export FAKE_CURL_CALLS=$TEST_HOME/curl-calls FAKE_CURL_FAILS=1 FAKE_CURL_FAIL_EXIT=1
  PATH=$TEST_HOME/lifecycle-fakes:$SYSTEM_PATH
  output=$(run_tty "

$source



$DOWN
$DOWN
$binary




" bash "$ROOT/install.sh" 2>&1)
  status=$?
  assert_eq 1 "$status" 'interactive activation failure status'
  [[ $output == *'Mullvad recommended'* && $output == *$' ProxyCode \033[0m  review'* ]] || fail 'interactive setup omits reviewed provider-neutral guidance'
  [[ $output == *'health check failed'* && $output == *"retry 'proxycode start work'"* ]] || fail 'interactive activation failure lacks recovery guidance'
  assert_eq 1 "$(<"$FAKE_CURL_CALLS")" 'interactive activation failure reaches the intended health probe'
  [[ -d $XDG_DATA_HOME/proxycode/profiles/work ]] || fail 'activation failure loses the imported Profile'
  [[ ! -e $XDG_RUNTIME_DIR/proxycode/active ]] || fail 'activation failure leaves the Profile active'
}

test_interactive_setup_rejects_early_and_resolves_profile_collision() {
  TESTS=$((TESTS + 1))
  new_home
  local binary=$TEST_HOME/custom/wireproxy cli input output profile source=$HOME/work.conf credential
  write_wireguard_config "$source"
  fake_wireproxy "$binary"
  bash "$ROOT/install.sh" --wg-config "$source" --name work --default --wireproxy-bin "$binary" >/dev/null || {
    fail 'interactive collision baseline install succeeds'; return;
  }
  cli=$HOME/.local/bin/proxycode
  profile=$XDG_DATA_HOME/proxycode/profiles/work
  credential=$(<"$profile/proxy-credential")
  bash "$ROOT/install.sh" --uninstall --yes >/dev/null || { fail 'interactive collision baseline uninstall succeeds'; return; }
  make_release_fakes x86_64

  input=$'\n\nmissing.conf\n'"$source"$'\n\n'"$DOWN$DOWN"$'\n'
  output=$(run_tty "$input" bash "$ROOT/install.sh")
  [[ $output == *"cannot read WireGuard configuration 'missing.conf'"* ]] || fail 'unreadable interactive WireGuard path is not reported immediately'
  (($(grep -ao 'WireGuard configuration file' <<<"$output" | wc -l) > 1)) || fail 'interactive setup does not retry an unreadable WireGuard path'
  [[ $output == *"Tunnel Profile 'work' already exists"* && $output == *'Replace existing Profile'* && $output == *'Cancelled. No changes were made.'* ]] || fail 'interactive collision cannot be cancelled before acquisition'
  [[ ! -e $CURL_URL_LOG && ! -x $cli ]] || fail 'cancelled interactive collision downloads or installs files'

  input=$'\n\n'"$source"$'\n\n'"$DOWN"$'\n\n'"$DOWN"$'\n\n\n'
  output=$(run_tty "$input" bash "$ROOT/install.sh") || { fail 'confirmed interactive replacement succeeds'; return; }
  [[ $output == *'Replaced Tunnel Profile: work'* && -x $cli ]] || fail 'confirmed interactive replacement does not complete installation'
  assert_eq "$credential" "$(<"$profile/proxy-credential")" 'interactive replacement changes the Proxy credential'

  input=$'\n\n'"$source"$'\n\n\ntravel\n\n'"$DOWN"$'\n\n\n'
  output=$(run_tty "$input" bash "$ROOT/install.sh") || { fail 'interactive alternate Profile name succeeds'; return; }
  [[ $output == *'Imported Tunnel Profile: travel'* && -d $XDG_DATA_HOME/proxycode/profiles/travel ]] || fail 'interactive collision cannot choose another Profile name'
}

test_interactive_management_dispatch() {
  TESTS=$((TESTS + 1))
  new_home
  install_custom_binary >/dev/null || { fail 'interactive management install succeeds'; return; }
  local cli=$HOME/.local/bin/proxycode source=$TEST_HOME/source/work.conf output status
  write_wireguard_config "$source"

  output=$($cli </dev/null 2>&1)
  status=$?
  assert_eq 2 "$status" 'non-terminal no-argument management status'
  [[ $output == Usage:* ]] || fail 'non-terminal management does not print usage'

  output=$(run_tty "
$source
travel

$DOWN$DOWN$DOWN$DOWN$DOWN$DOWN$DOWN$DOWN
" "$cli")
  [[ $output == *'Default: none'* && $output == *'Import a Tunnel Profile'* ]] || fail 'management menu omits state or settled actions'
  [[ $output == *$'\033[38;2;167;139;250m>\033[0m \033[38;2;103;232;249m\033[7mt\033[0m\033[38;2;113;113;122mype to filter\033[0m'* ]] || fail 'management filter placeholder does not begin under the block cursor'
  [[ $output == *'Exit'*'↑↓ move, enter confirm'* ]] || fail 'management filter omits the spaced navigation footer'
  [[ $output == *'Imported Tunnel Profile: travel'* ]] || fail 'management menu does not replace the suggested Profile name'
  assert_eq 1 "$(grep -ao ' ProxyCode ' <<<"$output" | wc -l)" 'management repeats its heading after an action'
  assert_eq 'travel' "$($cli profile list)" 'management import persists the Profile'
  assert_eq 'travel' "$(sed -n 's/^DEFAULT_PROFILE=//p' "$XDG_CONFIG_HOME/proxycode/settings")" 'management import selects Default when requested'

  output=$(run_tty $'\033[B\n' bash -c 'source "$1"; proxycode_choose "Pick one" One Two; printf "choice=%s\n" "$PROXYCODE_CHOICE"' _ "$XDG_DATA_HOME/proxycode/lib/proxycode.sh")
  [[ $output == *'choice=2'* ]] || fail 'chooser down arrow does not move immediately'

  output=$(run_tty "old${ESCAPE}new
" bash -c 'source "$1"; proxycode_prompt "Name" work; printf "answer=%s\n" "$PROXYCODE_ANSWER"' _ "$XDG_DATA_HOME/proxycode/lib/proxycode.sh")
  [[ $output == *'answer=new'* ]] || fail 'Escape followed by typing does not reset the current text question'
  [[ $output == *$'\033[38;2;103;232;249m\033[7mw\033[0m\033[38;2;113;113;122mork\033[0m'* ]] || fail 'default text does not begin under the block cursor'

  output=$(run_tty "*${BACKSPACE}sett
$DOWN$DOWN
exit
" "$cli")
  [[ $output == *'No matches'* ]] || fail 'management filter treats glob characters as patterns'
  [[ $output == *$'\033[38;2;103;232;249m◆\033[0m Choose an action'* ]] || fail 'management action menu is not filterable'
  [[ $output == *$'\033[38;2;167;139;250m  ❯ Settings\033[0m'* ]] || fail 'filtered management menu does not use the approved selection cursor'
  [[ $output == *$'\033[38;2;134;239;172m◇\033[0m Choose an action'*Settings* ]] || fail 'management selection does not collapse into the Clack trail'

  output=$(run_tty "check

exit
" "$cli")
  [[ $output == *$'\033[38;2;167;139;250m>\033[0m check\033[38;2;103;232;249m█'* ]] || fail 'management filter does not accept j and k as search text'
  [[ $output != *$'check\033[38;2;103;232;249m█\033[0m  \033[38;2;113;113;122mtype to filter'* ]] || fail 'management filter placeholder remains after typing'
  [[ $output != *'▏'* ]] || fail 'management filter still renders a thin cursor'

  output=$(run_tty "se${ESCAPE}exit
" "$cli")
  [[ $output == *$'\033[38;2;134;239;172mExit\033[0m'* ]] || fail 'Escape followed by typing does not reset the management filter'
}

test_lifecycle_lock_cleanup_after_failure() {
  TESTS=$((TESTS + 1))
  new_home
  install_custom_binary >/dev/null || { fail 'lock cleanup install succeeds'; return; }
  printf 'HTTP_PORT=invalid\nDEFAULT_PROFILE=\n' >"$XDG_CONFIG_HOME/proxycode/settings"

  local status
  timeout 2 bash -c '
    source "$1"
    proxycode_with_lifecycle_lock proxycode_status_locked >/dev/null 2>&1 || true
    proxycode_with_lifecycle_lock proxycode_status_locked >/dev/null 2>&1
  ' _ "$XDG_DATA_HOME/proxycode/lib/proxycode.sh"
  status=$?
  assert_eq 1 "$status" 'failed lifecycle preparation releases its locks'
}

test_piped_bootstrap() {
  TESTS=$((TESTS + 1))
  new_home
  local release=$TEST_HOME/release/proxycode-1.0.0 bundle=$TEST_HOME/proxycode-1.0.0.tar.gz output status
  mkdir -p "$release/bin" "$release/lib" "$TEST_HOME/bootstrap-fakes"
  cat >"$release/install.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$BOOTSTRAP_ARGS"
printf 'bundle installer ran\n'
EOF
  printf '# bundled command\n' >"$release/bin/proxycode"
  printf '# bundled library\n' >"$release/lib/proxycode.sh"
  tar -czf "$bundle" -C "$TEST_HOME/release" proxycode-1.0.0
  (cd "$TEST_HOME" && sha256sum proxycode-1.0.0.tar.gz >proxycode-1.0.0.tar.gz.sha256)
  cat >"$TEST_HOME/bootstrap-fakes/curl" <<'EOF'
#!/usr/bin/env bash
for ((index = 1; index <= $#; index++)); do
  if [[ ${!index} == -o ]]; then next=$((index + 1)); output=${!next}; fi
done
url=${!#}
printf '%s\n' "$url" >>"$BOOTSTRAP_URLS"
cp "$BOOTSTRAP_SOURCE/${url##*/}" "$output"
EOF
  chmod 700 "$TEST_HOME/bootstrap-fakes/curl"
  export BOOTSTRAP_ARGS=$TEST_HOME/bootstrap-args BOOTSTRAP_URLS=$TEST_HOME/bootstrap-urls BOOTSTRAP_SOURCE=$TEST_HOME

  output=$(cat "$ROOT/install.sh" | PATH=$TEST_HOME/bootstrap-fakes:$SYSTEM_PATH bash -s -- --install-only --wireproxy-bin "$TEST_HOME/a binary") || {
    fail 'complete piped bootstrap succeeds'; return;
  }
  [[ $output == *'bundle installer ran'* ]] || fail 'piped bootstrap does not run the verified bundle installer'
  assert_eq $'--install-only\n--wireproxy-bin\n'"$TEST_HOME/a binary" "$(<"$BOOTSTRAP_ARGS")" 'piped bootstrap preserves argv'
  assert_eq $'https://github.com/lukatman/proxy-code/releases/download/v1.0.0/proxycode-1.0.0.tar.gz\nhttps://github.com/lukatman/proxy-code/releases/download/v1.0.0/proxycode-1.0.0.tar.gz.sha256' "$(<"$BOOTSTRAP_URLS")" 'piped bootstrap uses fixed release assets'

  rm -f "$BOOTSTRAP_URLS"
  output=$(cat "$ROOT/install.sh" | PATH=$TEST_HOME/bootstrap-fakes:$SYSTEM_PATH bash -s 2>&1)
  status=$?
  assert_eq 2 "$status" 'non-terminal piped setup status'
  [[ $output == *'complete setup flags'* ]] || fail 'non-terminal piped setup lacks complete-flags guidance'
  [[ ! -e $BOOTSTRAP_URLS ]] || fail 'incomplete piped setup downloads a bundle'

  cp "$ROOT/install.sh" "$release/install.sh"
  cp "$ROOT/bin/proxycode" "$release/bin/proxycode"
  cp "$ROOT/lib/proxycode.sh" "$release/lib/proxycode.sh"
  tar -czf "$bundle" -C "$TEST_HOME/release" proxycode-1.0.0
  (cd "$TEST_HOME" && sha256sum proxycode-1.0.0.tar.gz >proxycode-1.0.0.tar.gz.sha256)
  fake_wireproxy "$TEST_HOME/custom/wireproxy"
  output=$(run_tty "$DOWN
$DOWN
$TEST_HOME/custom/wireproxy

" env PATH="$TEST_HOME/bootstrap-fakes:$SYSTEM_PATH" bash -c "cat '$ROOT/install.sh' | bash") || {
    fail 'piped interactive setup succeeds'; return;
  }
  [[ $output == *' ProxyCode '*setup* && $output == *'Installed custom WireProxy v1.1.3.'* ]] || fail 'piped installer does not prompt on the terminal'
}

test_custom_install_and_cli
test_profile_import_default_and_show
test_profile_replacement_and_validation_rollback
test_global_and_profile_settings
test_profile_default_name_validation_and_removal
test_lifecycle_start_status_and_stop
test_lifecycle_failed_start_cleanup
test_lifecycle_stale_and_ambiguous_state
test_lifecycle_lock_serializes_start
test_lifecycle_unknown_listener_refusal
test_wrapped_command_environment_and_fidelity
test_explicit_switch_success_and_failure
test_active_profile_management_constraints
test_pinned_architectures
test_verification_failure_preserves_installation
test_commit_failure_rolls_back
test_reinstall_preserves_user_data_and_refuses_active
test_incomplete_installation_recovery_and_downgrade_refusal
test_uninstall_preserves_and_purge_deletes
test_maintenance_process_safety_and_binary_drift
test_overlapping_roots_refuse_changes
test_purge_serializes_queued_cli_without_recreating_data
test_reinstall_waits_for_previous_version_lock
test_symlinked_managed_source_is_rejected_and_preserved
test_uninstall_preserves_profiles_nested_under_logs
test_invalid_install_and_runtime_residue_cleanup
test_unsupported_platform_changes_nothing
test_missing_dependencies_change_nothing
test_scripted_profile_setup
test_setup_validation_preserves_installation
test_interactive_setup_cancel_and_activation_failure
test_interactive_setup_rejects_early_and_resolves_profile_collision
test_interactive_management_dispatch
test_lifecycle_lock_cleanup_after_failure
test_piped_bootstrap

if ((FAILURES)); then
  printf '%d of %d tests failed\n' "$FAILURES" "$TESTS" >&2
  exit 1
fi
printf 'ok - %d tests passed\n' "$TESTS"
