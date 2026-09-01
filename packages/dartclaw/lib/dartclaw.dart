/// DartClaw — the client tier for a running DartClaw server.
///
/// Depend on this package to drive a server you already run: the HTTP API, the
/// SSE event streams, and the DTO types those endpoints carry. Nothing here
/// starts an agent, opens a DartClaw data directory, or pulls in the harness,
/// guard chain, storage, or channel runtime.
///
/// **Status: Pre-alpha.** API is unstable and will change. See the
/// [repository](https://github.com/DartClaw/dartclaw) for current status.
///
/// Client-tier abstractions:
///
/// - **DartclawApiClient** — requests, SSE streams, and the typed error envelope
/// - **ApiTransport** — the wire seam, for fakes and non-`dart:io` transports
/// - **Session** / **Message** — the shared DTOs the endpoints carry
///
/// To embed the runtime itself rather than talk to one, fork the repository and
/// depend on `dartclaw_core` and `dartclaw_kernel`
/// directly — see `docs/sdk/packages.md`.
library;

export 'package:dartclaw_client/dartclaw_client.dart';
export 'package:dartclaw_kernel/dartclaw_kernel.dart'
    show
        Session,
        SessionType,
        Message,
        MemorySearchResult,
        MemorySearchDegradation,
        MemorySearchOutcome,
        AgentDefinition,
        ChannelConfig,
        GroupAccessMode,
        RetryPolicy,
        ChannelType,
        ContainerConfig,
        ExecutionMode,
        ExecutionPolicy,
        SessionKey,
        SessionScopeConfig,
        ChannelScopeConfig,
        DmScope,
        GroupScope,
        WorkflowStepExecution;
