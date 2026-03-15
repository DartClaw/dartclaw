# Use-Case 5: Contact/CRM Tracker

## Overview

A lightweight contact management system built on messaging channels. The agent receives messages from allowlisted contacts via WhatsApp, Signal, or Google Chat, extracts key information (names, action items, follow-ups, meeting notes), and stores structured data in memory. You can query your contact history and pending items via the web UI.

## Features Used

- [Channels](../whatsapp.md) -- receives messages from contacts via DM allowlist (WhatsApp, [Signal](../signal.md), or [Google Chat](../google-chat.md))
- [MEMORY.md](../workspace.md) -- stores structured contact data and action items
- [Memory search](../search.md) -- retrieves contact history and pending items on demand
- [Input sanitizer](../security.md) -- filters inbound messages for safety
- [Outbound redaction](../security.md) -- redacts any secrets in responses
- [Session scoping](../configuration.md) -- controls how DM/group conversations are partitioned

## Configuration

Add this to your `dartclaw.yaml`:

```yaml
# Channel setup -- uncomment the channels you use
channels:
  whatsapp:
    enabled: true
    dm_access: allowlist
    dm_allowlist:                       # phone number (no +, no spaces) + @s.whatsapp.net
      - "491234567890@s.whatsapp.net"   # Alice (+49 123 456 7890)
      - "441234567890@s.whatsapp.net"   # Bob (+44 123 456 7890)
      - "11234567890@s.whatsapp.net"    # Carol (+1 123 456 7890)
    # task_trigger:                     # optional: create tasks from WhatsApp (0.9+)
    #   enabled: true
    #   prefix: "task:"
    #   auto_start: true

  # signal:                            # optional: add Signal alongside WhatsApp
  #   enabled: true
  #   phone_number: "+1234567890"
  #   dm_access: allowlist

  # google_chat:                       # optional: add Google Chat
  #   enabled: true
  #   service_account: ${GOOGLE_CHAT_SERVICE_ACCOUNT}
  #   dm_access: allowlist
  #   dm_allowlist:
  #     - "alice@example.com"

# Session scoping -- controls how DM conversations are partitioned
sessions:
  dm_scope: per-contact               # separate session per contact (recommended for CRM)
  group_scope: shared                 # one session per group
  maintenance:
    mode: enforce
    prune_after_days: 90              # auto-archive old contact sessions

# Security features
guards:
  enabled: true
  input_sanitizer:
    enabled: true
  content:
    enabled: true
```

## Behavior Files

### SOUL.md

```markdown
You are a CRM assistant that tracks contacts, conversations, and action items.

## Expertise
- Extracting structured information from casual messages
- Tracking action items, deadlines, and follow-ups
- Maintaining organized contact records

## Data Extraction Rules
When processing a message:
1. Identify the sender (from message metadata)
2. Extract any action items, deadlines, or commitments mentioned
3. Note any contact information shared (emails, phone numbers, addresses)
4. Summarize the conversation topic

## Storage Format
Save contact data using memory_save with structured entries:
- category='contacts' for contact info updates
- category='action-items' for tasks and follow-ups
- category='notes' for general conversation summaries

Always include the sender name and date in saved entries.

## Communication Style
- When responding to messages, be brief and helpful
- Confirm what you recorded: "Got it -- noted [action item] for follow-up by [date]"
- When asked about contacts or tasks, search memory and provide concise summaries
```

### USER.md

```markdown
# User Context
- Uses messaging channels for business and personal communication
- Wants action items tracked automatically
- Prefers concise confirmations

# Contact Directory
- Alice (+49...): Project collaborator, Berlin
- Bob (+44...): Client, London
- Carol (+1...): Team member, New York
```

## Cron Prompts

This use-case is event-driven -- the agent responds when messages arrive from allowlisted contacts. No cron jobs are required.

Optionally, add a daily summary job:

```yaml
scheduling:
  jobs:
    - id: crm-daily-summary
      prompt: >
        Review today's contact interactions and pending action items:
        1. Search memory for entries from today with category='action-items'
        2. List any overdue or upcoming deadlines
        3. Summarize key conversations
        Save a daily summary to memory with category='daily-crm-summary'
      schedule:
        type: cron
        expression: "0 18 * * 1-5"
      delivery: announce
```

## Workflow

1. **Contact sends a message** to your DartClaw number or Google Chat bot
2. **DM allowlist check** -- only messages from listed contacts are processed
3. **Input sanitizer** filters the message for safety
4. **Agent reads behavior files** -- SOUL.md for CRM instructions, USER.md for contact directory
5. **Agent extracts information** -- action items, deadlines, contact updates
6. **Data saved to memory** via memory_save with appropriate category (contacts, action-items, notes)
7. **Agent responds** with brief confirmation of what was recorded
8. **User queries later** via web UI: "What action items do I have with Alice?" or "Summarize last week's conversations"
9. **Agent searches memory** and returns structured results

## Customization Tips

- **Multi-channel tracking**: Enable Signal and/or Google Chat alongside WhatsApp -- all channels write to the same memory, so contact history is unified
- **Add contact categories**: Extend the category system in SOUL.md (e.g., 'prospects', 'vendors', 'personal')
- **Weekly digest**: Add a weekly cron job to generate a comprehensive contact activity report
- **Auto-reminders**: Add a morning cron job that checks for overdue action items and announces them
- **Manage allowlists via API**: Use `PATCH /api/config` to add/remove contacts without restarting the server (available since 0.6). Or edit allowlists in the web UI at `/settings/channels/<channel_type>`
- **Task triggers (0.9+)**: Enable `task_trigger` on a channel so contacts can create background tasks by prefixing messages with `task:`. See [Common Patterns](_common-patterns.md#channel-to-task-integration-09)
- **Session scoping**: `dm_scope: per-contact` (default) gives each contact their own session history. Use `per-channel-contact` if the same person contacts you from multiple channels and you want separate sessions per channel

## Gotchas & Limitations

- **Not a real CRM**: Data is stored as structured text in MEMORY.md, not a relational database. Complex queries (e.g., "all contacts in London with overdue tasks") may produce approximate results
- **Channel must be connected**: Messages are only received when the channel sidecar (GOWA for WhatsApp, signal-cli for Signal) is running and paired. Google Chat uses webhooks (no sidecar). Check connection status at `/settings` in the web UI
- **No media extraction**: The agent processes text messages only. Images, voice notes, and documents are not parsed
- **Session maintenance recommended**: Active contact tracking accumulates many sessions. Configure `sessions.maintenance` to auto-prune old sessions -- see [Common Patterns](_common-patterns.md#session-maintenance)
- **Outbound redaction**: If contacts share sensitive data (API keys, passwords), the redactor strips it from stored responses but the raw inbound message is processed by the agent
