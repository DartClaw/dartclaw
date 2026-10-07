---
profile: channels
viewport: desktop
port: 3336
auth_token: devtoken0
---
# Scenario: Google Chat Run Loop

Proves on a real Google Chat space that a workflow run started from a thread posts its lifecycle into that thread, that its approval card and Request changes dialog behave for admins and non-admins, and that the existing task cards still work. It is ledger row Q28-R03 and settles Q28-F20 to Q28-F23; its green result is the Google Chat half of Q28-M05. Facts live in `dev/testing/0.28-qualification.md`; this file states only the steps and what to observe.

Mark each step as the file convention says. A conversational step allows one retry and records it. `$DATA` is `DARTCLAW_CHANNELS_DATA_DIR`; the Runner reads `$DATA/audit-<UTC date>.ndjson` for audit entries.

Preparation (Owner, once): pair the bot with a test space as the private channel manual describes; keep the profile's `channels.google_chat` block enabled; list your own `users/<id>` under `governance.admin_senders`; keep `features.thread_binding.enabled: true`; register the workflow fixture project. None of these values is written into the repository.

The approval-gated run is `plan-and-implement` with `PLAN_REVIEW=true`, on the fixture project and the smallest scope `workflow-plan-and-implement-publish` S2 uses.

## S1: A Run Started From A Thread Posts Its Lifecycle There

### Steps

1. Owner: in a thread of the test space, ask the bot to start the approval-gated run. Conversational: allow one retry and record it
2. Runner: watch the space and the audit log until the awaiting-approval card appears, and record every post of the run and the thread it landed in

### Expected

- A started post and an awaiting-approval card appear in the same thread the run was started from, not as new top-level messages
- The awaiting-approval card has **Approve**, **Reject** and, if the gate names a revise step, **Request changes**


## S2: An Admin Approves On The Card

### Steps

1. Owner: click **Approve** on the card as a listed admin (Q28-F22)
2. Owner: look at the card after the click and try to click it again
3. Runner: wait for the finished post and read the audit entries for the run

### Expected

- The run resumes, and the card is edited to say who resolved it and when
- The card has no buttons after the click, so there is nothing to click again (Q28-F22)
- A finished or failed post follows in the same thread
- The audit log holds one allow entry for the run, with the channel, the sender, the run and the step


## S3: A Non-Admin Is Refused, And Who Sees The Refusal

### Steps

1. Owner: temporarily replace your ID in `governance.admin_senders` with another member's ID, then Runner: restart the profile
2. Owner: start a second gated run as in S1, then click **Approve** on its card
3. Owner: ask a second member of the space what, if anything, they saw appear after your click (Q28-F20)
4. Runner: read the audit entries for the refusal

### Expected

- The click is refused, the run stays at the gate, and the card keeps its buttons
- The refusal text is visible only to you, not to the second member, or the opposite is recorded in the ledger (Q28-F20)
- The audit log holds a deny entry with the channel, the sender, the run and the step


## S4: Request Changes Opens A Dialog

Restore your ID in `governance.admin_senders` and restart the profile first, then use the gated run of S3 step 2 or start a new one.

### Steps

1. Owner: click **Request changes**, enter "Reduce the plan to a single story" and submit (Q28-F23)
2. Runner: watch the run return to the revise step and pause at the same gate, and read the log for the dialog event's `postMessageId` handling (Q28-F23)
3. Owner: click **Request changes** again and submit with the feedback field blank. Watch whether the dialog stays open and what it shows (Q28-F21)
4. Owner: temporarily replace your ID in `governance.admin_senders`, restart the profile, and click **Request changes** as a non-admin; ask a second member whether they saw the dialog (Q28-F21)
5. Owner: restore your ID in `governance.admin_senders`, restart the profile, and click **Reject** on the card

### Expected

- A submission with text closes the dialog, the run returns to the gate and the card names the revision round (Q28-F23)
- The log shows the card was found through the identifier the dialog echoed back, not through a message in the submission (Q28-F23)
- A blank submission keeps the dialog open with the reason under the field, or the dialog closing is recorded in the ledger (Q28-F21)
- The non-admin's dialog holds only the refusal, with no form, and only the person who clicked sees it (Q28-F21)
- **Reject** cancels the run and the card loses its buttons


## S5: Task Cards Are Unchanged

### Steps

1. Owner: with thread binding on, start a task from the test space that ends in review (a mandatory-review task, see the tasks guide)
2. Owner: on the task's review card, click **Accept**, then repeat with a second task and click **Reject**

### Expected

- The task's notifications open one thread in the space and the review card carries **Accept** and **Reject** buttons exactly as before this milestone
- **Accept** accepts the task and **Reject** rejects it, each with the same card update as before
- No run-approval wording appears on a task card
