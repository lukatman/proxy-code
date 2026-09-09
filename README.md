# ProxyCode

Run a command through a WireGuard tunnel without changing your system's network
settings. ProxyCode installs [WireProxy](https://github.com/windtf/wireproxy),
manages named tunnel profiles, and gives commands such as Codex and Claude Code
an authenticated local HTTP proxy.

## Install

You need a WireGuard configuration from your provider or your own server.
Replace the configuration path below with yours. Run as your normal user, without
`sudo`:

```bash
setup_dir=$(mktemp -d)
curl --proto '=https' --tlsv1.2 -fL \
  https://github.com/lukatman/proxycode/releases/download/v0.1.0/install.sh \
  -o "$setup_dir/install.sh"
bash "$setup_dir/install.sh" \
  --wg-config "$HOME/Downloads/tunnel.conf" --name work --default
export PATH="$HOME/.local/bin:$PATH"
proxycode start
proxycode codex
```

The installer downloads a fixed ProxyCode bundle and verifies its release
checksum, then downloads WireProxy **1.1.3** and checks the SHA-256 pinned in the
installer. It copies your configuration into private storage. The flag-based
installation does not start the tunnel; `start` does that and checks HTTPS egress.

Keep the downloaded installer for the maintenance examples below. When finished,
remove it with `rm -rf -- "$setup_dir"`. Add `~/.local/bin` to your shell's PATH if
it is not already there; the installer does not edit shell configuration.

### Requirements

- Linux x86-64 or ARM64, Bash 4.4 or newer, readable `/proc`, and writable user/XDG
  directories. CI runs on Ubuntu 24.04 for both architectures.
- `curl` with HTTPS support and CA certificates, `flock` from util-linux, `tar`,
  GNU coreutils, `awk`, `grep`, and `sed`. Missing commands are reported by the
  installer; install them with your distribution's package manager.
- Loopback networking, access to GitHub over HTTPS, and outbound connectivity to
  your WireGuard endpoint and health-check URL.

There is no system VPN interface, service or automatic startup. macOS, Windows,
WSL and containers are not supported targets.

### Other installation options

For interactive setup, run the downloaded installer without arguments:

```bash
bash "$setup_dir/install.sh"
```

It asks for your configuration, profile name and preferences, then shows a review
before installation. To install first and import a profile later:

```bash
bash "$setup_dir/install.sh" --install-only
proxycode profile import "$HOME/Downloads/tunnel.conf" --name work --default
```

For a versioned piped installation:

```bash
curl --proto '=https' --tlsv1.2 -fL \
  https://github.com/lukatman/proxycode/releases/download/v0.1.0/install.sh |
  bash -s -- --wg-config "$HOME/Downloads/tunnel.conf" --name work --default
```

To inspect the full fixed release before running it, download and unpack it in a
new directory:

```bash
mkdir proxycode-inspect && cd proxycode-inspect
release=https://github.com/lukatman/proxycode/releases/download/v0.1.0
curl --proto '=https' --tlsv1.2 -fLO "$release/proxycode-0.1.0.tar.gz"
curl --proto '=https' --tlsv1.2 -fLO "$release/proxycode-0.1.0.tar.gz.sha256"
sha256sum -c proxycode-0.1.0.tar.gz.sha256 && tar -xzf proxycode-0.1.0.tar.gz
cd proxycode-0.1.0
less install.sh bin/proxycode lib/proxycode.sh
bash install.sh --wg-config "$HOME/Downloads/tunnel.conf" --name work --default
```

An optional `--wireproxy-bin /absolute/path/to/wireproxy` installs a binary you
provide. It checks compatibility, but does not verify that binary against the
pinned release checksum.

## Use

```bash
proxycode                    # Open the management menu
proxycode profile list
proxycode profile show work
proxycode start work
proxycode status             # Local process state; no network request
proxycode check              # HTTPS request through the active tunnel
proxycode codex
proxycode claude
proxycode --profile work curl https://example.com
proxycode stop
```

The **default profile** is the one selected by `start` or a wrapped command when
you omit a name. The **active profile** is the one currently running. Only one
profile can be active at a time.

```text
proxycode codex
  → select the default profile
  → start and check its tunnel if it is not running
  → launch Codex with local HTTP proxy variables
```

A wrapped command leaves the tunnel running when it exits. Reusing an active
tunnel does not repeat the startup check; use `proxycode check` to check it again.
If another profile is active, wrapping refuses to switch it silently.

```bash
proxycode profile import "$HOME/Downloads/travel.conf" --name travel
proxycode profile default travel
proxycode switch travel
proxycode profile remove work
```

Changing the default does not switch the active tunnel. Switching can interrupt
running commands. If the new tunnel fails its startup check, the old one is not
automatically restarted. Replacement (`profile import ... --replace`), switching
and removal ask for confirmation when needed; use `--yes` for automation.
Replacing or removing the active profile stops its tunnel. Replacement does not
restart it.

### Settings and health checks

The listener defaults to `127.0.0.1:25345`. Stop the tunnel before changing its port:

```bash
proxycode stop
proxycode settings --http-port 25346
proxycode profile settings work --probe cloudflare --expect-location US
```

Cloudflare is the default probe; without an expected country it checks egress
without requiring a location. Mullvad checks that the exit belongs to Mullvad.
A custom probe checks an HTTPS response's status and optional literal text:

```bash
proxycode profile settings work --probe mullvad --expect-location Sweden
proxycode profile settings work --probe custom \
  --url https://example.com/health --status 200 --contains ready
```

Run `proxycode help` for the full command syntax and `bash "$setup_dir/install.sh" --help` for
installer options.

### Coding-agent limitations

Wrapping sets uppercase and lowercase `HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY`
and `NO_PROXY` for the command and its descendants. Localhost bypasses the proxy.
The parent shell and other applications are unaffected.

Applications must honor those variables. This is not a network kill switch or a
guarantee that every subprocess uses the tunnel. In particular, Codex stdio MCP
servers and Claude background agents are not covered by the foreground CLI
contract. See the [retained upstream references](docs/research/README.md).

## Reinstall or remove

To repair an installation or install a newer version, stop the tunnel and rerun
that version's installer. Profiles, credentials and settings are preserved:

```bash
proxycode stop
bash "$setup_dir/install.sh" --install-only
```

If you use your own WireProxy binary, pass `--wireproxy-bin` again; otherwise the
installer installs its pinned binary. An older installer refuses to downgrade an
installation recorded as newer.

```bash
bash "$setup_dir/install.sh" --uninstall   # Keep profiles, credentials and settings
bash "$setup_dir/install.sh" --purge       # Remove all managed data
```

Both operations stop the managed tunnel safely and ask for confirmation. Add
`--yes` for unattended use. Neither deletes your original imported configuration.
After uninstall, rerunning `--install-only` makes the preserved profiles usable.

## Private files and troubleshooting

Default locations are below; `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_STATE_HOME`
and `XDG_RUNTIME_DIR` override the corresponding roots.

| Location | Contents |
| --- | --- |
| `~/.local/bin/proxycode` | Installed command |
| `~/.config/proxycode/` | Listener settings and default profile |
| `~/.local/share/proxycode/` | WireProxy, its ISC notice, library and private profiles |
| `~/.local/state/proxycode/` | Installation metadata and profile logs |
| `$XDG_RUNTIME_DIR/proxycode/` | Active process state; falls back to the state directory |

Managed directories and executables are owner-only (`0700`); private files are
`0600`. Do not publish profile files, proxy environment values or logs. Logs are
under `logs/NAME/wireproxy.log` in the state directory. A lifecycle command rotates
a log at 10 MiB, keeping one `.old` copy; this is not a continuous size limit.

| Problem | What to do |
| --- | --- |
| `proxycode` not found | Add `~/.local/bin` to PATH. |
| No default selected | Run `proxycode profile default NAME`, or supply a name. |
| Port already in use | Stop its owner or choose a free port with `proxycode settings`. |
| Startup health check fails | Check the source configuration, endpoint connectivity, probe and expected location. Inspect the private log, then retry `start`. |
| `check` fails | The tunnel remains running. Inspect the log and network, then stop/start if needed. |
| Process identity is ambiguous | Do not kill the recorded PID blindly. Verify which process owns the listener. Only after confirming no managed WireProxy remains, remove the `active` file at the path reported by `status` and retry. |
| Missing or damaged installed files | Rerun the fixed-version installer after stopping the tunnel. |

For contributor checks and the disposable release walkthrough, see
[Verification](docs/verification.md).
