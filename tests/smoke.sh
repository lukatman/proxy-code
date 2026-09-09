#!/usr/bin/env bash

# Opt in only when this WireGuard key is not in use by another tunnel.
set -euo pipefail
umask 077

if [[ -z ${PROXYCODE_SMOKE_WG_CONFIG:-} ]]; then
  printf 'Skipped: set PROXYCODE_SMOKE_WG_CONFIG to an unused WireGuard configuration.\n'
  exit 0
fi
[[ $PROXYCODE_SMOKE_WG_CONFIG == /* && -f $PROXYCODE_SMOKE_WG_CONFIG && -r $PROXYCODE_SMOKE_WG_CONFIG ]] || {
  printf 'Smoke configuration must be an absolute path to a readable file.\n' >&2
  exit 2
}
root=$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)
installer=${PROXYCODE_SMOKE_INSTALLER:-$root/install.sh}
[[ $installer == /* && -f $installer && -r $installer ]] || exit 2
port=${PROXYCODE_SMOKE_HTTP_PORT:-25346}
[[ $port =~ ^[0-9]{1,5}$ ]] && ((10#$port >= 1024 && 10#$port <= 65535)) || exit 2
port=$((10#$port))
# Downloads must not depend on the working proxy after its tunnel is stopped.
unset HTTP_PROXY http_proxy HTTPS_PROXY https_proxy ALL_PROXY all_proxy NO_PROXY no_proxy

port_is_listening() {
  local hex
  printf -v hex '%04X' "$port"
  awk -v port=":$hex" '$2 ~ port "$" && $4 == "0A" { found=1 } END { exit !found }' /proc/net/tcp /proc/net/tcp6
}
if port_is_listening; then
  printf 'Smoke HTTP port is occupied; choose PROXYCODE_SMOKE_HTTP_PORT.\n' >&2
  exit 2
fi

sandbox=$(mktemp -d /tmp/proxycode-smoke.XXXXXX) || exit 1
[[ $sandbox == /tmp/proxycode-smoke.* && -d $sandbox && ! -L $sandbox && -O $sandbox ]] || exit 1
cli=$sandbox/home/.local/bin/proxycode
pid=
cleanup() {
  local result=$?
  trap - EXIT
  if [[ -x $cli ]] && ! "$cli" stop >>"$sandbox/output.log" 2>&1; then
    printf 'Cleanup could not verify stop. Private sandbox retained: %s\n' "$sandbox" >&2
    exit 1
  fi
  if [[ -n $pid && $(readlink "/proc/$pid/exe" 2>/dev/null || true) == "$XDG_DATA_HOME/proxycode/bin/wireproxy" ]] || port_is_listening; then
    printf 'Process or listener remains. Private sandbox retained: %s\n' "$sandbox" >&2
    exit 1
  fi
  rm -rf -- "$sandbox"
  exit "$result"
}
export HOME=$sandbox/home XDG_CONFIG_HOME=$sandbox/config XDG_DATA_HOME=$sandbox/data
export XDG_STATE_HOME=$sandbox/state XDG_RUNTIME_DIR=$sandbox/runtime TMPDIR=$sandbox/tmp
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
mkdir -p "$HOME" "$XDG_RUNTIME_DIR" "$TMPDIR"
cp -- "$PROXYCODE_SMOKE_WG_CONFIG" "$sandbox/source.conf"

step() {
  local name=$1
  shift
  if ! "$@" >>"$sandbox/output.log" 2>&1; then
    printf 'Failed: %s (private command output is not printed).\n' "$name" >&2
    return 1
  fi
  printf 'Passed: %s\n' "$name"
}
profile_digest() {
  sha256sum "$XDG_CONFIG_HOME/proxycode/settings" "$XDG_DATA_HOME/proxycode/profiles/smoke/"*
}

step 'install pinned WireProxy' bash "$installer" --install-only
grep -qx 'WIREPROXY_SOURCE=pinned' "$XDG_STATE_HOME/proxycode/install"
step 'choose separate listener port' "$cli" settings --http-port "$port"
step 'import profile' "$cli" profile import "$sandbox/source.conf" --name smoke --default
step 'start and initial HTTPS check' "$cli" start
pid=$("$cli" status | sed -n 's/^Process: running (PID \([0-9]*\))$/\1/p')
[[ $pid =~ ^[0-9]+$ && $(readlink "/proc/$pid/exe") == "$XDG_DATA_HOME/proxycode/bin/wireproxy" ]]
port_is_listening
rm -rf -- "${XDG_RUNTIME_DIR:?}"
export XDG_RUNTIME_DIR=$sandbox/next-runtime
mkdir -p "$XDG_RUNTIME_DIR/proxycode"
printf 'unrelated runtime data\n' >"$XDG_RUNTIME_DIR/proxycode/keep"
[[ $("$cli" status) == *"Process: running (PID $pid)"* ]]
step 'health check after runtime directory replacement' "$cli" check
unauthenticated_status=$(curl --disable --silent --noproxy '' --proxy "http://127.0.0.1:$port" --max-time 10 \
  --output /dev/null --write-out '%{http_connect}' https://cloudflare.com/cdn-cgi/trace 2>/dev/null || true)
[[ $unauthenticated_status == 407 ]]
printf 'Passed: unauthenticated proxy request rejected.\n'
# shellcheck disable=SC2016 # The Wrapped command expands its own proxy environment.
step 'wrapped authenticated HTTPS request' "$cli" bash -c '
  [[ $https_proxy == http://proxy-code:*@127.0.0.1:* ]] || exit 1
  curl --disable --silent --show-error --fail --max-time 30 https://cloudflare.com/cdn-cgi/trace -o /dev/null
'
step 'stop' "$cli" stop
[[ ! -e $XDG_STATE_HOME/proxycode/active ]]
[[ $("$cli" status) == *'Process: stopped'* ]]
[[ $(readlink "/proc/$pid/exe" 2>/dev/null || true) != "$XDG_DATA_HOME/proxycode/bin/wireproxy" ]]
if port_is_listening; then exit 1; fi
before=$(profile_digest)
step 'reinstall' bash "$installer" --install-only
[[ $(profile_digest) == "$before" ]]
step 'uninstall' bash "$installer" --uninstall --yes
[[ ! -e $cli && $(profile_digest) == "$before" ]]
[[ $(cat "$XDG_RUNTIME_DIR/proxycode/keep") == 'unrelated runtime data' ]]
step 'restore preserved profile' bash "$installer" --install-only
[[ $(profile_digest) == "$before" ]]
step 'purge' bash "$installer" --purge --yes
[[ ! -e $cli ]]
for directory in "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME"; do
  [[ ! -e $directory/proxycode ]]
done
[[ $(cat "$XDG_RUNTIME_DIR/proxycode/keep") == 'unrelated runtime data' ]]
cmp -s -- "$PROXYCODE_SMOKE_WG_CONFIG" "$sandbox/source.conf"
printf 'Passed: preservation, purge, original source unchanged, process and listener cleanup.\n'
