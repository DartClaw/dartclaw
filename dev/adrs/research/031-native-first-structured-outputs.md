# ADR-031 Research Appendix: Codex `turn/start` `outputSchema` Probe

> Frozen synthesis supporting [ADR-031](../031-native-first-structured-outputs.md). Point-in-time as of 2026-09-13; not maintained as the design evolves.

## Question

Does `codex app-server` accept the unmodified DartClaw execution-envelope schema as `turn/start` `outputSchema`, and does it constrain the final assistant message to it?

## Environment

- `codex-cli 0.153.4`, model `gpt-6-astra`, reasoning effort `xhigh` (from the operator's `~/.codex/config.toml`).
- Codex home `~/.codex` (operator default; auth untouched).
- Auth mode **ChatGPT subscription**, not API key: `~/.codex/auth.json` carries `OPENAI_API_KEY` present but null plus `tokens`/`auth_mode`, and the app-server emitted `account/rateLimits/updated` with `"limitId":"codex"`. The `initialize` response carried no auth field.

## Schema-key confirmation (before sending)

`codex app-server generate-json-schema` puts a top-level, **untyped** property on `v2/TurnStartParams.json`:

```json
"outputSchema": {
  "description": "Optional JSON Schema used to constrain the final assistant message for this turn."
}
```

`required` on `TurnStartParams` is `["input","threadId"]` only – no strict-mode sub-schema, no `$defs` constraint, no declared shape. The app-server does not describe or validate the schema's own structure.

## The `turn/start` request (verbatim, `cwd` redacted to `/workspace/probe`)

```json
{"id": 3, "method": "turn/start", "params": {"threadId": "01a09b78-73b9-79c0-8745-53275820a15a", "input": [{"type": "text", "text": "Reply with a short greeting in two sentences. Do not run any tools."}], "cwd": "/workspace/probe", "model": "gpt-6-astra", "sandboxPolicy": {"type": "readOnly"}, "approvalPolicy": "never", "outputSchema": {"type": "object", "additionalProperties": false, "required": ["outputs", "step_outcome"], "properties": {"outputs": {"type": "object", "additionalProperties": false, "required": ["summary", "report_path"], "properties": {"summary": {"type": "string", "description": "One-paragraph summary of the work done."}, "report_path": {"type": ["string", "null"], "description": "Path of a report file already written, or null."}}}, "step_outcome": {"type": "object", "additionalProperties": false, "required": ["outcome", "reason"], "properties": {"outcome": {"type": "string", "enum": ["succeeded", "failed", "needsInput"], "description": "Semantic outcome of the work: \"succeeded\" when the step met its goal, \"failed\" when it could not, \"needsInput\" when a human decision or missing requirement blocks safe progress."}, "reason": {"type": "string", "description": "Short justification for the chosen outcome."}}}}}}}
```

The schema literal is the execution envelope as the host builds it, sent byte-for-byte.

## What came back

71 received lines. Ordered method summary, `mcpServer/startupStatus/updated` chatter elided:

`response id=3` → `thread/status/changed` → `turn/started` → `item/started`+`item/completed` (userMessage) → `item/started`+`item/completed` (reasoning) → `item/started` (agentMessage) → 30 × `item/agentMessage/delta` → `item/completed` (agentMessage) → `thread/tokenUsage/updated` → `account/rateLimits/updated` → `hook/started` → `hook/completed` → `thread/status/changed` → `turn/completed`.

The agentMessage `item/completed` `params` keys are `completedAtMs`, `item`, `threadId`, `turnId`; the item's own keys are `delivery`, `id`, `memoryCitation`, `phase`, `questions`, `text`, `type`. The `turn/completed` `params` keys are `threadId` and `turn`; the `turn` keys are `completedAt`, `durationMs`, `error`, `id`, `items`, `itemsView`, `startedAt`, `status`. Token usage for the turn: 28 037 input / 259 output (215 reasoning).

## Final assistant message (verbatim)

```
{"outputs":{"summary":"Hello! Good to see you.","report_path":null},"step_outcome":{"outcome":"succeeded","reason":"Greeting provided"}}
```

## Verdict: accepted and conforming

The schema was accepted unmodified – no error or warning about `additionalProperties: false`, the `["string","null"]` union, the `enum`, or the `description` strings. Conformance checks on the reply:

| Check | Result |
|---|---|
| parses as a JSON object | yes |
| top-level keys exactly `outputs`, `step_outcome` | yes |
| `outputs` keys exactly `summary`, `report_path` | yes |
| `outputs.summary` is a string | yes |
| `outputs.report_path` honors the nullable union | yes – emitted as JSON `null`, not `"null"`, not omitted |
| `step_outcome` keys exactly `outcome`, `reason` | yes |
| `step_outcome.outcome` in enum | yes (`succeeded`) |
| `step_outcome.reason` is a string | yes |
| no extra properties at any level | yes |

The prompt never mentioned JSON, a schema, or structure, and the model returned no prose at all – provider-side constraint, not instruction-following. The two-sentence greeting landed inside the `summary` string, so the schema won over the literal instruction shape. Every object in the envelope is closed and lists all its properties in `required`, and the nullable field is a type union: nothing needed relaxing.

## No typed payload field

The validated payload is surfaced nowhere as a typed field. The JSON exists only as the `text` string of the agentMessage item with `phase: "final_answer"`, and it streamed through the 30 `item/agentMessage/delta` notifications as ordinary text. The generated schema agrees: `AgentMessageThreadItem` declares only `text` (required), `id`, `type`, plus nullable `delivery`/`memoryCitation`/`phase`/`questions`. Enforcement and readback are therefore separate capabilities – the app-server enforces the schema without distinguishing a validated payload from prose.

## stderr

Empty. The app-server wrote zero bytes to stderr across both runs.

## Budget accounting

Exactly one turn reached the model. A first attempt was rejected by the app-server before any model work – no `turn/started`, no `item/*`, no token usage:

```json
{"error":{"code":-32600,"message":"Invalid request: unknown variant `read-only`, expected one of `dangerFullAccess`, `readOnly`, `externalSandbox`, `workspaceWrite`"},"id":3}
```

Cause: a request-framing mistake, not schema content. `thread/start.sandbox` (`SandboxMode`) is kebab-case `read-only`; `turn/start.sandboxPolicy.type` (`SandboxPolicy`) is camelCase `readOnly`. The retry changed only `"read-only"` → `"readOnly"`; the schema literal and prompt were byte-identical. This rejection is the evidence behind the `read-only` → `readOnly` entry in `CodexSettings._sandboxTranslations`.

## Artifacts

The driver script, the full session logs for both runs, and the generated app-server schemas stayed local and are not published. The two load-bearing frames – the `turn/start` request above and the `turn/completed` notification – are committed as `packages/dartclaw_core/test/harness/fixtures/codex_output_schema_frames.jsonl`, with the same `cwd` redaction.
