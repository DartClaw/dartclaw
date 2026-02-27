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
| **CommandGuard** | command | Shell injection, dangerous commands (rm -rf, curl to untrusted hosts) |
| **FileGuard** | filesystem | Access to `.ssh/`, `.aws/`, credentials files, symlink escape |
| **NetworkGuard** | network | Connections to non-allowlisted hosts/ports |
| **ContentGuard** | content | Prompt injection, harmful content at agent boundaries |
| **ToolPolicyGuard** | policy | Tools not in agent's sandbox allowlist |

### Configuration

```yaml
guards:
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
    model: claude-haiku-4-5-20251001
```

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

In container mode, API keys are never exposed to the agent process. The Dart host runs a credential proxy on a Unix socket that injects the `ANTHROPIC_API_KEY` header into outbound API requests.

## Audit Logging

All guard evaluations are logged with timestamps, verdicts, and context. Post-tool-use events log success/failure for audit trail.
