#!/usr/bin/env bash

test_custom_install_and_cli() {
  TESTS=$((TESTS + 1))
  new_home

  local output
  output=$(install_custom_binary) || { fail 'custom install succeeds'; return; }
  [[ $output == *'Installed proxycode 0.1.0.'* ]] || fail 'install reports Toolkit version'
  [[ $output == *'custom WireProxy v1.1.3'* ]] || fail 'install identifies custom WireProxy'

  local cli=$HOME/.local/bin/proxycode
  assert_eq 'proxycode 0.1.0' "$("$cli" version)" 'version output'
  output=$("$cli" help)
  [[ $output == Usage:* ]] || fail 'help output starts with usage'
  [[ $output == *'proxycode [--profile NAME] COMMAND [ARG...]'* ]] || fail 'help documents explicit Profile wrapping'
  [[ $output == *'profile settings NAME --probe custom --url HTTPS_URL --status CODE [--contains TEXT]'* ]] || fail 'help documents complete custom probe settings'
  [[ $output != *upgrade* ]] || fail 'help advertises an unavailable upgrade command'
  assert_mode "$cli" 700
  assert_mode "$XDG_DATA_HOME/proxycode/bin/wireproxy" 700
  assert_mode "$XDG_DATA_HOME/proxycode/lib/proxycode.sh" 600
  assert_mode "$XDG_DATA_HOME/proxycode/licenses/wireproxy.LICENSE" 600
  assert_mode "$XDG_STATE_HOME/proxycode/install" 600
  assert_mode "$XDG_DATA_HOME/proxycode" 700
  grep -q '^WIREPROXY_SOURCE=custom$' "$XDG_STATE_HOME/proxycode/install" || fail 'custom source is recorded'
  grep -q '^Copyright (c) 2026 Tsz Fung Wong' "$XDG_DATA_HOME/proxycode/licenses/wireproxy.LICENSE" || fail 'upstream notice is preserved'
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
  assert_eq 'proxycode 0.1.0' "$("$cli" version)" 'reinstall refreshes the Toolkit command'
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
  # /proc stat fields after the command name are whitespace-separated numbers.
  # shellcheck disable=SC2086
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
  for ((attempt = 0; attempt < 50; attempt++)); do
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
  local output status
  mkdir -p "$TEST_HOME/empty-path"
  output=$(PATH=$TEST_HOME/empty-path /usr/bin/bash "$ROOT/install.sh" --install-only 2>&1)
  status=$?
  assert_eq 1 "$status" 'missing dependency status'
  [[ $output == *'missing required commands: curl flock tar sha256sum timeout mktemp readlink stat nohup awk grep sed'* ]] || fail 'all missing dependencies are reported together'
  [[ ! -e $XDG_DATA_HOME/proxycode ]] || fail 'missing dependencies write no Toolkit data'
}

# Keep actual pipes: bootstrap must work when Bash reads a pipe, not a source file.
# shellcheck disable=SC2002
test_piped_bootstrap() {
  TESTS=$((TESTS + 1))
  new_home
  local release=$TEST_HOME/release/proxycode-0.1.0 bundle=$TEST_HOME/proxycode-0.1.0.tar.gz output status
  mkdir -p "$release/bin" "$release/lib" "$TEST_HOME/bootstrap-fakes"
  cat >"$release/install.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$BOOTSTRAP_ARGS"
printf 'bundle installer ran\n'
EOF
  printf '# bundled command\n' >"$release/bin/proxycode"
  printf '# bundled library\n' >"$release/lib/proxycode.sh"
  tar -czf "$bundle" -C "$TEST_HOME/release" proxycode-0.1.0
  (cd "$TEST_HOME" && sha256sum proxycode-0.1.0.tar.gz >proxycode-0.1.0.tar.gz.sha256)
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
  assert_eq $'https://github.com/lukatman/proxycode/releases/download/v0.1.0/proxycode-0.1.0.tar.gz\nhttps://github.com/lukatman/proxycode/releases/download/v0.1.0/proxycode-0.1.0.tar.gz.sha256' "$(<"$BOOTSTRAP_URLS")" 'piped bootstrap uses fixed release assets'

  rm -f "$BOOTSTRAP_URLS"
  output=$(cat "$ROOT/install.sh" | PATH=$TEST_HOME/bootstrap-fakes:$SYSTEM_PATH bash -s 2>&1)
  status=$?
  assert_eq 2 "$status" 'non-terminal piped setup status'
  [[ $output == *'complete setup flags'* ]] || fail 'non-terminal piped setup lacks complete-flags guidance'
  [[ ! -e $BOOTSTRAP_URLS ]] || fail 'incomplete piped setup downloads a bundle'

  cp "$ROOT/install.sh" "$release/install.sh"
  cp "$ROOT/bin/proxycode" "$release/bin/proxycode"
  cp "$ROOT/lib/proxycode.sh" "$release/lib/proxycode.sh"
  tar -czf "$bundle" -C "$TEST_HOME/release" proxycode-0.1.0
  (cd "$TEST_HOME" && sha256sum proxycode-0.1.0.tar.gz >proxycode-0.1.0.tar.gz.sha256)
  fake_wireproxy "$TEST_HOME/custom/wireproxy"
  output=$(run_tty "$DOWN
$DOWN
$TEST_HOME/custom/wireproxy

" env PATH="$TEST_HOME/bootstrap-fakes:$SYSTEM_PATH" bash -c "cat '$ROOT/install.sh' | bash") || {
    fail 'piped interactive setup succeeds'; return;
  }
  [[ $output == *' ProxyCode '*setup* && $output == *'Installed custom WireProxy v1.1.3.'* ]] || fail 'piped installer does not prompt on the terminal'
}
