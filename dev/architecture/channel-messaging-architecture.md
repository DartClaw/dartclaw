# DartClaw Channel Messaging Architecture

How inbound messages from WhatsApp, Signal, Google Chat, Slack, and the Web UI are normalized, routed, and delivered back through channel-specific adapters.

**Current through**: 0.28 threaded-notification capability and workflow run posts (Google Chat and Slack thread; run and task thread bindings), Slack adapter over Socket Mode (thread-in-session-key, ephemeral reserved-command replies, reserved-command refusal audit), turn-cap waits and reloadable queue cap; 0.25.2 channel agent binding.

---

## 1. Overview and Design Philosophy

DartClaw supports five messaging channels as entry points for human-to-agent interaction:

| Channel | Transport | Sidecar / Integration | Package |
|---------|-----------|----------------------|---------|
| **WhatsApp** | GOWA webhook | Go binary (`gowa`) | `dartclaw_whatsapp` |
| **Signal** | signal-cli SSE | External binary (`signal-cli`) | `dartclaw_signal` |
| **Google Chat** | REST API + Pub/Sub | Direct HTTP (no sidecar) | `dartclaw_google_chat` |
| **Slack** | Socket Mode WebSocket + Web API | Direct HTTP/WebSocket (no sidecar) | `dartclaw_slack` |
| **Web UI** | Direct HTTP / SSE | Built into `dartclaw_runtime` | `dartclaw_runtime` |

Three principles govern channel design:

1. **Normalize early** -- Every channel adapter converts platform-specific payloads into a single `ChannelMessage` model as close to the ingress point as possible. Downstream pipeline stages never see WhatsApp JIDs, Google Chat space names, or Signal envelopes directly.

2. **Outpost pattern** -- WhatsApp and Signal use external binaries (GOWA and signal-cli) managed as subprocesses. No shared runtime, no dependency contamination. The Dart host communicates with these sidecars via their native REST/RPC APIs.

3. **Core abstractions, platform packages** -- The abstract `Channel` base class, `ChannelManager`, `MessageQueue`, thread binding, and the `ChannelTaskBridge` live in `dartclaw_core`. Per-platform adapters (`WhatsAppChannel`, `SignalChannel`, `GoogleChatChannel`, `SlackChannel`) live in dedicated packages that depend on core. The Web channel is served directly by `dartclaw_runtime`.


---

## 2. Channel Abstraction Model

### 2.1 Core Types

All channel types are defined in `dartclaw_kernel`:

```
// packages/dartclaw_kernel/lib/src/channel_type.dart
enum ChannelType { web, whatsapp, signal, googlechat, slack }
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
- **Slack**: `spaceName` (the conversation ID, `D…` for a DM), `threadId`, `senderDisplayName`, `messageTs`

The `senderDisplayName` getter checks metadata keys in priority order: `senderDisplayName` (Google Chat, Slack), `pushname` (WhatsApp), `sourceName` (Signal).

`threadId` (`threadIdMetadataKey` in core) is the one platform-neutral thread key. An adapter that has threads stamps it on the inbound message; `ChannelManager.deriveSessionKey` adds it to the DM and group session key under every scope, so each thread is its own session; and `MessageQueue`, the reserved-command handler and the bridge's rate-limit and pause replies copy it onto every reply to that message, so the adapter posts the reply into the same thread. A message without it derives the key it always did and its replies carry no new metadata. It is distinct from `threadName`, the Google Chat key that channel's `ThreadedNotifications.extractThread` reads (§4).

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
- **Slack**: a user, channel or DM ID, `[UWCGD][A-Z0-9]+`; `ChannelManager` also tries `metadata['spaceName']`, so the DM channel ID finds the adapter

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

The full inbound flow from raw platform event to agent turn. Access control runs on every path: the WhatsApp webhook, Signal SSE, the Slack envelope dispatch and the Google Chat webhook run the gate in full, and the Google Chat Space Events Pub/Sub dispatch runs it with the mention stage off (un-mentioned space traffic is that feature's purpose) before reaching `ChannelManager.handleInboundMessage`:

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

1. **Raw event arrives** -- Platform-specific: webhook POST (WhatsApp, Google Chat), Pub/Sub pull (Google Chat Space Events), SSE stream event (Signal), Socket Mode envelope (Slack).

2. **Channel adapter normalizes** -- Each channel implementation parses the raw payload and produces a `ChannelMessage`. Bot-originated messages are filtered at this stage.

3. **Access control** -- WhatsApp, Signal, Slack and the Google Chat webhook all run the same `ChannelInboundGate.evaluate` in `dartclaw_core`: DM messages pass through `DmAccessController` (modes: `pairing`, `allowlist`, `open`, `disabled`), group messages pass through `GroupAccessMode` checks, and group messages are then checked against `MentionGating`. The gate is pure -- it returns a `ChannelInboundDecision` naming the admitting or dropping stage, and each channel keeps its own drop logging and pairing effect (WhatsApp and Signal log, Google Chat posts a pairing code into the space). An absent `DmAccessController` or `MentionGating` admits at that stage rather than denying. The Google Chat Space Events Pub/Sub dispatch (§7) runs the same gate with the mention stage off and acks a refused message rather than nacking it.

4. **Mention gating** -- Applied inside the gate, to group messages only. If `requireMention` is true and the bot's JID is not in `mentionedJids` or text patterns, the message is dropped.

5. **Deduplication** -- `MessageDeduplicator` (bounded FIFO set, default capacity 1000) prevents the same message from being processed twice when it arrives via both webhook and Pub/Sub. Keyed on message resource name.

6. **ChannelManager routing** -- Finds the owning channel via `ownsJid()`, derives a session key from `SessionScopeConfig`, and delegates to `ChannelTaskBridge` if wired.

Human channel turns use `PromptScope.primary`; the separate human-input flag makes fresh onboarding eligible independently of transport. Tasks,
scheduled work, workflows, and logical-agent turns use non-conversational scopes and never receive it.

7. **ChannelTaskBridge** -- Evaluates reserved commands, thread bindings, and per-sender rate limits, then routes a bound
   thread when present. Returns `true` if consumed.

8. **MessageQueue** -- If not consumed by the bridge, the message enters a per-session FIFO queue with debounce coalescing (default 1s window), global concurrency cap, and reply-delivery retry with backoff and dead-letter handling.


---

## 4. Thread Binding

Introduced in 0.12 (Crowd Coding), thread binding lets a channel thread route to a specific task session; since 0.28 a
binding can also hold the thread a workflow run posts into. Task binding is opt-in through
`features.thread_binding.enabled`: the binding commands, tools, task notification threading and inbound routing exist only
when that key is true. The live `ThreadBindingStore` itself is created when that key is true or
`workflow.chat_notifications` is configured, so `chat_notifications` alone gives one thread per run and no task binding
(`ChannelWiring.taskThreadBindingStore` is the store only while the flag is on, and every task-binding reader and
writer takes that getter).

`Channel.threadedNotifications` (`ThreadedNotifications`, `threaded_notifications.dart`) is the single declaration that a
channel threads; a channel without it cannot hold a binding. `ChannelManager.threadedNotificationsFor(channelType)`
resolves it by registered channel type name (null when unregistered or without the capability), and nothing in core names
a platform's thread key. Its operations:

| Operation | Role |
|-----------|------|
| `extractThread(metadata)` | Thread identity of an inbound message, or null. Google Chat reads `metadata['threadName']`; Slack builds `<conversationId>:<thread_ts>` from `metadata['spaceName']` and `metadata['threadId']`, so the identity is unique across conversations |
| `render(ChannelNotification)` | Turns a semantic notification (kind `task` or `run`, id, text, title, status, body, error, requestedBy, facts, timestamps, `reviewActions`) into the channel's native card or blocks beside its plain text. Google Chat: `ChatCardBuilder.taskNotification` and `runNotification`; Slack: Block Kit sections |
| `sendToNewThread(recipient, response, threadKey:)` | First message of a new thread; returns `ThreadedPost(threadId, messageId)` or null |
| `sendToThread(recipient, response, threadId:)` | Message into an existing thread; same return |

Slack's two sends also record the adapter's thread participation, so a mention-free reply in a thread the bot opened is
admitted. WhatsApp and Signal declare nothing and receive plain `sendMessage` calls. Every writer reads the
capability: `/bind` and `/unbind` (reserved command handler), `task_bind` (its `channel_type` enum is the registered
channels that declare it, read at each call), and `POST /api/tasks/<id>/bindings` (400 for a channel type without it).
A thread held by a run binding answers a conflict naming the run in all four writers, and `DELETE` on the bindings route
refuses it. A binding the router cannot resolve is never written.

### 4.1 Data Model

```
// packages/dartclaw_core/lib/src/channel/thread_binding.dart
enum ThreadBindingKind { task, run }

class ThreadBinding {
  final String channelType;    // e.g., 'googlechat', 'slack'
  final String threadId;       // the capability's identity: 'spaces/AAAA/threads/CCCC', 'C0123:1712345678.000100'
  final ThreadBindingKind kind;
  final String targetId;       // task ID or run ID
  final String? sessionKey;    // task bindings only
  final DateTime createdAt;
  final DateTime lastActivity;
}
```

Constructors are `ThreadBinding.task(taskId:, sessionKey:, ...)` and `ThreadBinding.run(runId:, ...)`. JSON keeps
`taskId` for a task, uses `runId` for a run, and adds `kind`; a persisted row without `kind` reads as a task.

Compound key: `$channelType::$threadId`

### 4.2 ThreadBindingStore

In-memory `Map<String, ThreadBinding>` backed by `thread-bindings.json` with atomic writes (temp file + rename). All lookups are synchronous; only writes touch the filesystem. Key operations: `create`, `lookupByThread`, `lookupByTask`, `lookupByRun`, `updateLastActivity`, `delete`, `deleteByTaskId`, `deleteByTarget(kind, id)`, `removeExpiredBindings`, `reconcile({activeTaskIds, activeRunIds})`.

`load()` keeps every well-formed row: the store loads before any channel registers, so it cannot tell a row nothing will resolve from one whose channel is still starting. Rows nothing can resolve are retired by the idle sweep (task bindings) or `reconcile`. `removeExpiredBindings` skips run bindings, because a run's thread lives as long as the run and a run can sit at an approval longer than the idle timeout.

### 4.3 ThreadBindingRouter

Stateless routing helper used by `ChannelTaskBridge.lookupThreadBinding(message, channel)`. Extracts the thread through the owning channel's `threadedNotifications.extractThread`, looks up the binding in the store, and routes the message to the bound session key if found. It routes task bindings only: a run binding holds a thread for the run's posts and never answers. `/bind` and `/unbind` extract through the same capability, so the read and write sides cannot disagree about what a binding is keyed by.

Bound-message routing awaits the activity-timestamp write before enqueuing the message.

### 4.4 ThreadBindingLifecycleManager

Manages automatic cleanup via two mechanisms: (1) **Auto-unbind** -- subscribes to `TaskStatusChangedEvent` on EventBus, removes the task binding when the task reaches a terminal state (accepted, rejected, cancelled, failed). It unbinds tasks only; a run's binding is deleted by `WorkflowRunNotificationSubscriber` after the run's terminal post. (2) **Idle timeout** -- periodic timer (default 5min interval) removes task bindings with `lastActivity` older than `idleTimeout` (default 1hr); run bindings are exempt.

The manager serializes its cleanup operations. Runtime shutdown awaits `dispose()`, which cancels new event/timer work and drains pending persistence. Persistence exceptions are logged without blocking later cleanup.

At startup `reconcileThreadBindings` (`service_wiring_notifications.dart`) passes the non-terminal task IDs (`TaskService.list`) and non-terminal run IDs (`WorkflowService.list`) to `ThreadBindingStore.reconcile`, so bindings of terminal or unknown tasks and runs are dropped and those of active ones are kept.

### 4.5 Thread Binding Flow

```
  Inbound message in a thread
                 |
                 v
  ThreadBindingRouter.lookupThreadBinding(message, channel)
  - Extracts the thread through channel.threadedNotifications
  - Looks up in ThreadBindingStore; a run binding does not answer
                 |
         +-------+-------+
         |               |
    (task binding)   (none)
         |               |
         v               v
  Route to bound     Fall through to
  session key        normal routing
         |
         v
  Update lastActivity
```

### 4.6 Notification Delivery

`TaskNotificationSubscriber` and `WorkflowRunNotificationSubscriber` (both in `dartclaw_runtime/lib/src/task/`) build a `ChannelNotification` and deliver it through the shared `ChannelNotificationDelivery`. The helper offers a plain send, a new-thread send and an existing-thread send; it imports no channel package and branches on no `ChannelType`. A new-thread send that returns no thread identity falls back to one plain send and one warning per subject (task or run). A failed send into an existing thread is dropped with one warning per subject and never repeated as plain text. A delivery never throws into its caller.

**Task notifications.** A task with a `TaskOrigin` posts on key status changes. A channel that declares the capability renders natively even with `features.thread_binding.enabled` off (Google Chat keeps its cards). With the flag on, the first (queued to running) notification opens a thread keyed `task-<id>` and writes `ThreadBinding.task`; later notifications post into the bound thread. A channel without the capability gets plain `sendMessage`.

**Run notifications.** `WorkflowRunNotificationSubscriber` listens to `WorkflowLifecycleEvent`s and posts:

| Post | Trigger |
|------|---------|
| started | `pending` to `running` only, never a resume or retry |
| awaiting approval | `WorkflowApprovalRequestedEvent`; the approval message is cut at 1,000 characters, plus a link `<server.base_url>/workflows/<runId>` when `base_url` is set |
| finished | completed or cancelled |
| failed | failed; the error is cut at 1,000 characters |
| step completed | optional, one line per step |

Which of these post follows `workflow.chat_notifications.events` (default: the first four). Destination, first match wins:

1. Origin surface `unknown`, or the run is missing: nothing.
2. Chat origin (channel type and recipient recorded) on a channel without the capability: plain posts to the origin recipient.
3. Chat origin on a threaded channel with a recorded thread: posts into that thread. No new thread, no binding, nothing to the configured channel.
4. Otherwise `workflow.chat_notifications`: one new thread per run (keyed `run-<id>`) when that channel threads, tracked by a `ThreadBinding.run` that is deleted after the terminal post; plain posts when it does not. Nothing when unconfigured.

A chat-origin run on a threaded channel that recorded no thread falls to the configured channel. Handling is chained per run ID, so one run's posts keep event order and the first opens the thread before a later one looks for it; other runs never wait. A failed post never blocks the run.

`wireRunNotifications` (`service_wiring_notifications.dart`) builds the subscriber after the channels register and validates `workflow.chat_notifications` against them: a channel that is not registered, or a recipient it does not own, warns and leaves runs started outside chat with nowhere to post.

The inbound thread recorded for a turn (`TurnProvenance.channel(threadId:)`, hence a run's origin) is read through the originating channel's capability, so a Slack-started `workflow_run` records the Slack identity; a channel without the capability records none.


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
    - Slack: shared Markdown-to-native conversion with `<url|label>` links after `&`, `<` and `>` are escaped, chunk at 4000 chars
    - Web: Markdown rendered client-side with Marked and sanitized by DOMPurify
         |
         v
  Channel.sendMessage(recipientJid, ChannelResponse)
    - WhatsApp: GOWA REST API (sendText, sendMedia, chat presence)
    - Signal: signal-cli JSON-RPC (send, sendTyping)
    - Google Chat: REST API (one queued send for text/card/threaded messages, editMessage)
    - Slack: Web API `chat.postMessage` into the reply's thread, or the ephemeral `response_url` answer to a slash command
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

Reply metadata. A reply to an inbound message carries `sourceMessageId` (the message's `id`) and, when the message had one, `threadId`. `MessageQueue` sets both on answers and on its apology, budget, busy and queue-full replies; the reserved-command handler sets both on every reply, so an adapter can tell which message a reply answers and where it belongs. Slack uses `sourceMessageId` to turn the reply to a slash command into the ephemeral `response_url` answer and `threadId` as `thread_ts`; the other channels ignore `threadId`, and Google Chat's reply to a reserved text command now carries `sourceMessageId`, which it already read for placeholder replacement and native quoting.

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

**Slack** -- See §9A. Replies are mrkdwn chunked at 4,000 characters, posted into the thread of the message they answer, at least one second apart per channel; a failed chunk is logged and dropped (the channel never throws a send failure, so the queue's delivery retry never runs for it).

Scheduled announcements also pass through `Channel.formatResponse`, so interactive and proactive model output use the same platform formatting and chunking rules.


---

## 6. Channel-Task Bridge

The `ChannelTaskBridge` is the integration point between the channel messaging pipeline and the task management subsystem. It lives in `dartclaw_core` to avoid circular dependencies.

```
// packages/dartclaw_core/lib/src/channel/channel_task_bridge.dart
class ChannelTaskBridge {
  Future<bool> tryHandle(ChannelMessage, Channel, {sessionKey, enqueue, ...});
  bool isReservedCommand(String text);
  ThreadBinding? lookupThreadBinding(ChannelMessage message, Channel channel);
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

A non-admin sender's reserved command is refused by the shared `ReservedCommandHandler`, on every channel, and each refusal writes one `AuditEntry` through the guard audit owner (`GuardAuditLogger.writeEntry`) before the refusal reply is sent: guard `ReservedCommand`, hook `channel_command`, verdict `block`, decision `deny`, the command name without its arguments as `tool`, the channel type name as `channel`, and the sender ID as `peerId` and `principal`. The logger reaches the handler through `ChannelWiring`'s `auditLogger` constructor parameter (the instance `SecurityWiring` uses); a missing logger writes nothing, a failing write is logged as a warning, and the refusal is always sent. Admin commands write no entry.

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

`ChatCardBuilder` produces Cards v2 structured payloads: `taskNotification()` (status + optional review buttons), `runNotification()` (workflow run lifecycle post), `errorNotification()`, `alertNotification()` (severity-colored), and `confirmationCard()`.

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

## 9A. Slack Specifics

### 9A.1 Transport and envelope dispatch

`SocketModeClient` (`packages/dartclaw_slack/lib/src/socket_mode_client.dart`) opens `apps.connections.open` with the app-level token, connects a WebSocket to the returned single-use URL at once (never logged), acknowledges every envelope by its ID before doing anything with it, and reconnects with backoff (1 s doubling to 60 s, a warning from the third consecutive failure, immediately on `disconnect` with `refresh_requested`). It exposes its state and last connect time for diagnostics. Slack does not replay an envelope after a disconnect, so the acknowledgement comes first and processing runs afterwards, one envelope at a time in arrival order.

Every envelope, whatever transport delivered it, becomes a `SlackEnvelope` (kind: event, slash command, block action, view submission, unknown; plus the decoded payload) and enters one `SlackEnvelopeDispatch`. The dispatch knows no socket: features register a handler per kind, an unhandled kind is logged at debug and dropped, and a failing handler is logged and swallowed. `SlackChannel` registers the event and slash-command handlers; interactions are acknowledged and dropped until a feature registers for them.

### 9A.2 Inbound events

`SlackChannel` normalizes `message` events into `ChannelMessage`s: sender is the user ID, group is the channel ID (null for a DM, `channel_type: im`), `metadata['spaceName']` is the conversation ID (so `resolveRecipientId` yields the `D…` or `C…` ID), `metadata['threadId']` is `thread_ts` or, for a top-level message, the message's own `ts`. Mentions come from the `user` elements of the event's blocks, or from `<@U…>` text tokens when there are no blocks; the bot's own token is removed from the turn text and `&amp;`, `&lt;`, `&gt;` are decoded. The sender name comes from `users.info`, cached for the process lifetime, falling back to the user ID.

Dropped without a turn: any message carrying `bot_id` (this app's own included), any subtype other than a plain message, `file_share` or `thread_broadcast` (so edits, deletions and joins), and unknown event types. An `app_mention` event is acknowledged and ignored: the same message arrives as a `message` event, which alone carries `files`, so exactly one turn runs per message.

Access runs through `ChannelInboundGate` as on the other channels. A reply in a channel thread needs no mention when the bot took part in the thread: participation is a bounded in-memory record (the bot was mentioned in the thread or posted into it), and a miss, such as after a restart, asks `conversations.replies` once per thread and remembers the answer.

### 9A.3 Slash commands

The five reserved commands are Slack slash commands. The envelope is acknowledged with no body, becomes a `ChannelMessage` whose text is `/command args` (no thread: a slash payload carries none, so `/bind` and `/unbind` give the handler's "not in a thread" refusal), and passes access gating but not mention gating. The adapter keeps the command's `response_url` by message ID, so the handler's reply, which carries that ID as `sourceMessageId`, is delivered as an ephemeral `response_url` answer. `stop!` typed in a thread or DM is an ordinary message and its reply is posted into that thread.

### 9A.4 Outbound

`formatResponse` converts Markdown to mrkdwn through the shared converter after escaping `&`, `<` and `>`, so only the links the converter builds contain `<`; text over 4,000 characters is chunked with `chunkNativeChatMarkup`. `SlackWebApiClient` posts with `thread_ts`, keeps posts to one channel at least one second apart, retries an HTTP 429 once after `Retry-After` (bounded at 60 s), and puts only the method and Slack's error code into an error: never a token, a header, a response URL or the Socket Mode ticket URL. The channel logs and drops a chunk Slack refuses. `SlackChannel.threadedNotifications` (`slack_threaded_notifications.dart`) is the §4 capability: it posts Block Kit sections, identifies a thread as `<conversationId>:<thread_ts>`, and records each thread it opens or posts into as bot participation.

### 9A.5 Wiring and configuration

`channels.slack` is parsed by `SlackConfig.fromYaml` through the shared channel config path. Tokens are never configured inline: `bot_token_credential` and `app_token_credential` name `credentials` entries, and `loadDartclawConfig` refuses an enabled section with a literal or unresolvable reference, a missing reference, both access modes disabled or a malformed channel or user ID (`refuseUnusableSlackConfig`). `ChannelWiring` builds the channel from the resolved tokens and includes its allowlist rows in the one `GroupConfigResolver`, so a row's `agent` binds the thread's session to that agent and its turns run through the bound-agent dispatch. `connect()` verifies the bot token with `auth.test` and throws on refusal, then starts Socket Mode in the background, so a transient outage never blocks the other channels. Slack sessions are per thread, so `GroupSessionInitializer` pre-creates none. `dm_access` defaults to `allowlist`: `pairing` creates a code, but the settings page and the allowlist API do not know Slack yet, so nothing confirms it.


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

The key's `agentId` component comes from the message's structured allowlist row: `ChannelManager.resolveRow()` asks the one `GroupConfigResolver` for the group row by `groupJid`, else the sender's DM row by `senderJid`, and the row's `agent` (default `main`) is passed to every `SessionKey` factory, so `agent: <name>` on a row opens that agent's session under the unchanged scope rule (`dm_scope: shared` means one session per agent lane). Both dispatch sites in `ChannelWiring` resolve the same row for `resolveChannelTurnOverrides` (row → per-channel → scope → crowd) and, when the row is bound, for `ChannelAgentBinder`, which resolves the agent through `HarnessWiring`'s `ExecutionPolicyResolver` and hands `dispatchChannelTurn` a pinned session (`provider`, `securityProfile`, `executionMode`) plus a `BehaviorFileService.withSoul(prompt)` variant composed under `PromptScope.task`; the unbound branch is today's `startTurn` call. `loadDartclawConfig` refuses a row naming an undeclared agent, and `GroupSessionInitializer` pre-creates group sessions with the same agent component.

### 11.3 Session Key Generation

`SessionKey` static factories in `dartclaw_kernel`: `dmShared()`, `dmPerContact(peerId)`, `dmPerChannelContact(channelType, peerId)`, `groupShared(channelType, groupId)`, `groupPerMember(channelType, groupId, peerId)`. Each takes an optional `threadId`, appended to the identifiers as `:thread:<encoded id>`; `ChannelManager.deriveSessionKey` passes the message's `threadId`, so a threaded conversation is one session per thread (per member and thread under `per_member`) and an unthreaded message keeps its key. `SessionKey.channelRoute` is the reader of those keys: it decodes a `dm` or `group` key into channel type, recipient and the `:thread:` suffix. Scheduled-job announce delivery and the loop-detection and budget notices read through it; a notice for a thread session is posted into that thread, while an announce still skips thread sessions.


---

## 12. Configuration

### 12.1 Channel Config

Top-level `channels:` YAML section with `debounce_window_ms`, `max_queue_depth`, `retry_policy` (max_attempts, base_delay_ms, jitter_factor), and per-channel subsections (`whatsapp`, `signal`, `google_chat`, `slack`). Typed models live in `dartclaw_kernel/lib/src/channel_config.dart`; per-channel sections are resolved by `resolveChannelConfig` in `dartclaw_runtime`.

### 12.2 DM Access and Groups

Per-channel `dm_access` mode (`pairing` | `allowlist` | `open` | `disabled`) with `dm_allowlist` rows, and `group_access` (`allowlist` | `open` | `disabled`) with `group_allowlist` rows. Both lists are parsed by `GroupEntry.parseList` into the same row form – a plain id, or a map carrying `id` plus optional `name`, `project`, `model`, `effort` and `agent` – and the channel configs expose `dmIds` / `groupIds` for the access checks. `ConfigWriter.readChannelAllowlist` answers the stored rows and `ChannelAccessService` edits them by id, so an API or pairing write never flattens a structured row.

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

**Concurrency and backpressure** -- Global concurrency cap with `Completer`-based wait queue; a released slot is handed to the next waiter at release, so no caller in between can take it too. The cap follows `concurrency.max_parallel_turns` reloads through the runtime's `MessageQueueReconfigurer` (registered by `ChannelWiring.wire`; core's queue only exposes the setter): a raise admits waiting sessions at once, a lowering admits nothing new until in-flight turns drop below it, and nothing is cancelled. Per-session FIFO (one turn at a time). Per-sender queue limit (admin-exempt). Queue depth limit per session -- excess messages receive a "busy" response. `BudgetExhaustedError` triggers a polite budget notification instead of retry.

**Retry and dead-letter** -- The queue dispatches each message once. A failed turn is never re-run, because a re-dispatch persists the inbound message again and starts a second agent turn: the sender gets one error notification and the failure is logged severe. Only reply delivery retries: each chunk's `sendMessage` is retried with jittered backoff (`baseDelay * attempt * (1 + random * jitterFactor)`) up to `maxAttempts` (default 3) while the session keeps its slot; an exhausted chunk dead-letters the reply with a severe log and its remaining chunks are not sent. The queue is the only delivery retrier, and it sees only failures a channel throws: WhatsApp and Signal throw on a failed text send (WhatsApp swallows media errors, so a retried chunk can resend its media), while Google Chat and Slack log a failed send and return, so their replies are never retried by the queue (Slack retries a rate-limited post once itself). A full global turn cap never reaches this path: `dispatchChannelTurn` persists the inbound message once, and when the turn start is refused with a non-same-session `BusyTurnException` it waits on `TurnManager.whenAdmissionCapacityAvailable()` and retries the start only.

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
       +---> dartclaw_slack
       |     (SlackChannel, SlackConfig, SlackWebApiClient,
       |      SocketModeClient, SlackEnvelopeDispatch)
       |     deps: dartclaw_core, dartclaw_kernel
       |
       v
  dartclaw_runtime
  (webhookRoutes, SlashCommandHandler, PauseController, ChannelWiring)
  deps: dartclaw_core, dartclaw_whatsapp, dartclaw_signal,
        dartclaw_google_chat, dartclaw_slack, dartclaw_kernel
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
