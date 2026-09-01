# Package Rules — `dartclaw_client`

**Role**: The client tier — the HTTP and SSE transport a consumer uses to drive a *running* DartClaw server. `DartclawApiClient`, the `ApiTransport`/`ApiRequest`/`ApiResponse` seam, `DartclawApiException`, and the SSE frame decoder. Barrel: `lib/dartclaw_client.dart` with explicit `show` clauses.

## Boundaries
- **Zero dependencies.** No `dartclaw_*` package, no pub package — `dart:async`/`dart:convert`/`dart:io` only. This is the package's only selling point: it keeps the package build-hook-free, and so `dart compile exe`-safe, independent of what `dartclaw_core` pulls in. Only the `dartclaw_*` half is gated (the tier order in `dev/package_tiers.txt` puts this package one step above the kernel, so the kernel is the only workspace package it could reach, and the direction gate fails any declared dependency it does not import); **a pub dependency would pass every gate in the repo**, so adding one is a review decision, not a CI one.
- **No config, no data directory, no token files.** Construction takes a base URI and an explicit token. Resolving a token from `DartclawConfig`, `TokenService`, or `$dataDir/gateway_token` is the composing application's job — in this repo, `apps/dartclaw_cli/lib/src/commands/connected_command_support.dart#apiClientFromConfig`.
- **No per-endpoint domain DTOs.** Responses stay `Map<String, dynamic>` / `List<dynamic>`. The types the endpoints carry (`Task`, `WorkflowRun`, `WorkflowDefinition`) are owned by `dartclaw_core` / `dartclaw_workflow`, which this package may not depend on; minting copies here would be a second authority for one JSON contract.
- **Do not declare `HttpClientFactory`.** The workspace's single declaration is `dartclaw_core/lib/src/util/http_request.dart`, which is unreachable from here. Type the injection seam inline as `HttpClient Function()`, as `dartclaw_kernel` and `dartclaw_runtime` already do at five sites. Dart function typedefs are structural, so a caller holding core's alias passes it here unchanged.

## Conventions
- The wire contract is consumed by the CLI, the desktop app, and smiðia. Routes, headers, query encoding, the bearer scheme, SSE frame parsing, the reconnect policy, and the `code`/`statusCode`/`details` error envelope are a compatibility surface — change them only deliberately, and say so in `CHANGELOG.md`.
- Public members carry dartdoc (`public_member_api_docs` is on in `analysis_options.yaml`).

## Gotchas
- `ApiResponse.body` must be drained or cancelled: the `dart:io` transport hands out `HttpClientResponse.asBroadcastStream` with an `onCancel` that closes the underlying `HttpClient`, so a body nobody reads holds the connection open. That is why `probeHealth` drains explicitly rather than discarding the response.
- `streamEvents` yields nothing for a frame with no `data:` line — a malformed frame is skipped, never fatal. `onDisconnect == null` ends the stream on the first drop rather than reconnecting.
- `version:` here is the project-wide version (`dartclawVersion`); bumping is release prep, not a per-package decision. `dev/tools/check_versions.sh` enforces it.

## Testing
- `test/dartclaw_api_client_test.dart` drives the client through a package-local `FakeApiTransport`. The CLI declares an identical one in `apps/dartclaw_cli/test/helpers/fake_api_transport.dart`; the duplication is deliberate and allowlisted in `dev/fitness/test/allowlist/no_duplicate_local_fakes.txt` rather than hidden behind a different name, because no shared home exists — this package must stay at zero dependencies and `dartclaw_testing` sits above it. Collapse them if a kernel-tier test-support home appears.

## Key files
- `lib/dartclaw_client.dart` — barrel; canonical export surface.
- `lib/src/dartclaw_api_client.dart` — the whole implementation: client, transport seam, `dart:io` transport, SSE decoder.
