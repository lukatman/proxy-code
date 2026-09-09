#!/usr/bin/env bash

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


test_setup_staging_paths_and_rollback() {
  TESTS=$((TESTS + 1))
  new_home
  local source=$TEST_HOME/source/work.conf binary=$TEST_HOME/custom/wireproxy before credentials
  write_wireguard_config "$source"
  fake_wireproxy "$binary"
  export TMPDIR=$TEST_HOME/staging
  mkdir -p "$TMPDIR"

  env -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_STATE_HOME -u XDG_RUNTIME_DIR \
    bash "$ROOT/install.sh" --wg-config "$source" --name work --default --wireproxy-bin "$binary" >/dev/null || {
    fail 'staging with unset XDG paths succeeds'; unset TMPDIR; return;
  }
  [[ -f $HOME/.local/share/proxycode/profiles/work/wireguard.conf ]] || fail 'default XDG destination is preserved'
  [[ -z $(find "$TMPDIR" -mindepth 1 -print -quit) ]] || fail 'successful staging leaves private temporary files'

  unset TMPDIR
  new_home
  export XDG_CONFIG_HOME="$TEST_HOME/config with spaces" XDG_DATA_HOME="$TEST_HOME/data with spaces"
  export TMPDIR=$TEST_HOME/staging
  mkdir -p "$TMPDIR"
  source=$TEST_HOME/source/work.conf
  binary=$TEST_HOME/custom/wireproxy
  write_wireguard_config "$source"
  fake_wireproxy "$binary"
  bash "$ROOT/install.sh" --wg-config "$source" --name work --default --wireproxy-bin "$binary" \
    --probe custom --url https://example.test/health --status 204 --contains ready >/dev/null || {
    fail 'staging with spaced XDG paths succeeds'; unset TMPDIR; return;
  }
  before=$(installation_digest)
  credentials=$(sha256sum "$XDG_DATA_HOME/proxycode/profiles/work/proxy-credential" "$XDG_CONFIG_HOME/proxycode/settings" \
    "$XDG_DATA_HOME/proxycode/profiles/work/settings")
  assert_status 2 'invalid staged probe fails' bash "$ROOT/install.sh" --wg-config "$source" --name work \
    --replace --yes --wireproxy-bin "$binary" --probe custom --url http://example.test --status 204
  assert_eq "$before" "$(installation_digest)" 'probe validation preserves installed payload'
  assert_eq "$credentials" "$(sha256sum "$XDG_DATA_HOME/proxycode/profiles/work/proxy-credential" "$XDG_CONFIG_HOME/proxycode/settings" \
    "$XDG_DATA_HOME/proxycode/profiles/work/settings")" 'probe validation preserves live settings and credentials'
  bash "$ROOT/install.sh" --wg-config "$source" --name work --replace --yes --wireproxy-bin "$binary" >/dev/null || fail 'replacement succeeds after staged failure'
  assert_eq "$credentials" "$(sha256sum "$XDG_DATA_HOME/proxycode/profiles/work/proxy-credential" "$XDG_CONFIG_HOME/proxycode/settings" \
    "$XDG_DATA_HOME/proxycode/profiles/work/settings")" 'replacement retains settings and credentials'
  [[ -z $(find "$TMPDIR" -mindepth 1 -print -quit) ]] || fail 'failed or replacement staging leaves private temporary files'
  unset TMPDIR
}

test_setup_staging_retains_lifecycle_lock() {
  TESTS=$((TESTS + 1))
  new_home
  local source=$TEST_HOME/source/work.conf binary=$TEST_HOME/custom/wireproxy before profile_before
  write_wireguard_config "$source"
  fake_wireproxy "$binary"
  bash "$ROOT/install.sh" --wg-config "$source" --name work --default --wireproxy-bin "$binary" >/dev/null || {
    fail 'staging lock baseline installation succeeds'; return;
  }
  before=$(installation_digest)
  profile_before=$(sha256sum "$XDG_CONFIG_HOME/proxycode/settings" "$XDG_DATA_HOME/proxycode/profiles/work/"*)
  (
    initial_failures=$FAILURES
    installer=
    trap 'touch "$TEST_HOME/release"; [[ -z $installer ]] || wait "$installer" 2>/dev/null' EXIT
    cat >"$TEST_HOME/custom/blocking-wireproxy" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == --config && $2 != *compatibility.conf ]]; then
  touch "$STAGING_LOCK_TEST_DIR/ready"
  for ((attempt = 0; attempt < 100; attempt++)); do
    [[ -e $STAGING_LOCK_TEST_DIR/release ]] && exit 1
    sleep 0.05
  done
  exit 1
fi
exec "$STAGING_LOCK_TEST_DIR/custom/wireproxy" "$@"
EOF
    chmod 700 "$TEST_HOME/custom/blocking-wireproxy"
    STAGING_LOCK_TEST_DIR=$TEST_HOME timeout 10 bash "$ROOT/install.sh" --wg-config "$source" --name work \
      --replace --yes --wireproxy-bin "$TEST_HOME/custom/blocking-wireproxy" >"$TEST_HOME/installer-output" 2>&1 &
    installer=$!
    for ((attempt = 0; attempt < 100; attempt++)); do
      [[ -e $TEST_HOME/ready ]] && break
      sleep 0.02
    done
    [[ -e $TEST_HOME/ready ]] || { fail 'installer reaches staged Profile validation'; exit 1; }
    assert_status 1 'staging retains the live lifecycle directory lock' flock -n "$XDG_RUNTIME_DIR" true
    touch "$TEST_HOME/release"
    wait "$installer"; status=$?
    installer=
    assert_eq 1 "$status" 'staged validation fails without timing out'
    assert_eq "$before" "$(installation_digest)" 'failed staging preserves installed payload'
    assert_eq "$profile_before" "$(sha256sum "$XDG_CONFIG_HOME/proxycode/settings" "$XDG_DATA_HOME/proxycode/profiles/work/"*)" 'failed staging preserves live Profile and settings'
    ((FAILURES == initial_failures))
  ) || fail 'staging lifecycle lock regression'
}

test_probe_questionnaire_reset_and_cancellation() {
  TESTS=$((TESTS + 1))
  (
    source "$ROOT/lib/proxycode.sh"
    initial_failures=$FAILURES
    choice=3 answer=0 cancel_at=-1 choose_status=0
    answers=('https://example.test/health' 200 'ready now')
    proxycode_choose() { PROXYCODE_CHOICE=$choice; return "$choose_status"; }
    proxycode_prompt() {
      ((answer != cancel_at)) || return 1
      PROXYCODE_ANSWER=${answers[answer]}
      answer=$((answer + 1))
    }
    result() { (IFS='|'; printf '%s' "${PROXYCODE_PROBE_SETTINGS[*]}"); }
    proxycode_prompt_probe_settings || fail 'custom questionnaire succeeds'
    assert_eq 'custom||https://example.test/health|200|ready now' "$(result)" 'custom questionnaire argument order'
    choice=1 answer=0 answers=('')
    proxycode_prompt_probe_settings || fail 'repeated questionnaire succeeds'
    assert_eq 'cloudflare||||' "$(result)" 'repeated questionnaire clears prior values'
    choose_status=1
    assert_status 2 'cancelled probe choice status' proxycode_prompt_probe_settings
    choose_status=0 choice=3 answers=('https://example.test/health' 200 ready)
    for cancel_at in 0 1 2; do
      answer=0
      assert_status 2 'cancelled probe answer status' proxycode_prompt_probe_settings
      assert_eq "$cancel_at" "$answer" 'cancellation stops subsequent questions'
    done
    ((FAILURES == initial_failures))
  ) || fail 'probe questionnaire reset and cancellation'
}
