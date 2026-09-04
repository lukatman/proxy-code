# Coding-agent CLI proxy compatibility contract

Research date: 2026-08-19

## Question

What proxy contract can Linux v1 rely on for current Codex CLI and Claude Code releases: recognized uppercase/lowercase proxy variables, HTTP CONNECT and SOCKS behavior, authenticated proxy URLs, `NO_PROXY`, child-process inheritance, argument and exit-status preservation, and material limitations?

Codex GUI remote behavior is out of scope.

## Versions examined

- [Codex CLI 0.148.0](https://github.com/openai/codex/releases/tag/rust-v0.148.0), released 2026-08-18. Source references below are pinned to the release commit `3ba0f711642a888aec92a611a3f3b2211157ff89`.
- [Claude Code 2.1.235](https://github.com/anthropics/claude-code/releases/tag/v2.1.235), released 2026-08-18. Claude Code's implementation is not published in full, so its official documentation is the authoritative source for its supported contract.

## Decision

Linux v1 should target the common denominator: an authenticated, loopback-bound **HTTP forward proxy** supplied through all uppercase and lowercase standard proxy variables. It should not depend on direct SOCKS support from either coding agent.

For the selected Profile, launch the command with these six variables set to the same URL:

```text
HTTP_PROXY=http://USER:PASSWORD@127.0.0.1:PORT
http_proxy=http://USER:PASSWORD@127.0.0.1:PORT
HTTPS_PROXY=http://USER:PASSWORD@127.0.0.1:PORT
https_proxy=http://USER:PASSWORD@127.0.0.1:PORT
ALL_PROXY=http://USER:PASSWORD@127.0.0.1:PORT
all_proxy=http://USER:PASSWORD@127.0.0.1:PORT
```

Set both `NO_PROXY` and `no_proxy` to the same comma-separated local bypass list. A safe default is:

```text
localhost,127.0.0.1,::1
```

Do not carry the caller's proxy variables or bypass list through unchanged: the two clients use different case precedence, and a pre-existing `NO_PROXY=*` or provider hostname would silently bypass the selected tunnel. Userinfo must be URL-safe. Prefer generated credentials drawn only from the unreserved URL character set; the shared URL builder must percent-encode arbitrary user-supplied credentials.

`ALL_PROXY` is included for Codex and for descendant tools, not because Claude Code documents it. The contract remains valid if Claude ignores it because the four HTTP(S) variables carry the same URL.

## Compatibility matrix

| Capability | Codex CLI 0.148.0 | Claude Code 2.1.235 | Linux v1 contract |
| --- | --- | --- | --- |
| `HTTP_PROXY` / `http_proxy` | Both; uppercase wins when both are set | Both; documented selection order is `https_proxy`, `HTTPS_PROXY`, `http_proxy`, `HTTP_PROXY` | Set both cases identically |
| `HTTPS_PROXY` / `https_proxy` | Both; uppercase wins when both are set | Both; lowercase HTTPS wins first | Set both cases identically to the HTTP listener URL |
| `ALL_PROXY` / `all_proxy` | Both; fallback after a scheme-specific variable | Not documented | Set both as a compatibility aid, but never rely on them for Claude |
| `NO_PROXY` / `no_proxy` | Both; uppercase wins | Both; documented comma- or space-separated entries and `*` | Set both identically; use comma-separated entries only |
| HTTP proxy for HTTPS / WSS | Supported; HTTPS uses the HTTP client proxy and secure WebSockets are explicitly CONNECT-tunneled | HTTP/HTTPS proxy is documented; CONNECT for TLS destinations follows from using a conventional HTTP forward proxy | Required transport; WireProxy must accept authenticated CONNECT |
| Authenticated proxy URL | Supported by the HTTP and WebSocket dependencies, including percent-decoded userinfo | Basic auth in `http://username:password@host:port` is documented | Required; generate URL-safe credentials and avoid displaying the URL |
| Direct SOCKS | Split/unsafe: Codex's WebSocket dependency supports SOCKS, but its release HTTP dependency is built without the required `socks` feature | Explicitly unsupported | Do not expose SOCKS URLs to either CLI |

## Evidence and implications

### Codex

Codex resolves HTTPS through `HTTPS_PROXY`, then `ALL_PROXY`; secure WebSockets through `HTTPS_PROXY`, `HTTP_PROXY`, then `ALL_PROXY`; and HTTP through `HTTP_PROXY`, then `ALL_PROXY`. It reads `NO_PROXY` with the selected proxy. Its helper checks uppercase first and the lowercase spelling second, ignoring empty values. See the pinned [route selection and environment lookup](https://github.com/openai/codex/blob/3ba0f711642a888aec92a611a3f3b2211157ff89/codex-rs/http-client/src/outbound_proxy.rs#L332-L353) and [case precedence](https://github.com/openai/codex/blob/3ba0f711642a888aec92a611a3f3b2211157ff89/codex-rs/http-client/src/outbound_proxy.rs#L840-L852).

The resolved URL is passed to `reqwest::Proxy::all`, with the bypass list attached through `reqwest::NoProxy`. Invalid proxy configuration fails client construction rather than silently trying another route. See [Codex's proxy client construction](https://github.com/openai/codex/blob/3ba0f711642a888aec92a611a3f3b2211157ff89/codex-rs/http-client/src/outbound_proxy.rs#L448-L476).

Codex's secure WebSocket dialer connects to an HTTP proxy and calls `connect_via_proxy` before the TLS/WebSocket handshake. The release includes tests specifically named for HTTP and HTTPS proxy tunneling of a secure WebSocket. See the [WebSocket dialer](https://github.com/openai/codex/blob/3ba0f711642a888aec92a611a3f3b2211157ff89/codex-rs/websocket-client/src/dialer.rs#L36-L129) and [CONNECT tunnel tests](https://github.com/openai/codex/blob/3ba0f711642a888aec92a611a3f3b2211157ff89/codex-rs/websocket-client/src/dialer_tests.rs#L205-L233).

Authenticated WebSocket CONNECT is supported by Codex's pinned first-party fork: it parses username/password userinfo, percent-decodes it, and emits `Proxy-Authorization: Basic ...` on CONNECT. See the pinned [proxy parser and HTTP CONNECT builder](https://github.com/openai-oss-forks/tungstenite-rs/blob/4fffad30fe373adbdcffab9545e9e9bf4f2fc19f/src/proxy.rs#L1817-L1900) and [authenticated CONNECT implementation](https://github.com/openai-oss-forks/tungstenite-rs/blob/4fffad30fe373adbdcffab9545e9e9bf4f2fc19f/src/proxy.rs#L1998-L2138). Codex's HTTP dependency likewise supports URL userinfo and Basic proxy auth through reqwest's proxy URL parser; see [reqwest 0.12.28 proxy parsing](https://github.com/seanmonstar/reqwest/blob/v0.12.28/src/proxy.rs#L3348-L3421).

Direct SOCKS must not be part of the common contract. Although Codex's WebSocket dependency recognizes SOCKS, Codex declares reqwest with only the `cookies` feature in the [0.148.0 workspace manifest](https://github.com/openai/codex/blob/3ba0f711642a888aec92a611a3f3b2211157ff89/codex-rs/Cargo.toml#L396-L400), while reqwest states that SOCKS requires its optional `socks` feature in the [pinned dependency source](https://github.com/seanmonstar/reqwest/blob/v0.12.28/src/proxy.rs#L2154-L2183). A SOCKS URL could therefore work for one transport and fail for another.

For `NO_PROXY`, Codex's HTTP dependency expects comma-separated entries, supports IPv4/IPv6 and CIDR entries, treats a leading-dot domain the same as its bare form, and supports only `*` as a wildcard. See [reqwest's pinned `NoProxy` rules](https://github.com/seanmonstar/reqwest/blob/v0.12.28/src/proxy.rs#L2933-L3000). Codex's WebSocket dependency also uses comma-separated entries and supports `*`, host suffixes, and optional ports in its [pinned bypass implementation](https://github.com/openai-oss-forks/tungstenite-rs/blob/4fffad30fe373adbdcffab9545e9e9bf4f2fc19f/src/proxy.rs#L1690-L1768). Comma separation is therefore the conservative Codex format.

### Claude Code

Claude Code's official [enterprise network configuration](https://code.claude.com/docs/en/corporate-proxy) says that it reads proxy variables once at startup, accepts `HTTPS_PROXY`, `HTTP_PROXY`, and `NO_PROXY`, accepts lowercase variants, and selects the first set value in this order: `https_proxy`, `HTTPS_PROXY`, `http_proxy`, `HTTP_PROXY`. It accepts comma- or space-separated `NO_PROXY` values and `*`, explicitly does not support SOCKS, and documents Basic proxy authentication in the URL.

Because Claude Code chooses lowercase HTTPS before uppercase values while Codex chooses uppercase before lowercase, a wrapper that sets only one case or preserves conflicting caller values is not deterministic across both products. Setting every spelling to one URL removes this difference.

The same Claude documentation says malformed proxy URLs stop launch and identifies `/status` as a way to inspect the active proxy. The wrapper should validate its generated URL before exec and must avoid printing credentials in diagnostics. Do not assume every upstream error means a tunnel failure: TLS inspection, custom CA configuration, streaming idle timeouts, and provider-specific endpoints remain separate concerns documented on that page.

### Child processes and long-lived helpers

An environment wrapper controls the CLI process it executes. Its reach into processes the CLI later creates is product-specific:

- Codex shell commands inherit the launch environment by default: the release's shell environment policy defaults to `inherit = All`, and its environment constructor begins from all process variables. Users can override that policy and filter the proxy variables. See [the default policy](https://github.com/openai/codex/blob/3ba0f711642a888aec92a611a3f3b2211157ff89/codex-rs/protocol/src/config_types.rs#L218-L253) and [environment construction](https://github.com/openai/codex/blob/3ba0f711642a888aec92a611a3f3b2211157ff89/codex-rs/protocol/src/shell_environment.rs#L49-L114).
- Codex local stdio MCP servers are different: their launcher clears the environment and rebuilds it from a small allowlist plus explicitly configured variables. The default allowlist does not contain proxy variables. See [the MCP environment builder](https://github.com/openai/codex/blob/3ba0f711642a888aec92a611a3f3b2211157ff89/codex-rs/rmcp-client/src/utils.rs#L16-L58) and its [default allowlist](https://github.com/openai/codex/blob/3ba0f711642a888aec92a611a3f3b2211157ff89/codex-rs/rmcp-client/src/utils.rs#L163-L175). Linux v1 must not promise transparent proxying of Codex MCP subprocesses; users must opt those variables into MCP configuration if needed.
- Claude foreground Bash/tool children normally receive the launch environment, although its documented `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB` mode can filter sensitive provider credentials. Shell-local exports made by one Bash tool call do not persist to the next; launch-time proxy values do not depend on such exports. See Claude's official [environment-variable reference](https://code.claude.com/docs/en/env-vars) and [Bash tool behavior](https://code.claude.com/docs/en/tools-reference).
- Claude background agents are a hard limitation for a per-command Profile wrapper. Its per-user supervisor is shared across terminals, starts on demand, outlives the shell, and keeps the environment of whichever shell started it first; an installed supervisor may receive no shell environment. Anthropic says settings are the only configuration that reliably reaches all background sessions. See [Apply network settings to background agents](https://code.claude.com/docs/en/corporate-proxy#apply-network-settings-to-background-agents).

The last point means foreground `with-wireproxy --profile NAME claude ...` is supportable, but the same guarantee cannot be made for `claude agents`, `--bg`, or `/background`. An already-running supervisor can use no proxy or a different Profile, and a single shared supervisor cannot simultaneously inherit two per-invocation Profiles. Linux v1 needs an explicit product decision: declare Claude background sessions unsupported, or add a separately designed global/supervisor integration with documented Profile-switch semantics. Stopping the supervisor before a Profile change can avoid stale state but cannot provide simultaneous background Profiles.

Claude's self-spawn launcher documentation reinforces the required wrapper behavior: launchers must pass inherited variables, preserve argument order, avoid absorbing arguments, and finish with `exec "$@"`. It also explains that Claude self-spawns use the binary's direct path rather than a `claude` wrapper found on `PATH`. See [the official launcher contract](https://code.claude.com/docs/en/corporate-launcher#the-launcher-contract). The proxy variables themselves normally continue through self-spawns because they are inherited; a PATH wrapper alone is not re-entered.

## Wrapper process contract

`with-wireproxy` should treat everything after its own options (or after `--`) as an argv vector, never as a command string. Once preflight and proxy startup succeed, it should:

1. Export the eight values described above: uppercase and lowercase HTTP, HTTPS, ALL, and NO proxy variables.
2. Leave stdin, stdout, stderr, current working directory, terminal membership, and unrelated environment variables unchanged.
3. Run `exec "$@"` without `eval`, reparsing, or an intermediate `sh -c`.

This preserves empty arguments, whitespace, wildcard characters, option boundaries, the command's eventual exit status, and normal signal/terminal behavior. A wrapper preflight failure uses the wrapper's own nonzero status; after `exec`, the observed status is the command's status. These requirements match Anthropic's published launcher contract and are suitable for Codex as an ordinary Unix CLI.

## Material limitations to carry into the specification

- The supported unit is a foreground Linux CLI process and the descendants that actually inherit its environment, not all activity associated with a vendor account or desktop application.
- Claude background sessions cannot be safely assigned concurrent per-command Profiles through environment wrapping alone.
- Codex stdio MCP servers do not receive proxy variables by default. User CLI configuration can also restrict Codex shell environment inheritance.
- Direct SOCKS is not portable across the two CLIs. Use WireProxy's HTTP listener even if its SOCKS listener remains available for other applications.
- Basic proxy credentials are present in the CLI environment and may be inherited by tools. Treat the URL as a secret: do not include it in normal output or logs, redact userinfo in errors, and keep credentials Profile-scoped. Local Basic auth protects against casual use of the listener; it is not a boundary against the same Unix account or root.
- `NO_PROXY` deliberately creates direct-routing exceptions. Keep the default local-only, validate additions, and warn that `*` or provider domains defeat the selected Profile for matching traffic.
- Vendor releases can change transport behavior independently of this toolkit. Maintain integration tests against current stable Codex and Claude Code releases instead of treating undocumented implementation details as permanent API guarantees.

## Required compatibility tests

Before declaring Linux v1 compatible, exercise both current stable CLIs against an authenticated test HTTP proxy with direct egress blocked or independently observed:

1. Foreground interactive and one-shot requests traverse the proxy.
2. HTTPS API traffic and Codex secure WebSocket traffic issue authenticated CONNECT and complete streaming responses.
3. Both uppercase-only and lowercase-only probes work, then the production wrapper sets both cases identically.
4. Comma-separated `NO_PROXY` bypasses a loopback HTTP target while a non-matching target uses the proxy; `NO_PROXY=*` is rejected or prominently warned about by toolkit configuration.
5. Credentials containing reserved characters are correctly percent-encoded, or generated credentials are restricted to URL-unreserved characters.
6. Arguments including spaces, empty strings, glob characters, and leading dashes arrive unchanged; exit codes such as 0, 7, and signal termination propagate unchanged.
7. Codex shell-tool inheritance, Codex stdio MCP non-inheritance, Claude foreground child inheritance, and Claude's already-running background-supervisor limitation match the documented behavior.

These tests should be version-labelled so a future CLI regression produces a precise compatibility warning rather than a false claim that the WireGuard tunnel itself is broken.
