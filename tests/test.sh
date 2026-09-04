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
  --config) printf 'Config OK\\n' ;;
  *) exit 2 ;;
esac
EOF
  chmod 700 "$target"
}

install_custom_binary() {
  fake_wireproxy "$TEST_HOME/custom/wireproxy"
  bash "$ROOT/install.sh" --install-only --wireproxy-bin "$TEST_HOME/custom/wireproxy"
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
