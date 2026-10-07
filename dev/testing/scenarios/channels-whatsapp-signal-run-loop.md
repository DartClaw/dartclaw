---
profile: channels
viewport: desktop
port: 3336
auth_token: devtoken0
---
# Scenario: WhatsApp And Signal Run Loop

Proves on paired WhatsApp and Signal devices that a workflow run started from a DM or a group posts plain messages to that origin, that an admin resumes it by asking the agent, and that a non-admin is refused. These channels have no buttons and no threads, so the agent tools are the only way to resolve a run from chat. WhatsApp is ledger row Q28-R04 (S1, S2) and Signal is Q28-R05 (S3, S4); their green result is the WhatsApp and Signal half of Q28-M05. Facts live in `dev/testing/0.28-qualification.md`.

Mark each step as the file convention says. A step where the model chooses the tool allows one retry and records it. `$DATA` is `DARTCLAW_CHANNELS_DATA_DIR`; the Runner reads `$DATA/audit-<UTC date>.ndjson` for audit entries.

Preparation (Owner, once): pair both devices as the private channel manual describes; list your own WhatsApp ID and Signal number under `governance.admin_senders`; open a test group on each channel (`group_access: allowlist` and the group in its allowlist, as the manual describes); register the workflow fixture project. None of these values is written into the repository.

The approval-gated run is `plan-and-implement` with `PLAN_REVIEW=true`, on the fixture project and the smallest scope `workflow-plan-and-implement-publish` S2 uses.

## S1: WhatsApp, Run Started From A DM And A Group

### Steps

1. Owner: in a DM to the bot, ask it to start the approval-gated run. Conversational: allow one retry and record it
2. Runner: watch the DM until the awaiting-approval message arrives and record every post of the run
3. Owner: reply in the DM "Approve the run" (Conversational)
4. Runner: wait for the finished post and read the audit entries for the run
5. Owner: repeat steps 1 to 4 in the test group, mentioning the bot as the group requires
6. Owner: temporarily replace your ID in `governance.admin_senders` with another contact's ID and Runner: restart the profile
7. Owner: start a third gated run in the DM, then ask the bot to approve it
8. Owner: restore your ID in `governance.admin_senders`; Runner: restart the profile; Owner: ask the bot to cancel the run with the reason "Plan not wanted"

### Expected

- Each run posts started, awaiting-approval and finished messages as plain messages to the DM or group it was started from, one message each, with no buttons and no thread
- The awaiting-approval message names the run and the step it waits at
- As an admin, asking the bot to approve resumes the run and the audit log holds one allow entry with the channel, the sender, the run and the step
- As a non-admin, the request is refused in the reply, the run stays at the gate, and the audit log holds a deny entry
- As an admin again, the cancel resolves the run with the reason recorded


## S2: WhatsApp, Existing Behaviour

### Steps

1. Owner: send the bot a normal question in the DM and in the test group
2. Owner: start a task that ends in review from the DM and note the task notifications

### Expected

- Both questions are answered as before this milestone
- Task notifications arrive as plain messages with no thread


## S3: Signal, Run Started From A DM And A Group

### Steps

1. Owner: in a DM to the bot, ask it to start the approval-gated run. Conversational: allow one retry and record it
2. Runner: watch the DM until the awaiting-approval message arrives and record every post of the run
3. Owner: reply in the DM "Approve the run" (Conversational)
4. Runner: wait for the finished post and read the audit entries for the run
5. Owner: repeat steps 1 to 4 in the test group, mentioning the bot as the group requires
6. Owner: temporarily replace your number in `governance.admin_senders` with another contact's, and Runner: restart the profile
7. Owner: start a third gated run in the DM, then ask the bot to approve it
8. Owner: restore your number in `governance.admin_senders`; Runner: restart the profile; Owner: ask the bot to cancel the run with the reason "Plan not wanted"

### Expected

- Each run posts started, awaiting-approval and finished messages as plain messages to the DM or group it was started from, one message each, with no buttons and no thread
- As an admin, asking the bot to approve resumes the run and the audit log holds one allow entry with the channel, the sender, the run and the step
- As a non-admin, the request is refused in the reply, the run stays at the gate, and the audit log holds a deny entry
- As an admin again, the cancel resolves the run with the reason recorded


## S4: Signal, Existing Behaviour

### Steps

1. Owner: send the bot a normal question in the DM and in the test group
2. Owner: start a task that ends in review from the DM and note the task notifications

### Expected

- Both questions are answered as before this milestone
- Task notifications arrive as plain messages with no thread
