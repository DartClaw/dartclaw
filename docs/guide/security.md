# Security

DartClaw uses defense-in-depth: multiple independent layers so that no single compromise breaks all boundaries.

## Architecture

```
User ──→ HTTP Auth ──→ Dart Host ──→ Guards ──→ Container ──→ claude binary
                           │                        │
                     Guard Chain              network:none
                     Audit Logger            Credential Proxy
                     Content Guard          Mount Allowlist
```

## Guard System

Guards evaluate tool calls, messages, and agent responses. First block wins. Exceptions = block (fail-closed).

### Built-in Guards

| Guard | Category | What It Blocks |
|-------|----------|---------------|
| **InputSanitizer** | input | Prompt injection patterns (instruction override, role-play, prompt leak, meta-injection) |
| **CommandGuard** | command | Shell injection, dangerous commands (rm -rf, curl to untrusted hosts) |
| **FileGuard** | filesystem | Access to `.ssh/`, `.aws/`, credentials files, symlink escape |
| **NetworkGuard** | network | Connections to non-allowlisted hosts/ports |
| **ContentGuard** | content | Prompt injection, harmful content at agent boundaries |
| **ToolPolicyGuard** | policy | Tools not in agent's sandbox allowlist |

### Configuration

```yaml
guards:
  input_sanitizer:
    enabled: true               # default: true
    channels_only: true          # default: true — only scan channel messages, web UI bypasses
    extra_patterns:              # optional additional regex patterns (case-insensitive)
      - 'custom\s+injection'
  command:
    enabled: true
    blocked_commands: [rm, shutdown, reboot]
    blocked_patterns: ['curl.*--upload']
  filesystem:
    enabled: true
    blocked_paths: [.ssh, .aws, .gnupg]
  network:
    enabled: true
    allowed_hosts: [api.anthropic.com, github.com]
  content:
    enabled: true
    model: haiku
```

The **InputSanitizer** ships with built-in patterns for 4 injection categories and requires no configuration for baseline protection. Set `channels_only: false` to also scan web UI messages.

## Container Isolation

When Docker is available, DartClaw runs the claude binary inside a container with:
- `network:none` -- no direct internet access
- Capability drops (`--cap-drop ALL`)
- Read-only root filesystem
- Credential proxy (Unix socket) for API access
- Mount allowlist for workspace files

### Pragmatic Mode

Without Docker, guards serve as the primary security boundary. This is suitable for personal use on a trusted machine.

## HTTP Authentication

The web UI and API support token-based and cookie-based authentication:

```yaml
gateway:
  auth_mode: token    # token | none
  token: ${DARTCLAW_TOKEN}
```

## Credential Proxy

In container mode, API keys are never exposed to the agent process. The Dart host runs a `CredentialProxy` on a Unix socket that injects authentication headers into outbound API requests. The container's `network:none` means this proxy is the **sole egress path** — there is no way for agent code to reach the internet directly.

### How It Works

```
Container (network:none)                          Host
┌────────────────────────────┐             ┌───────────────────────┐
│                            │             │                       │
│  claude binary             │             │  CredentialProxy      │
│    ANTHROPIC_BASE_URL=     │             │    Unix socket:       │
│    http://localhost:8080   │             │    <data>/proxy/      │
│          │                 │             │    proxy.sock         │
│          ▼                 │             │    (chmod 600)        │
│  socat bridge              │  bind-mount │                       │
│    TCP-LISTEN:8080 ────────┼─────────────┼──► Injects headers:  │
│    → UNIX-CLIENT:          │             │      x-api-key        │
│      /var/run/dartclaw/    │             │      Authorization    │
│      proxy.sock            │             │          │            │
│                            │             │          ▼            │
└────────────────────────────┘             │  api.anthropic.com   │
                                           └───────────────────────┘
```

1. **Dart host** starts `CredentialProxy` on `<dataDir>/proxy/proxy.sock` with `chmod 600` (owner-only access). The API key is held in host memory only.
2. **Container** is created with `--network none`. The socket directory is bind-mounted into the container at `/var/run/dartclaw/`.
3. **socat** runs inside the container, bridging a local TCP port to the Unix socket: `TCP-LISTEN:8080 → UNIX-CLIENT:/var/run/dartclaw/proxy.sock`.
4. **`ANTHROPIC_BASE_URL`** environment variable points the `claude` binary at the socat listener (`http://localhost:8080`).
5. When the agent makes an API call, the request flows through the chain. The proxy injects `x-api-key` and `Authorization: Bearer` headers before forwarding to `api.anthropic.com` over HTTPS.

### Authentication Modes

| Mode | When | Behavior |
|------|------|----------|
| **API key** | `ANTHROPIC_API_KEY` is configured | Proxy injects `x-api-key` and `Authorization: Bearer <key>` headers |
| **OAuth passthrough** | No API key (OAuth or setup token) | Proxy forwards existing auth headers from the `claude` binary unchanged |

In OAuth mode, the host's `~/.claude.json` is mounted read-only into the container so the `claude` binary can authenticate directly. The proxy acts as a transparent relay without adding credentials.

### Security Properties

- **Key isolation** — API keys never exist inside the container (not in env vars, filesystem, or process memory)
- **Owner-only socket** — `chmod 600` prevents other host processes from connecting
- **Sole egress** — `network:none` means the Unix socket is the only way out of the container
- **Observability** — the proxy tracks request and error counts for health monitoring

## Audit Logging

All guard evaluations are logged with timestamps, verdicts, and context. Post-tool-use events log success/failure for audit trail.
