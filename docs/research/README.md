# Stable research findings

Detailed product decisions live in GitHub issues. This note retains only the
external findings that still constrain Linux v1.

## Coding-agent proxy contract

- Launch Wrapped commands through an authenticated loopback HTTP proxy.
- Set uppercase and lowercase `HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY`, and
  `NO_PROXY` variants to deterministic values, then use direct `exec`.
- Use HTTP consistently because client transport support varies by component.
- Environment wrapping covers the foreground CLI and descendants that inherit
  its environment. It does not guarantee Codex stdio MCP or Claude background
  agent routing.

Sources: [Codex proxy implementation](https://github.com/openai/codex/blob/3ba0f711642a888aec92a611a3f3b2211157ff89/codex-rs/http-client/src/outbound_proxy.rs#L332-L353),
[Codex shell environment](https://github.com/openai/codex/blob/3ba0f711642a888aec92a611a3f3b2211157ff89/codex-rs/protocol/src/shell_environment.rs#L49-L114),
[Codex MCP environment](https://github.com/openai/codex/blob/3ba0f711642a888aec92a611a3f3b2211157ff89/codex-rs/rmcp-client/src/utils.rs#L16-L58),
[Claude Code proxy documentation](https://code.claude.com/docs/en/corporate-proxy),
[Claude Code launcher contract](https://code.claude.com/docs/en/corporate-launcher#the-launcher-contract).

## WireProxy distribution and runtime

- Pin a reviewed WireProxy version and project-owned SHA-256 values; never
  resolve `latest` during installation.
- Support only explicit OS/architecture asset mappings, download privately,
  verify before extraction, and reject unexpected archive members.
- Treat an adjacent upstream checksum file as corroboration, not an independent
  trust root. A user-supplied binary is user-controlled input.
- Bind the HTTP listener to loopback, validate imported configurations with
  `--configtest`, and use a proxied HTTPS request as the readiness authority.

Sources: [WireProxy v1.1.3 release](https://github.com/windtf/wireproxy/releases/tag/v1.1.3),
[release checksums](https://github.com/windtf/wireproxy/releases/download/v1.1.3/checksums.txt),
[release workflow](https://github.com/windtf/wireproxy/blob/v1.1.3/.github/workflows/wireproxy.yml),
[configuration parser](https://github.com/windtf/wireproxy/blob/v1.1.3/config.go#L535-L631),
[HTTP listener](https://github.com/windtf/wireproxy/blob/v1.1.3/http.go#L16-L51),
[ISC license](https://github.com/windtf/wireproxy/blob/v1.1.3/LICENSE).
