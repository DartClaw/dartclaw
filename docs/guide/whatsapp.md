# WhatsApp Integration

DartClaw connects to WhatsApp via GOWA (Go WhatsApp), a sidecar binary that handles the WhatsApp Web protocol.

## Prerequisites

- GOWA binary installed and on PATH
- A WhatsApp account (phone number)
- Network access to WhatsApp servers

## Setup

### 1. Configure GOWA in `dartclaw.yaml`

```yaml
channels:
  whatsapp:
    enabled: true
    gowa_executable: gowa    # default
    gowa_port: 3080          # default
    dm_access: pairing       # pairing | allowlist | open | disabled
    group_access: mention    # mention | all | disabled
    mention_patterns:
      - '@DartClaw'
      - '@bot'
```

### 2. Start DartClaw and Pair

```bash
dartclaw serve
```

Open the pairing page at `http://localhost:3000/whatsapp/pairing`. Scan the QR code with your WhatsApp app, or use a pairing code.

### 3. DM Access Control

| Mode | Behavior |
|------|----------|
| `pairing` | New users must present a pairing code (generated in web UI). Up to 3 pending codes. |
| `allowlist` | Only pre-approved JIDs can DM the agent. |
| `open` | Anyone can DM the agent. |
| `disabled` | DMs ignored. |

### 4. Group Policies

In groups, the agent only responds when mentioned (default `mention` mode). Configure mention patterns in `dartclaw.yaml`. The agent also responds to replies to its own messages.

## Message Handling

- **Text chunking**: Long responses split at ~4000 chars with `(n/total)` prefixes
- **Media**: Agent can send images/files via `MEDIA:<path>` directives in responses
- **Response prefix**: Messages prefixed with model name and agent identity

## Ban Risk

WhatsApp may ban accounts that appear automated. Mitigations:
- Use a dedicated phone number
- Keep message volume reasonable
- Don't spam groups
- Monitor for ban warnings

**Recovery**: If banned, create a new WhatsApp account with a different number. Your workspace data and configuration are preserved.

## Troubleshooting

| Issue | Solution |
|-------|----------|
| GOWA won't start | Check `gowa --version`, verify port 3080 is free |
| QR code not loading | Check GOWA health: `curl http://localhost:3080/health` |
| Messages not delivered | Check DM access mode, verify pairing is complete |
| Agent not responding in groups | Verify mention patterns match your @mention format |
