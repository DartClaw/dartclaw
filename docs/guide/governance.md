# Governance

DartClaw's governance subsystem guards against runaway cost, infinite agent loops, and abusive inbound traffic. All five mechanisms — admin senders, rate limits, daily token budgets, loop detection, and the emergency control commands — are **disabled or unlimited by default**, so a fresh install behaves as before until you opt in.

This page covers how each mechanism behaves and how they interact. For the raw YAML field reference and validation rules, see the [governance block in the configuration reference](configuration.md#full-config-reference).

## Admin Senders

Admin senders are user IDs listed under `governance.admin_senders`. They are the only users permitted to invoke the emergency control commands (`/stop`, `/pause`, `/resume`).

```yaml
governance:
  admin_senders:
    - "users/123456789012345"   # Google Chat sender ID
```

**Default behaviour**: when the list is empty, every sender is treated as an admin. This matches the single-user dev experience. Once you add at least one ID, non-listed senders lose admin powers.

**What admin sender status grants**:

- Exemption from `governance.rate_limits.per_sender.*` checks.
- Permission to invoke reserved commands without rate-limit blocking.

**What it does *not* grant**:

- Exemption from the daily token budget — budgets apply server-wide regardless of who sent the turn.
- Exemption from loop detection.
- Exemption from the `governance.rate_limits.global.turns` ceiling, which counts all turns across all senders.

The exemption is intentionally narrow so a misbehaving admin still cannot bankrupt the day's token budget.

## Rate Limits

Two independent sliding-window limiters protect inbound traffic and total agent work:

| Limit | Scope | What it bounds |
|-------|-------|---------------|
| `governance.rate_limits.per_sender.{messages, window}` | One sender | Inbound messages per sliding window per sender |
| `governance.rate_limits.global.{turns, window}` | All senders | Agent turns per sliding window across the whole server |

```yaml
governance:
  rate_limits:
    per_sender:
      messages: 10        # 0 = unlimited
      window: 5m
    global:
      turns: 30           # 0 = unlimited
      window: 1h
```

Either limit set to `0` disables that side. Per-sender limits are evaluated first; admin senders bypass the per-sender check but still contribute to the global turn count. Window durations accept `m`, `h`, and `d` suffixes (see [configuration reference](configuration.md#full-config-reference)).

When a sender exceeds the per-sender limit, the message is rejected before any agent work starts. When the global cap is reached, new turns are blocked until the window slides.

## Daily Token Budget

`governance.budget` caps the total tokens consumed across all sessions in a calendar day:

```yaml
governance:
  budget:
    daily_tokens: 250000   # 0 = unlimited
    action: block          # block | warn
    timezone: "UTC+1"
```

The budget resets at midnight in the configured timezone. Only fixed UTC offsets are supported (`UTC`, `UTC+N`, `UTC-N`); IANA names like `Europe/Stockholm` are **not** accepted and fall back to UTC with a warning — see the configuration note on `governance.budget.timezone` in the [configuration reference](configuration.md#full-config-reference). DST is not handled automatically.

**Actions**:

- `block` — once the day's token total reaches the cap, subsequent turns are refused until the next reset.
- `warn` — turns continue, but an alert is emitted once the cap is exceeded.

A soft warning is emitted at 80% of the cap regardless of `action`. This warning state is in-memory only and resets when the server restarts.

Daily budgets apply to everyone, including admin senders. This is deliberate: emergency overrides exist for control flow (`/stop`), not for spending.

## Loop Detection

`governance.loop_detection` watches for runaway agents that keep taking turns without making progress. Three independent heuristics run in parallel; each fires when its own threshold is crossed:

```yaml
governance:
  loop_detection:
    enabled: false
    max_consecutive_turns: 5
    max_tokens_per_minute: 10000
    velocity_window_minutes: 2
    max_consecutive_identical_tool_calls: 5
    action: abort           # abort | warn
```

| Heuristic | Trigger |
|-----------|---------|
| **Consecutive autonomous turns** | More than `max_consecutive_turns` turns without human input. Any inbound message from a user resets the counter. |
| **Token velocity** | Tokens spent inside the last `velocity_window_minutes` exceed `max_tokens_per_minute * velocity_window_minutes`. |
| **Identical tool calls** | Same tool invoked with the same arguments more than `max_consecutive_identical_tool_calls` times in a row. |

Each threshold can be disabled individually by setting it to `0`. When `enabled: false`, none of them run.

**Actions**:

- `abort` — the current turn is cancelled and a `loop_detected` alert is emitted on the SSE event stream.
- `warn` — the agent keeps running, but the alert is still emitted so an operator can intervene.

Loop detector state is in-memory and resets on server restart. Set thresholds high enough to tolerate normal agent behaviour — for example, a long-running coding task may legitimately make many similar tool calls in sequence — and tune downward only after observing the alerts in practice.

## Emergency Control Commands

Three reserved commands give an admin sender immediate control over the server, regardless of which channel they arrive on:

| Command | Effect |
|---------|--------|
| `/stop` | Cancels every task currently in `running` or `queued` state, cancels all active turns, and emits an `emergency_stop` SSE broadcast. Tasks already in `draft`, `review`, or `accepted` states are untouched. |
| `/pause` | Sets a server-wide pause flag. Inbound messages from any sender are held in a bounded per-sender queue instead of starting agent work. |
| `/resume` | Atomically clears the pause flag and drains the queue. Per-sender queued messages are collapsed into a single structured prompt before delivery, so the agent sees one coalesced input rather than a flood. |

These commands bypass the per-sender rate limiter — a paused server can always be resumed by an admin. They are server-wide: there is no per-task or per-channel scope. Non-admin senders who invoke them get a permission-denied response and the agent state is unchanged.

`/stop` is reflected in the audit log and on the SSE event bus, so operators can see who triggered it and what was cancelled. Re-running the agent afterwards is a manual decision — there is no automatic restart.

## See also

- [Configuration § Full Config Reference](configuration.md#full-config-reference) — full YAML field reference and validation rules
- [Tasks](tasks.md) — per-task `tokenBudget` overrides supplement the global daily budget
- [Web UI & API](web-ui-and-api.md) — SSE event stream where governance alerts surface
- [Security](security.md) — guard chain, authentication, and isolation (governance and guards are complementary layers)
