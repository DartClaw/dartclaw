# S0b step 2 — VM runbook

Runs the remaining half of the harness-stdio spike: a real `claude` (JSONL) and `codex app-server` (JSON-RPC) prompt→response turn over native-Windows stdio, with raw line-ending inspection. Step 1 (parser CRLF tolerance) already PASSed in CI — see [the brief](../spikes-scoping-brief.md).

## Prerequisites on the VM

1. `claude` and `codex` installed and authenticated (already true per the brief).
2. Dart SDK. If absent: `choco install dart-sdk`, or download a zip from <https://dart.dev/get-dart/archive>. The VM is Windows-on-ARM64 — a native arm64 SDK or the x64 SDK under emulation are both fine (this spike is arch-agnostic; the probe records the arch in its output either way).

## Run

1. Copy `s0b_step2_probe.dart` to the VM (e.g. via the Parallels shared folder, `\\Mac\Home\Repos\Libs\dartclaw\dartclaw-private\docs\specs\0.21\s0b-step2-probe\`).
2. In PowerShell (same environment where `claude` / `codex` work):

   ```powershell
   dart .\s0b_step2_probe.dart all *>&1 | Tee-Object s0b2-output.txt
   ```

   Or `claude` / `codex` instead of `all` to run one provider.
3. Bring `s0b2-output.txt` back for the findings section of the brief.

## What it does / PASS criteria

- Spawns the providers exactly the way `dartclaw_core`'s harnesses do (same CLI flags, same JSONL / JSON-RPC message shapes, LF-terminated writes) and parses stdout with a verbatim replica of the production `utf8.decoder | LineSplitter` chain.
- Reports raw on-the-wire line-ending counts (CRLF vs lone LF) for each provider — the documentation half of the spike question.
- PASS = `S0B2_PROBE_OK`: both providers complete a turn with every stdout line parsing as JSON (claude: `system` + `result` with `is_error=false`; codex: `initialize` → `thread/start` → `turn/completed`).
- A FAIL with clear diagnostics is valid spike output — especially for codex, where the app-server protocol may have drifted from the shapes in `codex_protocol_adapter.dart`; the probe logs every message both directions, so paste the output back and the probe can be adjusted.
