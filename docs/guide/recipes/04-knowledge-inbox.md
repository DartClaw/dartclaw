# Recipe 4: Knowledge Inbox

## Overview

Drop source files into a watched folder and let DartClaw extract durable knowledge from them automatically. Each file is processed through a bounded cron-session extraction turn that produces synthesized memory entries, a wiki page with provenance frontmatter, and temporal knowledge-graph facts. The original file moves to `processed/` on success or `quarantine/` after exhausting retries.

## Features Used

- [Knowledge inbox config](../configuration.md#full-config-reference) -- `knowledge.inbox.*` controls the drop folder, size limit, scan interval, retry/quarantine, and delivery
- [Memory](../workspace.md) -- synthesized findings are saved as memory entries with `category='knowledge-inbox'`
- [Wiki](../workspace.md) -- each processed file produces a wiki page under `<data_dir>/workspace/wiki/` with source-provenance frontmatter
- [Temporal KG](../workspace.md) -- extracted entity/predicate/value facts are stored in the knowledge graph (when enabled)
- [Wiki lint](../configuration.md#full-config-reference) -- the optional `knowledge.wiki_lint` job audits the wiki for stale pages, missing links, and provenance gaps
- [Delivery modes](../scheduling.md#delivery-modes) -- `announce`, `webhook`, or `none` for run-completion reports

## Configuration

Add this to your `dartclaw.yaml`:

```yaml
# --- Knowledge jobs (opt-in) ---
knowledge:
  inbox:
    enabled: true
    interval_minutes: 5        # how often the inbox folder is scanned
    max_bytes: 1048576         # 1 MiB per file (files larger than this are skipped)
    retry_attempts: 2          # processing attempts before quarantine
    processed_retention_days: 30   # days to keep files in processed/ before deletion
    delivery_mode: announce    # none | announce | webhook

  wiki_lint:                   # optional: audit wiki health on a schedule
    enabled: false
    interval_minutes: 60
    delivery_mode: announce
```

All `knowledge.inbox` fields are optional – the values above are the defaults. You only need `enabled: true` to start.

## Inbox Drop Folder

When the server starts with `knowledge.inbox.enabled: true`, it watches:

```
<server.data_dir>/workspace/inbox/
```

Drop files here and the scanner picks them up on the next interval tick. Subdirectories within `workspace/` are also created automatically: `processed/`, `quarantine/`, `skipped/`, and `wiki/`.

### Supported file types

| Extension | Notes |
|-----------|-------|
| `.md` | Markdown |
| `.txt` | Plain text |
| `.json` | JSON object or array |
| `.ndjson` | Newline-delimited JSON |

Files with any other extension (including `.pdf`) are moved to `skipped/` with an explanation.

### Size limit

Files larger than `max_bytes` (default 1 MiB) are skipped. The limit applies to the raw file size before processing.

### Stability window

The scanner waits 10 seconds after detecting a file and re-checks its size. If the file is still changing (e.g. a download in progress), it is skipped for the current scan and retried next interval.

## Processing Lifecycle

```
inbox/my-notes.md
  │
  ├── validate (extension, size, stability)
  │     └── fail → skipped/ (terminal)
  │
  ├── extraction turn (bounded cron session, 1 turn, no tools)
  │     ├── memory findings  →  memory entries (category: knowledge-inbox)
  │     ├── wiki page        →  workspace/wiki/<slug>.md  (provenance frontmatter)
  │     └── KG facts         →  temporal knowledge graph (if KG is enabled)
  │
  ├── success → processed/my-notes.md
  │               (deleted after processed_retention_days)
  │
  └── failure (all retry_attempts exhausted)
        → quarantine/my-notes.md
           quarantine/my-notes.md.error.json  (attempt count, error, timestamp)
```

Each file gets its own bounded cron session (visible in the web UI sidebar under the job id). The extraction turn runs with no outbound tools – the agent synthesizes knowledge from the file content alone.

### Extraction output

The extraction turn produces a structured JSON payload with three sections:

- **`memory_findings`** – one or more synthesized summaries, each saved as a memory entry prefixed with `Synthesized inbox finding from inbox/<filename>:`
- **`wiki_page`** – a slug, title, body, and confidence level (`high` / `medium` / `low`) written to `workspace/wiki/<slug>.md` with YAML frontmatter recording provenance, sources, confidence, and timestamps
- **`facts`** – temporal entity/predicate/value triples with ISO-8601 `valid_from` (required) and optional `valid_to`, inserted into the KG; conflicting facts are surfaced in the run report and excluded from the insert

Verbatim reproduction of the source is rejected at validation – the agent must synthesize, not copy.

### Knowledge-graph contradiction handling

If an extracted fact conflicts with an existing KG entry (same entity + predicate, overlapping time interval, different value), the conflicting fact is excluded and reported in the run summary. It is never silently discarded.

## Wiki Lint

When `knowledge.wiki_lint.enabled: true`, a separate scheduled job audits the wiki on the configured interval. It reports:

- **Stale pages** – not updated within 30 days
- **Missing links** – internal `.md` links that point to non-existent pages
- **Orphan pages** – pages with no inbound links (excluding `README.md`)
- **Provenance inconsistencies** -- pages missing required frontmatter fields or with invalid confidence values
- **KG contradictions** -- open conflicts between the knowledge graph entries

The lint result is delivered via `knowledge.wiki_lint.delivery_mode`.

## Delivery Modes

Both `knowledge.inbox` and `knowledge.wiki_lint` support:

| Value | Behavior |
|-------|----------|
| `none` | Job runs silently; result logged server-side |
| `announce` | Run-completion summary posted to the active session or channel |
| `webhook` | Summary delivered to the configured webhook |

## Customization Tips

- **Scan more or less frequently**: Adjust `interval_minutes`. The default of 5 minutes suits most drop-folder workflows.
- **Increase size limit**: Raise `max_bytes` for larger reference files. The limit is per-file, not per-run.
- **Tune retries**: `retry_attempts: 0` quarantines immediately on first failure; higher values are useful when transient I/O errors are expected.
- **Extend processed retention**: Increase `processed_retention_days` if you want to keep originals longer for reference.
- **Filter irrelevant topics**: Add a `## Not Relevant` section to your workspace `USER.md` – the extraction prompt reads it and omits those topics unless they provide essential supporting context.
- **Disable wiki lint**: Leave `knowledge.wiki_lint.enabled: false` (the default) if you only need memory/KG output.

## Troubleshooting

**File stays in `inbox/` after scan**
- Check server logs for the `knowledge-inbox` job – files still changing within the stability window are deferred, not skipped.
- Verify the file extension is `.md`, `.txt`, `.json`, or `.ndjson`.

**File moved to `skipped/`**
- Unsupported extension (including `.pdf`) or file exceeded `max_bytes`.
- Check the skipped entry name – the reason is logged alongside the filename in the run summary.

**File moved to `quarantine/`**
- All retry attempts failed. Read `quarantine/<filename>.error.json` for the error and attempt count.
- Common causes: extraction turn returned no findings, verbatim source reproduction detected, or malformed KG fact dates.

**Wiki page not appearing**
- Confirm the extraction turn produced a non-empty `wiki_page.body` – an empty body is a quarantine signal.
- Check the run summary in the cron session (web UI sidebar) for contradiction or validation details.

**No memory entries saved**
- If the extraction returned findings but none are visible in memory search, check that `memory.enabled` is not set to `false` in your config.

## Gotchas & Limitations

- **No real-time watch**: Processing is periodic, not inotify-based. Files dropped between scans are picked up on the next interval tick.
- **No exactly-once guarantee**: If the server crashes mid-write after some findings are committed, the file is reprocessed on the next run. Duplicate memory entries may result.
- **KG requires storage package**: Temporal KG storage is optional. When the KG is not wired (e.g. in minimal deployments), `facts` from the extraction are ignored without error.
- **`announce` delivery**: Posts a run summary (processed/skipped/quarantine counts) to the active session or channel. It does not push individual memory findings – query memory or the wiki directly to review extracted content.
