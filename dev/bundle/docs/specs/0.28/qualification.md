# 0.28 Qualification

This is the single ledger for the 0.28 live qualification: Slack, run lifecycle posts, run approvals and request changes, and cited shared knowledge in chat. It records the platform facts the unattended work could only assume, the success metrics, and one row per run-loop scenario file. It consumes the scenarios in `dev/testing/scenarios/channels-*.md`; it does not replace their assertions.

The qualification is owner-led: it needs a Slack workspace, a Google Chat space, and paired WhatsApp and Signal devices, so nothing here is runnable unattended. Every status below is `pending` until the owner runs the step. Candidate identity, receipts and failed-attempt handling follow `dev/guidelines/RELEASE_PREPARATION.md` (receipts: full commit SHA and tree, attempts retained, a failed retry never falls back to an older pass); a retry points to the earlier attempt instead of overwriting it.

Setup: `bash dev/testing/profiles/channels/run.sh` (port 3336, token `devtoken0`) with `DARTCLAW_CHANNELS_DATA_DIR` set to a persistent directory, then the owner steps in the private channel manual. Steps in the scenarios are marked Owner (a person acts) or Runner (an agent acts through HTTP or the audit log); see `dev/testing/scenarios/README.md`.

## Platform facts

One row per fact the shipped code relies on without having seen it live. "If it fails" states the behaviour the code or guide changes to. Evidence is the scenario output or log line that settled the row.

| ID | Assumed fact | Settled by | If it fails | Status | Evidence |
|---|---|---|---|---|---|
| Q28-F01 | Slack accepts both shipped manifests, and the agent-view key (`features.assistant_view`) is the one Slack expects; the keys were checked against the manifest reference, never imported | `channels-slack-setup` S1, S2 | The manifest key or field Slack names is corrected in the shipped file and the guide; a rejected agent-view key drops the status and streaming surfaces until it is fixed | pending | |
| Q28-F02 | Slack's `url_verification` request is answered with the challenge as plain text, and the request URL then shows Verified | `channels-slack-setup` S2 | The Events API answer changes to the body shape Slack accepts; the guide's setup steps change with it | pending | |
| Q28-F03 | A Web API response carries the granted scopes in the `X-OAuth-Scopes` header, so `slack.scopes` names exactly the scopes the token lacks | `channels-slack-setup` S1, S3 | The doctor reads scopes from the call that does return them, or reports the row as unknown instead of failing | pending | |
| Q28-F04 | `chat.appendStream` and `chat.stopStream` identify the stream message by `ts` (the documentation shows both `ts` and `message_ts`) | `channels-slack-run-loop` S5 | The client sends the field Slack accepts; until then a stream cannot be extended or stopped, and the reply falls back to one complete message | pending | |
| Q28-F05 | `chat.update` can edit a stream message after `chat.stopStream`, so a Markdown reply is corrected to its final text | `channels-slack-run-loop` S5 | A refused edit leaves the streamed text as the final message; the reply is then posted whole as a new message and the streamed one is left in the thread | pending | |
| Q28-F06 | Appends of at most 12,000 characters, one per second, stay inside the stream methods' rate limit, and a reply over 12,000 characters streams without a 429 pattern | `channels-slack-run-loop` S6 | The append size or interval shrinks to what Slack allows, or a long reply stops streaming and is posted whole | pending | |
| Q28-F07 | Escaping `<`, `>` and `&` in streamed `markdown_text` neutralises `<!channel>` and `<@U...>` there as it does in a posted message | `channels-slack-run-loop` S7 | A live ping means streamed text is filtered further (the mention syntax is stripped) before it is sent | pending | |
| Q28-F08 | `assistant.threads.setStatus` works in channel threads of an agent-view app, and its status expires after two minutes without the turn failing | `channels-slack-run-loop` S8 | Status stays a DM-only surface and is logged as skipped in channels; an expiry before the reply is not renewed | pending | |
| Q28-F09 | A file download without `files:read` answers with a sign-in page (a `text/html` body with status 200), not an error status, and the reply names the missing scope; redirects stay inside `slack.com` | `channels-slack-setup` S3; `channels-slack-run-loop` S9 | The missing-scope check changes to whatever Slack answers; a redirect off `slack.com` changes the host rule that keeps the bot token on Slack | pending | |
| Q28-F10 | A slash-command payload carries no thread, so `/bind` and `/unbind` are not registered and the three registered commands answer ephemerally to the sender | `channels-slack-run-loop` S10 | A payload that does carry a thread makes `/bind` and `/unbind` registrable again; the manifests and the guide's command table regain them | pending | |
| Q28-F11 | The Socket Mode connection URL from `apps.connections.open` is single-use or short-lived, so each connect asks for a fresh one, including after a restart | `channels-slack-run-loop` S4 | A URL that lives longer lets a reconnect reuse it; a shorter one needs the request to happen immediately before the connect | pending | |
| Q28-F12 | Claude Code's stream-json input accepts a base64 `image` content block, within `image/png`, `image/jpeg`, `image/gif` and `image/webp` up to 5 MiB | `channels-slack-run-loop` S11 | Images stop reaching the model on that harness and arrive by name only; the image types or the size bound change to what it accepts | pending | |
| Q28-F13 | Codex's `turn/start` accepts an `image` input item with a `data:` URL beside the text item, within the same types and size bound | `channels-slack-run-loop` S11 | The form changes to a staged local image path; until then Codex receives the image by name only | pending | |
| Q28-F14 | A channel mention arrives as both `app_mention` and `message`, and exactly one turn runs (the `message` event, which alone carries files) | `channels-slack-run-loop` S1 | A second reply or a missing file means `app_mention` is processed as a fallback and deduplicated against the `message` event | pending | |
| Q28-F15 | Over Socket Mode the `view_submission` acknowledgement body travels in the acknowledge frame's `payload`, and `{"response_action":"clear"}` closes the modal | `channels-slack-run-loop` S13 (Socket Mode variant) | The acknowledgement moves to wherever Slack reads it; until then a submitted request-changes modal stays open or errors | pending | |
| Q28-F16 | Over the Events API a `view_submission` is answered in the HTTP response body, within 3 seconds, and an empty body closes the same single modal | `channels-slack-run-loop` S13 (Events API variant) | The response body or its timing changes; a slow submission closes the modal and the post shows the outcome | pending | |
| Q28-F17 | A post into a deleted origin thread fails with `thread_not_found`, which is dropped and logged, never re-sent as a plain message | `channels-slack-run-loop` S15 | A run whose origin thread was deleted posts a plain message to the configured channel instead, or the failure is surfaced in the audit log | pending | |
| Q28-F18 | A button click is answered with an ephemeral reply through the payload's `response_url`, and `chat.update` can replace the post's blocks so the buttons go away | `channels-slack-run-loop` S12 | A refusal is posted visibly in the thread, or the post keeps its buttons after resolution and a second click is the only guard | pending | |
| Q28-F19 | Slack unfurls a wiki or graph source link in a reply, and the preview shows at most the link's title and host | `channels-slack-run-loop` S2 | A preview that shows page body means replies set `unfurl_links: false` | pending | |
| Q28-F20 | Google Chat shows a refusal text in a card-click response only to the person who clicked (`privateMessageViewer`), not to the space as the existing task-card errors are | `channels-google-chat-run-loop` S3 | A refusal visible to the space is rewritten to carry no sender detail, or answered through a dialog that only the clicker sees | pending | |
| Q28-F21 | A Google Chat dialog stays open and shows `userFacingMessage` when its submission answers an `INVALID_ARGUMENT` status, and a non-admin's dialog is visible only to the clicker | `channels-google-chat-run-loop` S4 | A dialog that closes on an error status loses what the person typed; the blank-feedback check moves ahead of the submit or the text is echoed back | pending | |
| Q28-F22 | Patching a Google Chat approval card with `updateMask=cards_v2,text` replaces the card with one that has no buttons | `channels-google-chat-run-loop` S2 | The card keeps its buttons after resolution; a second click is refused by the run, but the post must be replaced another way | pending | |
| Q28-F23 | A Google Chat dialog submission carries no `message`, so the post it came from is read from the `postMessageId` parameter the dialog echoes back | `channels-google-chat-run-loop` S4 | A submission with no echoed identifier cannot update the post; the post stays as it was and the run still resumes | pending | |
| Q28-F24 | The text streamed into Slack renders the same as the final reply formatted for Slack, so a plain reply needs no edit after the stream stops | `channels-slack-run-loop` S5 | A visible difference after the stream stops means every streamed reply is edited with `chat.update`, which costs one more call per reply | pending | |

### Not exercised live

Facts that no scenario step can reach on a normal workspace, with the reason. They stay covered by the automated tests only.

| Fact | Reason |
|---|---|
| A file shared from another Slack workspace (Slack Connect) is refused with a named reason | Needs a second workspace linked by Slack Connect; the stub is exercised in the Slack adapter tests |
| A slash command or button whose `trigger_id` expired answers with a private message to use the run page or the agent tool | Slack honours a `trigger_id` for three seconds; a person cannot reliably be slower than the server on demand |
| A partial stream message left behind by a retried turn is edited into the complete reply | Needs a failure injected between the first append and the stop call, which the live API does not offer |
| Socket Mode reconnects after a `refresh_requested` or a dropped connection, and fetches a fresh URL each time | Slack decides when to refresh a connection, and a dropped network cannot be staged without side effects on the whole profile; a restart (`channels-slack-run-loop` S4) covers the fresh-URL half |
| A participation lookup that fails transiently is remembered as "not participating" until the bot is mentioned again | Needs `conversations.replies` to fail on demand |
| A WhatsApp or Signal run post is refused by the platform and dropped | Needs a failing send on a paired device; the delivery path is covered by the notification tests |

## Success metrics

Targets and observation methods are the milestone's own. Each row names the step whose output is the evidence.

| ID | Metric | Target | How observed | Scenario step | Status | Evidence |
|---|---|---|---|---|---|---|
| Q28-M01 | Approval-gated runs started from Slack resolved without the web UI | 100 % of such runs in the qualification profile | Audit log: the approval source is a Slack interaction or a Slack-origin tool call, and no web resolution exists for the run | `channels-slack-run-loop` S12, S13, S14 | pending | |
| Q28-M02 | Knowledge questions in a channel answered with citations | The owner's review of 10 real channel questions finds a citation packet on every answer that used owner knowledge, and every wiki or graph source link in those answers opens in a browser with no DartClaw session | `context_research` calls attributed to Slack-origin sessions in the audit log; the owner's review; links opened from a private browser window | `channels-slack-run-loop` S2 | pending | |
| Q28-M03 | Runs started elsewhere are visible in the configured channel | Started and finished or failed posts within 5 seconds of the bus event for 100 % of runs while the channel is connected | The server log's `Posted run <run ID> <event kind> to <channel> <recipient> (event at <UTC time>, <n> ms after)` lines in the qualification profile, one per landed post (`n` is the delay from the bus event); the five-run burst is measured and recorded, not gated | `channels-slack-run-loop` S16 | pending | |
| Q28-M04 | Owner setup from manifest and guide alone | First DM answered with no source reading and `dartclaw doctor` green, on a fresh workspace | The owner's walkthrough, recorded in this ledger | `channels-slack-setup` S1, S2 | pending | |
| Q28-M05 | Existing channels keep working | The channels profile is green as before, and Google Chat run threads and approval cards are green too | The channels profile through the run-loop scenarios of Google Chat, WhatsApp and Signal | `channels-google-chat-run-loop` S1 to S5; `channels-whatsapp-signal-run-loop` S1 to S4 | pending | |

## Run-loop scenario files

One row per file and transport. A file is green when every step of it passed or its retry is recorded, and the facts it settles are recorded in the table above.

| ID | Scenario file | Transport or channel | Facts it settles | Status | Evidence |
|---|---|---|---|---|---|
| Q28-R01 | `channels-slack-run-loop` | Slack, Socket Mode | Q28-F04 to Q28-F15, Q28-F17 to Q28-F19, Q28-F24 | pending | |
| Q28-R02 | `channels-slack-run-loop` | Slack, Events API | Q28-F14, Q28-F16 and the Events API variants of the steps above | pending | |
| Q28-R03 | `channels-google-chat-run-loop` | Google Chat | Q28-F20 to Q28-F23 | pending | |
| Q28-R04 | `channels-whatsapp-signal-run-loop` | WhatsApp | none (plain posts and tool resolution) | pending | |
| Q28-R05 | `channels-whatsapp-signal-run-loop` | Signal | none (plain posts and tool resolution) | pending | |

The setup scenario `channels-slack-setup` settles Q28-F01 to Q28-F03 and Q28-F09 and carries the evidence for Q28-M04.

## Rescan

Every platform behaviour found in an `ASSUMPTION:` line or an observation of the milestone's specs is a row above or a line of the not-exercised list. A fact found later is added here before the owner runs the scenarios, with the scenario step that settles it.
