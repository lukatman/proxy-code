# Repository guidance

## Project intent

Build a public, provider-neutral toolkit that makes a user-space WireGuard proxy easy to install and manage for coding-agent CLIs such as Codex and Claude Code.

Users provide a WireGuard configuration, run an interactive installer, and choose their preferences. The toolkit should support multiple named profiles and scoped commands such as:

```bash
with-wireproxy codex
with-wireproxy claude
```

Linux is the initial target. Future scope includes macOS support and remote connections initiated from the Codex GUI.

Keep shared paths, proxy settings, health checks, process validation, log handling, and wrapper behavior in common configuration or code.

Treat user networking material as private. Keep WireGuard configurations, generated proxy configurations, credentials, logs, runtime files, and live binaries out of version control. Download WireProxy as a pinned, checksum-verified release during installation.

## Working priorities

Keep responses, plans, issues, and project documentation concise. Treat this as a small personal Linux project intended for public release. Prioritize a correct end-to-end implementation. Avoid speculative architecture, process ceremony, exhaustive policy, and security mechanisms for threats outside the project's stated boundary. Retain simple safeguards against data loss, secret exposure, unsafe command execution, unverified downloads, and signaling the wrong process. Ask before substantially expanding scope or adding a complex mechanism. However if going bigger and bolder would actually result in a better implementation based on what we want in the end, then do not shy away from proposing such ideas.

## Agent skills

### Issue tracker

Issues and specs are tracked in GitHub Issues. See `docs/agents/issue-tracker.md`.

### Triage labels

Use the five default triage labels. See `docs/agents/triage-labels.md`.

### Domain docs

Use the single-context domain documentation layout. See `docs/agents/domain.md`.

### Coding standards

Refer to `docs/agents/CODING_STANDARDS.md` for the coding standards and your role in this project.
