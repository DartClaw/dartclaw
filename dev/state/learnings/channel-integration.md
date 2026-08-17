# Channel Integration

### Google Chat
- **Config keys use `google_chat`, not `googlechat`.** Even though `ChannelType.googlechat` omits the underscore. Mismatch → channel wiring silently disappears.
- **Use `argumentText`, not `message.text`.** `message.text` includes the `@mention` prefix.
- **`spaces.members.get` uses bare numeric ID, not the `users/` prefix.** Strip `users/` from sender JIDs before constructing member URLs.
- **`quotedMessageMetadata` requires user OAuth.** `chat.bot` returns 403. When quoting fails with a typing placeholder present, *edit* the placeholder — *deleting* it leaves a permanent "message deleted by its author" tombstone.
- **Reactions also require user OAuth.** `chat.bot` cannot create or delete.
- **Quoting unsupported in unthreaded spaces.** Check `spaceType` against `UNTHREADED_MESSAGES` (`DM`, `GROUP_CHAT`) before building the quote.
- **`CARD_CLICKED` payload is flat `Map<String, String>`, not nested JSON.** `invokedFunction` + flat string parameters.
- **Slash commands have two event shapes.** `MESSAGE` with `message.slashCommand` AND `APP_COMMAND` with `appCommandMetadata` — write a compatibility parser.
- **Thread binding endpoints must share the live `ThreadBindingStore` instance.** Per-request reconstruction reads stale file state.

### Workspace Events / Pub/Sub
- **Workspace Events scopes differ from Chat API scopes.** Service account auth needs `chat.app.spaces` + `chat.app.memberships`; standard `chat.bot` is insufficient.
- **Workspace Events service account auth is Developer Preview.** Even with correct scopes, a Workspace admin must grant one-time approval. User OAuth (GA) does not need admin approval.
- **Workspace Events API must be enabled separately** from Pub/Sub and the Chat API. Missing enablement → `403 SERVICE_DISABLED`.
- **Pub/Sub Publisher and Subscriber are separate grants on different resources.** `chat-api-push@system.gserviceaccount.com` needs Publisher on the topic; your service account needs Subscriber on the subscription. Easy to confuse the two `403`s.
- **Pub/Sub shutdown must `dispose()`, not just `stop()`.** `stop()` is restart-safe and won't abort in-flight HTTP pulls; process shutdown without `dispose()` hits the 5-second timeout.

### Signal
- **Sealed-sender: pairing UUID vs later `sourceNumber`.** Allowlist must handle both forms and self-heal on first dual-form message.
- **UUIDs are mixed-case.** Lowercase before storage and lookup.
