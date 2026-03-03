# Use-Case 5: Contact/CRM Tracker

## Overview

A lightweight contact management system built on WhatsApp. The agent receives messages from allowlisted contacts, extracts key information (names, action items, follow-ups, meeting notes), and stores structured data in memory. You can query your contact history and pending items via the web UI.

## Features Used

- [WhatsApp channel](../whatsapp.md) -- receives messages from contacts via DM allowlist
- [MEMORY.md](../workspace.md) -- stores structured contact data and action items
- [Memory search](../search.md) -- retrieves contact history and pending items on demand
- [Input sanitizer](../security.md) -- filters inbound messages for safety
- [Outbound redaction](../security.md) -- redacts any secrets in responses

## Configuration

Add this to your `dartclaw.yaml`:

```yaml
channels:
  whatsapp:
    enabled: true
    dm_access: allowlist
    dm_allowlist:
      - "491234567890@s.whatsapp.net"   # Alice
      - "441234567890@s.whatsapp.net"   # Bob
      - "11234567890@s.whatsapp.net"    # Carol

# Security features (enabled by default)
guards:
  input_sanitizer:
    enabled: true
  content_guard:
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
When processing a WhatsApp message:
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
- When responding to WhatsApp messages, be brief and helpful
- Confirm what you recorded: "Got it -- noted [action item] for follow-up by [date]"
- When asked about contacts or tasks, search memory and provide concise summaries
```

### USER.md

```markdown
# User Context
- Uses WhatsApp for business and personal communication
- Wants action items tracked automatically
- Prefers concise confirmations

# Contact Directory
- Alice (+49...): Project collaborator, Berlin
- Bob (+44...): Client, London
- Carol (+1...): Team member, New York
```

## Cron Prompts

This use-case does not use cron jobs. It is event-driven -- the agent responds when WhatsApp messages arrive from allowlisted contacts.

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

1. **Contact sends WhatsApp message** to the DartClaw number
2. **DM allowlist check** -- only messages from listed numbers are processed
3. **Input sanitizer** filters the message for safety
4. **Agent reads behavior files** -- SOUL.md for CRM instructions, USER.md for contact directory
5. **Agent extracts information** -- action items, deadlines, contact updates
6. **Data saved to memory** via memory_save with appropriate category (contacts, action-items, notes)
7. **Agent responds** with brief confirmation of what was recorded
8. **User queries later** via web UI: "What action items do I have with Alice?" or "Summarize last week's conversations"
9. **Agent searches memory** and returns structured results

## Customization Tips

- **Add Signal contacts**: Enable Signal channel alongside WhatsApp with similar allowlist config for multi-channel tracking
- **Add contact categories**: Extend the category system in SOUL.md (e.g., 'prospects', 'vendors', 'personal')
- **Weekly digest**: Add a weekly cron job to generate a comprehensive contact activity report
- **Auto-reminders**: Add a morning cron job that checks for overdue action items and announces them
- **Expand allowlist**: Add new contact JIDs to `dm_allowlist` as your network grows

## Gotchas & Limitations

- **Not a real CRM**: Data is stored as structured text in MEMORY.md, not a relational database. Complex queries (e.g., "all contacts in London with overdue tasks") may produce approximate results
- **WhatsApp must be connected**: Messages are only received when the WhatsApp sidecar (GOWA) is running and paired. Check connection status at `/settings` in the web UI
- **DM allowlist is manual**: New contacts must be added to `dm_allowlist` in `dartclaw.yaml` and the server restarted (or use live config if available)
- **No media extraction**: The agent processes text messages only. Images, voice notes, and documents are not parsed
- **Memory growth**: Active contact tracking generates many memory entries. Enable memory pruning (`memory.pruning.enabled: true`) to archive old entries automatically
- **Outbound redaction**: If contacts share sensitive data (API keys, passwords), the redactor strips it from stored responses but the raw inbound message is processed by the agent
