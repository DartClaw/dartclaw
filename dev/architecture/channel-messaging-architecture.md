# DartClaw Channel Messaging Architecture

How inbound messages from WhatsApp, Signal, Google Chat, and the Web UI are normalized, routed, and delivered back through channel-specific adapters.

**Current through**: 0.25; 0.25 kernel package formation.

---

## 1. Overview and Design Philosophy

DartClaw supports four messaging channels as entry points for human-to-agent interaction:

| Channel | Transport | Sidecar / Integration | Package |
|---------|-----------|----------------------|---------|
| **WhatsApp** | GOWA webhook | Go binary (`gowa`) | `dartclaw_whatsapp` |
| **Signal** | signal-cli SSE | External binary (`signal-cli`) | `dartclaw_signal` |
| **Google Chat** | REST API + Pub/Sub | Direct HTTP (no sidecar) | `dartclaw_google_chat` |
| **Web UI** | Direct HTTP / SSE | Built into `dartclaw_runtime` | `dartclaw_runtime` |

Three principles govern channel design:

1. **Normalize early** -- Every channel adapter converts platform-specific payloads into a single `ChannelMessage` model as close to the ingress point as possible. Downstream pipeline stages never see WhatsApp JIDs, Google Chat space names, or Signal envelopes directly.

2. **Outpost pattern** -- WhatsApp and Signal use external binaries (GOWA and signal-cli) managed as subprocesses. No shared runtime, no dependency contamination. The Dart host communicates with these sidecars via their native REST/RPC APIs.

3. **Core abstractions, platform packages** -- The abstract `Channel` base class, `ChannelManager`, `MessageQueue`, thread binding, and the `ChannelTaskBridge` live in `dartclaw_core`. Per-platform adapters (`WhatsAppChannel`, `SignalChannel`, `GoogleChatChannel`) live in dedicated packages that depend on core. The Web channel is served directly by `dartclaw_runtime`.


---

## 2. Channel Abstraction Model

### 2.1 Core Types

All channel types are defined in `dartclaw_kernel`:

```
// packages/dartclaw_kernel/lib/src/channel_type.dart
enum ChannelType { web, whatsapp, signal, googlechat }
```

### 2.2 ChannelMessage (Normalized Inbound)

Every channel adapter produces a `ChannelMessage` -- the single inbound message type consumed by all downstream stages.

```
// packages/dartclaw_core/lib/src/channel/channel.dart
class ChannelMessage {
  final String id;               // UUID assigned by adapter
  final ChannelType channelType; // Transport origin
  final String senderJid;        // Normalized sender identifier
  final String? groupJid;        // Group identifier (null for DMs)
  final String text;             // Message body
  final DateTime timestamp;
  final List<String> mentionedJids;
  final Map<String, dynamic> metadata;  // Channel-specific extras
}
```

Key metadata keys by channel:
- **Google Chat**: `spaceName`, `spaceType`, `senderDisplayName`, `senderAvatarUrl`, `messageName`, `messageCreateTime`, `threadName`
- **WhatsApp**: `pushname`, `repliedToId`
- **Signal**: `sourceName`, `sourceUuid`

The `senderDisplayName` getter checks metadata keys in priority order: `senderDisplayName` (Google Chat), `pushname` (WhatsApp), `sourceName` (Signal).

### 2.3 ChannelResponse (Outbound)

```
// packages/dartclaw_core/lib/src/channel/channel.dart
class ChannelResponse {
  final String text;
  final List<String> mediaAttachments;
  final Map<String, dynamic> metadata;
  final String? replyToMessageId;
  final Map<String, dynamic>? structuredPayload;  // Cards v2, etc.
}
```

Channels that support structured rendering (Google Chat Cards v2) prefer `structuredPayload`; others fall back to
`text`. A producer that sets `structuredPayload` sets `text` too: it is the fallback delivered when structured
rendering is unavailable or the structured send fails. Adapters deliver that `text` verbatim and never re-derive
one from the payload; an adapter handed a payload with an empty `text` may deliver a generic placeholder rather than
nothing.

### 2.4 Abstract Channel

```
// packages/dartclaw_core/lib/src/channel/channel.dart
abstract class Channel {
  String get name;
  ChannelType get type;
  Future<void> connect();
  Future<void> sendMessage(String recipientJid, ChannelResponse response);
  Future<void> startTyping(String recipientJid); // default no-op
  Future<void> stopTyping(String recipientJid);  // default no-op
  bool ownsJid(String jid);
  Future<void> disconnect();
  List<ChannelResponse> formatResponse(String text);
}
```

`ownsJid()` is the JID-routing predicate -- each channel implementation recognizes its own identifier format:
- **WhatsApp**: ends with `@s.whatsapp.net` or `@g.us`
- **Signal**: strict E.164 or case-insensitive UUIDv4 identifiers are direct recipients; every other outbound identifier is a group ID
- **Google Chat**: starts with `spaces/`

### 2.5 ChannelManager

The `ChannelManager` is the routing hub. It holds a list of registered `Channel` instances, a `MessageQueue`, and an optional `ChannelTaskBridge`.

```
// packages/dartclaw_core/lib/src/channel/channel_manager.dart
class ChannelManager {
  final MessageQueue queue;
  final ChannelConfig config;
  final LiveScopeConfig liveScopeConfig;
  final ChannelTaskBridge? _taskBridge;
  final List<Channel> _channels;

  void registerChannel(Channel channel);
  void handleInboundMessage(ChannelMessage message);
  String deriveSessionKey(ChannelMessage message);
  Future<void> connectAll();
  Future<void> disconnectAll();
}
```

---

## 3. Inbound Message Pipeline

The full inbound flow from raw platform event to agent turn. Access control runs on every path: the WhatsApp webhook, Signal SSE and the Google Chat webhook run the gate in full, and the Google Chat Space Events Pub/Sub dispatch runs it with the mention stage off (un-mentioned space traffic is that feature's purpose) before reaching `ChannelManager.handleInboundMessage`:

```
                     Webhook POST / Pub/Sub Pull / SSE Event
                                    |
                                    v
                  +-----------------------------------+
                  |  Channel Adapter (per-platform)   |
                  |  - Parse raw payload              |
                  |  - Filter bot messages             |
                  |  - Normalize to ChannelMessage     |
                  +-----------------------------------+
                                    |
                                    v
                  +-----------------------------------+
                  |  DM Access Control                |
                  |  - DmAccessController (pairing,   |
                  |    allowlist, open, disabled)      |
                  +-----------------------------------+
                                    |
                                    v
                  +-----------------------------------+
                  |  Group Access Control              |
                  |  - GroupAccessMode (allowlist,     |
                  |    open, disabled)                 |
                  +-----------------------------------+
                                    |
                                    v
                  +-----------------------------------+
                  |  Mention Gating                   |
                  |  - MentionGating (group messages   |
                  |    only)                           |
                  +-----------------------------------+
                                    |
                                    v
                  +-----------------------------------+
                  |  MessageDeduplicator               |
                  |  - Bounded FIFO set (default 1000) |
                  |  - Keyed on message resource name  |
                  |  - Prevents webhook + Pub/Sub      |
                  |    double-processing               |
                  +-----------------------------------+
                                    |
                                    v
              +-----------------------------------------------+
              |  ChannelManager.handleInboundMessage()        |
              |  - Find owning channel via ownsJid()          |
              |  - Derive session key from scope config       |
              |  - Check pause state (queue if paused)        |
              +-----------------------------------------------+
                                    |
                         +----------+----------+
                         |                     |
                   (bridge wired)        (no bridge)
                         |                     |
                         v                     |
              +-----------------------------+  |
              |  ChannelTaskBridge.tryHandle |  |
              |  Routing precedence:        |  |
              |  0. Reserved commands        |  |
              |  1. Thread binding lookup    |  |
              |  2. Rate limit check         |  |
              |  3. Bound-thread routing     |  |
              +-----------------------------+  |
                         |                     |
             +-----------+--+                  |
             |              |                  |
          (handled)   (not handled)            |
             |              |                  |
             v              +--------+---------+
           done                      |
                                     v
                          +---------------------+
                          |  MessageQueue        |
                          |  - Debounce (1s)     |
                          |  - Per-session FIFO  |
                          |  - Global concurrency|
                          |  - Retry + dead-letter|
                          +---------------------+
                                     |
                                     v
                          +---------------------+
                          |  TurnDispatcher      |
                          |  (harness turn)      |
                          +---------------------+
```

### 3.1 Step-by-Step

1. **Raw event arrives** -- Platform-specific: webhook POST (WhatsApp, Google Chat), Pub/Sub pull (Google Chat Space Events), SSE stream event (Signal).

2. **Channel adapter normalizes** -- Each channel implementation parses the raw payload and produces a `ChannelMessage`. Bot-originated messages are filtered at this stage.

3. **Access control** -- WhatsApp, Signal and the Google Chat webhook all run the same `ChannelInboundGate.evaluate` in `dartclaw_core`: DM messages pass through `DmAccessController` (modes: `pairing`, `allowlist`, `open`, `disabled`), group messages pass through `GroupAccessMode` checks, and group messages are then checked against `MentionGating`. The gate is pure -- it returns a `ChannelInboundDecision` naming the admitting or dropping stage, and each channel keeps its own drop logging and pairing effect (WhatsApp and Signal log, Google Chat posts a pairing code into the space). An absent `DmAccessController` or `MentionGating` admits at that stage rather than denying. The Google Chat Space Events Pub/Sub dispatch (§7) runs the same gate with the mention stage off and acks a refused message rather than nacking it.

4. **Mention gating** -- Applied inside the gate, to group messages only. If `requireMention` is true and the bot's JID is not in `mentionedJids` or text patterns, the message is dropped.

5. **Deduplication** -- `MessageDeduplicator` (bounded FIFO set, default capacity 1000) prevents the same message from being processed twice when it arrives via both webhook and Pub/Sub. Keyed on message resource name.

6. **ChannelManager routing** -- Finds the owning channel via `ownsJid()`, derives a session key from `SessionScopeConfig`, and delegates to `ChannelTaskBridge` if wired.

Human channel turns use `PromptScope.primary`; the separate human-input flag makes fresh onboarding eligible independently of transport. Tasks,
scheduled work, workflows, and logical-agent turns use non-conversational scopes and never receive it.

7. **ChannelTaskBridge** -- Evaluates reserved commands, thread bindings, and per-sender rate limits, then routes a bound
   thread when present. Returns `true` if consumed.

8. **MessageQueue** -- If not consumed by the bridge, the message enters a per-session FIFO queue with debounce coalescing (default 1s window), global concurrency cap, retry with exponential backoff, and dead-letter handling.


---

## 4. Thread Binding

Introduced in 0.12 (Crowd Coding), thread binding enables channel threads (e.g., Google Chat threaded conversations) to
be routed to a specific task session. It is opt-in through `features.thread_binding.enabled`; the runtime creates the
binding store and enables binding commands, tools, notifications, and routing only when that key is true.

`supportsThreadBinding(channelType)` in `thread_binding.dart` is the single authority for which channels can hold a
binding, and it answers Google Chat alone — the one channel that stamps `metadata['threadName']`, the sole input to
`extractThreadId`. Every writer honours it: `/bind` keys off `extractThreadId` directly, `task_bind` narrows its
`channel_type` enum through it, `POST /api/tasks/<id>/bindings` rejects on it, and `ThreadBindingStore.load()` drops
(and rewrites away) persisted rows that fail it. A binding the router cannot resolve is never written.

### 4.1 Data Model

```
// packages/dartclaw_core/lib/src/channel/thread_binding.dart
class ThreadBinding {
  final String channelType;    // e.g., 'googlechat'
  final String threadId;       // e.g., 'spaces/AAAA/threads/CCCC'
  final String taskId;
  final String sessionKey;
  final DateTime createdAt;
  final DateTime lastActivity;
}
```

Compound key: `$channelType::$threadId`

### 4.2 ThreadBindingStore

In-memory `Map<String, ThreadBinding>` backed by `thread-bindings.json` with atomic writes (temp file + rename). All lookups are synchronous; only writes touch the filesystem. Key operations: `create`, `lookupByThread`, `lookupByTask`, `updateLastActivity`, `delete`, `deleteByTaskId`, `removeExpiredBindings`, `reconcile(activeTaskIds)`.

### 4.3 ThreadBindingRouter

Stateless routing helper used by `ChannelTaskBridge`. Extracts `threadId` from `message.metadata['threadName']` via `extractThreadId`, looks up the binding in the store, and routes the message to the bound session key if found. `extractThreadId` is also what `/bind` and `/unbind` key on, so the read and write sides cannot disagree about what a binding is keyed by.

### 4.4 ThreadBindingLifecycleManager

Manages automatic cleanup via two mechanisms: (1) **Auto-unbind** -- subscribes to `TaskStatusChangedEvent` on EventBus, removes binding when task reaches a terminal state (accepted, rejected, cancelled, failed). (2) **Idle timeout** -- periodic timer (default 5min interval) removes bindings with `lastActivity` older than `idleTimeout` (default 1hr).

### 4.5 Thread Binding Flow

```
  Inbound message with threadName metadata
                 |
                 v
  ThreadBindingRouter.lookupThreadBinding()
  - Extracts threadId from metadata['threadName']
  - Looks up in ThreadBindingStore
                 |
         +-------+-------+
         |               |
    (binding found)  (no binding)
         |               |
         v               v
  Route to bound     Fall through to
  session key        normal routing
         |
         v
  Update lastActivity
```


---

## 5. Outbound Message Pipeline

### 5.1 Response Flow

`MessageQueue` starts channel typing immediately before dispatching an accepted queued turn and attempts to clear it in guaranteed, bounded cleanup before final delivery, including failures and retries. Transport failures are logged but never prevent the turn or response. Unsupported channels inherit no-op hooks. Google Chat keeps its existing placeholder/reaction flow at ingress because the API has no native typing state.

```
  Agent turn completes
         |
         v
  TurnDispatcher returns response text
         |
         v
  MessageRedactor (optional) -- redact sensitive content
         |
         v
  Channel.formatResponse(text) -- channel-specific formatting
    - WhatsApp: shared Markdown-to-native conversion with WhatsApp links and attribution prefix
    - Signal: Markdown-to-text + native UTF-16 style ranges, style-aware chunking
    - Google Chat: shared Markdown-to-native conversion with Chat links, table normalization, chunk at 4000 chars
    - Web: Markdown rendered client-side with Marked and sanitized by DOMPurify
         |
         v
  Channel.sendMessage(recipientJid, ChannelResponse)
    - WhatsApp: GOWA REST API (sendText, sendMedia, chat presence)
    - Signal: signal-cli JSON-RPC (send, sendTyping)
    - Google Chat: REST API (one queued send for text/card/threaded messages, editMessage)
    - Web: SSE event stream
```

### 5.2 Recipient Resolution

`resolveRecipientId()` determines where to send the response:

```
// packages/dartclaw_core/lib/src/channel/recipient_resolver.dart
String resolveRecipientId(ChannelMessage message) {
  // Priority:
  // 1. metadata['spaceName'] -- Google Chat Space name
  // 2. groupJid -- WhatsApp/Signal group
  // 3. senderJid -- Direct message fallback
}
```

### 5.3 Text Chunking

Large responses are split at smart break points:

```
// packages/dartclaw_core/lib/src/channel/text_chunking.dart
List<String> chunkText(String text, {int maxSize = 4000})
// Break priority: paragraph > line > sentence > word
// Multi-part chunks get "(n/total)" prefix
```

### 5.4 Channel-Specific Outbound Behavior

**Google Chat** -- Core's standard-Markdown converter supplies Chat markup through a Google-specific link wrapper. `ChatCardBuilder` produces Cards v2 payloads for structured notifications (task status, review buttons, error alerts). Typing indicators use placeholder messages or emoji reactions. Native quote-reply support is available in Spaces.

**WhatsApp** -- `ResponseFormatter` uses core's standard-Markdown converter with WhatsApp link rendering and prepends
model/agent attribution. Explicit `attach_media` tool calls deliver workspace files through GOWA multipart API. Native
chat presence uses `POST /send/chat-presence` with `start` / `stop` actions for both DMs and groups, driven by core's
shared `TypingLeaseTracker` with no refresh interval.

**Signal** -- Standard Markdown is parsed into readable text plus signal-cli `textStyle` ranges (`BOLD`, `ITALIC`, `STRIKETHROUGH`, `MONOSPACE`). Style offsets use UTF-16 code units and are remapped when text is chunked. Replies use signal-cli JSON-RPC `send`; DMs use `recipient` and groups use `groupId`. Typing uses bounded `sendTyping` calls through core's shared `TypingLeaseTracker`, refreshed every 10 seconds before Signal's 15-second expiry, with a best-effort STOP before delivery or disconnect.

Scheduled announcements also pass through `Channel.formatResponse`, so interactive and proactive model output use the same platform formatting and chunking rules.


---

## 6. Channel-Task Bridge

The `ChannelTaskBridge` is the integration point between the channel messaging pipeline and the task management subsystem. It lives in `dartclaw_core` to avoid circular dependencies.

```
// packages/dartclaw_core/lib/src/channel/channel_task_bridge.dart
class ChannelTaskBridge {
  Future<bool> tryHandle(ChannelMessage, Channel, {sessionKey, enqueue, ...});
  bool isReservedCommand(String text);
  ThreadBinding? lookupThreadBinding(ChannelMessage message);
}
```

### 6.1 Routing Precedence

`tryHandle()` evaluates the message in strict order:

| Priority | Check | Consumed? |
|----------|-------|-----------|
| 0 | **Reserved text commands** (`/stop`, `/pause`, `/resume`, `/bind`, `/unbind`) | Yes, if recognized |
| 1 | **Thread binding lookup** -- capture bound task/session context | No (sets context) |
| 2 | **Per-sender rate limit** -- `SlidingWindowRateLimiter` check | Yes, if rate-limited |
| 3 | **Bound-thread routing** -- route to bound session via enqueue | Yes, if bound |

If no step consumes the message, `tryHandle()` returns `false` and the message falls through to `MessageQueue` for normal session processing.

### 6.2 Task Origin

When a task is created from a channel message, a `TaskOrigin` record captures the originating context:

```
// packages/dartclaw_core/lib/src/channel/task_origin.dart
class TaskOrigin {
  final String channelType;
  final String sessionKey;
  final String recipientId;
  final String? contactId;
  final String? sourceMessageId;
  final String? senderDisplayName;
  final String? senderId;
  final String? senderAvatarUrl;
}
```

Stored under `task.configJson['origin']` at creation time.


---

## 7. Google Chat Specifics

Google Chat is the most complex channel integration, with two ingest paths and a rich outbound rendering surface.

### 7.1 Ingest Paths

```
  +-------------------+        +-------------------+
  |  Webhook POST     |        |  Pub/Sub Pull     |
  |  (synchronous)    |        |  (async polling)  |
  +--------+----------+        +--------+----------+
           |                            |
           v                            v
  GoogleChatWebhookHandler     CloudEventAdapter
  (dartclaw_google_chat)       (dartclaw_google_chat)
           |                            |
           +------+-----+------+-------+
                  |            |
                  v            v
           MessageDeduplicator
           (prevents double-processing)
                  |
                  v
           ChannelManager.handleInboundMessage()
```

**Webhook** -- Google Chat sends HTTP POST to a configured endpoint. `GoogleChatWebhookHandler` and `GoogleChatJwtVerifier` in `dartclaw_google_chat` authenticate the JWT, parse the payload, apply access control and mention gating, then forward to `ChannelManager`. The handler covers `MESSAGE`, `ADDED_TO_SPACE`, `REMOVED_FROM_SPACE`, `CARD_CLICKED` and `APP_COMMAND`.

**Pub/Sub** -- `PubSubClient` polls a Cloud Pub/Sub subscription for CloudEvent messages delivered by Google Workspace Events API. `CloudEventAdapter` converts these into `ChannelMessage` objects, and `GoogleChatSpaceEventsWiring` runs the inbound gate with the mention stage off before forwarding to `ChannelManager`; a refused message is acked, not nacked. Supports `message.v1.created` and `message.v1.batchCreated` event types.

### 7.2 Authentication

Two auth paths:
- **Service account** (`GcpAuthService`) -- For Chat REST API calls (send messages, manage spaces)
- **User OAuth** (`UserOAuthAuthService`) -- For Workspace Events API subscriptions (requires user-delegated credentials)

### 7.3 Workspace Events Manager

```
// packages/dartclaw_google_chat/lib/src/workspace_events_manager.dart
class WorkspaceEventsManager {
  Future<SubscriptionRecord?> subscribe(String spaceId);
  Future<bool> unsubscribe(String spaceId);
  Future<void> reconcile();  // Startup recovery
}
```

Key behaviors:
- **Proactive renewal** at 75% of TTL (4h for full-data, 7d for name-only subscriptions)
- **Startup reconciliation** -- loads persisted records, verifies via API, recreates expired
- **Space discovery** -- auto-subscribes to discovered spaces during reconciliation
- **409 recovery** -- handles `ALREADY_EXISTS` by fetching the existing subscription
- Persists to `google-chat-subscriptions.json` with atomic writes

### 7.4 Pub/Sub Client

```
// packages/dartclaw_google_chat/lib/src/pubsub_client.dart
class PubSubClient {
  void start();           // Begin pull loop (async)
  Future<void> stop();    // Graceful shutdown
  PubSubHealthStatus get healthStatus;
}
```

- Pull-based polling (default: 2s interval, 100 messages per pull)
- Exponential backoff on transient errors (429, 5xx)
- Permanent error backoff after 10 consecutive failures
- Health status: `healthy` / `degraded` (>=5 consecutive errors) / `unavailable`
- Graceful shutdown with 5s timeout
- Yields to timer queue each iteration to prevent microtask starvation

### 7.5 Cloud Event Adapter

`CloudEventAdapter` converts Pub/Sub messages into `AdapterResult` variants (`MessageResult`, `Filtered`, `LogOnly`, `Acknowledged`). Supports both structured CloudEvent payloads and Pub/Sub binding format (metadata in attributes, data in body).

### 7.6 Outbound: Cards v2

`ChatCardBuilder` produces Cards v2 structured payloads: `taskNotification()` (status + optional review buttons), `errorNotification()`, `alertNotification()` (severity-colored), and `confirmationCard()`.

### 7.7 Slash Commands

`SlashCommandParser` extracts slash commands from both `MESSAGE+slashCommand` and `APP_COMMAND` event shapes. Default command ID mapping: `{1: 'new', 2: 'reset', 3: 'status', 4: 'stop', 5: 'pause', 6: 'resume'}`.

### 7.8 Health Monitoring

`PubSubHealthReporter` bridges Pub/Sub infrastructure health into the `/health` endpoint, reporting status (`healthy`/`degraded`/`unavailable`), last successful pull, consecutive errors, and active subscription count.


---

## 8. WhatsApp Specifics

### 8.1 GOWA Sidecar

WhatsApp integration uses GOWA (Go WhatsApp), a Go binary managed as a subprocess. Spawn, startup-health polling,
teardown and restart policy are shared with the signal-cli sidecar by `SidecarProcessManager`
(`packages/dartclaw_core/lib/src/channel/sidecar_process_manager.dart`), which `GowaManager` extends; the base owns the
state and the primitives while each manager keeps its own `start`/`stop`/`reset` sequence:

```
// packages/dartclaw_whatsapp/lib/src/gowa_manager.dart
class GowaManager extends SidecarProcessManager {
  Future<void> start();         // Spawn + health check
  Future<void> stop();          // Platform-capability termination + bounded reap
  Future<void> sendText(String jid, String text);
  Future<void> sendMedia(String jid, String filePath, {String? caption});
  Future<void> sendChatPresence(String jid, {required bool isTyping});
  Future<GowaStatus> getStatus();
  Future<GowaLoginQr> getLoginQr();
  Future<Map<String, dynamic>> requestPairingCode(String phone);
}
```

Key behaviors:
- **Process termination** -- POSIX uses SIGTERM then SIGKILL; Windows uses one unconditional hard terminate. The policy
  comes from `PlatformCapabilities.posixSignalsAvailable`, and an unconfirmed exit emits a lifecycle warning.
- **External service detection** -- If GOWA is already running on the configured port, attaches rather than spawning
- **Multi-device** -- GOWA v8 requires `X-Device-Id` header; `GowaManager` auto-provisions a device on first start
- **Crash recovery** -- Exponential backoff (2^n seconds, capped at 30s, max 5 attempts), decided once in the base.
  `GowaManager` implements only the scheduling seam, deferring the retry to a later event-loop turn
- **JID capture** -- Parses `LOGIN_SUCCESS` from stderr to capture the paired WhatsApp JID
- **Ban detection** -- Monitors send errors for "banned"/"restricted" signals, auto-disables channel

### 8.2 WhatsApp Channel

```
// packages/dartclaw_whatsapp/lib/src/whatsapp_channel.dart
class WhatsAppChannel extends Channel {
  void handleWebhook(Map<String, dynamic> payload);
}
```

Webhook payload parsing (GOWA v8 format):
- Filters: `event != 'message'`, `is_from_me == true`, empty text
- Normalizes: `from` -> `senderJid`, `chat_id` ending with `@g.us` -> `groupJid`
- Metadata: `pushname` (from_name), `repliedToId`

### 8.3 Media and Response Formatting

`ResponseFormatter` converts standard Markdown to WhatsApp-native markup, prepends attribution, and chunks text to the
configured maximum size. Media delivery is explicit: the registered `attach_media` tool applies `WorkspacePathGuard`,
which resolves symlinks on both candidate and workspace root and refuses traversal or outside-workspace paths. The tool
takes no recipient; `DeliveryService.deliverMedia` resolves the owner's active DM targets from channel sessions.

### 8.4 JID Format

- Individual: `PHONENUMBER@s.whatsapp.net`
- Group: `GROUPID@g.us`


---

## 9. Signal Specifics

### 9.1 signal-cli Sidecar

Signal uses signal-cli running in HTTP daemon mode. It shares the GOWA sidecar's spawn, startup-health, teardown and
restart machinery through `SidecarProcessManager`
(`packages/dartclaw_core/lib/src/channel/sidecar_process_manager.dart`), extending it and keeping its own
SSE-aware `start`/`stop`/`reset` sequence:

```
// packages/dartclaw_signal/lib/src/signal_cli_manager.dart
class SignalCliManager extends SidecarProcessManager {
  Future<void> start();    // Spawn + health check + SSE connect
  Future<void> stop();
  Future<void> sendMessage(String recipient, String text, {required bool isGroup});
  Future<void> sendTyping(String recipient, {required bool isGroup, required bool isTyping});
  Future<String?> getLinkDeviceUri({String deviceName});  // QR linking
  Future<SignalRegistrationState> registrationState();
  Stream<Map<String, dynamic>> get events;  // SSE event stream
}
```

Key behaviors:
- **SSE event stream** -- Connects to `/api/v1/events` for real-time inbound message notification
- **JSON-RPC** -- All commands sent via JSON-RPC 2.0 to `/api/v1/rpc`
- **Device linking** -- `getLinkDeviceUri()` starts a link session, caches the URI, and long-polls `finishLink` (5-minute timeout) until the user confirms on their phone
- **Post-start registration** -- The daemon uses `--receive-mode on-connection`; successful registration reconnects SSE so accounts added after daemon startup immediately begin receiving
- **Crash recovery** -- The same base decision as GOWA (max 5 attempts, 30s cap); `SignalCliManager` implements the
  scheduling seam by starting the retry inline, and `stop()` bumps the lifecycle generation before taking the lock
- **SSE reconnection** -- Single-flight guard prevents concurrent reconnect attempts

### 9.2 Signal Channel

```
// packages/dartclaw_signal/lib/src/signal_channel.dart
class SignalChannel extends Channel {
  // Listens to SignalCliManager.events, parses envelopes, routes to ChannelManager
}
```

Envelope parsing:
- `sourceNumber` (E.164 phone) preferred over `sourceUuid` (ACI UUID)
- `SignalSenderMap` for UUID-to-phone normalization
- `dataMessage.message` -> text, `dataMessage.groupInfo.groupId` -> group

### 9.3 Sender Map

```
// packages/dartclaw_signal/lib/src/signal_sender_map.dart
class SignalSenderMap {
  String resolve({String? sourceNumber, String? sourceUuid});
}
```

Signal's sealed-sender protocol means unknown senders appear as UUID only. The sender map caches UUID-to-phone associations so that UUID-only messages resolve to stable phone numbers for consistent session key derivation. Persisted to `signal-sender-map.json`.

### 9.4 DM Access

Signal gates inbound events through core's shared `ChannelInboundGate` and core's `GroupAccessMode` / `MentionGating` types; it holds no gating types of its own.

Sealed-sender complication: Signal's own call site reacts to the gate's DM-denied decision by also trying `metadata['sourceUuid']` as an alternate identifier when the primary `senderJid` is not in the allowlist. If the UUID matches, the phone number is automatically added to the allowlist for future lookups. The shared gate performs no such lookup, so WhatsApp and Google Chat get no alternate-identity resolution and no allowlist self-heal.


---

## 10. Crowd Coding Integration (0.12)

Multi-user collaborative agent steering via channel Spaces. Adds governance ordering, per-sender rate limiting, emergency controls, and pause handling on top of the bridge pipeline.

### 10.1 Governance Ordering

Governance checks (rate limiting, token budget) are applied **before** thread binding routing in the `ChannelTaskBridge` pipeline. This ensures that rate-limited users cannot bypass limits by posting in a bound thread.

### 10.2 Per-Sender Rate Limiting

`SlidingWindowRateLimiter` in `ChannelTaskBridgeSupport`:
- Configured via `governance.rate_limits.per_sender` in YAML
- Admin senders are exempt (checked via `isAdmin` callback)
- Reserved text commands bypass rate limiting; review requests are ordinary model turns and receive no exemption
- Rate-limited senders receive a polite rejection with the limit info

### 10.3 Emergency Controls

Reserved commands parsed from channel messages:
- `/stop` -- Abort all turns, cancel running tasks (admin-only)
- `/pause` -- Queue incoming messages in-memory, structured per-sender concatenation drain
- `/resume` -- Flush queued messages back to normal processing

These bypass:
- Rate limiting (always processed)
- Pause state (always processed)

Implementation: `ReservedCommandDispatch` callback in `ChannelTaskBridge`, with pause state managed by `PauseController` in `dartclaw_runtime` injected via callbacks to keep `dartclaw_core` free of server dependencies.

### 10.4 Pause Handling

When the agent is paused:
1. Reserved commands still execute
2. All other messages are queued via `_enqueueForPause` callback
3. A pause acknowledgment is sent to the sender: "Agent is paused by {admin}. Your message has been queued."
4. On resume, queued messages are drained in structured per-sender groups


---

## 11. Session Scoping

Session keys determine which agent conversation receives a message. The `SessionScopeConfig` system provides flexible scoping with per-channel overrides.

### 11.1 Scope Modes

**DM Scoping** (`DmScope`):
| Mode | Session Key | Use Case |
|------|-------------|----------|
| `shared` | Single shared session | All DMs in one conversation |
| `perContact` | Per sender (cross-channel) | One conversation per person |
| `perChannelContact` | Per (channel, sender) | Default. Isolates WhatsApp Alice from Signal Alice |

**Group Scoping** (`GroupScope`):
| Mode | Session Key | Use Case |
|------|-------------|----------|
| `shared` | Per group | Default. One conversation per group/space |
| `perMember` | Per (group, sender) | Isolated per-member conversations within a group |

### 11.2 Per-Channel Overrides

```
// packages/dartclaw_kernel/lib/src/session_scope_config.dart
class SessionScopeConfig {
  final DmScope dmScope;           // Global default
  final GroupScope groupScope;     // Global default
  final Map<String, ChannelScopeConfig> channels;  // Per-channel overrides
  final String? model;             // Model override for this scope
  final String? effort;            // Effort override for this scope
}
```

`ChannelManager.deriveSessionKey()` resolves the effective scope by checking per-channel overrides first, then falling back to global defaults.

### 11.3 Session Key Generation

`SessionKey` static factories in `dartclaw_kernel`: `dmShared()`, `dmPerContact(peerId)`, `dmPerChannelContact(channelType, peerId)`, `groupShared(channelType, groupId)`, `groupPerMember(channelType, groupId, peerId)`.


---

## 12. Configuration

### 12.1 Channel Config

Top-level `channels:` YAML section with `debounce_window_ms`, `max_queue_depth`, `retry_policy` (max_attempts, base_delay_ms, jitter_factor), and per-channel subsections (`whatsapp`, `signal`, `googlechat`). Typed models live in `dartclaw_kernel/lib/src/channel_config.dart`; per-channel sections are resolved by `resolveChannelConfig` in `dartclaw_runtime`.

### 12.2 DM Access and Groups

Per-channel `dm_access` mode (`pairing` | `allowlist` | `open` | `disabled`) with `allowlist` entries. Group access via `group_access` (`allowlist` | `open` | `disabled`) with `group_ids`.

### 12.3 Session Scope

`session_scope` section: `dm_scope` (`shared` | `per-contact` | `per-channel-contact`), `group_scope` (`shared` | `per-member`), with per-channel overrides under `channels:`.

### 12.4 Governance

`governance.rate_limits.per_sender` (`messages`, `window`, and queue bounds) and
`governance.budget` (`daily_tokens`, `action`, and `timezone`). Zero message, turn, or token limits disable the
corresponding bound.


---

## 13. Message Queue

The `MessageQueue` is the final stage before agent turn dispatch. Key parameters: `debounceWindow` (default 1s), `maxConcurrentTurns` (default 3), `maxQueueDepth` (default 100), `maxQueued` (per-sender limit, 0 = unlimited), `queueStrategy` (`fifo` or `fair`).

**Debounce** -- Messages from the same `(sessionKey, senderJid)` within the debounce window are coalesced into a single queue entry with concatenated text.

**Queue strategies** -- `fifo` is strict per-session ordering; `fair` uses round-robin sender rotation to prevent a single user from monopolizing the queue.

**Concurrency and backpressure** -- Global concurrency cap with `Completer`-based wait queue. Per-session FIFO (one turn at a time). Per-sender queue limit (admin-exempt). Queue depth limit per session -- excess messages receive a "busy" response. `BudgetExhaustedError` triggers a polite budget notification instead of retry.

**Retry and dead-letter** -- Failed turns retry with jittered backoff (`baseDelay * attempt * (1 + random * jitterFactor)`). After `maxAttempts` (default 3), the message is dead-lettered and the sender receives an error notification.

**Channel feedback** -- Native typing-capable channels override `Channel.startTyping` / `stopTyping` by delegating to core's `TypingLeaseTracker` (`src/channel/typing_lease_tracker.dart`), which owns per-recipient lease counting, update serialization, the single START retry and the shutdown latch for every adopter; WhatsApp and Signal differ only in the three constructor arguments -- sendability predicate, transport call and refresh interval. The queue brackets every dispatched turn with these best-effort calls. `ChannelFeedbackStrategy` remains the richer progress-feedback interface used by Google Chat. `NoFeedbackStrategy` is its default no-op.


---

## 14. Package Dependencies

```
  dartclaw_kernel
  (ChannelType, ChannelConfig, SessionScopeConfig, DmScope, GroupScope,
   RetryPolicy, SessionKey)
       |
       v
  dartclaw_core
  (Channel, ChannelMessage, ChannelResponse, ChannelManager, MessageQueue,
   MessageDeduplicator, ChannelInboundGate, MentionGating, DmAccessController,
   standard Markdown conversion, ThreadBinding,
   ThreadBindingStore, ThreadBindingRouter, ThreadBindingLifecycleManager,
   ChannelTaskBridge,
   RecipientResolver, ChannelFeedbackStrategy, TurnProgressEvent)
       |
       +---> dartclaw_whatsapp
       |     (WhatsAppChannel, GowaManager, WhatsAppConfig,
       |      ResponseFormatter)
       |     deps: dartclaw_core, dartclaw_kernel
       |
       +---> dartclaw_signal
       |     (SignalChannel, SignalCliManager, SignalConfig,
       |      SignalSenderMap)
       |     deps: dartclaw_core, dartclaw_kernel
       |
       +---> dartclaw_google_chat
       |     (GoogleChatChannel, GoogleChatConfig, GoogleChatRestClient,
       |      ChatCardBuilder, CloudEventAdapter, PubSubClient,
       |      WorkspaceEventsManager, SlashCommandParser,
       |      GoogleChatWebhookHandler, GoogleChatJwtVerifier,
       |      PubSubHealthReporter, Markdown link/plain-text wrappers)
       |     deps: dartclaw_core, dartclaw_kernel, shelf
       |
       v
  dartclaw_runtime
  (webhookRoutes, SlashCommandHandler, PauseController, ChannelWiring)
  deps: dartclaw_core, dartclaw_whatsapp, dartclaw_signal,
        dartclaw_google_chat, dartclaw_kernel
```

Dependency direction is strictly downward: platform packages depend on core, never on each other. The server package depends on all platform packages for webhook routing and lifecycle management.

### 14.1 Avoiding Circular Dependencies

- `ChannelTaskBridge` accepts reserved-command and enqueue callbacks rather than importing `dartclaw_runtime` types
- `PauseController` state is injected into `ChannelManager` via function callbacks (`isPaused`, `enqueueForPause`, `pausedByName`)
- `BudgetExhaustedError` is an abstract interface in `dartclaw_core` implemented by `BudgetExhaustedException` in `dartclaw_runtime`


---

## 15. Webhook and Server Integration

### 15.1 Webhook Routes

```
// packages/dartclaw_runtime/lib/src/api/webhook_routes.dart
Router webhookRoutes({
  WhatsAppChannel? whatsApp,
  String? webhookSecret,
  GoogleChatWebhookHandler? googleChat,
  EventBus? eventBus,
  List<String> trustedProxies,
});
```

- `POST /webhook/whatsapp` -- GOWA webhook (optional `secret` query parameter)
- `POST {config.webhookPath}` -- Google Chat webhook (JWT-verified)

Webhook routes are excluded from gateway auth -- external services call them directly.

### 15.2 Google Chat Webhook Handler

`GoogleChatWebhookHandler` in `dartclaw_google_chat` handles the full event lifecycle: `MESSAGE` (parse, access control, dedup, typing indicator, route), `ADDED_TO_SPACE` (welcome + auto-subscribe), `REMOVED_FROM_SPACE` (unsubscribe), `CARD_CLICKED` (review buttons), and `APP_COMMAND` (slash commands). It also normalizes Workspace Add-on format to legacy Chat API format. `dartclaw_runtime` mounts it and supplies the runtime-owned `SlashCommandHandler` through the channel's executor interface.


---

## Cross-References

- [System Architecture](system-architecture.md) -- 2-layer model, component overview, package DAG
- [Security Architecture](security-architecture.md) -- Guard pipeline applied to channel messages, DM access control, webhook secret validation
- [Data Model](data-model.md) -- `thread-bindings.json` persistence, session key derivation, governance state
- [Control Protocol](control-protocol.md) -- How channel messages reach the harness via turn dispatch
- [Workflow Architecture](workflow-architecture.md) -- How channel-triggered tasks enter the workflow system
- [Architecture Governance](architecture-governance.md) -- Fitness functions that enforce channel package boundaries
