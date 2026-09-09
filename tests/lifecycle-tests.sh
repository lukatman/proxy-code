#!/usr/bin/env bash

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
  assert_mode "$XDG_STATE_HOME/proxycode" 700
  assert_mode "$XDG_STATE_HOME/proxycode/active" 600
  assert_mode "$XDG_STATE_HOME/proxycode/logs/work" 700
  assert_mode "$XDG_STATE_HOME/proxycode/logs/work/wireproxy.log" 600
  pid=$(sed -n 's/^PID=//p' "$XDG_STATE_HOME/proxycode/active")
  [[ $pid =~ ^[0-9]+$ && -d /proc/$pid ]] || fail 'start records a running process'
  grep -q '^READY=1$' "$XDG_STATE_HOME/proxycode/active" || fail 'successful activation marks state ready'
  for fd in /proc/"$pid"/fd/*; do
    [[ $(readlink "$fd" 2>/dev/null) != "$XDG_STATE_HOME" ]] || fail 'WireProxy inherits the lifecycle lock'
  done

  output=$("$cli" status)
  [[ $output == $'Default: work\nActive: work\nProfiles: travel, work\nProcess: running (PID '*')' ]] || fail 'status reports local lifecycle state'
  calls=$(<"$FAKE_CURL_CALLS")
  output=$("$cli" start work)
  assert_eq 'Tunnel Profile already active: work' "$output" 'starting the Active Profile is idempotent'
  assert_eq "$calls" "$(<"$FAKE_CURL_CALLS")" 'idempotent start does not repeat health'

  sed -i 's/^READY=1$/READY=0/' "$XDG_STATE_HOME/proxycode/active"
  output=$("$cli" status 2>&1)
  status=$?
  assert_eq 1 "$status" 'incomplete activation status'
  [[ $output == *$'Active: none\n'* && $output == *'Process: starting'* ]] || fail 'incomplete activation is reported without claiming Active'
  output=$("$cli" start work)
  assert_eq $'Stopped Tunnel Profile: work\nStarted Tunnel Profile: work\nLocation: SG' "$output" 'start recovers a verified incomplete activation'
  [[ ! -e /proc/$pid ]] || fail 'incomplete activation recovery leaves the old process running'
  pid=$(sed -n 's/^PID=//p' "$XDG_STATE_HOME/proxycode/active")

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
  [[ -e /proc/$pid && -e $XDG_STATE_HOME/proxycode/active ]] || fail 'explicit health failure mutates lifecycle state'
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
  [[ ! -e $XDG_STATE_HOME/proxycode/active ]] || fail 'stop clears active state'
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
  [[ ! -e $XDG_STATE_HOME/proxycode/active ]] || fail 'failed activation leaves active state'
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
  grep -q '^READY=0$' "$XDG_STATE_HOME/proxycode/active" || fail 'unverified startup loses its provisional state'
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
  local -a stat_fields
  write_wireguard_config "$source"
  "$cli" profile import "$source" --name work --default >/dev/null || { fail 'state safety Profile import succeeds'; return; }
  install_lifecycle_fakes
  EXPECTED_WIREPROXY_EXE=$(readlink -f "$XDG_DATA_HOME/proxycode/bin/wireproxy")
  export EXPECTED_WIREPROXY_EXE
  PATH=$TEST_HOME/lifecycle-fakes:$SYSTEM_PATH
  "$cli" status >/dev/null
  state=$XDG_STATE_HOME/proxycode/active

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
  read -ra stat_fields <<<"$rest"
  shell_started=${stat_fields[19]}
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
  for _ in {1..50}; do
    [[ -s $WIREPROXY_START_LOG ]] && break
    sleep 0.02
  done
  [[ -s $WIREPROXY_START_LOG ]] || fail 'first start reaches activation'
  rm -rf -- "$XDG_RUNTIME_DIR"
  XDG_RUNTIME_DIR=$TEST_HOME/next-runtime "$cli" start >"$TEST_HOME/second.out" & second=$!
  wait "$first" || fail 'first serialized start succeeds'
  wait "$second" || fail 'second serialized start succeeds idempotently'
  assert_eq 1 "$(wc -l <"$WIREPROXY_START_LOG")" 'starts from different sessions launch one WireProxy process'
  assert_eq 2 "$(<"$FAKE_CURL_CALLS")" 'transient activation failure retries once before success'
  pid=$(sed -n 's/^PID=//p' "$XDG_STATE_HOME/proxycode/active")
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
  [[ ! -e $WIREPROXY_START_LOG && ! -e $XDG_STATE_HOME/proxycode/active ]] || fail 'unknown listener is adopted or replaced'
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
  [[ $(readlink "$fd" 2>/dev/null) != "$XDG_STATE_HOME" ]] || exit 98
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
  pid=$(sed -n 's/^PID=//p' "$XDG_STATE_HOME/proxycode/active")
  [[ -e /proc/$pid ]] || fail 'WireProxy does not remain active after the Wrapped command exits'

  local calls marker=$TEST_HOME/refused-command-ran
  calls=$(<"$FAKE_CURL_CALLS")
  "$cli" --profile work /usr/bin/true || fail 'Wrapped command reuses its matching Active Tunnel Profile'
  assert_eq "$calls" "$(<"$FAKE_CURL_CALLS")" 'Wrapped command reuse performs no health probe'
  output=$("$cli" --profile travel /usr/bin/touch "$marker" 2>&1)
  status=$?
  assert_eq 1 "$status" 'Wrapped command refuses a different Active Tunnel Profile'
  [[ $output == *"Tunnel Profile 'work' is active; stop it first"* && ! -e $marker ]] || fail 'Wrapped command refusal is unclear or executes the command'
  [[ $(sed -n 's/^PROFILE=//p' "$XDG_STATE_HOME/proxycode/active") == work ]] || fail 'Wrapped command refusal changes the Active Tunnel Profile'
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
  [[ $(sed -n 's/^PROFILE=//p' "$XDG_STATE_HOME/proxycode/active") == work ]] || fail 'unconfirmed switch changes the Active Tunnel Profile'

  export EXPECTED_PROXY_URL=http://proxy-code:$travel_password@127.0.0.1:25345
  output=$("$cli" switch travel --yes) || { fail 'confirmed switch succeeds'; return; }
  assert_eq $'Stopped Tunnel Profile: work\nStarted Tunnel Profile: travel\nLocation: SG' "$output" 'successful switch output'
  [[ $(sed -n 's/^PROFILE=//p' "$XDG_STATE_HOME/proxycode/active") == travel ]] || fail 'successful switch does not activate its target'
  assert_eq 'Tunnel Profile already active: travel' "$("$cli" switch travel)" 'switching to the Active Profile is idempotent without consent'

  export EXPECTED_PROXY_URL=http://proxy-code:$work_password@127.0.0.1:25345 FAKE_CURL_EXIT=60
  output=$("$cli" switch work --yes 2>&1)
  status=$?
  assert_eq 1 "$status" 'failed switch activation status'
  [[ $output == *'Stopped Tunnel Profile: travel'* && $output == *'health check failed'* ]] || fail 'failed switch does not explain stop and activation failure'
  [[ ! -e $XDG_STATE_HOME/proxycode/active ]] || fail 'failed switch does not leave the Toolkit stopped'
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
  pid=$(sed -n 's/^PID=//p' "$XDG_STATE_HOME/proxycode/active")

  output=$("$cli" settings --http-port 31080 2>&1)
  status=$?
  assert_eq 1 "$status" 'HTTP port change while active status'
  [[ $output == *'stop it first'* ]] || fail 'active HTTP port refusal lacks stop guidance'
  assert_eq 'HTTP port: 25345' "$("$cli" settings)" 'active HTTP port refusal changes settings'

  printf '\n# replacement\n' >>"$source"
  output=$("$cli" profile import "$source" --name work --replace --yes) || { fail 'Active Profile replacement succeeds'; return; }
  assert_eq $'Stopped Tunnel Profile: work\nReplaced Tunnel Profile: work' "$output" 'Active Profile replacement output'
  [[ ! -e $XDG_STATE_HOME/proxycode/active && ! -e /proc/$pid ]] || fail 'Active Profile replacement leaves its old process or state behind'
  cmp -s "$source" "$profile/wireguard.conf" || fail 'Active Profile replacement does not install the new private copy'
  "$cli" start work >/dev/null || { fail 'replaced Active Profile restarts'; return; }
  pid=$(sed -n 's/^PID=//p' "$XDG_STATE_HOME/proxycode/active")

  export FAKE_READLINK_EXE=/usr/bin/not-wireproxy
  output=$("$cli" profile remove work --yes 2>&1)
  status=$?
  assert_eq 1 "$status" 'unverified Active Profile removal status'
  [[ $output == *'identity is ambiguous'* && -d $profile && -e /proc/$pid ]] || fail 'unverified Active Profile removal deletes files or signals the process'
  unset FAKE_READLINK_EXE

  output=$("$cli" profile remove work --yes) || { fail 'verified Active Profile removal succeeds'; return; }
  assert_eq $'Stopped Tunnel Profile: work\nRemoved Tunnel Profile: work' "$output" 'Active Profile removal output'
  [[ ! -e $profile && ! -e $XDG_STATE_HOME/proxycode/active && ! -e /proc/$pid ]] || fail 'Active Profile removal leaves Profile, state, or process behind'
  [[ -f $source ]] || fail 'Active Profile removal touches the source configuration'
}

test_lifecycle_lock_cleanup_after_failure() {
  TESTS=$((TESTS + 1))
  new_home
  install_custom_binary >/dev/null || { fail 'lock cleanup install succeeds'; return; }
  local cli=$HOME/.local/bin/proxycode
  printf 'HTTP_PORT=invalid\nDEFAULT_PROFILE=\n' >"$XDG_CONFIG_HOME/proxycode/settings"
  assert_status 1 'invalid settings fail promptly' timeout 2 "$cli" status
  printf 'HTTP_PORT=31080\nDEFAULT_PROFILE=\n' >"$XDG_CONFIG_HOME/proxycode/settings"
  assert_status 0 'a command after failed preparation can acquire the lock' timeout 2 "$cli" status
}

test_probe_result_classification_and_cleanup() {
  TESTS=$((TESTS + 1))
  new_home
  install_custom_binary >/dev/null || { fail 'probe test install succeeds'; return; }
  local cli=$HOME/.local/bin/proxycode source=$TEST_HOME/source/work.conf calls status output
  write_wireguard_config "$source"
  "$cli" profile import "$source" --name work --default >/dev/null || { fail 'probe Profile import succeeds'; return; }
  install_lifecycle_fakes
  EXPECTED_WIREPROXY_EXE=$(readlink -f "$XDG_DATA_HOME/proxycode/bin/wireproxy")
  export EXPECTED_WIREPROXY_EXE FAKE_CURL_CALLS=$TEST_HOME/curl-calls
  export PATH=$TEST_HOME/lifecycle-fakes:$SYSTEM_PATH
  "$cli" start >/dev/null || { fail 'probe Profile starts'; return; }

  calls=$(<"$FAKE_CURL_CALLS")
  assert_status 1 'explicit check does not retry a timeout' env FAKE_CURL_EXIT=28 "$cli" check
  assert_eq "$((calls + 1))" "$(<"$FAKE_CURL_CALLS")" 'explicit check makes one request'
  for status in 503 400 301; do
    assert_status 1 "unexpected HTTP $status fails" env FAKE_CURL_STATUS="$status" "$cli" check
  done
  "$cli" profile settings work --probe mullvad --expect-location Sweden >/dev/null
  output=$(FAKE_CURL_BODY='{"mullvad_exit_ip":true,"country":"Singapore"}' "$cli" check 2>&1)
  assert_eq 1 "$?" 'Mullvad mismatch fails'
  [[ $output == *'Location: Singapore'* ]] || fail 'Mullvad mismatch reports observed location'

  "$cli" profile settings work --probe custom --url https://example.test --status 503 --contains '[ready]' >/dev/null
  output=$(FAKE_CURL_STATUS=503 FAKE_CURL_BODY='[ready]' "$cli" check)
  assert_eq 0 "$?" 'explicit custom 503 succeeds'
  [[ $output == *'Location: unavailable'* ]] || fail 'custom success clears observed location'
  assert_status 1 'custom substring is literal' env FAKE_CURL_STATUS=503 FAKE_CURL_BODY=ready "$cli" check

  cat >"$TEST_HOME/lifecycle-fakes/chmod" <<'EOF'
#!/usr/bin/env bash
[[ ${!#} == "$XDG_STATE_HOME/proxycode/probe."* ]] && exit 1
exec /usr/bin/chmod "$@"
EOF
  chmod 700 "$TEST_HOME/lifecycle-fakes/chmod"
  calls=$(<"$FAKE_CURL_CALLS")
  assert_status 1 'response permission failure fails check' "$cli" check
  assert_eq "$calls" "$(<"$FAKE_CURL_CALLS")" 'response permission failure makes no request'
  [[ -z $(find "$XDG_STATE_HOME/proxycode" -name 'probe.*' -print) ]] || fail 'probe leaves temporary response files'
  "$cli" stop >/dev/null || fail 'probe test stops its process'
}

test_active_state_write_failures() {
  TESTS=$((TESTS + 1))
  new_home
  install_custom_binary >/dev/null || { fail 'state write fault test install succeeds'; return; }
  local cli=$HOME/.local/bin/proxycode source=$TEST_HOME/source/work.conf fault pid output
  write_wireguard_config "$source"
  "$cli" profile import "$source" --name work --default >/dev/null || { fail 'state write fault Profile import succeeds'; return; }
  install_lifecycle_fakes
  EXPECTED_WIREPROXY_EXE=$(readlink -f "$XDG_DATA_HOME/proxycode/bin/wireproxy")
  export EXPECTED_WIREPROXY_EXE FAKE_CURL_CALLS=$TEST_HOME/curl-calls WIREPROXY_START_LOG=$TEST_HOME/wireproxy-starts
  export FAKE_ACTIVE_WRITES=$TEST_HOME/active-writes FAKE_ACTIVE_LOST_IDENTITY=$TEST_HOME/lost-identity
  mkdir -p "$TEST_HOME/state-fakes"
  cat >"$TEST_HOME/state-fakes/mv" <<'EOF'
#!/usr/bin/env bash
if [[ ${!#} == "$XDG_STATE_HOME/proxycode/active" ]]; then
  count=0
  [[ ! -f $FAKE_ACTIVE_WRITES ]] || count=$(<"$FAKE_ACTIVE_WRITES")
  count=$((count + 1))
  printf '%s\n' "$count" >"$FAKE_ACTIVE_WRITES"
  if ((count == FAKE_ACTIVE_FAIL)); then
    [[ ${FAKE_ACTIVE_AMBIGUOUS:-0} == 0 ]] || touch "$FAKE_ACTIVE_LOST_IDENTITY"
    exit 1
  fi
fi
exec /usr/bin/mv "$@"
EOF
  cat >"$TEST_HOME/state-fakes/readlink" <<'EOF'
#!/usr/bin/env bash
if [[ ${!#} == /proc/*/exe && -f $FAKE_ACTIVE_LOST_IDENTITY ]]; then
  printf '/usr/bin/not-wireproxy\n'
else
  exec "$TEST_HOME/lifecycle-fakes/readlink" "$@"
fi
EOF
  chmod 700 "$TEST_HOME/state-fakes/"*
  export TEST_HOME PATH=$TEST_HOME/state-fakes:$TEST_HOME/lifecycle-fakes:$SYSTEM_PATH
  for fault in 1 2 3; do
    rm -f "$FAKE_ACTIVE_WRITES" "$WIREPROXY_START_LOG"
    assert_status 1 "active state write $fault failure" env FAKE_ACTIVE_FAIL="$fault" "$cli" start
    [[ ! -e $XDG_STATE_HOME/proxycode/active ]] || fail "write $fault leaves active state after cleanup"
    if ((fault == 1)); then
      [[ ! -e $WIREPROXY_START_LOG ]] || fail 'reservation failure spawns a process'
    else
      pid=$(tail -n 1 "$WIREPROXY_START_LOG")
      [[ ! -e /proc/$pid ]] || fail "write $fault leaves its process running"
    fi
  done

  rm -f "$FAKE_ACTIVE_WRITES"
  output=$(FAKE_ACTIVE_FAIL=3 FAKE_ACTIVE_AMBIGUOUS=1 "$cli" start 2>&1)
  assert_eq 1 "$?" 'failed final write with uncertain process identity fails'
  [[ $output == *'ambiguous state was retained'* ]] || fail 'uncertain cleanup lacks recovery guidance'
  grep -q '^READY=0$' "$XDG_STATE_HOME/proxycode/active" || fail 'uncertain cleanup loses provisional state'
  pid=$(tail -n 1 "$WIREPROXY_START_LOG")
  [[ -e /proc/$pid ]] || fail 'uncertain cleanup signals the process'
  rm -f "$FAKE_ACTIVE_LOST_IDENTITY"
  "$cli" stop >/dev/null || fail 'restored process identity permits safe stop'
}

test_lifecycle_survives_session_runtime_changes() {
  local scenario cli pid output original_runtime
  for scenario in removed changed unset; do
    TESTS=$((TESTS + 1))
    new_home
    original_runtime=$XDG_RUNTIME_DIR
    mkdir -p "$original_runtime/proxycode"
    printf 'not managed by this installation\n' >"$original_runtime/proxycode/unrelated"
    install_custom_binary >/dev/null || { fail 'session runtime test install succeeds'; continue; }
    cli=$HOME/.local/bin/proxycode
    write_wireguard_config "$TEST_HOME/source/work.conf"
    "$cli" profile import "$TEST_HOME/source/work.conf" --name work --default >/dev/null || { fail 'session runtime Profile import succeeds'; continue; }
    "$cli" settings --http-port 31080 >/dev/null || { fail 'session runtime test port is configured'; continue; }
    install_lifecycle_fakes
    EXPECTED_WIREPROXY_EXE=$(readlink -f "$XDG_DATA_HOME/proxycode/bin/wireproxy")
    export EXPECTED_WIREPROXY_EXE FAKE_CURL_CALLS=$TEST_HOME/curl-calls WIREPROXY_START_LOG=$TEST_HOME/wireproxy-starts
    export PATH=$TEST_HOME/lifecycle-fakes:$SYSTEM_PATH
    "$cli" start >/dev/null || { fail 'session runtime Profile starts'; continue; }
    pid=$(tail -n 1 "$WIREPROXY_START_LOG")
    [[ -f $original_runtime/proxycode/unrelated && ! -e $original_runtime/proxycode/active ]] || fail 'lifecycle writes into session runtime storage'

    case $scenario in
      removed) rm -rf -- "$original_runtime/proxycode" ;;
      changed) export XDG_RUNTIME_DIR=$TEST_HOME/next-runtime ;;
      unset) unset XDG_RUNTIME_DIR ;;
    esac
    output=$("$cli" status)
    assert_eq 0 "$?" "$scenario runtime status succeeds"
    [[ $output == *$'Active: work\n'* && $output == *"Process: running (PID $pid)"* ]] || fail "$scenario runtime loses the running Profile"
    assert_status 0 "$scenario runtime health check finds the Profile" "$cli" check
    assert_eq 'Tunnel Profile already active: work' "$("$cli" start)" "$scenario runtime reuses the original process"
    assert_eq 1 "$(wc -l <"$WIREPROXY_START_LOG")" "$scenario runtime launches a duplicate process"
    assert_eq 'Stopped Tunnel Profile: work' "$("$cli" stop)" "$scenario runtime stops the original process"
    [[ ! -e /proc/$pid && ! -e $XDG_STATE_HOME/proxycode/active ]] || fail "$scenario runtime leaves its original process or active state"
    if [[ $scenario != removed ]]; then
      [[ -f $original_runtime/proxycode/unrelated ]] || fail 'lifecycle deletes unrelated session runtime files'
    fi
  done
}
