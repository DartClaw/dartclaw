# FIS: Native and HTTP Embedding Providers

**Plan**: dev/bundle/docs/specs/0.26/phase-b/plan.json
**Story-ID**: S03

_Authored against public `3396754b6501` on `feat/0.26`; commands and `packages/...` paths run from
`../dartclaw-public/`._

## Feature Overview and Goal

**Intent**: Let an owner generate reproducible embeddings locally or through an explicitly selected HTTP endpoint
without silent network use, credential disclosure or an indefinitely blocked runtime lifecycle.

**Expected Outcomes**:

- [OC01] A verified local EmbeddingGemma model produces finite query and ordered document embeddings in process, using
  one reproducible model identity and the frozen input conventions.
- [OC02] An explicitly configured OpenAI-compatible endpoint produces the same provider contract while invalid
  responses, network refusals and credential-bearing failures remain safe and actionable.
- [OC03] The default model can be acquired explicitly and verified before publication, while existing verified bytes
  are reused and failed acquisition cannot damage them.
- [OC04] Native provider initialization and shutdown return within their fixed deadlines, and dependency failures leave
  the provider unavailable rather than wedging callers.

## Pinned Consumer Surface

S05 constructs providers and wires `dartclaw search download-model`; S07 consumes the artifact metadata in release
proofs. These are the concrete public entry points:

```dart
typedef NetworkAccessCheck = Future<void> Function(Uri uri);

final class NativeEmbeddingProvider implements EmbeddingProvider {
  NativeEmbeddingProvider({
    required String modelPath,
    required String expectedSha256,
    Duration initializationTimeout = const Duration(seconds: 60),
    Duration shutdownTimeout = const Duration(seconds: 10),
  });
}

final class HttpEmbeddingProvider implements EmbeddingProvider {
  HttpEmbeddingProvider({
    required Uri endpoint,
    required String model,
    required NetworkAccessCheck checkNetworkAccess,
    String? apiKey,
    Duration requestTimeout = const Duration(seconds: 30),
    HttpClientFactory? httpClientFactory,
  });
}

final class DefaultEmbeddingModelAcquirer {
  DefaultEmbeddingModelAcquirer({
    required NetworkAccessCheck checkNetworkAccess,
    HttpClientFactory? httpClientFactory,
  });

  Future<ModelAcquisitionResult> acquire({required String destinationPath});
}

enum ModelAcquisitionStatus { reused, downloaded }

final class ModelAcquisitionResult {
  String get path;
  ModelAcquisitionStatus get status;
}
```

`DefaultEmbeddingModel` exposes the selected filename, immutable source URL, byte size, SHA-256, licence name and
licence URL from `native-artifacts.json`. S05 resolves any HTTP credential reference through the existing
`CredentialRegistry.namedEntry` authority, passes only its API-key secret, and wraps the existing runtime network/SSRF
check as `NetworkAccessCheck`; this package adds no configuration or network-policy authority. Constructor durations
are deterministic defaults and test seams, not operator settings. `HttpEmbeddingProvider` validates `endpoint` before
assigning or otherwise storing it: the URI must be absolute `http` or `https`, have a non-empty host, and have no
userinfo, query or fragment.

## Required Context

- `docs/specs/0.26/phase-b/plan.json#sharedDecisions` – exact `EmbeddingProvider` port, selected artifact/settings,
  package boundary and final-verification ownership.
- `docs/specs/0.26/phase-b/s01-search-contracts-and-canonical-chunk-identities.md#pinned-contract-surface` – accepted
  provider signatures and vector validation that every implementation must preserve.
- `docs/specs/0.26/phase-b/prd.md#fr2-local-and-opt-in-http-embeddings` – explicit acquisition/HTTP opt-in, batch
  validation, fingerprint and failure behavior.
- `docs/specs/0.26/phase-b/prd.md#fr6-native-distribution-and-failure-handling` – exact dependency, verified artifacts,
  lifecycle bounds and actual-platform proof obligations.
- `docs/specs/0.26/phase-b/selected-settings.json#queryPrefix` – frozen native-model hash, Gemma query/document prefixes
  and package versions selected before held-out evaluation.
- `docs/specs/0.26/phase-b/native-artifacts.json#model` – immutable default model source, exact bytes, checksum and
  licence metadata.
- `docs/specs/0.26/phase-b/implementation-context.md#verified-native-api-and-offline-inputs` – current llamadart 0.8.22
  load/embed/dispose calls, local cache facts and offline hook inputs.
- `docs/specs/0.26/phase-b/implementation-context.md#initialization-lifecycle-source-check-2026-09-09-0200-cest` – the
  dependency-owned 30-second worker handshake and the unbounded model-load/dispose distinction.
- `../dartclaw-public/dev/state/PRODUCT.md#proportionality` – prototype scale and the ban on speculative worker pools,
  distributed services and duplicate authorities.
- `../dartclaw-public/dev/adrs/050-native-hybrid-search.md#decision` – in-process primary, HTTP escape hatch, one-binary
  posture and local-first network boundary.

## Deeper Context

- `docs/research/dart-native-hybrid-search/spike-llamadart-embeddings.md#caveats` – historical feasibility only; it is
  not current dependency, platform or lifecycle proof.
- `../dartclaw-public/dev/adrs/056-package-topology-consolidation.md#amendment-2026-08-22--the-tier-order-replaces-the-per-edge-tables`
  – current package-direction and count authority amended by S01.
- `../dartclaw-public/dev/guidelines/TESTING-STRATEGY.md#layer-2--integration-tests-in-process-with-fakes` – injected
  engine, HTTP and filesystem boundary tests without native/network prerequisites.

## Acceptance Scenarios

- **S01 [OC01] [TI01] Verified local bytes lazily produce convention-correct query and ordered document embeddings**
  - **Given** a model file matching the configured SHA-256 and an injected engine returning finite equal-dimension
    vectors
  - **When** the first `embedQuery` or non-empty `embedDocuments` call initializes the provider and later calls embed a
    query and ordered batch
  - **Then** concurrent first calls share one verified local load, the engine receives the exact frozen query/document
    prefixes, outputs retain input order/cardinality, and an empty document batch returns empty without loading

- **S02 [OC01,OC02] [TI01,TI02] Model fingerprints are stable, secret-free and change with embedding-determining input**
  - **Given** equivalent provider settings, then a changed native model checksum, HTTP endpoint or required model name
  - **When** each provider exposes `modelFingerprint`
  - **Then** equivalent settings yield the same lowercase SHA-256 fingerprint; any changed embedding input yields a
    different fingerprint; native identity includes its Gemma-prefix convention, HTTP identity includes its fixed raw-
    input convention, and paths, API keys and other credentials never contribute to or appear in either

- **S03 [OC02] [TI02] Explicit HTTP embedding preserves indexed response order and rejects unsafe transport behavior**
  - **Given** an absolute HTTP(S) embeddings endpoint with a non-empty host and no userinfo, query or fragment, a
    required model, injected network check and an optional API key
  - **When** query or document embeddings are requested
  - **Then** the check runs before every request, the OpenAI-compatible `input` contains the exact raw query or document
    strings with the required model and bearer key, no Gemma prefix or model-name heuristic is applied, redirects are
    refused, and unique response indices are reassembled into exact input order

- **S04 [OC02] [TI02] Malformed or credential-bearing HTTP failures expose no invalid vector or sensitive material**
  - **Given** an endpoint containing embedded user/password credentials or a query credential, or a non-success status,
    malformed JSON, missing/duplicate/out-of-range indices, wrong cardinality, or empty, non-finite or inconsistent-
    dimension vectors whose response or exception text contains the API key/content
  - **When** the provider rejects the endpoint during construction or handles the response
  - **Then** it throws a sanitized embedding failure naming only the safe operation/host/status context, publishes no
    partial result, includes neither the rejected URI, credentials, request content nor response body, and an invalid
    endpoint causes no network-policy check or request

- **S05 [OC03] [TI03] Explicit model acquisition reuses verified bytes and publishes only a complete verified download**
  - **Given** either an existing exact default file or an absent/corrupt destination
  - **When** `acquire` runs
  - **Then** exact bytes return `reused` without a network check/request; otherwise the check precedes each request,
    redirects are refused, bytes stream to an operation-unique sibling temporary file, and exact size plus SHA-256 are
    required before a downloaded file is published and returned

- **S06 [OC03,OC04] [TI01,TI03] Provider and acquisition failures preserve recoverability within fixed deadlines**
  - **Given** injected stalled native load/dispose calls, a missing/corrupt model, a denied network request, interrupted
    transfer, wrong size or wrong checksum
  - **When** provider initialization/disposal or acquisition fails
  - **Then** initialization returns an error within 60 seconds, disposal completes or returns a sanitized timeout within
    10 seconds, an ordinary failed lazy initialization is cleared so a later call can recover after explicit acquisition,
    a load timeout poisons that provider until reconstruction, disposal is terminal, a previously verified model remains
    byte-identical, and only this acquisition's temporary file is removed

## Structural Criteria

- **SC01** `dartclaw_search` owns both concrete providers and acquisition; it depends on `dartclaw_kernel` plus only
  justified external packages and imports neither core nor runtime.
- **SC02** Native execution uses llamadart exactly 0.8.22 with its existing 30-second worker handshake; no outer
  isolate, subprocess, worker pool or provider-specific scheduler is added.
- **SC03** Neither provider construction nor ordinary FTS/runtime startup downloads a model or contacts a cloud
  endpoint; only explicit acquisition or calls through an explicitly constructed HTTP provider can use the network.
- **SC04** Default metadata and native fingerprints derive from the frozen selected artifact/settings; native uses the
  frozen Gemma prefixes, HTTP uses fixed `openai-compatible-raw-input-v1`, llamadart model parameters retain their
  verified defaults, and returned vectors are validated at the provider edge.
- **SC05** ADR-050 records llamadart 0.8.22's dependency-owned worker handshake and distinguishes it from model
  load/dispose deadlines; historical 0.8.17 missing-library behavior is not stated as current implementation fact.

## Scope & Boundaries

### Work Areas

- `dartclaw_search` public provider/acquisition surface and barrel exports.
- In-process llamadart adapter, deterministic fingerprinting and bounded lifecycle state.
- OpenAI-compatible HTTP request/response validation and credential-safe errors.
- Verified default-model streaming acquisition and atomic publication.
- Focused injected tests for provider, HTTP and acquisition contracts.
- ADR-050 dependency/lifecycle evidence correction.

### What We're NOT Doing

- Runtime/configuration parsing, credential-reference resolution, `search` CLI registration or recovery command text –
  S05 owns those consumers.
- Native archive mirroring, build-hook overrides, platform packaging, Linux dependencies or executable probe harnesses –
  S07 owns portable release preparation and final verification runs them.
- Vector synchronization, storage, fusion or degradation handling – S02, S04 and S05 consume the provider port.
- Cloud/model discovery, automatic provider fallback, automatic download or a second remote model-identity setting – the
  endpoint plus required model is the operator-stable HTTP identity.
- A wrapper isolate/process to force-stop llamadart – actual process probes decide whether an upstream causal fix is
  needed.

## Architecture Decision

**Approach**: Implement both providers and the one default-model acquirer inside `dartclaw_search`; derive fingerprints
from canonical secret-free settings, inject the existing network check, and bound llamadart calls without replacing its
worker lifecycle.
**Why this over alternatives**: It keeps the native dependency and HTTP escape hatch behind S01's one port while
preserving the runtime's existing credential/network authorities and avoiding a second worker framework.

## Code Patterns & External References

```text
# type | path#anchor | why needed
file | ../dartclaw-public/packages/dartclaw_kernel/lib/src/http_request.dart#HttpClientFactory | injected Dart HTTP seam
file | ../dartclaw-public/packages/dartclaw_kernel/lib/src/message_redactor.dart#MessageRedactor | literal-secret fail-closed redaction
file | ../dartclaw-public/packages/dartclaw_kernel/lib/src/credential_registry.dart#CredentialRegistry.namedEntry | S05's sole credential-resolution owner
file | ../dartclaw-public/packages/dartclaw_runtime/lib/src/mcp/web_fetch_tool.dart#WebFetchTool.checkSsrfPolicy | S05 adapter to existing egress check
url | https://github.com/leehack/llamadart/blob/v0.8.22/lib/src/core/engine/engine.dart#LlamaEngine | exact load/embed/dispose API
url | https://github.com/leehack/llamadart/blob/v0.8.22/lib/src/backends/llama_cpp/llama_cpp_backend.dart#NativeLlamaBackend | worker handshake and dispose behavior
```

## Constraints & Gotchas

- Fingerprint canonical inputs are `provider=native`, llamadart `0.8.22`, actual verified model SHA-256, convention
  version and the two exact prefixes for native; HTTP inputs are `provider=http`, normalized endpoint, required model and
  `openai-compatible-raw-input-v1`. Encode unambiguously, hash with SHA-256, and exclude path/key/timeout.
- Query prefix is `task: search result | query: ` and document prefix is `title: none | text: `. The input-convention
  version is fixed with them for the native EmbeddingGemma provider; neither is tunable in configuration. HTTP sends raw
  query/document strings because the configured endpoint owns model-specific preprocessing; never infer behavior from
  its model name or add a preprocessing setting.
- HTTP accepts only absolute `http`/`https` endpoints with a non-empty host and no userinfo, query or fragment. Validate
  this before storing, serializing or fingerprinting the URI and before any network-policy check or request. Endpoint
  rejection never echoes the rejected URI, including through `ArgumentError.value(endpoint)`. Refuse redirects, apply
  one request deadline and cap response bytes. A bearer key requires HTTPS except for literal loopback hosts. Validate
  JSON from raw test literals, then map unique indices `0..input.length-1`; never trust response array order.
- `Future.timeout` bounds the provider caller but does not kill llamadart's private worker isolate. Ordinary synchronous
  model refusal clears the lazy attempt for later recovery; a load timeout poisons that provider so retries cannot
  accumulate workers, and disposal is terminal. Recovery after timeout requires diagnosis and provider reconstruction.
  Do not claim worker termination from the timeout alone.
  S07/S09's actual missing-library/absent/corrupt/load/dispose process probes must prove no retained worker/process on
  every selected platform. Any failure blocks combined acceptance and triggers a causal dependency/provider fix.
- Acquisition checks the existing destination before authorizing network, disables redirects, streams without buffering
  the 333590944-byte model, uses a unique sibling temporary file, and publishes only after exact length/hash validation.
  Cleanup addresses that exact temporary path; never delete or truncate a pre-existing destination on failure.
- Focused tests use injected engines/transports and shortened duration arguments. Reuse the verified private model/native
  caches via an uncommitted local hook override for any local probe; never commit machine paths or download bundles again.

## Implementation Plan

### Implementation Tasks

- **TI01** Native embeddings have verified identity and bounded provider lifecycle
  - Implement S01's exact port with llamadart 0.8.22, frozen prefixes/fingerprint inputs, provider-edge vector validation
    and one shared lazy initialization attempt; clear ordinary failures for explicit recovery, poison on load timeout, make
    disposal terminal, reuse the dependency handshake and inject only the engine boundary for tests.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_search/test/native_embedding_provider_test.dart packages/dartclaw_search/test/embedding_fingerprint_test.dart` – construction is I/O-free; concurrent first calls share verified loading; ordinary initialization failure retries only on a later call; load timeout and disposal are terminal; exact prefixes, ordered/empty batches, finite dimensions, fingerprint changes and deadlines cover every S01/S02/S06 clause owned here
  - **SATISFIES**: S01, S02, S06, SC01, SC02, SC03, SC04

- **TI02** Explicit HTTP embeddings are ordered, validated and credential-safe
  - Use the pinned constructor and injected network/HTTP seams; validate endpoint shape before retaining it or deriving
    identity, then validate transport, OpenAI-compatible indexed responses and vectors before return, with fixed
    response bounds and `MessageRedactor` literal-secret handling.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_search/test/http_embedding_provider_test.dart` – requests carry the exact model/raw inputs/key without Gemma prefixes or model-name heuristics, fingerprints include the fixed raw-input convention, policy precedes I/O, redirects/TLS violations and every malformed response fail, indices restore input order, embedded user/password and query-credential endpoints are rejected before fingerprinting/policy/request, and hostile failures expose no rejected URI, key, content or body
  - **SATISFIES**: S02, S03, S04, SC01, SC03, SC04

- **TI03** Default-model acquisition is explicit, streamed and failure-atomic
  - Export exact selected metadata and the pinned acquirer/result surface; verify a destination first, otherwise stream the
    immutable URL through the injected policy/HTTP seams to a unique sibling temp and publish only matching bytes.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_search/test/default_embedding_model_acquirer_test.dart` – verified reuse makes zero network calls; success returns downloaded only after exact length/hash; denial, redirect, interruption and mismatch preserve the old destination and remove only the operation temp
  - **SATISFIES**: S05, S06, SC01, SC03, SC04

- **TI04** ADR-050 states the selected dependency lifecycle evidence
  - Correct the historical initialization claim to 0.8.22's 30-second worker handshake, while retaining the separate
    model-load/dispose deadline and final process-proof obligations.
  - **Verify**: `cmd: rg -q '0\.8\.22' dev/adrs/050-native-hybrid-search.md && rg -q '30-second' dev/adrs/050-native-hybrid-search.md && rg -q 'model[- ]load.*dispose' dev/adrs/050-native-hybrid-search.md` – the ADR names all three current lifecycle facts
  - **SATISFIES**: SC05

### Testing Strategy

- Provider tests inject a minimal engine adapter, fake HTTP client and raw response literals so deadline, hostile-error,
  index/cardinality and cleanup assertions fail independently of native/network availability. Actual native/platform and
  stuck-process behavior is intentionally deferred once to the final combined A+B gate using S07's executable harness.

## Implementation Observations

_No observations recorded yet._
