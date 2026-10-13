---
profile: channels
viewport: desktop
port: 3336
auth_token: devtoken0
---
# Scenario: Slack Run Loop

Proves the milestone's loop on a real Slack workspace: a channel answers from shared knowledge with openable citations, streams and posts correctly, and a workflow run is started, watched, approved, sent back for changes and cancelled from chat. Run the whole file twice, once on Socket Mode (ledger row Q28-R01) and once on the Events API (Q28-R02), after `channels-slack-setup`. Steps tagged `[socket]` or `[events]` run on that transport only. Facts are ledger rows (`dev/testing/0.28-qualification.md`); this file names the row a step settles and states only what to do and observe.

Mark each step as the file convention says. A conversational step (the model chooses the tool) allows one retry and records it. `$DATA` is `DARTCLAW_CHANNELS_DATA_DIR`; the Runner reads `$DATA/audit-<UTC date>.ndjson` (or `GET /health-dashboard/audit?guard=<name>` with the Bearer token) for audit entries and the server log for the rest.

Preparation (Owner, once per transport): in `$DATA/dartclaw.yaml`, set `channels.slack.enabled: true` and the transport `mode`; list your member ID under `governance.admin_senders`; add one test channel to `channels.slack.group_allowlist` as `{id: <channel ID>, agent: eng-bot}` and invite the bot to it; set `workflow.chat_notifications` to `{channel: slack, recipient: <that channel ID>}`; set the top-level `base_url` to an address your browser reaches; register the workflow fixture project and seed one wiki page and one graph fact the bot can cite. None of these values is written into the repository.

## S1: A Channel Mention Is Answered Once, With Citations

### Steps

1. Owner: in the test channel, mention the bot with a question the seeded wiki page answers
2. Runner: count the bot's replies to that mention, and the turns the server log shows for it (Q28-F14)
3. Runner: open the session the mention created (session detail in the web UI, or `GET /api/sessions/<id>` with the Bearer token) and read which agent the turn ran under
4. Owner: reply in the same thread without a mention

### Expected

- Exactly one turn runs and exactly one reply is posted for the mention (Q28-F14)
- The reply carries a citation for the wiki page it used
- The session's record names the logical agent `eng-bot`
- The reply in the thread is answered without a mention


## S2: Ten Real Questions, Every Source Link Opens

### Steps

1. Owner: ask the bot ten questions about knowledge you hold in the shared wiki and graph, each in a thread, and keep the replies
2. Runner: list the `context_research` calls attributed to Slack-origin sessions in the audit log (Q28-M02)
3. Owner: open every wiki and graph link from those replies in a private browser window with no DartClaw session (Q28-M02)
4. Owner: note what Slack's link preview shows for one source link (Q28-F19)

### Expected

- A `context_research` call is attributed to a Slack-origin session for each answer that used owner knowledge (Q28-M02)
- Every answer that used owner knowledge carries a citation packet, and every source link in those answers opens read-only in the private window (Q28-M02)
- The preview, if any, shows at most the link's title and host; page body in the preview is recorded (Q28-F19)


## S3: Shared Writes Are Admin Only

### Steps

1. Owner: temporarily replace your ID in `governance.admin_senders` with another member's ID, then Runner: restart the profile
2. Owner: ask the bot in the channel to record a new fact in the shared graph
3. Runner: read the audit entries for the attempt
4. Owner: restore your ID in `governance.admin_senders` and Runner: restart the profile
5. Owner: ask the bot again to record the same fact
6. Runner: read the audit entries for the second attempt and query the graph for the fact

### Expected

- The first attempt is refused in the reply, writes nothing, and leaves an audit entry with outcome deny, the channel and the sender
- The second attempt is accepted, the fact exists in the graph, and an audit entry records outcome allow with the channel and the sender


## S4: A Thread Continues After A Restart

### Steps

1. Owner: start a thread with the bot in the test channel and let it answer
2. Runner: stop and start the profile, and wait for `GET /health` to answer 200 and for the Slack channel to connect (Q28-F11)
3. Owner: reply in the same thread without a mention

### Expected

- The channel reconnects after the restart with no connection-URL error in the log (Q28-F11)
- The reply is answered in the same thread without a mention


## S5: A Streamed Reply With Text Before A Tool Call

### Steps

1. Owner: ask the bot "Say one sentence about what you are about to do, then list the files in your workspace with a shell command, then summarise them in two lines with some Markdown."
2. Owner: watch the thread while the reply is written and note whether text appears before the tool call and whether the message changes at the end (Q28-F24)
3. Runner: read the server log for the stream calls and for any rejected stream call (Q28-F04, Q28-F05)

### Expected

- Text appears in the thread before the tool call runs
- The thread ends with one message holding exactly the reply, with the Markdown rendered, and no leftover partial message (Q28-F05, Q28-F24)
- The log shows no rejected `chat.appendStream` or `chat.stopStream` call (Q28-F04)


## S6: A Reply Over 12,000 Characters

### Steps

1. Owner: ask the bot for a reply of about 15,000 characters, such as a numbered list of 600 short lines
2. Runner: read the server log for the append calls and any 429 answer (Q28-F06)

### Expected

- The whole reply is in the thread, in order, once
- The log shows no 429 on a stream call (Q28-F06)


## S7: A Literal `<!channel>`

### Steps

1. Owner: ask the bot to repeat exactly the text `<!channel> <!here> <@U0000000>` inside its reply
2. Owner: note whether any member was notified and how the text renders (Q28-F07)

### Expected

- No notification reaches any channel member, and the reply shows the text as written (Q28-F07)


## S8: A Turn Silent For Over Two Minutes

### Steps

1. Owner: ask the bot "Run `sleep 150` in a shell, then answer done."
2. Owner: note the assistant status shown in the thread at the start, at about two minutes, and at the end (Q28-F08)
3. Runner: read the server log for status calls on that turn

### Expected

- The thread shows the "is working..." status while the turn runs, in a channel thread as in a DM (Q28-F08)
- A status that expires before the reply is not an error in the log, and the reply arrives once when the turn ends (Q28-F08)


## S9: Files In A Thread And On A Mention

### Steps

1. Owner: post a small text file and a PNG image in a thread the bot is in, with the message "Summarise these"
2. Owner: mention the bot in the channel with a file attached
3. Owner: post six small files in one message
4. Runner: read the server log for the downloads and for any refused redirect (Q28-F09)

### Expected

- Both messages are answered, with the text file's content reflected in the reply
- Downloads succeed with the full `files:read` scope, and the log shows no refused redirect (Q28-F09)
- The sixth file of the third message is refused, and one reply names the refusal and its reason


## S10: Reserved Commands And Slash Commands

### Steps

1. Owner: in the test channel, send the bot's `/pause` command as an admin, then `/resume`
2. Owner: in a thread, type `/` and look through the offered commands

### Expected

- `/pause` and `/resume` are answered ephemerally to you only, and the channel gains no message from either
- Only `/stop`, `/pause` and `/resume` are offered; `/bind` and `/unbind` are not registered, since a slash payload carries no thread (Q28-F10)


## S11: Images Reach The Model

### Steps

1. Owner: for each harness the profile configures (Claude Code and Codex), set the `eng-bot` agent's provider to it and restart, then paste a screenshot of a recognisable page into a Slack thread with the question "What is in this image?" (Q28-F12, Q28-F13)
2. Owner: open the web chat in the same instance, attach a similar screenshot in the composer and ask the same question (Q28-F12, Q28-F13)

### Expected

- On each harness both replies describe the screenshot's content, so the image reached the model as image input (Q28-F12, Q28-F13)


## S12: A Run Started From A Thread, Approved By Button

The approval-gated run is `plan-and-implement` with `PLAN_REVIEW=true`, on the fixture project and with the smallest scope `workflow-plan-and-implement-publish` S2 uses; close any pull request it publishes afterwards.

### Steps

1. Owner: in a thread, ask the bot to start `plan-and-implement` with `PLAN_REVIEW=true` for the fixture project. Conversational: allow one retry and record it
2. Runner: watch the thread and the audit log until the awaiting-approval post appears, and record the posts and their times
3. Owner: click **Approve** as an admin
4. Owner: click **Approve** again on the same post (Q28-F18)
5. Runner: wait for the run to finish and read the audit entries for the run (Q28-M01)

### Expected

- The thread holds a started post, an awaiting-approval post with **Approve**, **Reject** and, if the gate names a revise step, **Request changes**, and a finished post
- The first click resumes the run, the post is edited to say who resolved it and when, and its buttons are gone (Q28-F18)
- The second click is answered privately to you and changes nothing (Q28-F18)
- The audit log holds one allow entry for the run, source a Slack interaction, and no web resolution exists for the run (Q28-M01)


## S13: Request Changes Through The Modal

Start a second gated run as in S12 steps 1 and 2.

### Steps

1. Owner: click **Request changes**, leave the feedback blank and submit
2. Owner: click **Request changes** again, enter "Reduce the plan to a single story" and submit (Q28-F15 on `[socket]`, Q28-F16 on `[events]`)
3. Runner: watch the run return to the revise step and pause at the gate again, and read the audit entries (Q28-M01)
4. Owner: click **Reject** on the refreshed post

### Expected

- A blank submission keeps the modal open with the reason under the field
- A submission with text closes the modal on both transports, the post is updated, and the run returns to the gate (Q28-F15, Q28-F16)
- The audit entry for the revision carries the round and its limit and never the feedback text
- **Reject** cancels the run and edits the post to say who rejected it


## S14: A Non-Admin Is Refused, A Conversational Cancel Carries Feedback

### Steps

1. Owner: temporarily replace your ID in `governance.admin_senders` with another member's ID, then Runner: restart the profile
2. Owner: start a third gated run as in S12 steps 1 and 2, then click **Approve** and then **Request changes**
3. Owner: ask the bot in the thread to cancel the run, with the reason "Plan not wanted". Conversational: allow one retry and record it
4. Owner: restore your ID in `governance.admin_senders`; Runner: restart the profile
5. Owner: ask the bot in the thread to cancel the run, with the reason "Plan not wanted"
6. Runner: read the audit entries for the run (Q28-M01)

### Expected

- As a non-admin, both clicks and the cancel request are refused privately or in the reply, the run stays at the gate, and the post keeps its buttons
- As an admin, the cancel resolves the run with the reason recorded, source a Slack-origin tool call
- The audit log holds a deny entry for each refusal and an allow entry for the cancel, each with channel, sender, run and step


## S15: A Deleted Origin Thread

### Steps

1. Owner: start a gated run from a thread as in S12 step 1
2. Owner: delete the thread's first message and its replies, while the run is still working
3. Runner: read the server log when the run reaches the gate and finishes (Q28-F17)
4. Runner: cancel the run through `POST /api/workflows/runs/<id>/cancel` with the Bearer token

### Expected

- The failed post is logged once for the run and not repeated as a plain message in the channel (Q28-F17)
- The run itself is unaffected by the failed posts, and the cancel in step 4 succeeds


## S16: Runs Started Elsewhere Post To The Configured Channel

### Steps

1. Runner: start one run through `POST /api/workflows/run-form` with the Bearer token, and one through the `/workflows` page in the browser; use a workflow that finishes fast
2. Runner: read the server log for each run's `Posted run <run ID> started ...` and `Posted run <run ID> finished ...` (or `failed`) lines; each carries the event time and the milliseconds from that event to the post (Q28-M03)
3. Runner: start five runs within ten seconds and record every `Posted run ...` line's delay, and the order of the posts (Q28-M03)

### Expected

- Each run opens one new thread in the configured channel, with started and finished or failed posts (Q28-M03)
- Every started and finished or failed post is within 5 seconds of its event, for each of the runs in steps 1 and 3 (Q28-M03)
- The burst's delays are recorded, whatever they are, because the burst is measured and not gated


## S17: A Real Plan Revision

Continue from the gated run of S13, before its **Reject** click, or start a new one.

### Steps

1. Owner: request changes with "Split the plan into two stories, the second adding a README note"
2. Runner: when the run pauses at the gate again, read the revised plan from the run page
3. Owner: click **Reject** to end the run

### Expected

- The revised plan reflects the feedback: it differs from the first plan in the requested way
- The run paused at the same gate with the revision round shown, and the post names the round and its limit


## S18: Audit And Log Hygiene

### Steps

1. Owner: send `/pause` from a non-admin account (or while your ID is not in `governance.admin_senders`)
2. Runner: `[events]` send an unsigned `POST` to the Events API path on the server with a made-up body
3. Runner: read the audit log for both
4. Runner: after all steps, search the whole server log for the text `xoxb-`, `xapp-`, each credential's value and the signing secret

### Expected

- The non-admin `/pause` is refused and leaves a deny audit entry with the channel and sender
- `[events]` the unsigned request gets `401`, starts no turn, and leaves an audit entry
- The server log holds no Slack token or signing-secret value
