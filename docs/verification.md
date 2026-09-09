# Maintainer verification

These checks are for development and release preparation. Installing and using
ProxyCode does not require ShellCheck or running the test suite.

Run from the repository root on Linux. The behavior suite needs the runtime
dependencies in the README and util-linux's `script` and `setsid` for terminal tests.
ShellCheck is the only additional lint tool.

```bash
for file in install.sh bin/proxycode lib/proxycode.sh tests/*.sh; do
  bash -n "$file" || exit
done
shellcheck -x -P SCRIPTDIR install.sh bin/proxycode lib/proxycode.sh tests/*.sh
script -qec 'env SHELLOPTS=errexit bash tests/test.sh' /dev/null </dev/null
```

[GitHub Actions](../.github/workflows/checks.yml) runs these same checks on
`ubuntu-24.04` and `ubuntu-24.04-arm`. The suite exercises the installer and
installed CLI with temporary HOME/XDG roots and fake external commands. CI starts
it in a terminal with inherited `errexit` to check that expected failures and
confirmation prompts cannot silently abort or hang the runner. For everyday
local checks, `bash tests/test.sh` is enough. It needs
no WireGuard account and does not use your installed tunnel.

## Real tunnel and release walkthrough

Run this before marking a release ready, and after changing the WireProxy pin or
lifecycle. It requires the real pinned WireProxy and a working WireGuard
configuration. A skipped smoke check does not count as a pass.

**If the configuration's key is already in use, stop that tunnel first.** Reusing
one key concurrently can disrupt WireGuard connectivity. If you only have one
configuration, use a separate local terminal, note the active profile from
`proxycode status`, and run `proxycode stop`. Restart that profile after testing.
Do not run this from a remote session that depends on the tunnel staying up.

Download the prerelease installer before stopping your working tunnel:

```bash
smoke_download=$(mktemp -d)
curl --proto '=https' --tlsv1.2 -fL \
  https://github.com/lukatman/proxycode/releases/download/v0.1.0/install.sh \
  -o "$smoke_download/install.sh"
```

Once the key is unused, run from the repository root, replacing the configuration
path with your original file's absolute path:

```bash
PROXYCODE_SMOKE_WG_CONFIG=/absolute/path/to/tunnel.conf \
PROXYCODE_SMOKE_INSTALLER="$smoke_download/install.sh" \
  bash tests/smoke.sh && rm -rf -- "$smoke_download"
```

The script uses port **25346** by default; set `PROXYCODE_SMOKE_HTTP_PORT` to
another unused port if needed. It clears inherited proxy variables, so downloads
require HTTPS access without the stopped proxy. Leave `PROXYCODE_SMOKE_INSTALLER`
unset to test the local checkout instead; that does not verify release downloads.

The disposable walkthrough uses the README's public operations, with temporary
paths, profile `smoke`, and a separate listener port:

```text
install --install-only → settings --http-port → profile import --default
  → start → check → wrapped HTTPS request → stop
  → reinstall → uninstall (verify preservation)
  → reinstall (verify restoration) → purge
```

It also verifies pinned-binary installation, rejects an unauthenticated proxy
request, verifies tracking after session runtime storage disappears, checks
process/listener/active-state cleanup, and confirms the
original input was untouched. Command output stays in a private temporary
directory and is removed after the run. If safe stop cannot be verified, the
script retains that directory and reports its path for local recovery.

Report the pass/fail step names and exit status. Do not post configurations,
credentials, proxy environment values or private logs. A foreground Codex or
Claude prompt is an optional manual check, not a release requirement.

## Release assets

Create assets from the reviewed commit, not the working directory. Version
`0.1.0` must match the installer and CLI library. The bundle includes just the
three runtime source files; user documentation remains in the repository.

```bash
release_dir=$(mktemp -d)
git archive --format=tar.gz --prefix=proxycode-0.1.0/ \
  -o "$release_dir/proxycode-0.1.0.tar.gz" HEAD \
  install.sh bin/proxycode lib/proxycode.sh
git show HEAD:install.sh > "$release_dir/install.sh"
(cd "$release_dir" && sha256sum proxycode-0.1.0.tar.gz > proxycode-0.1.0.tar.gz.sha256)
```

Publish `install.sh`, `proxycode-0.1.0.tar.gz` and its `.sha256` as a GitHub
prerelease attached to that commit. Verify the downloaded assets and run the
walkthrough against their fixed URLs. Promote only after both hosted architecture
checks and the real-tunnel walkthrough pass. Record the commit, hosted run links
and smoke result in the release issue; do not claim readiness from fake tests.

Before committing or publishing, inspect `git ls-files` and the staged diff for
private networking material, generated configurations, logs, runtime state,
downloaded binaries and host-specific drafts. WireProxy's ISC notice is installed
with its binary; do not add a ProxyCode license as part of this release.
