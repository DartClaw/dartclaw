# Troubleshooting

Common issues when running DartClaw as a personal assistant or automation platform. Check these before diving into logs.

## Scheduled Jobs

### Job not firing

1. **Is the server running?** Cron jobs only fire when `dartclaw serve` is active
2. **Check timezone**: Cron expressions use server-local time. Run `date` on your server to confirm. If your server is UTC but you want 7 AM Berlin time, use `0 5 * * *` in winter (UTC+1) or `0 4 * * *` in summer (UTC+2)
3. **Check syntax**: Cron uses 5-field format: `minute hour day-of-month month day-of-week`. Common mistake: `7 0 * * *` fires at 12:07 AM, not 7:00 AM (should be `0 7 * * *`)
4. **Enable verbose logging**: Set `logging.level: FINE` and look for `Scheduling` or `CronScheduler` entries
5. **Test with interval**: Replace your cron expression with a short interval to verify the job runs:
   ```yaml
   schedule:
     type: interval
     minutes: 1
   ```

### Job fires but produces no output

1. **Check `delivery` mode**: `delivery: none` means output goes to logs only, not to any session or channel
2. **Check the prompt**: If your prompt says "skip if empty" and the input files (MEMORY.md, errors.md) are empty, the agent may do nothing. Check the cron session in the web UI sidebar
3. **Model availability**: If the configured model is unavailable or the API key is invalid, the turn will fail silently. Check logs for API errors

### Job fires but `announce` doesn't reach my phone

> **Known limitation**: `announce` delivery is currently a placeholder. Job results are logged but not routed to channels or web sessions. This is tracked for implementation. For now, use `delivery: none` and check cron session results in the web UI sidebar, or use `delivery: webhook` to POST results to an external endpoint.

If/when announce routing is implemented:
1. **Is a channel connected?** `announce` will need at least one active target. Check `/settings` in the web UI for channel connection status
2. **Check channel health**: WhatsApp requires the GOWA sidecar to be running and paired. Signal requires `signal-cli` to be running. Google Chat uses webhooks (no sidecar)
3. **Check logs**: Look for "announce" or "delivery" in the logs to see where the result was routed

## Memory & Consolidation

### MEMORY.md keeps growing / consolidation not running

1. **Is heartbeat enabled?** Memory consolidation only runs during heartbeat cycles:
   ```yaml
   scheduling:
     heartbeat:
       enabled: true
       interval_minutes: 60
   ```
2. **Check `memory_max_bytes`**: Consolidation only triggers when MEMORY.md exceeds this threshold. Default is 32KB (`32768`). If you set it very high, consolidation may never trigger
3. **Is heartbeat firing?** Check logs for `HeartbeatScheduler` entries. If heartbeat is enabled but not firing, check that the server has been running long enough for the interval to elapse

### Memory search returns nothing

1. **Has the search index been built?** Run `dartclaw rebuild-index` to rebuild the FTS5 index
2. **Are entries being saved?** Check MEMORY.md directly -- does it contain the entries you expect?
3. **Search backend**: FTS5 uses keyword matching. If you're searching for concepts rather than exact words, consider enabling QMD hybrid search (`search.backend: qmd`)

## Git Sync

### Git sync not committing

1. **Is git sync enabled?**
   ```yaml
   workspace:
     git_sync:
       enabled: true
   ```
2. **Is the workspace a git repo?** Run `ls -la <data_dir>/workspace/.git` to check. If not: `cd <data_dir>/workspace && git init`
3. **Are there changes to commit?** Git sync only commits when workspace files change. If nothing changed since the last heartbeat, no commit is created

### Git push failing

1. **Is a remote configured?** Run `cd <data_dir>/workspace && git remote -v`. If empty: `git remote add origin <url>`
2. **Is `push_enabled` set?**
   ```yaml
   workspace:
     git_sync:
       push_enabled: true
   ```
3. **Authentication**: SSH keys or credential helpers must be configured for the git user running `dartclaw`. Test with `cd <data_dir>/workspace && git push` manually

## Channels

### WhatsApp messages not reaching DartClaw

1. **Is GOWA running?** The WhatsApp sidecar must be running and paired. Check `/settings` in the web UI
2. **Is the sender allowlisted?** If `dm_access: allowlist`, the sender's JID must be in `dm_allowlist`. JID format: international phone number + `@s.whatsapp.net` (e.g., `+49 123 456 7890` → `491234567890@s.whatsapp.net`)
3. **Is the sender paired?** If `dm_access: pairing`, the sender must be approved via the pairing flow in the web UI at `/settings/channels/whatsapp`
4. **Input sanitizer blocking?** If `guards.input_sanitizer.enabled: true`, the message may have been blocked. Check the guard audit log at `/health-dashboard`

### Google Chat bot not responding

1. **Is the webhook URL correct?** The Google Chat app must be configured to send events to `https://<your-host>/google-chat/webhook` (or your custom `webhook_path`)
2. **Is JWT verification passing?** Check logs for authentication errors. The `service_account` must match the GCP project
3. **Is the sender allowlisted?** Check `dm_access` and `dm_allowlist` settings

## General

### Server won't start

1. **Port conflict**: Another process may be using the configured port. Check with `lsof -i :<port>`
2. **Invalid config**: Run `dartclaw --config <path> serve` and check for YAML parsing errors in the output
3. **Missing data directory**: The `data_dir` must exist or be creatable. Check permissions

### High API costs

1. **Check cron frequency**: A 5-minute interval job makes ~288 API calls/day. Consider whether you need that frequency
2. **Use cheaper models for scheduled jobs**: Set `agent.agents.cron.model: sonnet` or `haiku` for routine work
3. **Check `max_turns`**: High `max_turns` values allow the agent to use more tool calls per session. Lower values cap API usage per job
4. **Review heartbeat interval**: A 30-minute heartbeat with an active HEARTBEAT.md checklist also consumes tokens. Consider 60 or 120 minutes if your checklist is simple
5. **Monitor usage**: Check the memory dashboard at `/memory` for token usage trends (if `usage.budget_warning_tokens` is configured)

### How do I know my assistant is working?

See [Monitoring Your Assistant](_common-patterns.md#monitoring-your-assistant).
