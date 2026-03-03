# Scheduled Task Queue

## Overview

Multiple scheduled jobs running at different intervals to form a task automation pipeline. Combines health checks, report generation, and maintenance tasks -- each with its own schedule and delivery mode.

## Features Used

- **[Cron scheduling](../scheduling.md)** -- multiple jobs with cron expressions
- **[Interval scheduling](../scheduling.md)** -- short-interval jobs for monitoring
- **[Delivery modes](../scheduling.md#delivery-modes)** -- `announce`, `webhook`, and `none` for different job types
- **[HEARTBEAT.md](../workspace.md)** -- periodic checklist for ongoing monitoring tasks

## Configuration

Add this to your `dartclaw.yaml`:

```yaml
data_dir: ~/.dartclaw

agent:
  model: sonnet
  max_turns: 50

concurrency:
  max_parallel_turns: 3

scheduling:
  heartbeat:
    enabled: true
    interval_minutes: 30
  jobs:
    - id: health-check
      prompt: >
        Run a quick health check. Review TOOLS.md for endpoints to monitor.
        Report status of each endpoint (up/down/degraded).
        Only flag issues -- if everything is healthy, respond with "All systems nominal."
      schedule:
        type: interval
        minutes: 5
      delivery: none

    - id: daily-report
      prompt: >
        Generate an end-of-day summary report. Include:
        1. System health overview from today's checks
        2. Any issues or anomalies detected
        3. Action items that need attention
        Format as a brief status report.
      schedule:
        type: cron
        expression: "0 18 * * *"
      delivery: announce

    - id: weekly-cleanup
      prompt: >
        Perform weekly maintenance:
        1. Review MEMORY.md for stale or outdated entries
        2. Summarize the week's health check patterns
        3. Suggest any configuration improvements
        Write findings to MEMORY.md via memory_save.
      schedule:
        type: cron
        expression: "0 3 * * 0"
      delivery: none
```

## Behavior Files

### SOUL.md

```markdown
You are a system administrator assistant that monitors services and maintains operational health.

## Expertise
- System health monitoring and status reporting
- Log analysis and anomaly detection
- Operational maintenance and cleanup

## Communication Style
- Status-oriented: up/down/degraded
- Flag issues prominently
- Keep reports concise and actionable
```

### TOOLS.md

```markdown
# Environment Notes
- Health endpoint: https://status.example.com/api/health
- API endpoint: https://api.example.com/v1/status
- Dashboard: https://grafana.example.com
```

### HEARTBEAT.md

```markdown
- [ ] Check if any monitored endpoints have changed status
- [ ] Review recent logs for warning patterns
- [ ] Verify disk space and resource usage are within limits
```

The heartbeat processes this checklist every 30 minutes (as configured above), complementing the scheduled jobs with continuous monitoring.

## Cron Prompts

Each job has its own prompt tailored to its purpose:

**Health check** (every 5 minutes):
> Run a quick health check. Review TOOLS.md for endpoints to monitor. Report status of each endpoint (up/down/degraded). Only flag issues -- if everything is healthy, respond with "All systems nominal."

**Daily report** (6 PM daily):
> Generate an end-of-day summary report. Include: system health overview, issues detected, action items. Format as a brief status report.

**Weekly cleanup** (Sunday 3 AM):
> Perform weekly maintenance: review MEMORY.md for stale entries, summarize health check patterns, suggest configuration improvements. Write findings to MEMORY.md.

## Workflow

Multiple jobs coexist and run independently:

1. **Health check fires every 5 minutes** -- quick status check, results logged only (`delivery: none`)
2. **Heartbeat fires every 30 minutes** -- processes HEARTBEAT.md checklist in an isolated session, runs memory consolidation if needed
3. **Daily report fires at 6:00 PM** -- summarizes the day's findings and delivers via `announce` to the active session or channel
4. **Weekly cleanup fires Sunday at 3:00 AM** -- maintenance tasks, results saved to MEMORY.md

Each job runs in its own isolated session. Jobs do not share state directly -- they communicate through MEMORY.md. The `max_parallel_turns: 3` setting limits how many concurrent agent turns can run.

## Customization Tips

- **Add/remove jobs**: Each `- id:` block is independent. Add new jobs or remove ones you don't need
- **Mix cron and interval schedules**: Use `type: interval` for frequent checks and `type: cron` for time-of-day tasks
- **Use webhook delivery**: For jobs that should notify external systems:
  ```yaml
  - id: alert-check
    prompt: "Check for critical alerts and report any findings."
    schedule:
      type: interval
      minutes: 10
    delivery: webhook
  ```
- **Add environment-specific endpoints**: Put server URLs, API keys, and monitoring targets in TOOLS.md
- **Adjust concurrency**: Increase `max_parallel_turns` if you have many concurrent jobs, or decrease it to reduce resource usage

## Gotchas & Limitations

- **Jobs run in isolated sessions** -- there is no shared state between jobs except via MEMORY.md. A health check cannot directly pass data to the daily report
- **`max_parallel_turns` limits concurrent execution** -- if multiple jobs trigger simultaneously and the limit is reached, excess jobs queue until a slot opens
- **Interval jobs drift over time** -- `type: interval` measures time since the last run, not wall-clock alignment. A 5-minute interval job started at 10:03 runs at 10:08, 10:13, etc., not at 10:05, 10:10
- **Webhook delivery requires a reachable endpoint** -- the agent POSTs results to the configured URL. If the endpoint is down, the result is logged but delivery fails
- **Heartbeat and cron are independent** -- the heartbeat processes HEARTBEAT.md on its own timer, separate from cron jobs. They can overlap
