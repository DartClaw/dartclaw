All DartClaw packages use lock-step versioning. This changelog tracks changes relevant to `dartclaw_client`.

## Unreleased

### Added
- Dependency-free HTTP and SSE client for a running DartClaw server: `DartclawApiClient`, the `ApiTransport`/`ApiRequest`/`ApiResponse` seam, and `DartclawApiException`. Extracted unchanged from the DartClaw CLI, which now consumes this package.
