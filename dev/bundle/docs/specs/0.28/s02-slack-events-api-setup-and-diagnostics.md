# FIS: Slack Events API, setup and diagnostics

**Plan**: dev/bundle/docs/specs/0.28/plan.json
**Story-ID**: S02

## Feature Overview and Goal

**Intent**: An instance with a public URL cannot use Slack until the HTTP transport exists, and no owner can tell why a Slack setup fails; this story adds the signed Events API transport behind story S01's dispatch, the manifests and guide that get an owner from an empty workspace to a first DM, and the `dartclaw doctor` checks that name the cause when it does not work.

**Expected Outcomes**:

- [OC01] An owner switches `channels.slack.mode` to `events` and nothing else about chat changes: events, slash commands and interactions reach the same dispatch as over Socket Mode.
- [OC02] Forged, stale, replayed and oversized requests never start a turn, and Slack's 3 s acknowledgement is met however long a turn runs.
- [OC03] `dartclaw doctor` names the cause of a Slack setup failure (missing or revoked credential, missing scope, dead socket, wrong signing secret) and never prints a secret.
- [OC04] An owner sets Slack up on either transport from the shipped manifest and guide alone.


## Required Context

- `docs/specs/0.28/s01-slack-adapter-over-socket-mode.md` – the dispatch (SC03), fake doubles (SC04), config naming and the TI03 load refusals this story extends; its "What We're NOT Doing" hands `signing_secret_credential`, `webhook_path` and `mode: events` here.
- `docs/specs/0.28/prd.md#fr2-slack-transports` – the Events API half: signature, window, ack, ledger, same-path interactions.
- `docs/specs/0.28/prd.md#fr9-setup-credentials-and-diagnostics` – manifest, doctor rows, scope drift, redaction.
- `docs/specs/0.28/prd.md#fr10-documentation-and-parity-record` – the guide page and its config-key entries; the cross-cutting records are story S08's.
- `docs/specs/0.28/prd.md#constraints` and `#non-functional-requirements` – TD-124, Events API latency, retry and signature rows.
- `docs/research/slack-threaded-runs-0.28/recommendation.md#f5-framework-neutral-helpers-in-existing-core` – the helper contract and the TD-124 closure test list.


## Acceptance Scenarios

- **S01 [OC01] A signed event reaches the dispatch exactly as a socket event does**
  - **Given** `mode: events` with a signing secret, and a `message.im` event from an admitted sender
  - **When** Slack POSTs it to `webhook_path` with a valid signature and a fresh timestamp
  - **Then** the response is 200 with an empty body and story S01's dispatch receives one event envelope whose payload equals the one the fake Socket Mode server delivers for the same event; the same fixture set (DM, mention, slash command, interaction) fed through both transports admits the same messages

- **S02 [OC01] Request URL verification**
  - **Given** a signed `url_verification` body
  - **When** it arrives
  - **Then** the response is 200 carrying the challenge value and nothing reaches the dispatch; the same body unsigned is refused as in scenario S03

- **S03 [OC02] Bad, missing or stale signatures are refused**
  - **Given** a request that is unsigned, signed with another secret, signed over a body altered by one byte, missing the timestamp header, or timestamped more than 300 s from now in either direction
  - **When** it arrives
  - **Then** the response is 401, nothing reaches the dispatch, and one failed-auth event fires with source `webhook`, the resolved remote key (trusted-proxy rule included) and reason `missing_slack_signature` (header or timestamp absent or malformed), `stale_slack_timestamp`, or `invalid_slack_signature`; the same request writes one audit entry (guard `slack_signature`, hook `webhook`, verdict `block`, channel `slack`, the reason code and the remote key as peer) and no other webhook gains one; a timestamp 299 s old with a valid signature is accepted. The signature is checked over the exact received bytes, so a body with non-ASCII text, reordered keys and trailing whitespace verifies

- **S04 [OC02] A Slack retry is acknowledged, not reprocessed**
  - **Given** an event already accepted, and Slack retrying it with the same `event_id`
  - **When** the retry arrives, even while the first turn is still running
  - **Then** the response is 200 and no second envelope reaches the dispatch; the ledger remembers the last 1,000 distinct IDs

- **S05 [OC02] The acknowledgement never waits for processing**
  - **Given** a dispatch whose handler never completes, and another whose handler throws
  - **When** a valid event arrives for each
  - **Then** the 200 returns without waiting; the throw is logged and not retried by DartClaw, and its `event_id` stays in the ledger

- **S06 [OC01] Slash commands and interactions use the same signed path**
  - **Given** a signed form-encoded `/stop` command with `response_url`, and a signed `payload=` interaction of type `block_actions`
  - **When** each arrives
  - **Then** each is acknowledged with 200 and an empty body; the dispatch receives a slash-command envelope and an interactive envelope carrying the payload shapes Socket Mode delivers; unsigned or stale copies are refused as in scenario S03

- **S07 [OC02] Oversized bodies are refused before they are buffered**
  - **Given** a body over 1 MiB declared by `Content-Length`, and another streamed in chunks with no length header
  - **When** each arrives
  - **Then** the response is 413 and nothing is verified or dispatched

- **S08 [OC02] Malformed and unknown payloads are contained**
  - **Given** a correctly signed body that is not JSON, one with an unknown top-level `type`, and an `app_rate_limited` notice
  - **When** each arrives
  - **Then** the first answers 400; the other two answer 200, the unknown type is logged at debug and the rate-limit notice at warning, and nothing reaches the dispatch

- **S09 [OC01] Config selects the transport and refuses a contradiction**
  - **Given** `channels.slack` with `enabled: true`
  - **When** the config loads with `mode: events` plus bot-token and signing-secret references and no app token, with `mode: socket` plus an app token, with `webhook_path` omitted, set, malformed (no leading `/`) or equal to another webhook path, with an unknown `mode`, or with the references of both transports
  - **Then** the first two load and `webhook_path` defaults to `/integrations/slack`; events mode without a signing-secret reference, socket mode without an app-token reference, a malformed or colliding path and an unknown mode are refused naming the key and the fix; both transports' references load with one warning naming the unused one; a literal signing secret is refused naming the `credentials.<name>` form, without echoing the value

- **S10 [OC01] The route exists only in events mode and is exempt from gateway auth only there**
  - **Given** two instances, one with `mode: events` and one with `mode: socket`
  - **When** an unauthenticated POST hits `webhook_path`
  - **Then** the events instance answers through the signature rules (401 for an unsigned one, never the gateway's login redirect or token 401) and still demands gateway auth everywhere else; the socket instance mounts nothing there; in events mode the channel verifies the bot token at connect and opens no socket

- **S11 [OC03] A store-held credential is valid for doctor**
  - **Given** Slack references naming credentials that exist only in the named credential store
  - **When** `dartclaw doctor`, `secrets audit` or setup loads the config with the stored view off
  - **Then** loading does not fail and `config.valid` passes; presence is judged by the doctor's credential row, and a literal token in a reference key is still refused

- **S12 [OC03] Doctor names credential, token and scope causes**
  - **Given** Slack enabled, and each of: a reference naming no credential or an empty one, a bot token Slack rejects as `token_revoked` or `invalid_auth`, a token missing `assistant:write`, a token with scopes beyond the manifest's, Slack unreachable, and a healthy setup
  - **When** `dartclaw doctor` runs, as text and as `--json`
  - **Then** the credentials row fails naming the config key and credential name; the auth row fails with Slack's error code and the reinstall-and-update-the-credential fix; the scopes row fails naming each missing scope and warns on extras; an unreachable Slack is a warning, not a failure; the healthy case passes all three; no output contains a token, and no row is added while `channels.slack.enabled` is false

- **S13 [OC03] Doctor reports transport state from the running server**
  - **Given** a running server answering `/health`, in socket mode connected, reconnecting after failures or never connected, and in events mode with no request yet, a recent verified request, a stale-timestamp failure, and an `invalid_slack_signature` failure newer than the last verified request
  - **When** `dartclaw doctor` runs
  - **Then** socket mode passes with the last connect time, warns naming the consecutive failures, or fails when it never connected; events mode warns that no request arrived yet, passes with the last verified time, warns about clock skew, or fails naming the signing secret and its `credentials.<name>` as the likely cause. With no running server these rows are skipped with the `dartclaw serve` fix. `/health` carries no secret, ID or message content for Slack

- **S14 [OC04] The manifests declare what the adapter needs**
  - **Given** the two shipped manifests, one for Socket Mode and one for the Events API
  - **When** they are parsed
  - **Then** both declare the agent view, the ten bot scopes of PRD FR9, the events `app_mention`, `message.im`, `message.channels` and `message.groups`, interactivity and the five slash commands `/stop`, `/pause`, `/resume`, `/bind` and `/unbind`; the socket one enables Socket Mode and carries no request URL; the events one disables it and ends every request URL in the default `webhook_path`; the two differ in nothing else; and the scope list the doctor compares against equals the manifests'

- **S15 [OC04] The guide documents every key and both transports**
  - **Given** `docs/guide/slack.md`
  - **When** it is read against the config schema
  - **Then** every `channels.slack.*` key the schema holds appears with type and default, and a Socket Mode section and an Events API section each give the Slack UI steps from manifest import to a first DM, ending with the doctor rows to expect

- **S16 [OC03] The three Slack secrets are never written out**
  - **Given** a started instance whose bot token, app token and signing secret resolve to known values, the signing secret having no token shape
  - **When** requests fail signature verification, a handler error whose text embeds each value is logged, `/health` is read, `dartclaw doctor` runs as text and as `--json`, and the redactor's patterns are recompiled after a config reload
  - **Then** none of the three values appears in the log output, the audit entries, the `/health` body or the doctor output, and the redactor masks each value fully (no leading characters kept) before and after the recompile


## Structural Criteria

- **SC01** Bounded raw-byte reading, trusted-proxy remote-key selection, failed-auth event construction and the payload-size constant each have one owner in `dartclaw_core`; runtime and Google Chat keep only Shelf field extraction, and their byte loops are gone (TD-124 closed).
- **SC02** `dartclaw_slack` takes no `shelf` dependency and imports no runtime; the signature is compared with `crypto`'s `Digest` equality, so `constantTimeEquals` stays with runtime.
- **SC03** The Events API handler enters story S01's dispatch only through its envelope value and imports no Socket Mode code.
- **SC04** Every new `channels.slack.*` key has a reader, and the schema, config reference and advisory golden match `ConfigMeta`.
- **SC05** The workspace gates stay green: per-package LOC targets, package tiers, config-key consumers, no duplicate production type names.


## Scope & Boundaries

### Work Areas
- `packages/dartclaw_core`: webhook helpers, barrel – TI01
- `packages/dartclaw_runtime` and `packages/dartclaw_google_chat`: helper adoption, consumers, `webhook_http_support.dart` – TI02
- `packages/dartclaw_kernel` (ConfigMeta), `packages/dartclaw_slack` config, runtime `config_load.dart`: keys and load checks – TI03, TI04
- `packages/dartclaw_kernel` `MessageRedactor` and runtime `channel_wiring.dart`: secret registration – TI15
- `packages/dartclaw_slack`: events handler, health reporter, channel events mode, Web API `auth.test` scopes, fakes, scope constant – TI05, TI06, TI07, TI09
- `packages/dartclaw_runtime`: `channel_wiring.dart`, webhook route, server auth exemption, `HealthService`, secrets audit – TI08
- `apps/dartclaw_cli`: doctor rows, secrets audit, pubspec – TI10
- `examples/` manifests and `docs/guide/slack.md` – TI11, TI12
- Records: architecture deep-dives, CLI reference, guide index, CHANGELOG, TD backlog, LOC targets – TI02, TI13, TI14

### What We're NOT Doing
- Acknowledgement bodies that change what Slack shows (`response_action` for `view_submission`) – story S07 extends the ack path if it needs them; here every interaction is acknowledged empty.
- A Slack-specific audit sink, or an audit entry for other webhooks' failed verification: the Slack route writes its entry through the existing guard audit logger, and the shared failed-auth event gains no audit subscriber.
- Throttling failed signatures (`AuthRateLimiter`): no webhook has one, and the PRD names none; each rejected request writes its one audit entry.
- A second redactor or a regex-per-secret redaction path: the three Slack secrets join the existing `MessageRedactor` as literals.
- Validating the app-level token or Socket Mode at doctor time from the CLI: the running server's connection state is the evidence.
- Delegating `container/gateway/gateway_models.dart`'s `readBody` to the new reader: it reads a container bridge pipe with its own `GatewayDenied` contract, not an HTTP webhook, and F5 names the HTTP callers.
- Moving `constantTimeEquals`, response helpers or `AuthRateLimiter`: F5 keeps them with their owners.
- Slack in the settings page or config API – story S01's exclusion stands; the manifest and guide are the setup surface.
- Streaming or media keys and their guide rows – story S03; the parity matrix, glossary, feature comparison and `channels` profile – story S08.


## Architecture Decision

**Approach**: Events API handling is framework-neutral in `dartclaw_slack` (raw bytes and header map in, status and body out, `package:crypto` for the HMAC); the runtime owns the one Shelf adapter that extracts bytes, headers and peer facts through core's helpers, as it already does for the GitHub webhook. A request becomes the same envelope value Socket Mode delivers, so S01's handlers cannot tell the transports apart. Diagnostics reach doctor the way Pub/Sub health already does: a reporter feeds `HealthService`, and doctor reads the running server's `/health`.
**Why this over the floor**: the floor, a Shelf handler inside `dartclaw_slack` like Google Chat's, would add `shelf` to the Slack package and a third copy of request extraction, against F5's containment goal; the CLI cannot see connection or signature state without the server, and no Slack API reports a wrong signing secret, so `/health` is the only channel (FR9).
**Flow**: Shelf route → bounded bytes (413 on overflow) → handler: headers present, timestamp window, HMAC → type switch (`url_verification` answers; `event_callback` is deduped by `event_id`, wrapped and handed to the dispatch unawaited; form bodies become slash-command or interactive envelopes) → empty 200. A rejection returns its reason to the adapter, which fires the failed-auth event and writes the audit entry.

- Doctor adds no Slack row while `channels.slack.enabled` is false; a permanent skip row per channel would be noise.
- "Wrong signing secret" is a well-formed, fresh request failing the HMAC with no verified request since. A forged request looks identical, so the row says "likely" and names the credential. Health state is per process lifetime.
- Two manifest variants ship, because Events mode needs request URLs in three places and Socket Mode needs none.
- The `url_verification` reply is the challenge value as `text/plain`.
- A failed signature verification writes its audit entry through the existing guard audit logger (`GuardAuditLogger.writeEntry(AuditEntry)`), beside the failed-auth event. Only the Slack route does so, and no second audit sink is added.
- The three Slack secrets (bot token, app token, signing secret) are registered at startup as literal strings with the existing `MessageRedactor`, which masks them fully like call-time `sensitiveValues`. Channel wiring already receives the redactor and resolves the credentials, so it registers them. `logging.redact_patterns` stays the only operator-facing knob and its recompile on reload leaves the registered literals intact. A rotated secret takes effect on restart.
- ASSUMPTION: Slack's own validation of the manifests (schema, the agent-view key) cannot run unattended; the executor checks the keys against docs.slack.dev and records the check date in the guide, and Slack's own manifest validation and the agent-view key are verified by the owner's import in the live qualification after the last story (owner D22).


## Constraints & Gotchas

- **Constraint**: doctor, `secrets audit` and setup load config with `resolveStoredCredentials: false`, so a load-time check that a reference names an existing credential (story S01 TI03) rejects a credential held only in the store, which is where `dartclaw secrets set` puts it – Workaround: existence and emptiness checks run only when the stored view is resolved; doctor's credentials row judges presence against declared plus stored entries, as `_defaultDatabaseReadiness` merges them. Story S01's refusal already runs on the merged view; TI04 keeps that and adds the signing secret.
- **Constraint**: `auditSecrets` reports a `credentials.<name>` no `credential:` reference consumes as an orphan (a failing `secrets.orphans` row) – Workaround: count all three Slack references as consumers. Story S01 did not list this for its two token keys; extend, never duplicate, whatever it added.
- **Constraint**: the route sits outside gateway auth, so the signature is its only gate – Workaround: add the path to the auth middleware's public paths only when the handler exists, as for Google Chat; never a prefix.
- **Constraint**: Slack signs the exact bytes – Workaround: nothing decodes, re-encodes or parses the body before verification; the guide tells owners a reverse proxy must not rewrite it.
- **Constraint**: `MessageRedactor` extras are regexes that keep up to 8 leading characters of a match, and the signing secret has no recognisable shape, so registering it as an extra pattern would leak part of it – Workaround: a registered literal set masked fully like `sensitiveValues`, separate from the compiled patterns so `recompilePatterns` cannot drop it.
- **Constraint**: `/health` is unauthenticated – Workaround: Slack's object holds mode, connection state, timestamps, a failure count and a reason code, nothing else.
- **Constraint**: `dartclaw_core` cannot depend on `shelf` – Workaround: core helpers take primitives; each Shelf adapter extracts them, with no size loop, proxy choice or event construction of its own.
- **Constraint**: a new `ConfigMeta` key drifts the schema, config reference and `config_advisory_baseline_test` golden, and the key-consumer gate needs a reader per key – Workaround: `mode` and `signing_secret_credential` are read by channel wiring, `webhook_path` by route mounting.
- **Constraint**: package-scoped runs stay green while the workspace fails (LEARNINGS) – Workaround: the Final Validation Checklist is workspace-wide.


## Implementation Plan

### Implementation Tasks

- **TI01** `dartclaw_core` owns the webhook helpers: the 1 MiB size constant; a bounded reader taking a byte stream, optional declared length and limit that checks both before buffering and returns exact bytes or null; a remote-key resolver taking peer address, forwarded header and trusted proxies with today's rule (forwarded client only when the peer is a trusted proxy, null with no peer); a failed-auth emitter taking bus, source, path, reason, remote key and limited flag; exported through the barrel's `show` list.
  - Pattern: `packages/dartclaw_runtime/lib/src/auth/auth_utils.dart` (`readBounded`, `requestRemoteKey`, `fireFailedAuthEvent`) is the behavior to preserve.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/auth/webhook_http_test.dart` – chunked and no-length streams over the limit return null and the reader stops at the first chunk that crosses the bound; exact bytes back including invalid UTF-8; an empty body is empty; each proxy-rule case; the event carries every field
  - **SATISFIES**: SC01, S07

- **TI02** Runtime and Google Chat read bodies, remote keys and failed-auth events through core: `auth_utils.dart` and `webhook_http_support.dart` keep only `Request` field extraction (stream, length, peer address, `x-forwarded-for`, path), `readRequestBody` and Google Chat's `readJsonObject` delegate their byte loop, every consumer keeps its status codes, UTF-8 and JSON behavior, both duplicate size constants are gone, and the TD-124 entry is deleted from `dev/state/TECH-DEBT-BACKLOG.md`.
  - Inventory: consumers in `github_webhook.dart`, `webhook_routes.dart`, `mcp_router.dart`, `auth_middleware.dart`, `web_routes.dart`, `google_chat_webhook.dart`, `google_chat_subscription_routes.dart`; tests importing `maxWebhookPayloadBytes` from runtime change their import.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/auth packages/dartclaw_runtime/test/api packages/dartclaw_runtime/test/mcp packages/dartclaw_runtime/test/web` and `cmd: dart test --reporter=failures-only packages/dartclaw_google_chat` – existing cases pass unchanged, including 413 with and without `Content-Length`, the invalid-signature, secret and JWT failed-auth events, and the trusted-proxy remote key; `cmd: ! git grep -n -E 'await for \(final chunk in request\.read\(\)\)|trustedProxies\.contains\(|const maxWebhookPayloadBytes|^[[:space:]]+FailedAuthEvent\($' -- packages/dartclaw_runtime/lib packages/dartclaw_google_chat/lib` – no second algorithm or constant
  - **SATISFIES**: SC01

- **TI03** `channels.slack.mode` accepts `events`, and `signing_secret_credential` and `webhook_path` (default `/integrations/slack`) parse through `SlackConfig`, with ConfigMeta entries, schema, config reference and advisory golden regenerated; the app-token reference is required only in socket mode.
  - Pattern: story S01 TI02 for registration and regeneration; `channels.google_chat.webhook_path` in `packages/dartclaw_kernel/lib/src/config_meta/channel_fields.dart`.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_slack/test/slack_config_test.dart` then `cmd: dart test --reporter=failures-only packages/dartclaw_kernel` – defaults, both modes, path default and override; then `cmd: bash dev/tools/fitness/run_all.sh` – schema, reference and key-consumer gates green (readers land with TI08)
  - **SATISFIES**: S09, SC04

- **TI04** Load refuses and warns as scenario S09 states, and applies story S01's literal-token and reference checks to the signing secret; existence and emptiness checks run only on the resolved stored view (scenario S11); a webhook path equal to Google Chat's or GitHub's is refused.
  - Pattern: story S01 TI03 in `packages/dartclaw_runtime/lib/src/config/config_load.dart`.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/config/slack_config_load_test.dart` – each refusal names its key and fix and echoes no value; a store-only credential loads with the stored view off and is refused with it on when absent; the unused-transport warning appears once
  - **SATISFIES**: S09, S11

- **TI05** `SlackEventsHandler` (`packages/dartclaw_slack/lib/src/slack_events_handler.dart`) verifies requests as scenarios S02, S03, S07 and S08 state: headers, the 300 s window against an injectable clock, HMAC over the exact bytes with `Digest` equality, `url_verification` answered after verification, and the three rejection reasons returned for the adapter to emit.
  - Pattern: `packages/dartclaw_runtime/lib/src/api/github_webhook.dart#_validSignature` for the shape; Slack's basestring is `v0:<timestamp>:<body>`, header `v0=<hex>`.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_slack/test/slack_events_handler_test.dart` – every clause of scenarios S02, S03 and S08 including the 299 s and 301 s boundaries, bytes-exact verification, and an empty signing secret verifying nothing
  - **SATISFIES**: S02, S03, S08

- **TI06** The handler turns verified requests into story S01's envelope values and hands them over as scenarios S01, S04, S05, S06 and S08 state: events deduped by `event_id` in a 1,000-entry ledger, dispatched unawaited with failures logged, form bodies decoded into slash-command and interactive envelopes, every accepted request answered with an empty 200.
  - Pattern: `MessageDeduplicator` in `dartclaw_core` is the ledger (default capacity 1,000); reserve the ID before dispatching and never release it on a processing failure.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_slack/test/slack_events_handler_test.dart` – S04's retry during a running turn and the 1,000-ID bound, S05's never-completing and throwing handlers, S06's payload shapes asserted equal to what `FakeSocketModeServer` delivers, and the parity fixture set of scenario S01 through both transports into the real dispatch; `cmd: ! git grep --untracked -n -i "socket_mode" -- packages/dartclaw_slack/lib/src/slack_events_handler.dart` – the handler imports no Socket Mode code
  - **SATISFIES**: S01, S04, S05, S06, SC03

- **TI07** `SlackChannel` honours `mode`: events mode verifies the bot token at `connect()` and starts no socket client; a Slack health reporter exposes mode, socket connection state, last connect time and consecutive failures, and the handler's last verified time and last failure reason and time.
  - Pattern: `packages/dartclaw_google_chat/lib/src/pubsub_health_reporter.dart`.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_slack/test/slack_channel_events_mode_test.dart packages/dartclaw_slack/test/slack_health_reporter_test.dart` – events mode opens no socket against the fake server and fails loudly on a rejected token; the reporter map for each state scenario S13 lists, holding no secret or ID
  - **SATISFIES**: S10, S13

- **TI08** The runtime serves and reports Events mode: channel wiring builds the handler only in events mode and exposes it as it does Google Chat's; one Shelf route at `webhook_path` reads bounded bytes (413), calls the handler and, on a rejection, fires the failed-auth event with the trusted-proxy remote key and writes the audit entry through the server's `GuardAuditLogger`; the auth middleware's public paths gain the path only then; `HealthService` carries the Slack reporter's map under `slack` as it does Pub/Sub's; `auditSecrets` counts the three Slack references as consumers.
  - Pattern: `googleChatWebhookHandler` through `channel_wiring.dart`, `service_wiring_builder.dart`, `server_composition.dart`, `server_deps.dart`, `server.dart`; `packages/dartclaw_runtime/test/health/pubsub_health_integration_test.dart` for the health test.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/api/slack_webhook_route_test.dart packages/dartclaw_runtime/test/runtime/channel_wiring_test.dart packages/dartclaw_runtime/test/health packages/dartclaw_runtime/test/auth/auth_middleware_test.dart` – scenario S10's two instances through a composed server, the 401 event with the forwarded client, one audit entry per rejection reason with the fields scenario S03 lists and none for an accepted request, a 413 or another webhook's failure, `/health` with and without Slack (its body and the audit entries hold no signing-secret value), existing wiring and middleware cases unchanged
  - **SATISFIES**: S03, S07, S10, S13, S16, SC04

- **TI09** `SlackWebApiClient.authTest` also returns the granted scopes from the `X-OAuth-Scopes` header and Slack's error code on failure, without any token, header or URL in an error; `FakeSlackWebApi` scripts both.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_slack/test/slack_web_api_client_test.dart` – scopes parsed from a comma list with spaces, absent header yields no scopes, error text holds no `xoxb-` token
  - **SATISFIES**: S12

- **TI10** Doctor emits the Slack rows scenarios S11 to S13 state, ids `slack.credentials`, `slack.auth`, `slack.scopes` and `slack.transport`, only while Slack is enabled; the auth call goes through an injectable client factory defaulting to `SlackWebApiClient`; transport state comes from the server health doctor already reads; the expected scope list is one constant in `dartclaw_slack`; `dartclaw_cli` depends on `dartclaw_slack` as it does on `dartclaw_google_chat`.
  - Pattern: `SetupChecks._containerRows` and the `serverHealth` seam in `apps/dartclaw_cli/lib/src/commands/init/setup_checks.dart`; `FakeSlackWebApi` supplies the client in tests.
  - **Verify**: `cmd: dart test --reporter=failures-only apps/dartclaw_cli/test/commands/doctor_slack_test.dart apps/dartclaw_cli/test/commands/doctor_command_test.dart` – each state of scenarios S12 and S13 as text and JSON, a store-only credential passing, no token and no signing-secret value anywhere in output, no Slack row while disabled, existing doctor cases unchanged
  - **SATISFIES**: S11, S12, S13, S16

- **TI11** Two manifests ship under `examples/` (Socket Mode and Events API) as scenario S14 states, and a test parses both and compares them with each other, with the scope constant and with the default `webhook_path`.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_slack/test/slack_setup_assets_test.dart` – every clause of scenario S14
  - **SATISFIES**: S14

- **TI12** `docs/guide/slack.md` exists as scenario S15 states and joins `docs/guide/README.md`'s channel table and the channel links in the root `README.md`; the same test as TI11 compares the guide with the schema's `channels.slack.*` keys.
  - Pattern: `docs/guide/google-chat.md` for section order; credentials per `docs/guide/security.md`; the guide names the app-level token's `connections:write` scope, the signing-secret location, doctor rows and their remedies, event-ID retries, and that a proxy must not alter the body.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_slack/test/slack_setup_assets_test.dart` – key coverage with type and default; `inspect: docs/guide/slack.md:1` – both transport sections give the Slack UI steps, read once against the shipped manifests
  - **SATISFIES**: S15

- **TI13** The records match the code: `security-architecture.md` names core as the owner of the webhook helpers, Slack's signature scheme beside the other webhooks and its audit entry; `channel-messaging-architecture.md` gains the Events API route, the health object and the transport choice, with both "Current through" markers bumped; `docs/guide/cli-reference.md`'s doctor table lists the four Slack row ids; the `[0.28.0]` CHANGELOG section gains Added and Changed lines without story IDs.
  - **Verify**: `inspect: dev/architecture/security-architecture.md:1` – marker names this change and the webhook-auth paragraph names the helper owner; `cmd: git grep -n "slack.transport" -- docs/guide/cli-reference.md` – the row ids are listed
  - **SATISFIES**: SC01

- **TI14** The workspace gates hold: `_libLocCeilings` re-measured where this diff moved a package past its band (core and kernel grow, runtime and Google Chat shrink, Slack and CLI grow) with a reviewed-necessity line each, and `dartclaw_slack`'s pubspec gains `crypto`.
  - **Verify**: `cmd: dart run dev/tools/arch_check.dart` – every L2 line passes; `cmd: bash dev/tools/fitness/run_all.sh` – gates green; `cmd: ! git grep --untracked -n -E "shelf|dartclaw_runtime" -- packages/dartclaw_slack/pubspec.yaml packages/dartclaw_slack/lib` – the Slack package takes no Shelf or runtime dependency
  - **SATISFIES**: SC02, SC05

- **TI15** `MessageRedactor` holds a registered literal set, masked fully (`[REDACTED]`) before the pattern pass exactly as call-time `sensitiveValues` are, untouched by `recompilePatterns`; channel wiring registers the resolved bot token, signing secret (events mode) and app token (socket mode) when it builds the Slack channel and a redactor is present, and never an empty value.
  - Pattern: `MessageRedactor.redact`'s `sensitiveValues` handling in `packages/dartclaw_kernel/lib/src/message_redactor.dart`; `_MessageRedactorAdapter` in `security_wiring.dart` is the recompile path to keep intact.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_kernel/test/message_redactor_test.dart` – a registered value masked fully inside surrounding text and inside an assignment-shaped line, empty value ignored, still masked after `recompilePatterns`, existing cases unchanged; `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/runtime/channel_wiring_test.dart` – a started Slack wiring registers exactly the references its mode uses, so a logged error text embedding each resolved value comes out without it; `cmd: ! git grep --untracked -n -E "MessageRedactor\(" -- packages/dartclaw_slack/lib` – no second redactor in the Slack package
  - **SATISFIES**: S16


## Final Validation Checklist

- Workspace-wide, not package-scoped: `dart format --line-length=120 --output=none --set-exit-if-changed .`, `dart analyze --fatal-infos`, `bash dev/tools/test_workspace.sh`, `dart run dev/tools/arch_check.dart`, `bash dev/tools/fitness/run_all.sh`, `git diff --check`.
- A live Slack import of both manifests and a first DM per transport runs in the owner-led qualification after the last story; no unattended proof needs a Slack token.
