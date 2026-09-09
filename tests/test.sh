#!/usr/bin/env bash

# Expected command failures are asserted below, even when the caller exports errexit.
set +e
set -u

# Only run_tty supplies a terminal; other tests assert noninteractive behavior.
exec </dev/null

ROOT=$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)
SYSTEM_PATH=$PATH
TESTS=0
FAILURES=0
TEST_HOMES=()
DOWN=$'\033[B'
ESCAPE=$'\033'
BACKSPACE=$'\177'

test_process_matches() {
  local pid=$1 started=$2 script=$3 stat rest argument
  local -a fields
  [[ $pid =~ ^[0-9]+$ && -r /proc/$pid/stat ]] || return 1
  IFS= read -r stat <"/proc/$pid/stat" || return 1
  rest=${stat##*) }
  read -ra fields <<<"$rest"
  [[ ${fields[19]:-} == "$started" && ${fields[0]:-} != Z ]] || return 1
  while IFS= read -r -d '' argument; do
    [[ $argument == "$script" ]] && return 0
  done <"/proc/$pid/cmdline"
  return 1
}

cleanup_tests() {
  local directory pid started script attempt
  export PATH=$SYSTEM_PATH
  for directory in "${TEST_HOMES[@]}"; do
    [[ $directory == /tmp/proxycode-tests.* && -d $directory && ! -L $directory ]] || continue
    if [[ -f $directory/processes ]]; then
      while IFS=$'\t' read -r pid started script; do
        [[ $script == "$directory/"* ]] || continue
        if test_process_matches "$pid" "$started" "$script"; then
          kill -TERM "$pid" 2>/dev/null || true
          for attempt in {1..20}; do
            test_process_matches "$pid" "$started" "$script" || break
            sleep 0.1
          done
          if test_process_matches "$pid" "$started" "$script"; then
            kill -KILL "$pid" 2>/dev/null || true
          fi
        fi
      done <"$directory/processes"
    fi
    rm -rf -- "$directory"
  done
}
trap cleanup_tests EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

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
  TEST_HOME=$(mktemp -d /tmp/proxycode-tests.XXXXXX) || exit 1
  [[ $TEST_HOME == /tmp/proxycode-tests.* && -d $TEST_HOME && ! -L $TEST_HOME && -O $TEST_HOME ]] || exit 1
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
  mkdir -p "$HOME" "$XDG_RUNTIME_DIR" || exit 1
  export TEST_PROCESS_LOG=$TEST_HOME/processes
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
    IFS= read -r process_stat </proc/\$\$/stat
    read -ra process_fields <<<"\${process_stat##*) }"
    printf '%s\\t%s\\t%s\\n' "\$\$" "\${process_fields[19]}" "\$0" >>"\$TEST_PROCESS_LOG"
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
if [[ ${1:-} == 1 && ${2:-} == bash ]]; then
  # Lifecycle tests simulate the listener instead of probing the user's port.
  [[ -n ${FAKE_PORT_BUSY:-} ]]
  exit $?
fi
exec /usr/bin/timeout "$@"
EOF
  chmod 700 "$TEST_HOME/lifecycle-fakes/"*
}

test_sandbox_cleanup() {
  TESTS=$((TESTS + 1))
  new_home
  local directory=$TEST_HOME pid unrelated attempt
  fake_wireproxy "$TEST_HOME/custom/wireproxy"
  "$TEST_HOME/custom/wireproxy" --config "$TEST_HOME/fake.conf" >/dev/null 2>&1 & pid=$!
  sleep 60 & unrelated=$!
  for attempt in {1..20}; do
    [[ -s $TEST_PROCESS_LOG ]] && break
    sleep 0.05
  done
  [[ -s $TEST_PROCESS_LOG ]] || fail 'fake process registers for cleanup'
  printf '%s\t%s\t%s\n' "$unrelated" "$(awk '{print $22}' "/proc/$unrelated/stat")" "$TEST_HOME/custom/wireproxy" >>"$TEST_PROCESS_LOG"
  cleanup_tests
  [[ ! -e $directory ]] || fail 'cleanup leaves its temporary tree'
  [[ ! -e /proc/$pid ]] || fail 'cleanup leaves its fake WireProxy running'
  kill -0 "$unrelated" 2>/dev/null || fail 'cleanup signals an unrelated process'
  kill -TERM "$unrelated" 2>/dev/null || true
  wait "$pid" "$unrelated" 2>/dev/null || true
}

source "$ROOT/tests/install-tests.sh"
source "$ROOT/tests/profile-tests.sh"
source "$ROOT/tests/lifecycle-tests.sh"
source "$ROOT/tests/interactive-tests.sh"

test_custom_install_and_cli
test_profile_import_default_and_show
test_profile_replacement_and_validation_rollback
test_global_and_profile_settings
test_profile_default_name_validation_and_removal
test_lifecycle_start_status_and_stop
test_lifecycle_failed_start_cleanup
test_lifecycle_stale_and_ambiguous_state
test_lifecycle_lock_serializes_start
test_lifecycle_survives_session_runtime_changes
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

test_probe_result_classification_and_cleanup
test_active_state_write_failures
test_probe_questionnaire_reset_and_cancellation
test_setup_staging_paths_and_rollback
test_setup_staging_retains_lifecycle_lock

test_sandbox_cleanup

if ((FAILURES)); then
  printf '%d of %d tests failed\n' "$FAILURES" "$TESTS" >&2
  exit 1
fi
printf 'ok - %d tests passed\n' "$TESTS"
