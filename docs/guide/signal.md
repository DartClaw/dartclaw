# Signal Integration

DartClaw connects to Signal via [signal-cli](https://github.com/AsamK/signal-cli), a command-line client for Signal that runs as a JSON-RPC daemon. DartClaw spawns signal-cli as a subprocess, receiving inbound messages via Server-Sent Events (SSE) and sending outbound messages via JSON-RPC.

## Prerequisites

- signal-cli installed and on PATH (or absolute path in config)
- A phone number for Signal registration, or an existing Signal account for device linking

## Installing signal-cli

**macOS (recommended):**

```bash
brew install signal-cli
```

This installs signal-cli and its Java dependency automatically.

**Linux:**

Download from [GitHub releases](https://github.com/AsamK/signal-cli/releases) (requires Java 21+):

```bash
wget https://github.com/AsamK/signal-cli/releases/download/v0.14.0/signal-cli-0.14.0-Linux.tar.gz
tar xf signal-cli-0.14.0-Linux.tar.gz
sudo mv signal-cli-0.14.0/bin/signal-cli /usr/local/bin/
```

Verify: `signal-cli --version`

## Setup

### 1. Configure Signal in `dartclaw.yaml`

```yaml
channels:
  signal:
    enabled: true
    phone_number: "+1234567890"    # E.164 format
    executable: signal-cli         # binary name or absolute path
    host: 127.0.0.1               # signal-cli daemon listen address
    port: 8080                    # signal-cli daemon listen port
    dm_access: open               # allowlist | open | disabled
    group_access: disabled        # allowlist | open | disabled
    require_mention: true         # groups: only respond when @mentioned
    mention_patterns:
      - '@DartClaw'
      - '@bot'
    dm_allowlist: []              # phone numbers (E.164) for allowlist mode
    group_allowlist: []           # signal group IDs (base64) for allowlist mode
    max_chunk_size: 4000
```

DartClaw starts signal-cli in daemon HTTP mode (`signal-cli daemon --http <host>:<port>`), communicating via JSON-RPC on `http://<host>:<port>/api/v1/rpc` and receiving events via SSE on `http://<host>:<port>/api/v1/events`.

### 2. Start DartClaw and Register

```bash
dartclaw serve
```

Open the pairing page at `http://localhost:<port>/signal/pairing`. Three registration options are available:

#### Option 1: Device Linking (Recommended)

Links DartClaw as a secondary device to your existing Signal account. Your phone remains the primary device.

1. The pairing page displays a `sgnl://linkdevice?uuid=...` URI
2. On your phone: Signal > Settings > Linked Devices > Link New Device
3. Enter the URI or scan the QR code (if rendered)
4. Refresh the pairing page to see "Signal Connected"

#### Option 2: SMS Registration

Registers the phone number as a new Signal identity. **Warning**: This takes over the phone number for Signal — the phone can no longer use that number for Signal.

1. Click "Send SMS Code" on the pairing page
2. Enter the verification code received via SMS
3. Click "Verify"

#### Option 3: Voice Registration

Same as SMS registration but delivers the verification code via voice call. Use this if SMS is not available for the phone number.

1. Click "Request Voice Call" on the pairing page
2. Enter the verification code received via voice call
3. Click "Verify"

### 3. DM Access Control

| Mode | Behavior |
|------|----------|
| `open` | Anyone can DM the agent. |
| `disabled` | DMs ignored. |
| `allowlist` | Only pre-approved phone numbers (E.164 format) can DM the agent. |

### 4. Group Access Control

| Mode | Behavior |
|------|----------|
| `disabled` (default) | Group messages ignored. |
| `open` | Any group message processed (subject to mention gating). |
| `allowlist` | Only messages from groups in `group_allowlist` processed. |

In groups, the agent only responds when mentioned (default `require_mention: true`). Configure mention patterns in `dartclaw.yaml`. Mention detection uses regex matching against message text.

## Message Handling

- **Text chunking**: Long responses split at ~4000 chars with smart break points (paragraph > sentence > word)
- **Response prefix**: Messages include agent identity prefix

## Known Limitations

- **No media sending**: signal-cli supports attachments, but `SignalChannel` currently sends text only. Media support is planned for a future release.
- **No QR code rendering**: The `sgnl://` device link URI is displayed as text. Users must copy/paste or use a QR generator.
- **No CAPTCHA handling**: signal-cli handles CAPTCHA challenges internally when needed by Signal servers.
- **No Safety Number verification**: Signal Safety Number changes are not surfaced to the user.
- **Startup time**: signal-cli (Java) can take 10-30 seconds to become reachable. DartClaw polls health for up to 30 seconds.

## signal-cli Not Found

If `signal-cli` is not on PATH and `executable` is not a valid absolute path:
- DartClaw logs a WARNING and continues without Signal
- Web UI and other features work normally
- `/signal/pairing` shows "signal-cli Not Reachable" with config instructions

## Troubleshooting

| Issue | Solution |
|-------|----------|
| signal-cli won't start | Check `signal-cli --version`, verify Java 17+ installed |
| Daemon not reachable | Check port 8080 is free: `curl http://127.0.0.1:8080/api/v1/check` |
| Registration fails | Signal rate-limits registration attempts. Wait and retry. |
| Messages not delivered | Check DM access mode, verify registration is complete |
| Agent not responding in groups | Verify `group_access: open` and `mention_patterns` match your @mention format |
| SSE disconnects | signal-cli auto-reconnects with 2s backoff. Check signal-cli logs for errors |
| signal-cli crashes repeatedly | Check logs for restart attempts; max 5 retries with exponential backoff (2s, 4s, 8s, 16s, 30s cap) |

## Manual E2E Test Procedure

These tests verify the full Signal integration. Tests requiring a phone/number are marked accordingly.

### T01: signal-cli Startup

1. Configure `dartclaw.yaml` with `channels.signal.enabled: true` and `phone_number` set
2. Run `dartclaw serve`
3. Verify: logs show "signal-cli started successfully"
4. Verify: `curl http://127.0.0.1:8080/api/v1/check` returns 200

### T02: Device Linking (requires phone)

1. Open `http://localhost:<port>/signal/pairing` (with auth token)
2. Verify: pairing page shows "Option 1 -- Link Device" with `sgnl://` URI
3. Signal > Settings > Linked Devices > Link New Device > enter URI
4. Refresh pairing page -- verify "Signal Connected"

### T03: SMS Registration (requires phone number)

1. On a fresh signal-cli instance (not yet registered)
2. Open pairing page, click "Send SMS Code"
3. Verify redirect to verify step
4. Enter verification code, click "Verify"
5. Verify "Signal Connected" state

### T04: Voice Registration (requires phone number)

1. On a fresh signal-cli instance
2. Open pairing page, click "Request Voice Call"
3. Verify redirect to verify step
4. Enter verification code, click "Verify"
5. Verify "Signal Connected" state

### T05: Text DM Round-Trip (requires phone)

1. Send a Signal DM to the registered number
2. Verify: SSE event received (check DartClaw logs)
3. Verify: agent processes the message (turn starts)
4. Verify: response received in Signal

### T06: Group Mention Gating (requires phone)

1. Add bot to Signal group, set `group_access: open` and `require_mention: true`
2. Send group message without mentioning bot -- verify: no response
3. Send group message with `@DartClaw` -- verify: bot responds
4. Set `require_mention: false` -- verify: bot responds to all messages

### T07: DM Access Control (requires phone)

| Mode | Test | Expected |
|------|------|----------|
| `open` | Any phone DMs bot | Bot responds |
| `disabled` | Any phone DMs bot | No response (log: "DM from unapproved sender") |
| `allowlist` | Unlisted phone DMs | No response |
| `allowlist` | Listed phone DMs | Bot responds |

### T08: Group Access Control

| Mode | Test | Expected |
|------|------|----------|
| `disabled` | Any group message | Dropped (log: "group access disabled") |
| `open` | Any group message | Processed (subject to mention gating) |
| `allowlist` | Group not in list | Dropped (log: "not in allowlist") |
| `allowlist` | Group in list | Processed |

### T09: Text Chunking (requires phone)

1. Send a prompt that generates a response > 4000 chars
2. Verify: response arrives as multiple Signal messages
3. Verify: each chunk within `max_chunk_size`

### T10: signal-cli Crash Recovery

1. While DartClaw is running, kill signal-cli: `pkill signal-cli` or `pkill java`
2. Verify: logs show "signal-cli exited unexpectedly"
3. Verify: exponential backoff restart (2s, 4s, 8s, 16s, 30s cap)
4. Verify: signal-cli restarts and SSE reconnects

### T11: signal-cli Not Installed

1. Set `executable: /nonexistent/signal-cli` in config
2. Start DartClaw
3. Verify: WARNING log for Signal channel failure
4. Verify: server continues running; web UI works
5. Verify: `/signal/pairing` shows "signal-cli Not Reachable"

### T12: InputSanitizer on Channel Messages (requires phone)

1. With `guards.input_sanitizer.enabled: true` and `channels_only: true` (default)
2. Send a Signal DM containing an injection pattern (e.g. "ignore all previous instructions")
3. Verify: guard blocks the message (`source='channel'`)
4. Verify: SEVERE log from `GuardAuditLogger`
5. Verify: turn does NOT execute
6. Verify: a normal follow-up message is processed normally

### T13: MessageRedactor on Channel Responses (requires phone)

1. With `guards.enabled: true` and a `MessageRedactor` configured
2. Trigger agent to generate a response containing a secret-like pattern
3. Verify: response on phone has the secret redacted
4. Verify: original secret never reaches the phone
