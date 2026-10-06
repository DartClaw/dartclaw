# FIS: Documentation, parity record and qualification

**Plan**: dev/bundle/docs/specs/0.28/plan.json
**Story-ID**: S08

## Feature Overview and Goal

**Intent**: Stories S01 to S07 and S09 each document their own change, so what is left is the record no single story owns: the cross-channel parity view, the glossary, the statements about who DartClaw is for, and the owner's means to prove on live Slack and Google Chat the platform facts the unattended stories could only assume.

**Expected Outcomes**:

- [OC01] The parity matrix, glossary and feature comparison describe the four-channel product and its run lifecycle as shipped, with each channel's value taken from the code.
- [OC02] No guide or product statement still calls DartClaw single-owner or threading Google Chat-only, and the Slack guide page covers everything the milestone ships.
- [OC03] The owner can run the live qualification from the channels profile, per-channel scenarios and one ledger that maps every unverified platform fact and every success metric to a step and to what changes if it fails.


## Required Context

- `docs/specs/0.28/prd.md#fr10-documentation-and-parity-record` – the records, their acceptance criteria and the ceiling rule.
- `docs/specs/0.28/prd.md#fr7-existing-channel-parity` – the matrix rows and the per-channel run-loop scenarios.
- `docs/specs/0.28/prd.md#success-metrics` – the five rows the ledger observes.
- `docs/specs/0.28/prd.md#decisions-log` – the four glossary definitions and owner D22 (live proof is owner-led, after the last story).
- `docs/specs/0.28/s01-slack-adapter-over-socket-mode.md`, `docs/specs/0.28/s02-slack-events-api-setup-and-diagnostics.md`, `docs/specs/0.28/s03-slack-streaming-replies-and-inbound-media.md`, `docs/specs/0.28/s05-threaded-channels-and-run-lifecycle-posts.md`, `docs/specs/0.28/s06-run-approvals-from-chat.md`, `docs/specs/0.28/s07-request-changes-at-approval-gates.md`, `docs/specs/0.28/s09-openable-citation-sources-and-gated-shared-writes.md` – the `ASSUMPTION:` lines to collect and each story's own doc tasks, which this story must not repeat (plan `sharedDecisions`, "Documentation ownership"). Story S04 records no platform fact.
- `docs/specs/channel-parity-matrix.md` and `docs/specs/feature-comparison.md` – the two private records edited here.
- `dev/testing/scenarios/README.md` and `dev/testing/0.27-qualification.md` (public) – the scenario format and the ledger precedent.


## Acceptance Scenarios

- **S01 [OC01] The parity matrix shows Slack beside the other three channels**
  - **Given** the matrix at "Current through 0.25" with three channel columns, and the shipped Slack adapter
  - **When** a reader checks any feature row and then the run-lifecycle rows
  - **Then** every table carries a Slack column whose values come from the shipped adapter, not the PRD; the status line and channel list name 0.28 and Slack; rows exist for run threads, run approvals and interactions, request changes and the threaded-notification capability, each valued for all four channels (WhatsApp and Signal: plain posts, no buttons, resolution through the agent tools); Slack-specific rows exist for streaming, assistant status and inbound files; a Slack-only section and a Slack implementation-reference row exist

- **S02 [OC01] The glossary names the four new terms**
  - **Given** the PRD Decisions Log definitions of run origin, run thread, threaded channel and approval interaction
  - **When** the glossary is read
  - **Then** a row exists for each, in the bounded context that owns it per `dev/architecture/context-map.md`, with a definition equal in meaning to the Decisions Log and naming the shipped type or key; the `Channel` row's concrete list, the `Thread Binding` row (task or run target) and the Overloaded Terms `Thread` row no longer describe Google Chat only; the glossary changelog gains one dated line; the file stays within its Index ceiling, and the pruned lines are named in the report

- **S03 [OC01] The feature comparison lists what 0.28 adds**
  - **Given** the comparison, whose Slack row reads "Post-0.2" for DartClaw
  - **When** the Messaging Channels and Workflow tables and the phase summary are read
  - **Then** the Slack row states the 0.28 working-tree adapter with qualification pending, in the file's existing working-tree wording; rows exist for run lifecycle posts in chat, run approvals from chat and request changes at gates, with competitor cells marked "Not re-verified" where this story did not verify them; the "all 3 channels" chunking claim and the thread-bound-sessions row (run bindings) are corrected; the phase summary has a 0.28 row; the header carries today's date

- **S04 [OC02] No guide statement still says single-owner or Google Chat-only threading**
  - **Given** `docs/guide/context-engine.md` and `docs/guide/tasks.md`, which call DartClaw single-owner, and the `task_bind` documentation that names only `googlechat`
  - **When** they and the guide's prose channel lists are read
  - **Then** the context-engine page states one administrator with many users instead of "single-owner"; the tasks page's `task_bind` row, channel-type bullet and reach caveat name every registered threaded channel and no longer claim the tool reaches only the owner's own threads, since a shared team channel holds other members' threads; a prose list that is meant to be the complete set of channels includes Slack, and a claim about which channels a feature reaches is checked against the code

- **S05 [OC02] PRODUCT.md and OUT-OF-SCOPE.md match the shipped trust model**
  - **Given** the 2026-10-04 amendments to both, and the shipped model (one shared session per thread in an allowlisted channel, run resolution and shared wiki and graph writes from channel turns gated by `governance.admin_senders` with an empty list making every sender an admin, no per-sender arbitration, one workspace)
  - **When** each statement is compared with shipped behaviour
  - **Then** PRODUCT.md no longer says Slack is "in progress" and stays within its word ceiling; OUT-OF-SCOPE.md's statement that crowd coding survives "inside the Google Chat package" is reconciled with the shipped threaded-channel seam; every other sentence is left unchanged unless it contradicts what ships; each edit, and each sentence checked and kept, is named in the report

- **S06 [OC02] The Slack guide page covers everything the milestone ships**
  - **Given** the page story S02 created, to which stories S03, S07 and S09 may or may not have added sections (stories S03 and S09 skip their section when the page does not yet exist)
  - **When** it is read against the shipped behaviour
  - **Then** it has a section each for streaming and status, inbound files (the 20 MB and 5-file bounds), run notifications (`workflow.chat_notifications`, the `base_url` run-page link, run threads in the configured channel needing only `workflow.chat_notifications` while `features.thread_binding.enabled` gates task binding only, plain posts on channels that cannot thread), approvals (Approve and Reject buttons, admin senders, audit, the agent tools and the `agent.agents.<id>.tools` grant a bound agent needs, WhatsApp and Signal by tool) request changes (the modal, the revision limit) and knowledge answers (a bound agent with a closed `tools` list of the five context-engine read tools plus the workflow tools, source links needing a `base_url` the members can reach, shared wiki and graph writes for admin senders only, linking the context-engine page for the rest); it states for group channels that an empty `admin_senders` makes every sender an admin; every `channels.slack.*` key appears with type and default, and the `workflow.chat_notifications.*` and `features.thread_binding.enabled` keys link to their `configuration.md` entries; a section an earlier story wrote is kept, and content another guide page owns is linked, not copied

- **S07 [OC03] The channels profile carries Slack and says so**
  - **Given** the channels profile, which enables WhatsApp, Signal and Google Chat while its README row and `run.sh` header say "WhatsApp + Signal"
  - **When** the seed is loaded and the owner-only Slack setup is read
  - **Then** the seed loads under the config schema and advisory baseline and carries a Slack block disabled by default, naming credential references only, a bound agent `eng-bot` whose `tools` grant the five workflow tools and `context_research`, and thread binding on; the README row and `run.sh` header name all four channels and point to the private manual's real path; the private manual has a Slack section listing what only the owner can do for this profile (create the app from a shipped manifest, store the credentials, flip the block on, supply workspace-specific IDs)

- **S08 [OC03] Every unverified platform fact has a ledger row, a scenario step and a consequence**
  - **Given** the `ASSUMPTION:` lines of stories S01 to S07 and S09 that state a Slack or Google Chat behaviour as unverified
  - **When** the ledger is read
  - **Then** each fact has a row holding the assumed fact, the scenario step that settles it, what changes if it fails (stated as behaviour, no story ID) and status `pending`; the rows cover at least: the manifest's agent-view key and Slack's validation of both manifests; the `url_verification` plain-text answer; the `X-OAuth-Scopes` header the doctor reads; `ts` versus `message_ts` on `chat.appendStream` and `chat.stopStream`; `chat.update` after `chat.stopStream`; stream append size and rate limits; `<!channel>` neutralised inside streamed `markdown_text`; `assistant.threads.setStatus` in channel threads and its two-minute expiry; the response to a file download without `files:read`; slash-command payloads carrying no thread; the Socket Mode connection URL's lifetime; Claude Code accepting base64 `image` content blocks and Codex accepting `image` input items with a `data:` URL, within the image types and size bound the inbound-media story sends; one turn per mention across `app_mention` and `message`; the Socket Mode acknowledgement `payload` for `view_submission`; the Events API response body for `view_submission`; `thread_not_found` for a deleted origin thread; ephemeral replies and `chat.update` blocks on a button click; whether Slack unfurls a source link and what the preview shows (if it shows page body, replies set `unfurl_links: false`); whether a Google Chat refusal text is private; whether the Google Chat dialog stays open on an error status and whether a non-admin's dialog is visible only to the clicker; the Google Chat card patch that retires its buttons; a `## Not exercised live` list gives each fact no step can reach (Slack Connect stubs, an expired `trigger_id`, a partial stream message left by a retried turn, Socket Mode reconnect) with the reason; a re-scan of the eight FIS at execution adds any platform-behaviour assumption found since

- **S09 [OC03] Slack scenarios take the owner from manifest to a supervised run on both transports**
  - **Given** the channels profile, the ledger and the Slack guide
  - **When** the owner follows the setup scenario and then the run-loop scenario, each step marked Owner or Runner
  - **Then** setup imports each shipped manifest into a new Slack app by following only the guide's steps (cited, not restated), reaches a first DM answered with the doctor's Slack rows green, proves URL verification and a turn longer than 3 s with no duplicate reply on the Events API variant, and includes one reinstall without `assistant:write` and `files:read` whose expected outcomes are the doctor's scope failure, a status failure that never delays the turn, one complete reply after a stream-start failure and a reply naming the missing scope for a file; the run loop covers a channel mention answered once with citations and a logical-agent execution record, a cited wiki link and graph link opened in a private browser window, a non-admin's request to record a fact refused and an admin's accepted, each with its audit entry, a thread reply after a server restart continuing without a mention, a streamed reply with text before a tool call, a reply over 12,000 characters, a literal `<!channel>`, a turn silent over two minutes, files in a thread and on a mention, a reserved command's ephemeral reply, a screenshot pasted into a Slack thread and one attached in the web composer each described in the agent's reply (images reach the model as native image input), a non-admin slash command and a bad-signature Events API request each leaving an audit entry, the server log read after the session for any Slack token or signing-secret value, a run started from a thread with started, awaiting-approval and finished posts, an admin's Approve click and a second click, a non-admin refusal (the owner made a non-admin through a temporary `admin_senders` entry), a conversational cancel with feedback, request changes through the modal on both transports including blank feedback, runs started from the web form into the configured channel with post timing and a five-run burst measured, a deleted origin thread, and `plan-and-implement` with `PLAN_REVIEW` set through a real plan revision; a conversational step allows one retry, because tool choice is the model's, and records it

- **S10 [OC03] Google Chat, WhatsApp and Signal scenarios prove the same loop on their own platforms**
  - **Given** the same profile and ledger, a Google Chat space for the bot, and WhatsApp and Signal devices paired as the private manual describes
  - **When** the owner follows the Google Chat and the WhatsApp and Signal scenarios
  - **Then** Google Chat covers a run started from a thread posting its lifecycle into that thread, an admin's Approve on the card (buttons Approve and Reject) with the card losing its buttons, a non-admin's refusal observed for who can see it, the Request changes dialog opened, submitted, submitted blank and watched for staying open, and the task Accept and Reject cards unchanged; WhatsApp and Signal each cover a run started from a DM and from a group posting plain messages to that origin, an admin resuming by asking the agent, and a non-admin refused

- **S11 [OC03] The success metrics are observable**
  - **Given** the PRD's five Success Metrics rows
  - **When** the ledger is read
  - **Then** each has a row holding its target, how it is observed (copied in meaning from the PRD) and the scenario step that produces the evidence, plus a row per run-loop scenario file (Slack on each transport, Google Chat, WhatsApp, Signal); every status is `pending`, because the qualification is owner-led and runs after this story


## Structural Criteria

- **SC01** Nothing this story writes holds a credential, signing secret, phone number, internal URL or workspace-specific ID.
- **SC02** Each fact has one home: status, assumed fact and consequence in the ledger, steps in the scenarios, Slack app-creation steps in the guide that the scenarios cite.
- **SC03** The glossary and PRODUCT.md, at their Index ceilings, end no longer than they began.
- **SC04** The ledger and scenarios carry no story ID, because the FIS files are deleted at release prep.


## Scope & Boundaries

### Work Areas
- Private repo: `docs/specs/channel-parity-matrix.md` – TI01; `docs/specs/feature-comparison.md` – TI03; `docs/OUT-OF-SCOPE.md` – TI05; `docs/testing/channel-e2e-manual.md` – TI11
- Public repo: `dev/state/UBIQUITOUS_LANGUAGE.md` – TI02; `dev/state/PRODUCT.md` – TI05; `docs/guide/context-engine.md`, `docs/guide/tasks.md`, prose channel lists in `README.md` and `docs/guide` – TI04; `docs/guide/slack.md` – TI06
- Public repo testing: `dev/testing/profiles/channels/` and `dev/testing/README.md` – TI07; `dev/testing/0.28-qualification.md` – TI08; `dev/testing/scenarios/README.md` and `dev/testing/scenarios/channels-*.md` – TI09, TI10

### What We're NOT Doing
- Running the live qualification, or writing any result as a pass or fail – owner D22 puts it after this story and in the owner's hands; every ledger status stays `pending`.
- Any step needing a Slack, Google Chat, WhatsApp or Signal credential – the executor never handles one.
- Committing in the private repo – its policy; the four private files are left for the owner and the report names them.
- Architecture deep-dives, the CHANGELOG and package guides – each story owns the lines its change touches; this story adds no CHANGELOG line because the features it records are already announced there.
- `docs/ROADMAP.md`, `docs/specs/competitor-analysis.md` and `docs/wireframes/deviations.md` – the owner's records, outside this story's scope.
- A dedicated `slack` testing profile – the channels profile is the profile FR7 names.
- A script or fitness check that cross-reads the ledger and scenarios – the Verify lines below do it once.
- The architecture docs' "suitable for single-user deployments" admin-sender sentences (`dev/architecture/system-architecture.md`, `session-state-architecture.md`, `security-architecture.md`) – story S06 restates them for group channels (its TI12).


## Architecture Decision

**Approach**: Each record is edited in place at its canonical home. The live qualification is three layers with no code: one ledger (facts, consequences, metrics, status), scenario files in the existing format with an Owner or Runner mark on each step, and the channels profile seed holding the config that carries no secret or workspace ID. Facts come from shipped code and package guides, never from this FIS or the PRD, because key and type names in stories S01 to S07 are provisional.
**Why this over the floor**: the floor, leaving the assumptions in the FIS, loses them when the FIS files are deleted at release prep, and owner D22 and FR7 require per-channel run-loop scenarios and a ledger the success metrics name.

Decisions, each also stated where it bites:
- The ledger is `dev/testing/0.28-qualification.md`, beside the 0.27 one it copies the shape of (fact, evidence, status per row, failed attempts kept).
- Four scenario files, `channels-slack-setup.md`, `channels-slack-run-loop.md`, `channels-google-chat-run-loop.md` and `channels-whatsapp-signal-run-loop.md`, port 3336 and the profile's token.
- The scenario README gains a short convention marking a step Owner (a person acts) or Runner (an agent acts through HTTP or the audit log), since the format has no human step today.
- The "Slack setup" in the plan scope is the seed block plus a Slack section of the private manual listing what only the owner can do, with app creation itself left to the guide.
- A non-admin case is staged by setting `governance.admin_senders` to another sender for the step, so no second account is needed.
- Scenarios run on the profile's host lane (`container.enabled: false`); the container-lane grant is proved by story S06's tests.
- The burst measurement is recorded, not gated, since the PRD leaves coalescing an open question awaiting "a measured burst".
- PRD FR10's "`UBIQUITOUS_LANGUAGE.md` rows for run origin, run thread, threaded channel and approval interaction" is the whole glossary change.
- The owner runs the qualification and commits the private-repo files; no task waits on either.


## Constraints & Gotchas

- **Constraint**: paths under `docs/specs/`, `docs/OUT-OF-SCOPE.md` and `docs/testing/` are the private repo, reached from the public checkout as `../dartclaw-private/` (from a worktree outside the main checkout's parent, substitute the private checkout beside the main public checkout, located with `git worktree list`); `dev/`, `docs/guide/`, `README.md` and `packages/` are public – Workaround: private Verify lines use `git -C ../dartclaw-private`, and the private edits stay uncommitted.
- **Constraint**: the channels seed holds a real phone number and an internal URL that no spec, ledger or scenario may repeat – Workaround: edit around them, reference nothing; scenarios name config keys and credential names, never values.
- **Constraint**: story S05 names its capability `threadedNotifications` and its key names "provisional", and stories S01 to S03 may rename keys in review – Workaround: read the shipped code and generated config reference, then write the name that ships.
- **Constraint**: the glossary is at its 300-line ceiling and PRODUCT.md at its 700-word ceiling – Workaround: prune in the same story and never shard (FR10); old glossary changelog entries are the first candidates; name every prune.
- **Constraint**: the channels profile config sits in the schema corpus and the advisory baseline golden – Workaround: run both tests after the seed edit and regenerate the golden with `DARTCLAW_UPDATE_CONFIG_ADVISORY_GOLDEN=1` only for a reviewed difference (LEARNINGS).
- **Constraint**: story S02 creates the Slack guide page, stories S03 and S09 add their sections only if the page exists by then, story S07 adds request-changes statements, and no story writes run notifications or approvals; the doc tasks of stories S05 and S06 never touch `docs/guide/tasks.md`, whose `task_bind` text story S05 makes stale – Workaround: this story fills those gaps and no more; read the page first.
- **Constraint**: a conversational approval or cancel goes through a model turn (ADR-054), so a scenario step cannot demand a fixed tool call – Workaround: the step states the outcome, allows one retry, and records the retry.


## Implementation Plan

### Implementation Tasks

- **TI01** The parity matrix has the Slack column in every table, the run-lifecycle, approval, request-changes and capability rows for all four channels, the Slack-specific rows and section, and the 0.28 status line.
  - Pattern: the matrix's own table shapes; Slack values read from `packages/dartclaw_slack` and its `CLAUDE.md`, run and approval values from the shipped capability and run-control code.
  - **Verify**: `cmd: ! git -C ../dartclaw-private grep -n -E "^\| Feature \| WhatsApp \| Signal \| Google Chat \|$" -- docs/specs/channel-parity-matrix.md && git -C ../dartclaw-private grep -q "Current through 0.28" -- docs/specs/channel-parity-matrix.md && git -C ../dartclaw-private grep -q -E "^\| Slack \| .*dartclaw_slack" -- docs/specs/channel-parity-matrix.md` – no three-column table header remains, the status names 0.28, the implementation table names the package; `cmd: for t in "run thread" "run approval" "request changes"; do git -C ../dartclaw-private grep -q -i -F "$t" -- docs/specs/channel-parity-matrix.md || exit 1; done` – each new row exists; `inspect: docs/specs/channel-parity-matrix.md:1` – every data row of every table has one value per channel
  - **SATISFIES**: S01

- **TI02** The glossary holds the four terms in their owning contexts, the three corrected rows and one dated changelog line, within its ceiling.
  - Pattern: `dev/state/UBIQUITOUS_LANGUAGE.md` row shape and "Avoid" column; the date from `date +%Y-%m-%d`; the Decisions Log wording in the PRD.
  - **Verify**: `cmd: for t in "Run Origin" "Run Thread" "Threaded Channel" "Approval Interaction"; do git grep -q -F "| $t |" -- dev/state/UBIQUITOUS_LANGUAGE.md || exit 1; done` – the four rows; `cmd: ! git grep -n -E "concrete: .WhatsAppChannel., .SignalChannel., .GoogleChatChannel.\." -- dev/state/UBIQUITOUS_LANGUAGE.md` – the `Channel` list names Slack; `cmd: test "$(git diff HEAD --numstat -- dev/state/UBIQUITOUS_LANGUAGE.md | cut -f1)" -le "$(git diff HEAD --numstat -- dev/state/UBIQUITOUS_LANGUAGE.md | cut -f2)"` – lines added do not exceed lines removed
  - **SATISFIES**: S02, SC03

- **TI03** The feature comparison states Slack and the run-lifecycle capabilities as scenario S03 says, with unverified competitor cells marked as such.
  - Pattern: the 0.27 "working tree" wording and the "Not re-verified" cells already in the Conversation tables; the date from `date +%Y-%m-%d`.
  - **Verify**: `cmd: ! git -C ../dartclaw-private grep -n -E "^\| Slack \|.*Post-0\.2" -- docs/specs/feature-comparison.md && ! git -C ../dartclaw-private grep -n "all 3 channels" -- docs/specs/feature-comparison.md && git -C ../dartclaw-private grep -q -E "^\| \*\*0\.28" -- docs/specs/feature-comparison.md` – the stale Slack cell and claim are gone and the phase row exists; `cmd: for t in "run lifecycle" "run approvals" "request changes"; do git -C ../dartclaw-private grep -q -i -F "$t" -- docs/specs/feature-comparison.md || exit 1; done` – the three capability rows
  - **SATISFIES**: S03

- **TI04** `docs/guide/context-engine.md` and `docs/guide/tasks.md` state one administrator with many users and every registered threaded channel for `task_bind`, and the guide's complete-set channel lists include Slack.
  - Inventory: case-insensitive search for `single-owner`, `one person owns`, `only .googlechat.` and `WhatsApp, Signal` across `README.md` and `docs`; `docs/guide/recipes/01-morning-briefing.md` and `07-nightly-reflection.md` list channels for `announce` delivery, so read the code before adding Slack there; the context-engine sentence's "one carved-out exception" framing follows the new statement.
  - **Verify**: `cmd: ! git grep -n -i -E "single-owner|one person owns the chat identity|accepts only .googlechat" -- docs README.md` – no stale statement; `cmd: ! git grep -n -E "WhatsApp, Signal,? (and )?Google Chat" -- README.md docs ':!docs/guide/recipes/01-morning-briefing.md' ':!docs/guide/recipes/07-nightly-reflection.md' | grep -v -i slack` – every complete-set list names Slack; `inspect: docs/guide/recipes/01-morning-briefing.md` and `07-nightly-reflection.md` – their `announce` channel lists name Slack only if the code delivers `announce` to Slack
  - **SATISFIES**: S04

- **TI05** PRODUCT.md and OUT-OF-SCOPE.md match the shipped trust model, with only contradicted sentences edited.
  - Pattern: the 2026-10-04 amendment in `docs/OUT-OF-SCOPE.md`; the Team assistant bullet at `dev/state/PRODUCT.md`; the trust facts in scenario S05 read from the shipped code and `docs/guide/governance.md`.
  - **Verify**: `cmd: ! git grep -n -i "slack is in progress" -- dev/state/PRODUCT.md` – the stale status is gone; `inspect: dev/state/PRODUCT.md:28` – the Team assistant bullet matches what shipped, and the file is no longer than it was; `inspect: docs/OUT-OF-SCOPE.md:37` – the crowd-coding sentence is consistent with the threaded-channel seam, every other sentence compared and the report listing each
  - **SATISFIES**: S05, SC03

- **TI06** `docs/guide/slack.md` holds every section scenario S06 lists, the group-channel `admin_senders` warning, and key tables covering `workflow.chat_notifications.*` and `features.thread_binding.enabled` with type and default, writing only what earlier stories left missing.
  - Pattern: story S02's page and `docs/guide/google-chat.md` for section order; the type and default values come from the generated `docs/guide/configuration.md` rows.
  - **Verify**: `cmd: for h in streaming "inbound files" "run notifications" approvals "request changes" knowledge; do git grep -q -i -E "^#+ .*$h" -- docs/guide/slack.md || exit 1; done` – the six sections; `cmd: for k in chat_notifications thread_binding admin_senders base_url workflow_resume; do git grep -q -F "$k" -- docs/guide/slack.md || exit 1; done` – the keys and tool named; `cmd: dart test --reporter=failures-only packages/dartclaw_slack/test/slack_setup_assets_test.dart` – story S02's guide-to-schema test still passes; `inspect: docs/guide/slack.md:1` – the page read once against shipped behaviour, with no passage copied from another guide page
  - **SATISFIES**: S06

- **TI07** The channels profile seed, README row and `run.sh` header are as scenario S07 states, holding no secret or identifier.
  - Pattern: the existing channel blocks in `dev/testing/profiles/channels/data/dartclaw.yaml`; the key names and canonical tool names shipped by stories S01 to S07; `channels.slack.enabled: false` so the profile still starts for an owner without a Slack app. The real manual path is `dartclaw-private/docs/testing/channel-e2e-manual.md`; the header's current path is wrong.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_kernel/test/config_schema_corpus_test.dart packages/dartclaw/test/config_advisory_baseline_test.dart` – the seed loads under the schema and the advisory baseline; `cmd: git grep -q -E "^  slack:$" -- dev/testing/profiles/channels/data/dartclaw.yaml && ! git grep -n -E "WhatsApp \+ Signal" -- dev/testing/README.md dev/testing/profiles/channels` – the block exists and no stale channel list remains; `cmd: ! git grep -n -E "xox[a-z]-[0-9A-Za-z-]{10,}|xapp-[0-9A-Za-z-]{10,}" -- dev/testing/profiles/channels` – no token-shaped value
  - **SATISFIES**: S07, SC01

- **TI08** The ledger exists with the fact rows, the not-exercised list, the five metric rows and the per-scenario-file rows of scenarios S08 and S11, every status `pending`.
  - Pattern: `dev/testing/0.27-qualification.md` for the table and evidence conventions, pointing at its candidate-identity section rather than copying it; row IDs `Q28-F01`, `Q28-M01` and `Q28-R01` upward (fact, metric, run-loop file); `dev/testing/README.md` names the ledger beside the 0.27 one.
  - **Verify**: `cmd: for k in message_ts chat.update "<!channel>" setStatus files:read view_submission privateMessageViewer url_verification X-OAuth-Scopes unfurl; do git grep -q --untracked -F "$k" -- dev/testing/0.28-qualification.md || exit 1; done` – the named platform facts have rows; `cmd: for id in Q28-M01 Q28-M02 Q28-M03 Q28-M04 Q28-M05 Q28-R01; do git grep -q --untracked -F "$id" -- dev/testing/0.28-qualification.md || exit 1; done && ! git grep -n --untracked -E "\| *(pass|fail)" -- dev/testing/0.28-qualification.md` – metric and run-loop rows exist and no status claims a result; `cmd: ! git grep -n --untracked -E "(^|[^A-Za-z0-9])S0[1-9]([^0-9]|$)" -- dev/testing/0.28-qualification.md` – no story ID; `cmd: ! git grep -n --untracked -E "xox[a-z]-[0-9A-Za-z-]{10,}|xapp-[0-9A-Za-z-]{10,}|\+[0-9]{9,}|ts\.net" -- dev/testing/0.28-qualification.md` – no secret or identifier
  - **SATISFIES**: S08, S11, SC01, SC02, SC04

- **TI09** The scenarios README states the Owner and Runner step convention, and the Slack setup and Slack run-loop scenario files exist as scenario S09 states.
  - Pattern: `dev/testing/scenarios/README.md` format and `governance-enforcement.md` for curl steps with the Bearer token; scenarios cite the guide's setup steps and the ledger's `Q28-` IDs and restate neither the guide's steps nor the ledger's consequences.
  - **Verify**: `cmd: for f in dev/testing/scenarios/channels-slack-setup.md dev/testing/scenarios/channels-slack-run-loop.md; do git grep -q --untracked -E "^profile: channels$" -- "$f" && git grep -q --untracked -E "^port: 3336$" -- "$f" && git grep -q --untracked -E "^### Expected$" -- "$f" || exit 1; done` – README-format frontmatter and sections; `cmd: git grep -q -F "Owner" -- dev/testing/scenarios/README.md` – the convention is documented; `inspect: dev/testing/scenarios/channels-slack-setup.md:1` – both manifests, both transports and the reinstall case are covered, and step order follows the guide
  - **SATISFIES**: S09, SC02, SC04

- **TI10** The Google Chat and the WhatsApp and Signal run-loop scenario files exist as scenario S10 states, and every ledger row ID appears in at least one scenario.
  - Pattern: TI09's files; the hardware pairing stays in the private manual and is cited.
  - **Verify**: `cmd: for f in dev/testing/scenarios/channels-google-chat-run-loop.md dev/testing/scenarios/channels-whatsapp-signal-run-loop.md; do git grep -q --untracked -E "^profile: channels$" -- "$f" && git grep -q --untracked -E "^### Expected$" -- "$f" || exit 1; done` – format; `cmd: for id in $(git grep -h --untracked -o -E "Q28-[FMR][0-9]+" -- dev/testing/0.28-qualification.md | sort -u); do git grep -q --untracked -F "$id" -- 'dev/testing/scenarios/channels-*.md' || exit 1; done` – no ledger row lacks a step; `cmd: ! git grep -n --untracked -E "(^|[^A-Za-z0-9])S0[1-9]([^0-9]|$)|xox[a-z]-[0-9A-Za-z-]{10,}|xapp-[0-9A-Za-z-]{10,}|\+[0-9]{9,}|ts\.net" -- 'dev/testing/scenarios/channels-*.md'` – no story ID, secret or identifier
  - **SATISFIES**: S08, S10, SC01, SC04

- **TI11** The private manual has a Slack section listing only what the owner does for this profile and naming credential names, never values.
  - Pattern: the WhatsApp and Signal sections of `docs/testing/channel-e2e-manual.md`; it links the guide for app creation rather than repeating it.
  - **Verify**: `cmd: git -C ../dartclaw-private grep -q -i -E "^## Slack" -- docs/testing/channel-e2e-manual.md && ! git -C ../dartclaw-private grep -n -E "xox[a-z]-[0-9A-Za-z-]{10,}|xapp-[0-9A-Za-z-]{10,}" -- docs/testing/channel-e2e-manual.md` – the section exists and holds no token-shaped value
  - **SATISFIES**: S07, SC01


## Final Validation Checklist

- `git diff --check` and `bash dev/tools/fitness/run_all.sh` over the public diff, and `git -C ../dartclaw-private diff --check` over the four private files, which stay uncommitted.
- The live qualification this story prepares runs after it, owner-led (PRD owner D22); the executor records no result.
