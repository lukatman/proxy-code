# WireProxy distribution trust and runtime findings

Research date: 2026-08-19

## Question

What must the Linux v1 specification account for when it acquires and runs
WireProxy, and where do the trust boundaries lie for the preferred
`curl ... | bash` bootstrap and the local installer alternative?

## Decision

Linux v1 should use the current canonical upstream repository,
[`windtf/wireproxy`](https://github.com/windtf/wireproxy), and pin one reviewed
WireProxy release in proxy-code source. The installer must select only an
explicitly supported OS/architecture asset and verify it against a SHA-256 value
stored in the same reviewed proxy-code version. It must not resolve `latest` at
install time or treat an adjacent upstream checksum file as an independent trust
root.

The initial pin can be WireProxy `v1.1.3`, resolved to commit
[`31a9a34498267d7fb8aeff05aba79d929b15eb39`](https://github.com/windtf/wireproxy/commit/31a9a34498267d7fb8aeff05aba79d929b15eb39):

| Linux platform | Upstream asset | Project-owned expected SHA-256 |
| --- | --- | --- |
| `x86_64` | `wireproxy_linux_amd64.tar.gz` | `e88c1d090740373fc606c1bafd81d9a5eadc642cce5667616e20e9d7a444f51c` |
| `aarch64` / `arm64` | `wireproxy_linux_arm64.tar.gz` | `370e00bd2167960d1ecd1c3c1439715bbaa94a0a110a2040468670c9af6021b6` |

These values appear in both the [v1.1.3 release](https://github.com/windtf/wireproxy/releases/tag/v1.1.3)
and its [upstream checksum asset](https://github.com/windtf/wireproxy/releases/download/v1.1.3/checksums.txt).
They are recorded here so a later release update is an explicit reviewed change,
not a decision made by a live installer.

Offer both proxy-code entry paths:

- The documented convenience path may remain a versioned `curl ... | bash`
  command, with its unavoidable pre-execution trust boundary stated plainly.
- The higher-assurance and offline-capable path downloads or checks out a fixed
  proxy-code release, lets the user inspect/verify it, and then runs its local
  installer.

Both paths converge after bootstrap: the selected proxy-code version verifies
every subsequently downloaded WireProxy archive before extraction or execution.

## Distribution and provenance findings

### What upstream provides

The v1.1.3 release supplies Linux `amd64` and `arm64` tarballs, among other
platforms, plus `checksums.txt`. GitHub's [release API response](https://api.github.com/repos/windtf/wireproxy/releases/tags/v1.1.3)
also exposes a server-computed `sha256:` digest for each asset. The upstream
[GoReleaser configuration](https://github.com/windtf/wireproxy/blob/v1.1.3/.github/wireproxy-releaser.yml)
builds with `CGO_ENABLED=0`, names archives `wireproxy_<os>_<arch>`, and generates
`checksums.txt`.

The published evidence is useful for integrity checks, but it is not a complete
independent provenance chain:

- The v1.1.3 release API marks the release `immutable: false`. GitHub explains
  that only [immutable releases](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases)
  lock both the tag and release assets and automatically receive a release
  attestation.
- The release has no signature or attestation asset. Its checksum manifest is
  downloaded from the same mutable release as the archives, so fetching both at
  installation time would detect accidental corruption but would not prevent an
  actor able to replace both upstream assets from supplying a matching malicious
  pair. GitHub's [attestation API](https://api.github.com/repos/windtf/wireproxy/attestations/sha256:e88c1d090740373fc606c1bafd81d9a5eadc642cce5667616e20e9d7a444f51c)
  returned no attestation for the amd64 archive; GitHub documents the verification
  model in its [attestation API reference](https://docs.github.com/en/rest/repos/attestations).
- GitHub's asset `digest` field is a valuable second observation from the hosting
  platform ([REST API documentation](https://docs.github.com/en/rest/releases/assets)),
  but dynamically fetching it still trusts the same GitHub repository/release
  control plane.
- The upstream [release workflow](https://github.com/windtf/wireproxy/blob/v1.1.3/.github/workflows/wireproxy.yml)
  invokes actions and GoReleaser through movable major or `latest` references and
  clones the repository's then-current default branch into the release work
  directory. The artifacts therefore are not reproducibly linked by that
  workflow to the already checked-out tag. The v1.1.3 tag points at a
  GitHub-verified commit, but no published cryptographic statement links each
  binary archive to that source commit. The observed [v1.1.3 workflow run](https://github.com/windtf/wireproxy/actions/runs/29468291481)
  did record the expected commit and a clean GoReleaser state; this is useful
  audit evidence, but not a cryptographically verifiable artifact provenance
  statement.

Consequently, proxy-code should treat the reviewed hash embedded in its own
version as the acceptance rule. Upstream `checksums.txt` and GitHub's API digest
may be checked as diagnostics during a deliberate dependency update, but neither
may replace the embedded hash at install time.

### Required acquisition algorithm

For an automatic WireProxy install, the specification should require this order:

1. Normalize `uname -s` and `uname -m`; accept Linux `x86_64` and
   `aarch64`/`arm64` only, mapping them to the two exact asset names above. Reject
   anything else before downloading.
2. Construct a versioned URL under
   `https://github.com/windtf/wireproxy/releases/download/v1.1.3/`; never use a
   `latest` download URL.
3. Download to a newly created private temporary directory. Do not stream an
   archive into `tar`, and do not write it over the live binary.
4. Calculate SHA-256 locally and compare it to the constant shipped by
   proxy-code. On mismatch, delete/quarantine the temporary payload, report the
   expected and actual digest without executing it, and preserve the installed
   version.
5. Inspect/extract only the expected `wireproxy` member, rejecting absolute
   paths, traversal, unexpected file types, or extra executable payloads.
6. Verify the extracted program reports the pinned version, run its config test
   against the generated profile, and only then atomically install it. A version
   string is a compatibility check, not an integrity substitute.
7. Record the installed version and digest so `status` can detect drift without
   silently repairing it.

A user-supplied local binary is a separate trust mode: the user owns its
provenance. proxy-code should not claim it is verified merely because it runs or
prints a plausible version. It should record its digest and version, check that
it is a regular executable file rather than following an unexpected symlink, run
the same compatibility/config validation, and make clear that automatic upstream
hash verification was bypassed.

## Bootstrap trust boundaries

`curl ... | bash` gives the downloaded program text to Bash before the user can
inspect or independently hash it. No logic inside that program can retroactively
authenticate the code that has already begun executing. Its initial trust root is
therefore the URL named in the documentation plus DNS, TLS, GitHub, and control of
the proxy-code repository/release. curl's official [option documentation](https://curl.se/docs/manpage.html)
supports restricting protocols, requiring TLS 1.2 or newer, following redirects,
and failing on HTTP errors, but those transport controls do not provide publisher
authentication beyond the HTTPS endpoint. Streaming execution can also execute a
valid prefix before a late transfer failure is observed.

The preferred convenience command should therefore:

- name a particular proxy-code release/bootstrap, not a mutable branch such as
  `main` and not a `latest` URL;
- use HTTPS-only initial and redirect protocols, TLS 1.2 or newer, fail-on-error,
  and show errors (for example, `--proto '=https' --proto-redir '=https'
  --tlsv1.2 -fsSL`);
- be described honestly as trusting GitHub delivery and project repository
  control for the bootstrap itself;
- keep the bootstrap small and make it download a fixed toolkit payload whose
  digest or release attestation it verifies before execution; and
- read interactive answers from `/dev/tty`, because the shell's standard input
  is occupied by the piped script. In a non-interactive environment it must
  require complete flags or fail, rather than consume script bytes or guess.

proxy-code should enable immutable GitHub releases for its own published
versions. That locks the release tag and assets and supplies the GitHub release
attestation described in the official documentation. This improves the fixed
bootstrap and toolkit-payload chain, though the one-line bootstrap still begins
with trust in GitHub delivery.

The documented local alternative is the higher-assurance path: download a fixed
release to disk (or check out its exact commit), verify it using a digest or
attestation obtained through the documented trust channel, optionally inspect
it, and invoke `./install.sh`. It must perform the same pinned WireProxy checks as
the convenience bootstrap. Avoid presenting a mutable shallow clone of `main` as
equivalent to a verified release.

## Runtime facts the specification must preserve

### Configuration validation

WireProxy v1.1.3 exposes `--configtest` / `-n`. The
[CLI source](https://github.com/windtf/wireproxy/blob/v1.1.3/cmd/wireproxy/main.go#L210-L251)
parses the configuration and returns after printing `Config OK`, before starting
the WireGuard device or listeners. Its
[configuration parser](https://github.com/windtf/wireproxy/blob/v1.1.3/config.go#L535-L631)
can load a referenced `WGConfig`, requires exactly one `[Interface]` and at least
one `[Peer]`, validates key encodings and addresses, and resolves peer endpoint
hostnames while parsing.

The installer should run config-test on the exact generated configuration before
publishing it as active, but must not overstate what passed:

- it proves the file can be read and parsed by that WireProxy binary;
- it may require DNS/network access because endpoint hostnames are resolved;
- it does not prove that listener ports are free, the peer can handshake, the
  tunnel can reach a target, or the proxy accepts traffic; and
- some key parse errors include the rejected value in the error text
  ([parser source](https://github.com/windtf/wireproxy/blob/v1.1.3/config.go#L133-L155)),
  so validation stderr must never be copied into permissive logs or diagnostic
  bundles without redaction.

### HTTP and SOCKS authentication

Both listener types support username/password authentication, but their enabling
conditions differ in the exact source:

- SOCKS5 selects username/password authentication only when `Username` is
  non-empty; otherwise it explicitly installs a no-auth authenticator, even if a
  password was supplied.
- HTTP requires authentication when either field is non-empty and validates an
  HTTP Basic `Proxy-Authorization` value. Credential comparison is constant-time.

See the [listener routines](https://github.com/windtf/wireproxy/blob/v1.1.3/routine.go#L158-L209)
and [HTTP authentication implementation](https://github.com/windtf/wireproxy/blob/v1.1.3/http.go#L16-L51).
To make one profile safe and consistent across both listeners, proxy-code must
generate and persist a non-empty username and a strong non-empty password, set
both fields on both listeners, explicitly bind each listener to `127.0.0.1`, and
store the generated configuration with owner-only permissions. Generated values
should use a parser-safe alphabet without whitespace or a leading `$`, while
proxy URLs must still percent-encode credentials rather than concatenate them
raw.

This authentication prevents unauthenticated use by other local accounts that
can reach the loopback port; it is not a security boundary against root or
processes running as the profile owner. The protocols do not encrypt credentials
on their own, which is another reason never to expose these listeners beyond
loopback.

### Concurrent profiles and process ownership

The source shows per-process configuration and listeners and no global singleton
or shared runtime lock. Multiple instances are therefore possible, provided all
host bind addresses/ports are unique. This is an inference from the upstream
[configuration model](https://github.com/windtf/wireproxy/blob/v1.1.3/config.go#L17-L85)
and [startup loop](https://github.com/windtf/wireproxy/blob/v1.1.3/cmd/wireproxy/main.go#L282-L302),
not an explicit upstream concurrency guarantee.

Each profile must own distinct SOCKS, HTTP, and health-listener ports. The
installer must also account for an optional WireGuard `[Interface] ListenPort`;
reusing a fixed one can collide across instances. A successful config-test does
not reserve any port. A bind failure occurs only in the spawned listener and is
fatal, so startup must wait for and verify the child rather than treating a
successful fork as readiness.

Do not use WireProxy's `--daemon` mode as the toolkit's process manager. The
[daemon implementation](https://github.com/windtf/wireproxy/blob/v1.1.3/cmd/wireproxy/main.go#L203-L269)
starts a child, returns without a PID/state contract, and redirects the child's
standard output and error to `/dev/null`. proxy-code should start WireProxy in the
foreground as its managed child, record PID plus executable identity/start time,
keep per-profile private logs, and validate identity before status or stop
operations.

### Readiness and health

`--info <address:port>` starts an unauthenticated HTTP information listener. Its
[`/readyz` implementation](https://github.com/windtf/wireproxy/blob/v1.1.3/routine.go#L351-L403)
returns `503` when any configured `CheckAlive` address has not replied within
`CheckAliveInterval + 2 seconds`; `/metrics` exposes WireGuard device data while
redacting private and preshared keys. The
[README's health contract](https://github.com/windtf/wireproxy/blob/v1.1.3/README.md#health-endpoint)
also states that `/readyz` returns an empty JSON object with `200` when no
`CheckAlive` target is configured.

Therefore:

- bind the information listener explicitly to a profile-specific loopback port;
  it has no authentication and exposes operational metadata;
- never interpret an empty `200 {}` as tunnel readiness;
- if using upstream readiness, require at least one profile-specific
  `CheckAlive` IP and wait until the response is `200` with a non-empty record;
- treat ICMP readiness as one signal, because otherwise healthy destinations may
  reject ping; and
- make the authoritative provider-neutral health test a small HTTP request sent
  through the authenticated proxy to the profile's configured check URL, with
  expected status/body rules. Mullvad can be a recommended preset, not a runtime
  dependency.

`status` should distinguish at least: stopped, stale/unowned PID, process alive
but listeners not accepting, WireProxy readiness pending/failing, and end-to-end
proxy health passing. That preserves useful failure information instead of
collapsing every state into “running.”

## Licensing

WireProxy v1.1.3 is licensed under the
[ISC license](https://github.com/windtf/wireproxy/blob/v1.1.3/LICENSE), which
requires its copyright and permission notice to appear in all copies. The
GoReleaser archive configuration adds no ancillary files beyond the built
program. If proxy-code installs, caches, mirrors, or packages WireProxy, it should
install or distribute the upstream ISC notice alongside it and identify the
pinned version in third-party notices. This does not decide proxy-code's own
license; that remains a separate deferred project decision.

## Update rule

A WireProxy upgrade is a reviewed dependency change. The maintainer should inspect
the exact new tag/commit, release workflow and assets; verify the two downloaded
archives against both the upstream manifest and GitHub asset digests; test the
binary/config/runtime contract; then change the version, asset names, and embedded
hashes together. Existing installations must never silently follow upstream
`latest`.
