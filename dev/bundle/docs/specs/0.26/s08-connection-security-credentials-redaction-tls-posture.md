# FIS: Connection Security – Credentials, Redaction, TLS Posture

**Plan**: dev/bundle/docs/specs/0.26/plan.json
**Story-ID**: S08

_Refreshed 2026-09-02 against released 0.25 (public HEAD `daf5125a`), after the 2026-07-30 authoring against 0.24. Version labels: 0.26 is this milestone (the PRD title still carries its pre-renumber label), released 0.25 is the compatibility baseline. The posture decisions stand (ADR-045 #1, #5, #6; ledger `database-credential-source`, `tls-omission`; the malformed-DSN shapes; the two-role guidance and superuser warning). Two premises of the prior FIS were wrong and are rewritten here: the loopback seam is not extracted from `HttpMcpTransport` – the kernel already exports `isLoopbackHost` and the transport carries a private duplicate to retire; and redaction is key-side and unconditional since 0.25, so DSN coverage is a value-side addition beside the key-side classifier, not a new mechanism. The packages the prior FIS targeted (`dartclaw_config`, `dartclaw_security`, `dartclaw_server`) are gone: the redactor, credential registry, audit primitives and network predicate live in `dartclaw_kernel`; the config serializer and MCP transport live in `dartclaw_runtime`. Code references (`packages/...`, `apps/...`, `dev/...`) are paths inside `../dartclaw-public/`; every command runs from that root._

## Feature Overview and Goal

**Intent**: Let an operator opt into PostgreSQL without persisting a usable secret, exposing it during a failed start, or silently weakening its network security.

**Expected Outcomes**:

- [OC01] An active PostgreSQL configuration resolves exactly one DSN – an env-substituted `database.url` or an existing generic `credentials:` entry named by `database.credential` – synchronously before any connection attempt; a persisted inline password, both or neither reference, an unset variable, or an unknown or wrong-typed credential name refuses by name only.
- [OC02] No resolved DSN, userinfo, or password appears on any observable surface – redacted text, typed exceptions, audit records, `/api/config` and `dartclaw config` output – including authentication failures and the fail-closed schema bootstrap/compatibility path.
- [OC03] A non-loopback PostgreSQL host with omitted `sslmode` connects with `verify-full`, an explicit `disable` to a non-loopback host refuses before connecting, loopback is exempt under the one kernel predicate that MCP egress also uses, and verification and untrusted-CA failures are distinct actionable errors.
- [OC04] Operators can audit database connection lifecycle (open, close, authentication failure) as trusted host-side egress and are warned once when the runtime role is a superuser, with the two-role model documented and nothing enforced.


## Required Context

- `docs/specs/0.26/plan.json#sharedDecisions` – "`database.*` typed config section and the 0.25 config gates": S07 owns the section, its parse, `_sections['database']` at `restart`, and the registry part; this story adds reference validation, `readonly` mutability for `url`/`credential`, masking, and regenerates the schema and reference – it does not re-create the section. "Redaction-safe typed storage exceptions, kernel loopback predicate, audit sink": key-side `MessageRedactor` extended to DSN userinfo shapes; `isLoopbackHost` (`network_guard.dart`) is the single MCP+DB loopback seam and `HttpMcpTransport`'s private duplicate is retired; lifecycle audit through `GuardAuditLogger`/`AuditEntry`, never `DartclawEvent` (sealed, ADR-057); `CredentialRegistry.resolve` is synchronous and runs before any async connect.
- `docs/specs/0.26/plan.json#bindingConstraints` – FR6 and FR7 anchors, the sources of every scenario here.
- `docs/specs/0.26/prd.md#fr6-credential-reference-database-configuration` – the acceptance criteria seeded here: exactly one of `url`/`credential`, inline password rejected with the reference-model pointer, resolution through the existing `CredentialEntry` path with no new credential type, DSN redaction across log, exception, audit, and CLI paths including the malformed shapes (password containing `@` or `:`, percent-encoded credentials, keyword/value form, missing scheme), `dartclaw config` masking, `database.*` as boot-time config; error handling names the variable or reference, never a partial value.
- `docs/specs/0.26/prd.md#fr7-connection-security-posture` – omitted `sslmode` → `verify-full`, explicit cleartext/disabled fails closed, loopback exempt through a shared seam, trusted host-side egress documented in the security architecture doc, lifecycle audit, two-role model with superuser warning; error handling distinguishes explicit disablement, failed verification, and untrusted CA.
- `docs/specs/0.26/prd.md#edge-cases` – rows "Inline password in persisted `database.url`", "Cleartext DSN to non-loopback host", "Runtime role is superuser".
- `../dartclaw-public/dev/adrs/045-pluggable-database-backend.md#configuration` – "Credential handling (binding)": the reference model, `://user:pass@` redactor coverage, masking "the same way `CredentialEntry.toString()` masks secrets". `#decided-posture--contracts-owner-accepted-2026-07-24` – decisions #1 (TLS; loopback via the shared seam, never a reach into `HttpMcpTransport`), #5 (egress classification, same category as git operations), #6 (role separation; guidance plus warning, not enforced).
- `docs/specs/0.26/s07-opt-in-postgresbackend-core.md#technical-overview` – #1 `DatabaseConfig` (`url` env-substituted at parse, `credential` a name), #2 `databaseBackendFactoryFor(database, {resolveDsn})`, #3 the `resolveDatabaseDsn(DatabaseConfig)` seam whose body this story replaces, #4 `PostgresBackend.open({dsn, poolSize})` and its version probe on one leased connection, #7 the dispatch policy that maps open/authentication failures, #8 the kernel `StorageException` family composed from allow-listed safe fields only. `#what-were-not-doing` – the exact list S07 left to this story.
- `../dartclaw-public/packages/dartclaw_kernel/lib/src/network_guard.dart#isLoopbackHost` – the predicate: literal-only, case-insensitive, bare host (no port, IPv6 without brackets – the `Uri.host` shape), `localhost`/`127.0.0.1`/`::1` only; `127.0.0.2` is not loopback.
- `../dartclaw-public/packages/dartclaw_runtime/lib/src/mcp/outbound/http_mcp_transport.dart#HttpMcpTransport._isLoopbackHost` – the private duplicate (`InternetAddress.tryParse(host)?.isLoopback`) that accepts all of `127.0.0.0/8`; adopting the kernel predicate narrows the MCP exemption to the three literals.
- `../dartclaw-public/packages/dartclaw_kernel/lib/src/message_redactor.dart#MessageRedactor` – key-side classifier `isSecretKey` (a `password`/`secret`/`credential`/`token` key redacts its value unconditionally) plus value-side built-ins (PEM, Stripe, Anthropic, JWT, AWS, Bearer) with proportional reveal. A bare `postgres://user:pass@host/db` in prose matches neither today.
- `../dartclaw-public/packages/dartclaw_kernel/lib/src/credentials_config.dart#CredentialEntry` – the generic entry is `CredentialType.apiKey` (`api_key:` in YAML or `dartclaw secrets set <name> --type api-key`), `secret` is the resolved value, `envVars` preserves the referenced variable names, `toString()` masks the secret. `#CredentialsConfig` – `operator []` is the named lookup.
- `../dartclaw-public/packages/dartclaw_kernel/lib/src/credential_registry.dart#CredentialRegistry` – `resolve(providerId, {family})` is the synchronous provider-to-credential path; named generic entries are reached through the `CredentialsConfig` the registry wraps. This story adds one synchronous named-entry accessor on the registry and nothing else.
- `../dartclaw-public/packages/dartclaw_kernel/lib/src/env_substitute.dart#envSubstitute` – an undefined variable substitutes to the empty string with a warning; `envReferences` lists the names a raw template references. Inline-secret validation must therefore see the raw template, and an empty substituted `url` must refuse by variable name.
- `../dartclaw-public/packages/dartclaw_kernel/lib/src/guard_audit.dart#AuditEntry` and `#GuardAuditLogger` – the structured fields (`guard`, `hook`, `verdict`, `reason`, `server`, `decision`, `principal`, `credentialRef`) and the fail-closed sink `writeEntry(AuditEntry)`; `logVerdict` is the fire-and-forget guard path.
- `../dartclaw-public/packages/dartclaw_runtime/lib/src/mcp/outbound/outbound_mcp_pool.dart#_auditDecision` – the egress audit entry shape to mirror (`guard: 'EgressGuard'`, `server`, `decision`, `credentialRef: entry?.credential`).
- `../dartclaw-public/packages/dartclaw_runtime/lib/src/runtime/service_wiring.dart#_wireStorage` and `#_wireSecurity` – storage wires before security, and `SecurityWiring.wire` constructs the `GuardAuditLogger` at `security_wiring.dart#wire`; a lifecycle audit at database open needs the logger constructed earlier and shared.
- `../dartclaw-public/packages/dartclaw_runtime/lib/src/config/config_serializer.dart#ConfigSerializer.toJson` – the `/api/config` shape `dartclaw config show` renders; secrets are emitted as the literal `'***'` when set (`gateway.token`, `github.webhookSecret`).
- `../dartclaw-public/packages/dartclaw_kernel/lib/src/config_meta/channel_fields.dart` – `channels.google_chat.service_account` is the `ConfigMutability.readonly` exemplar ("Read-only: secret material is never editable through the API").
- `../dartclaw-public/dev/architecture/security-architecture.md#outbound-mcp-egress-boundary` – the current loopback statement (`127.0.0.0/8`) that this story corrects to the three literals; `#credential-security` and `#audit-chain` – where the database egress section lands.
- `../dartclaw-public/dev/state/LEARNINGS.md#security` – "Collapse whitespace where a one-line report is assembled" and the subprocess-env rules; `#specs--documentation` – "Cross-story deferral can land a seam nowhere: grep the producer before done" (S07 left `resolveDatabaseDsn` throwing – this story is the producer).
- `docs/specs/0.26/launch-context.md#live-structural-constraints` – the live configuration gates, loopback predicates and package placement that supersede both temporary re-plan audits.


## Deeper Context

- `docs/specs/0.26/s10-startup-interlock-and-backend-switch-semantics.md#technical-overview` – the abandoned-store probe reuses this story's posture evaluator and audit hook; nothing here may be private to `PostgresBackend`.
- `docs/specs/0.26/s12-operator-and-developer-documentation.md#implementation-tasks` – S12 writes the operator PostgreSQL guide (administrator and runtime-role SQL, TLS requirements); this story writes the architecture section it cites.
- `../dartclaw-public/dev/guidelines/TESTING-STRATEGY.md#layer-4--live-integration--e2e-tests` – `@Tags(['integration'])`, `--run-skipped -t integration`.
- `../dartclaw-public/dev/state/LEARNINGS.md#tooling--verification` – "failure injection must hit the claimed transition"; "passes locally" is no evidence for a boundary the host masks (TLS).
- `https://pub.dev/packages/postgres/versions/3.5.12` – `SslMode {disable, require, verifyFull}`; `ConnectionSettings.sslMode` defaults to `require` when unset; `parseConnectionString` (`lib/src/connection_string.dart`) accepts `postgres`/`postgresql` URI form only, maps `verify-ca` to `verifyFull`, and is not exported – DartClaw owns DSN parsing.


## Acceptance Scenarios

- **S01 [OC01] [TI01,TI02] Exactly one database credential reference resolves, by name, before any connection**
  - **Given** `database.backend: postgres` with (a) `database.url: ${DARTCLAW_DATABASE_URL}` and the variable set to a DSN carrying userinfo, (b) `database.credential: database-main` naming a generic `api_key` entry whose secret is a DSN, (c) both fields, (d) neither, (e) the variable unset, (f) an unknown credential name, (g) a credential name whose entry is a `github-token` type, (h) a persisted `database.url` containing a literal `user:password@` or a `password=` query parameter, and (i) `database.backend: sqlite` with any of the above retained
  - **When** the config loads and `resolveDatabaseDsn` runs
  - **Then** (a) and (b) produce the in-memory DSN and no reclassification of its userinfo as a persisted secret; (c), (d), and (h) are refused at load with a warning naming `database.url`/`database.credential` and pointing at env substitution or a named credential; (e), (f), and (g) throw `StorageConnectionException` naming only the variable or reference name; every refusal happens with zero connection attempts; (i) loads without validation or warning

- **S02 [OC02] [TI03] Redaction covers every DSN shape on every text surface**
  - **Given** `MessageRedactor` and the runtime `LogRedactor`, and input text containing `postgres://alice:s3cretX9@db.example.com:5432/dartclaw`, `postgresql://alice:p%40ss%3Aw0rd@db.example.com/dartclaw`, `alice:p@ss:w0rd@db.example.com/dartclaw` (missing scheme), `host=db.example.com user=alice password=s3cretX9`, `DARTCLAW_DATABASE_URL=postgres://alice:s3cretX9@db.example.com/dartclaw`, and a JSON line `"url": "postgres://alice:s3cretX9@db.example.com/dartclaw"`
  - **When** each input is redacted
  - **Then** no password or percent-encoded password survives, the URL form renders as `postgres://***@db.example.com:5432/dartclaw` (userinfo replaced, scheme and host observable), the keyword/value and assignment forms redact through the key-side classifier, and the existing redactor suite stays green

- **S03 [OC02,OC04] [TI02,TI06,TI07] [runtime] Failed PostgreSQL starts remain secret-free and are audited**
  - **Given** a DSN with a distinctive high-entropy user, password, host, and database name that (a) fails authentication, and (b) authenticates against a database whose schema the S07 gate refuses
  - **When** `dartclaw serve` starts through `DartclawRuntime.build`
  - **Then** each start aborts before serving; captured stdout, stderr, the log formatter's output, the thrown exception's rendering, and the audit partition contain none of the distinctive values; (a) writes one `AuditEntry` with `decision: auth_failure`, the safe server identity (host, port, database), and `credentialRef` equal to the variable or credential name; (b) writes `open` then `close` and no `auth_failure`

- **S04 [OC03] [TI06] TLS posture is fail-closed outside literal loopback, before pool construction**
  - **Given** DSNs for `localhost`, `127.0.0.1`, `[::1]`, `db.example.com` with `sslmode` omitted; `db.example.com?sslmode=disable`; `localhost?sslmode=disable`; `db.example.com?sslmode=require`; `db.example.com?sslmode=verify-ca`; `db.example.com?sslmode=prefer`; `127.0.0.2` with `sslmode` omitted; a keyword/value string; and a missing-scheme string
  - **When** the posture evaluator prepares connection settings
  - **Then** the three loopback literals with omitted mode keep the driver default (`require`); `db.example.com` omitted and `verify-ca` both resolve to `SslMode.verifyFull`; `require` passes as an explicit operator choice; `localhost?sslmode=disable` passes; `db.example.com?sslmode=disable` and `127.0.0.2` with `?sslmode=disable` refuse with `StorageConnectionException` stating that cleartext to a non-loopback host is refused and naming the loopback exemption; `prefer`, keyword/value, and missing scheme refuse as malformed naming the offending parameter or shape but never its value; every refusal occurs with no pool or socket created

- **S05 [OC03] [TI05] MCP and database boundaries use one literal-only loopback rule**
  - **Given** `localhost`, `127.0.0.1`, `::1`, `127.0.0.2`, `::ffff:127.0.0.1`, and a hostname that resolves to loopback
  - **When** `HttpMcpTransport` with `requireTls` and the database posture evaluator classify the host
  - **Then** both accept exactly the three literals, `127.0.0.2` is refused by both, no DNS lookup occurs, and `HttpMcpTransport` no longer declares a loopback predicate
  - **Proof**: `packages/dartclaw_kernel/test/network_guard_test.dart#rejects anything that is not an exact loopback literal` – green – parity/regression (run 2026-09-02; the kernel contract both consumers adopt; the MCP side's parity test is named in TI05's Verify)

- **S06 [OC04] [TI07,TI08] [runtime] Lifecycle audit and the superuser warning need no privilege machinery**
  - **Given** a live PostgreSQL 14+ reachable through `DARTCLAW_TEST_POSTGRES_URL`, a runtime role that is a superuser, and a second least-privilege role owning only its schema
  - **When** `PostgresBackend.open` and `close` run with each role
  - **Then** the audit sink receives `open` and `close` entries with `guard: DatabaseEgress`, `verdict: allow`, safe server identity, and `credentialRef`, and never a DSN, userinfo, or raw driver text; the superuser role produces exactly one warning line naming the two-role model, the least-privilege role produces none; no second application credential or role switch exists

- **S07 [OC02] [TI04] Configuration surfaces mask the URL and expose only the reference name**
  - **Given** a loaded config with `database.url` set, and separately with `database.credential: database-main`
  - **When** `/api/config` is served and `dartclaw config show` renders it
  - **Then** `database.url` renders as `***` when set and `null` when unset, `database.credential` renders its name, `database.backend` and `database.poolSize` render their values, and the published schema marks `url` and `credential` read-only
  - **Proof**: `packages/dartclaw_runtime/test/config/config_serializer_test.dart#gateway.token masked as "***" when non-null` – green – parity/regression (run 2026-09-02; the masking convention this story extends)


## Structural Criteria

- **SC01** `database.url` and `database.credential` carry `ConfigMutability.readonly` in the field registry with descriptions naming the reference model; `schemas/dartclaw.schema.json` and `docs/guide/configuration.md` are regenerated; the five 0.25 config gates stay green with no new allowlist line; `database` stays `ConfigReloadTier.restart`.
- **SC02** `isLoopbackHost` is the only loopback classification in production code: no `InternetAddress.*isLoopback`, no `_isLoopbackHost`, and no `dart:io` import remains in `http_mcp_transport.dart`; the database evaluator imports the predicate from the kernel barrel.
- **SC03** Database lifecycle records are `AuditEntry` values composed from allow-listed safe fields; no `DartclawEvent` subtype, no file under `packages/dartclaw_core/lib/src/events/`, and no `alert_classifier.dart` change is introduced.
- **SC04** No database-specific credential type, registry, store, second application credential, or role-switching mechanism exists: `CredentialType` is unchanged, `_parseCredentials` is unchanged, and no production symbol matches `DatabaseCredential`.
- **SC05** Inline-secret validation judges the raw persisted `database.url` template before environment substitution; the parsed `DatabaseConfig` retains the referenced variable names so an empty substitution refuses by variable name.
- **SC06** S07's contracts are untouched: the posture evaluator runs inside `PostgresBackend.open` before the pool is constructed, the `auditLogger` parameter is additive and nullable, and the retry bound, backoff, pool-wait ceiling, dispatch boundary, and schema identity are not modified.


## Scope & Boundaries

### Work Areas
- Typed config and registry: `../dartclaw-public/packages/dartclaw_kernel/lib/src/database_config.dart` (raw-template check, `urlEnvVars`), its parse site, `config_meta/database_fields.dart` (`readonly` on `url`/`credential`), regenerated `../dartclaw-public/schemas/dartclaw.schema.json` and `../dartclaw-public/docs/guide/configuration.md` (TI01)
- Credential resolution: `../dartclaw-public/packages/dartclaw_kernel/lib/src/credential_registry.dart` (named-entry accessor), `../dartclaw-public/packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart#resolveDatabaseDsn` (TI02)
- Redaction: `../dartclaw-public/packages/dartclaw_kernel/lib/src/message_redactor.dart` value-side DSN built-ins (TI03)
- Config surfaces: `../dartclaw-public/packages/dartclaw_runtime/lib/src/config/config_serializer.dart` `database` block (TI04)
- Loopback seam: `../dartclaw-public/packages/dartclaw_runtime/lib/src/mcp/outbound/http_mcp_transport.dart` adopts `isLoopbackHost` (TI05)
- Posture and lifecycle: `../dartclaw-public/packages/dartclaw_core/lib/src/storage/postgres_connection_posture.dart` (new: DSN parse, loopback classification, `SslMode` resolution, safe identity), `postgres_backend.dart` (evaluator before pool, audit hook, superuser probe), `postgres_dispatch_policy.dart` (TLS failure classes), `database_backend_selection.dart` (audit sink threaded); `../dartclaw-public/packages/dartclaw_runtime/lib/src/runtime/service_wiring.dart` and `security_wiring.dart` (one `GuardAuditLogger` constructed before storage wiring and shared) (TI06, TI07, TI08)
- Docs and tests: `../dartclaw-public/dev/architecture/security-architecture.md`, `../dartclaw-public/CHANGELOG.md`; `../dartclaw-public/packages/dartclaw_kernel/test/{database_config_test,message_redactor_test,credential_registry_test}.dart`, `../dartclaw-public/packages/dartclaw_core/test/storage/{postgres_connection_posture_test,postgres_backend_live_test}.dart`, `../dartclaw-public/packages/dartclaw_runtime/test/{config/config_serializer_test,mcp/outbound/outbound_mcp_transport_test,runtime/storage_wiring_backend_selection_test,runtime/storage_wiring_postgres_live_test}.dart` (TI01–TI09)

### What We're NOT Doing

_(`S<NN>` outside `## Acceptance Scenarios` names a plan story; inside it, a scenario ID.)_

- A database-specific credential model, secret store, or `CredentialType` – the generic `api_key` entry reached through the registry is the sole named-reference mechanism (ADR-045 credential handling).
- Live reload or in-process backend switching – `database.*` stays restart-tier (S07) and `url`/`credential` become read-only; no settings-form control is added.
- Custom CA bundles, client certificates, or `sslrootcert` handling – `verify-full` uses the platform trust store; an untrusted CA is an actionable refusal, not a configuration surface.
- Interlock, abandoned-store probe, and backend-switch behavior – story S10 consumes the evaluator and audit hook exposed here.
- The operator PostgreSQL guide with example SQL – story S12; this story writes the security-architecture section and the CHANGELOG lines only.
- Enforcing role separation – v1 is guidance plus one warning (ADR-045 #6).


## Architecture Decision

**Approach**: Complete S07's `resolveDatabaseDsn` seam through the existing env-substitution and `CredentialsConfig` paths behind one synchronous registry accessor; put DSN parsing and TLS posture in a side-effect-free core evaluator that consumes the kernel `isLoopbackHost`; emit lifecycle records as `AuditEntry` through one `GuardAuditLogger` constructed before storage wiring; extend the kernel redactor with value-side DSN built-ins as defense in depth behind S07's allow-listed exceptions. See ADR: `../dartclaw-public/dev/adrs/045-pluggable-database-backend.md` (#1, #5, #6, credential handling); `../dartclaw-public/dev/adrs/057-workflow-events-stay-in-the-sealed-event-library.md` (why lifecycle records are not events).
**Why this over alternatives**: the kernel predicate already exists with the literal-only contract the ADR asks for, so extraction would create the second implementation the plan forbids; a `DartclawEvent` lifecycle type would have to be declared inside the sealed core library and classified in `alert_classifier.dart` for no consumer; a second `GuardAuditLogger` instance for storage would interleave two write chains into the same NDJSON partition.


## Technical Overview

1. **Parse** (`database_config.dart`, S07's parser): before `envSubstitute`, the raw `database.url` template is rejected when its authority carries a literal password or its query carries `password=`; a template that is only `${VAR}` references passes. `DatabaseConfig` gains `urlEnvVars` (`envReferences(raw)`). Field registry: `url` and `credential` `ConfigMutability.readonly`; `backend` and `pool_size` stay `restart`. Validation applies only when `backend` is `postgres`.
2. **Resolve** (`resolveDatabaseDsn`, runtime, synchronous): `url` → the substituted value, refused when blank naming `urlEnvVars`; `credential` → `CredentialRegistry.namedEntry(name)` (new, delegating to `CredentialsConfig[name]`), refused when absent, empty, or not `isApiKeyCredential`, naming the credential name and its `envVars`. The registry instance is the one `service_wiring.dart#_credentialRegistry` already builds. Every refusal is `StorageConnectionException` with the reference name and remediation, never a value fragment. The credential-reference label (`${VAR}` name or credential name) travels with the DSN as `credentialRef` for audit.
3. **Evaluate** (`postgres_connection_posture.dart`, core, pure): `Uri.parse` on `postgres`/`postgresql` only; keyword/value, missing scheme, unknown query parameters, and unrecognized `sslmode` values are malformed (`StorageConnectionException`, naming the parameter key or shape only). Host classified with `isLoopbackHost(uri.host)`. `sslmode` omitted → `verifyFull` for non-loopback, driver default for loopback; `verify-full`/`verify-ca` → `verifyFull`; `require` → `require`; `disable` → allowed on loopback, refused otherwise with the exemption named. Output: `Endpoint`, `SslMode`, safe identity (host, port, database), and the `credentialRef` label. `PostgresBackend.open` calls it before constructing the pool; S10 calls it for the probe.
4. **Classify TLS failures** (`postgres_dispatch_policy.dart` mapping): a handshake failure whose driver text indicates certificate-chain trust maps to `StorageConnectionException` with untrusted-CA guidance; hostname or certificate validity mismatch maps to failed-verification guidance; the raw text is inspected for the class and discarded.
5. **Audit** (`PostgresBackend`): `open` writes `AuditEntry(guard: 'DatabaseEgress', hook: 'connection', verdict: 'allow', decision: 'open', server: '<host>:<port>/<database>', credentialRef)`; `close` writes `decision: 'close'`; an authentication failure writes `verdict: 'deny', decision: 'auth_failure'` with the same safe fields. The sink is `GuardAuditLogger.writeEntry` (fail-closed; an audit failure at open aborts the open). The logger is constructed once in `DartclawRuntime.build`/`stageHeadless` before `_wireStorage`, handed to `StorageWiring` and to `SecurityWiring` (which stops constructing its own); `databaseBackendFactoryFor` threads it to `PostgresBackend.open`; the CLI open sites (`cleanup`, `workflow status --standalone`) construct one over the same data dir.
6. **Superuser probe** (`PostgresBackend.open`): the leased connection that reads `server_version_num` also reads `rolsuper` for `current_user`; `true` logs one warning naming the two-role model and continues.
7. **Redact** (`MessageRedactor` built-ins): a URL-form authority `://user:pass@` renders `://***@` (host preserved); a missing-scheme `user:pass@host` shape with a dotted or literal-loopback host renders `***@host`; keyword/value `password=` and `DARTCLAW_DATABASE_URL=`/`url:` assignments are covered by adding `url`, `dsn`, `connection_string` to the key-side secret set only where the last word is one of those and the preceding word is `database`. `LogRedactor` inherits.
8. **Serialize**: `ConfigSerializer.toJson` emits `'database': {'backend', 'url': url != null ? '***' : null, 'credential', 'poolSize'}`; `config show` needs no change.


## Code Patterns & External References

```
# type | path#anchor                                                                                              | why needed (intent)
file   | ../dartclaw-public/packages/dartclaw_kernel/lib/src/network_guard.dart#isLoopbackHost                     | the one loopback predicate; adopt, never copy
file   | ../dartclaw-public/packages/dartclaw_runtime/lib/src/mcp/outbound/http_mcp_transport.dart#_verifyTls      | the consumer whose private duplicate is retired
file   | ../dartclaw-public/packages/dartclaw_kernel/lib/src/message_redactor.dart#_compilePatterns                 | built-in pattern list and proportional reveal – add DSN built-ins here
file   | ../dartclaw-public/packages/dartclaw_kernel/lib/src/message_redactor.dart#isSecretKey                      | key-side classifier – the `database.url` key rule lands here
file   | ../dartclaw-public/packages/dartclaw_kernel/lib/src/credentials_config.dart#CredentialEntry                | generic entry, `envVars`, masked toString
file   | ../dartclaw-public/packages/dartclaw_kernel/lib/src/credential_registry.dart#CredentialRegistry.resolve    | synchronous resolution idiom the named accessor sits beside
file   | ../dartclaw-public/packages/dartclaw_kernel/lib/src/env_substitute.dart#envReferences                     | raw-template provenance
file   | ../dartclaw-public/packages/dartclaw_kernel/lib/src/guard_audit.dart#GuardAuditLogger.writeEntry           | fail-closed audit sink
file   | ../dartclaw-public/packages/dartclaw_runtime/lib/src/mcp/outbound/outbound_mcp_pool.dart#_auditDecision    | egress audit entry composition to mirror
file   | ../dartclaw-public/packages/dartclaw_runtime/lib/src/runtime/security_wiring.dart#wire                     | where the audit logger is constructed today
file   | ../dartclaw-public/packages/dartclaw_runtime/lib/src/config/config_serializer.dart#ConfigSerializer.toJson | `'***'` masking convention
file   | ../dartclaw-public/packages/dartclaw_kernel/lib/src/config_meta/channel_fields.dart                       | `ConfigMutability.readonly` exemplar with description wording
file   | docs/specs/0.26/s07-opt-in-postgresbackend-core.md#technical-overview                                     | the seams this story fills: #2, #3, #4, #7, #8
url    | https://pub.dev/packages/postgres/versions/3.5.12                                                        | SslMode, Endpoint, PoolSettings.sslMode, default `require`
```


## Constraints & Gotchas

- **Critical**: validate only the active PostgreSQL configuration. Under `sqlite`, a retained `url`/`credential` is legal and unvalidated (story S10's probe depends on it).
- **Critical**: the raw template is the only input for inline-secret rejection; the resolved DSN is never judged as persisted input, and the substituted value never appears in a warning.
- **Critical**: adopting `isLoopbackHost` narrows MCP's exemption from `127.0.0.0/8` to `localhost`, `127.0.0.1`, `::1` – intended (the kernel predicate's documented posture), recorded in the CHANGELOG and the security doc; the existing MCP loopback test uses only the three literals and stays green.
- **Critical**: the evaluator runs before any pool or socket exists (prior review F9): a malformed DSN or refused posture must never reach the driver's own parser, whose `ArgumentError` text echoes parameter values.
- **Constraint**: no raw driver text, DSN, or userinfo may be stored on a typed exception or passed as a logger error argument (S07 Technical Overview #8); redaction is defense in depth, not the barrier. Secrecy tests use distinctive high-entropy fixture values, never `dartclaw` or `localhost` substrings (prior review F7).
- **Constraint**: `CredentialRegistry` stays synchronous; the DSN is resolved before the first `await` of the open path.
- **Constraint**: the config gates are text scanners – `readonly` mutability changes the generated schema and reference, so both are regenerated and committed in the same change; the core-key list is unchanged (S07 added `database.backend` and `database.url`).
- **Gotcha**: `Uri.host` strips IPv6 brackets, matching the bare-host shape `isLoopbackHost` expects; never pass `uri.authority`.
- **Gotcha**: the driver maps `verify-ca` to `verifyFull` – document it as an upgrade, do not emulate `verify-ca`.
- **Gotcha**: a loopback server without TLS needs an explicit `?sslmode=disable` (the driver default is `require`); the S11 CI service URL will carry it. Recorded assumption, see Testing Strategy.
- **Constraint**: comments are rationale-only; no story IDs in code, dartdoc, CHANGELOG, or user-facing text.


## Implementation Plan

### Implementation Tasks

- **TI01** `database.*` validates the persisted reference form and marks the two secret-bearing fields read-only
  - Technical Overview #1 in S07's `database_config.dart` and parser; `config_meta/database_fields.dart` sets `url`/`credential` to `ConfigMutability.readonly` with descriptions naming env substitution and named credentials; regenerate with `generate_config_schema.dart` and `render_config_reference.dart`.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_kernel/test/database_config_test.dart && dart run packages/dartclaw_kernel/tool/generate_config_schema.dart --check && bash dev/tools/fitness/check_config_reference_drift.sh` – the kernel suite proves scenario S01 (c), (d), (h) refuse at load naming the field and the reference model, (a)/(b) parse with `urlEnvVars` populated from the raw template, (i) loads silently; the schema shows `url` and `credential` as file-only; no drift; all five config gates green
  - **SATISFIES**: S01, SC01, SC05

- **TI02** `resolveDatabaseDsn` resolves one reference synchronously through the registry and refuses by name
  - Technical Overview #2: `CredentialRegistry.namedEntry(String)` in the kernel; the runtime body replaces S07's placeholder throw; returns the DSN with its `credentialRef` label. Depends on TI01.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_kernel/test/credential_registry_test.dart packages/dartclaw_runtime/test/runtime/storage_wiring_backend_selection_test.dart && ! rg -q "not wired" packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart` – the registry suite proves the accessor returns a present `api_key` entry and `null` otherwise; the wiring suite proves scenario S01 (a), (b), (e), (f), (g): the resolved DSN reaches the injected factory for (a)/(b), each refusal throws `StorageConnectionException` whose rendering contains the variable or credential name and none of the fixture secret, and the factory is never called; S07's placeholder is gone
  - **SATISFIES**: S01, S03, SC04

- **TI03** `MessageRedactor` covers DSN userinfo shapes without weakening existing coverage
  - Technical Overview #7 in `_compilePatterns` and `isSecretKey`; `LogRedactor` needs no change.
  - **Verify**: `packages/dartclaw_kernel/test/message_redactor_test.dart#DSN userinfo` – scenario S02's six inputs leave no `s3cretX9`, `p@ss:w0rd`, or `p%40ss%3Aw0rd` in the output, the URL form keeps scheme and host, and the pre-existing groups in the file still pass unchanged
  - **SATISFIES**: S02

- **TI04** Configuration surfaces mask `database.url` and expose the credential name
  - Technical Overview #8 in `ConfigSerializer.toJson`; `config show`/`config get` inherit through `/api/config`.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/config/config_serializer_test.dart packages/dartclaw_runtime/test/api/config_api_routes_test.dart` – scenario S07: `database.url` serializes as `***` when set and `null` when unset, `credential` as its name, `backend` and `poolSize` as values, on both the serializer and the route
  - **SATISFIES**: S07

- **TI05** `HttpMcpTransport` uses the kernel loopback predicate and owns no duplicate
  - `_verifyTls` calls `isLoopbackHost(_url.host)`; `_isLoopbackHost` and the `dart:io` import are removed; the security doc's `127.0.0.0/8` statement is corrected and a CHANGELOG `### Changed` line records the narrowed exemption. Depends on nothing.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/mcp/outbound/outbound_mcp_transport_test.dart && ! rg -q "_isLoopbackHost|InternetAddress|dart:io" packages/dartclaw_runtime/lib/src/mcp/outbound/http_mcp_transport.dart && test "$(rg -l "isLoopback\b|_isLoopbackHost" packages apps --glob '*.dart' --glob '!**/test/**' | rg -v 'dartclaw_kernel/lib/src/network_guard.dart|dartclaw_runtime/lib/src/mcp/web_fetch_tool.dart' | wc -l | tr -d ' ')" = 0 && ! awk '/^### Outbound MCP Egress Boundary/{f=1;next} /^### |^## /{f=0} f' dev/architecture/security-architecture.md | rg -q "127\.0\.0\.0/8"` – the transport suite stays green and gains scenario S05's `127.0.0.2` refusal under `requireTls`; no host-literal loopback predicate exists outside the kernel (`web_fetch_tool.dart`'s `addr.isLoopback` is the SSRF check on a resolved address and stays); the Outbound MCP Egress Boundary section no longer claims the /8 exemption, while the SSRF blocked-ranges table keeps its `127.0.0.0/8` row
  - **SATISFIES**: S05, SC02

- **TI06** PostgreSQL connection posture is evaluated, fail-closed, before the pool exists
  - Technical Overview #3 and #4: `postgres_connection_posture.dart` (`show`-exported from the core barrel for S10), consumed at the top of `PostgresBackend.open`; TLS failure classes in the dispatch-policy mapping. Depends on TI02 for the `credentialRef` label.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/storage/postgres_connection_posture_test.dart packages/dartclaw_core/test/storage/postgres_dispatch_policy_test.dart && ! rg -q "InternetAddress|isLoopback\(" packages/dartclaw_core/lib/src/storage/postgres_connection_posture.dart` – scenario S04's full matrix (resolved `SslMode` per row, each refusal's exception naming the parameter key or shape and the loopback exemption, no fixture value in any rendering, and a counting fake proving zero pool construction on refusal); the dispatch-policy suite proves untrusted-CA and failed-verification handshake failures map to distinct guidance with the driver text discarded; the evaluator classifies through the kernel predicate only
  - **SATISFIES**: S03, S04, SC06

- **TI07** Connection lifecycle is audited as trusted host-side egress through one shared audit logger
  - Technical Overview #5: `PostgresBackend.open({dsn, poolSize, auditLogger})` additive parameter; `databaseBackendFactoryFor` threads it; the logger is constructed in `DartclawRuntime.build`/`stageHeadless` before `_wireStorage` and injected into `SecurityWiring`; CLI open sites construct one over the data dir. Depends on TI06.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/runtime/storage_wiring_backend_selection_test.dart packages/dartclaw_runtime/test/runtime/security_wiring_seam_integration_test.dart && test "$(rg -c "GuardAuditLogger\(" packages/dartclaw_runtime/lib/src/runtime/security_wiring.dart | tr -d ' ')" = 0 && dart analyze --fatal-infos packages/dartclaw_core/test/storage/postgres_backend_live_test.dart packages/dartclaw_runtime/test/runtime/storage_wiring_postgres_live_test.dart` – the wiring suites prove one logger instance reaches both storage and security and that security no longer constructs its own; the live suites prove scenarios S03 and S06: `open`/`close`/`auth_failure` entries with `guard: DatabaseEgress`, safe identity, and `credentialRef`, none of the distinctive fixture values anywhere in the partition, the log output, or the exception rendering, and a failing audit write aborts the open
  - **SATISFIES**: S03, S06, SC03, SC06

- **TI08** Startup warns once when the runtime role is a superuser
  - Technical Overview #6 on S07's version-probe connection; the warning names the two-role model and the security doc section. Depends on TI07.
  - **Verify**: `cmd: dart analyze --fatal-infos packages/dartclaw_core/test/storage/postgres_backend_live_test.dart` – the live suite's role cases prove scenario S06: a superuser connection logs exactly one warning, a least-privilege role created by the test logs none, and the open succeeds in both cases with no additional query after the probe
  - **SATISFIES**: S06

- **TI09** The security architecture documents the database egress posture and the two-role model
  - A "Database Connection Egress" subsection under `#credential-security` (or beside `#outbound-mcp-egress-boundary`): trusted host-side egress in the git-operations category, outside the agent guard chain; TLS posture per Technical Overview #3 including the loopback default and `verify-ca` upgrade, stating plainly that an explicit `sslmode=require` encrypts the connection but skips certificate verification (the driver's `SslMode.require` is `ignoreCertificateIssues`) and is accepted as an operator choice, with `verify-full` the recommendation; the outbound-MCP statement rewritten to say that the shared kernel predicate narrowed the plain-HTTP loopback exemption from `127.0.0.0/8` to `localhost`, `127.0.0.1`, `::1` (plan decision 2026-09-02, DECISION NOTE below); credential reference model and masking; lifecycle audit fields; administrator provisioning plus one least-privilege runtime role confined to the DartClaw schema, superuser warning, not enforced; "Current through" bumped. CHANGELOG `### Added` line for the posture and `### Changed` line from TI05. Depends on TI05–TI08 for accuracy.
  - **Verify**: `cmd: rg -q "Database Connection Egress" dev/architecture/security-architecture.md && rg -q "verify-full" dev/architecture/security-architecture.md && rg -q "superuser" dev/architecture/security-architecture.md && rg -q "loopback" CHANGELOG.md && ! rg -q "S0[0-9]|TI0[0-9]" dev/architecture/security-architecture.md CHANGELOG.md && git diff --check` – the section exists with the TLS default, the role model, and the audit description; the CHANGELOG carries both lines; no story or task IDs leaked; whitespace clean
  - **SATISFIES**: S06, SC04

### Testing Strategy

- [TI01–TI06] Untagged Layer 1/2: config parsing, registry accessor, redactor, serializer, transport, evaluator matrix, TLS-failure classification over S07's injectable driver seam – no PostgreSQL process.
- [TI07, TI08] Live Layer 4 (`integration`): audit emission, authentication failure, superuser and least-privilege roles, the composition-root boot. The support helper from S07 fails naming `DARTCLAW_TEST_POSTGRES_URL` when unset; role cases create and drop their own role inside the test namespace.
- Secrecy assertions use distinctive high-entropy fixture values for user, password, host, and database; the leak check runs over captured stdout, stderr, the log formatter's output, exception renderings, and the audit partition.
- ASSUMPTION (AUTO_MODE, 2026-09-02): a loopback host with omitted `sslmode` keeps the driver default `require` rather than `disable`; ADR-045 #1 exempts loopback from fail-closed refusal but does not choose a default, and never weaker than the driver is the conservative reading. A loopback server without TLS needs `?sslmode=disable` explicitly; the refusal text names it.
- The three bound Proofs are parity; every new behavior is proven by the TI01–TI09 Verify lines. Red-at-spec-time surface: `message_redactor_test.dart#DSN userinfo`, `postgres_connection_posture_test.dart`, the `database` cases in `config_serializer_test.dart`, `database_config_test.dart`, `storage_wiring_backend_selection_test.dart`, and the audit/role cases in the two live suites.

### Validation

- A live PostgreSQL 14+ through `DARTCLAW_TEST_POSTGRES_URL` is required for TI07 and TI08; without it execution reports `BLOCKED:` for those tasks. None was available at spec time (2026-09-02); no live Proof is bound.

### Execution Contract

- Story S07 must be complete (this story fills `resolveDatabaseDsn`, extends `PostgresBackend.open`, and adds to `database_fields.dart` and the dispatch-policy mapping). Order: TI01 → TI02 → TI03 ∥ TI04 ∥ TI05 → TI06 → TI07 → TI08 → TI09.
- The public working tree may carry another session's uncommitted edits outside this story's Work Areas; touch only the files named there. `service_wiring.dart` sits at the 1500-line cap – the shared-logger change must be line-neutral or move the construction into `_WiringContext`.
- Stories S10 and S12 build on this story's evaluator, audit hook, and security-doc section; none may require changing the posture matrix.


## Final Validation Checklist

- Captured startup output for authentication, TLS, and bootstrap/compatibility failures contains no resolved DSN, userinfo, or password.
- No `dartclaw_config`, `dartclaw_security`, or `dartclaw_server` path or package name appears in code, tests, or dev docs touched by this story.
- `dart analyze --fatal-infos`, `bash dev/tools/fitness/run_all.sh`, and `dart run dev/tools/arch_check.dart` are green with `DARTCLAW_TEST_POSTGRES_URL` unset.


## Implementation Observations

> _Managed by exec-spec post-implementation – append-only. Spec authors: leave this section empty._

#### DECISION NOTE: s08-mcp-loopback-exemption-narrowing

Decision-Key: s08-mcp-loopback-exemption-narrowing
Altitude: plan
Affected surface: `HttpMcpTransport._verifyTls` (TI05); scenario S05; `dev/architecture/security-architecture.md#outbound-mcp-egress-boundary` and the CHANGELOG `### Changed` line (TI09)
Decision: retire `HttpMcpTransport`'s private `InternetAddress.isLoopback` duplicate in favour of the kernel `isLoopbackHost`, accepting that the outbound-MCP plain-HTTP exemption narrows from every `127.0.0.0/8` address (plus `localhost`, `::1`) to exactly `localhost`, `127.0.0.1`, `::1`; a `127.0.0.2` MCP endpoint under `requireTls` is refused after this story.
Rationale: the plan forbids a second loopback implementation, and the kernel predicate's literal-only contract is the posture ADR-045 #1 asks for; the narrowing is a behavior change to a shipped MCP feature, so it is recorded as a decision rather than inferred from a CHANGELOG line.
Evidence: plan decision 2026-09-02 recorded in `docs/specs/0.26/plan.json` sharedDecisions "Redaction-safe typed storage exceptions, kernel loopback predicate, audit sink"; the owner may veto, in which case TI05 keeps a `/8` branch in the transport and this note is amended.

### Run: 2026-09-08 14:19 UTC – repair-proof

#### DRIFT

- spec-stale: TI01 Verify target repaired | Stale targets: – | `cmd: dart test --reporter=failures-only packages/dartclaw_kernel/test/database_config_test.dart && dart run packages/dartclaw_kernel/tool/generate_config_schema.dart --check && bash dev/tools/fitness/check_config_reference_drift.sh && bash dev/tools/fitness/run_all.sh` → `cmd: dart test --reporter=failures-only packages/dartclaw_kernel/test/database_config_test.dart && dart run packages/dartclaw_kernel/tool/generate_config_schema.dart --check && bash dev/tools/fitness/check_config_reference_drift.sh`

### Run: 2026-09-08 14:19 UTC – observations

2026-09-08 16:14 CEST owner scheduling override: one focused independent review and relevant checks per story. Full workspace and full fitness runs in task Verify commands are deferred to the final combined A+B gate, with no acceptance requirement removed. The retained command proves the story-local checks; prose referring to full-suite success describes final milestone evidence. Standard fast-tier closure remains; broad integration, platform and release verification run at the end.

### Run: 2026-09-08 17:06 UTC – repair-proof

#### DRIFT

- spec-stale: TI07 Verify target repaired | Stale targets: – | `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/runtime/storage_wiring_backend_selection_test.dart packages/dartclaw_runtime/test/runtime/security_wiring_seam_integration_test.dart && test "$(rg -c "GuardAuditLogger\(" packages/dartclaw_runtime/lib/src/runtime/security_wiring.dart | tr -d ' ')" = 0 && test -n "$DARTCLAW_TEST_POSTGRES_URL" && dart test --run-skipped -t integration --reporter=failures-only packages/dartclaw_core/test/storage/postgres_backend_live_test.dart packages/dartclaw_runtime/test/runtime/storage_wiring_postgres_live_test.dart` → `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/runtime/storage_wiring_backend_selection_test.dart packages/dartclaw_runtime/test/runtime/security_wiring_seam_integration_test.dart && test "$(rg -c "GuardAuditLogger\(" packages/dartclaw_runtime/lib/src/runtime/security_wiring.dart | tr -d ' ')" = 0 && dart analyze --fatal-infos packages/dartclaw_core/test/storage/postgres_backend_live_test.dart packages/dartclaw_runtime/test/runtime/storage_wiring_postgres_live_test.dart`

### Run: 2026-09-08 17:06 UTC – repair-proof

#### DRIFT

- spec-stale: TI08 Verify target repaired | Stale targets: – | `cmd: test -n "$DARTCLAW_TEST_POSTGRES_URL" && dart test --run-skipped -t integration --reporter=failures-only packages/dartclaw_core/test/storage/postgres_backend_live_test.dart` → `cmd: dart analyze --fatal-infos packages/dartclaw_core/test/storage/postgres_backend_live_test.dart`

### Run: 2026-09-08 17:06 UTC – observations

Owner scheduling override: the updated Verify commands prove local implementation and compilation only. Live integration and Windows/platform acceptance remain PENDING at the final combined A+B gate. Original postponed commands are retained by the repair-proof observations and deferred-live-platform-proofs.json. Do not report those postponed behaviors or milestone release acceptance as passed from a local receipt. Named targeted scenario proofs, the driver feasibility spike and missing-DSN refusal checks remain runnable. Final full-suite evidence may cover duplicate/subset invocations only with explicit owner-to-result mapping; platform and contract-report variants remain distinct.
