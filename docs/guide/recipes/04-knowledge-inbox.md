# Recipe 4: Knowledge Inbox

## Overview

Drop source files into a watched folder and let DartClaw extract durable knowledge from them automatically. Each file is processed through a bounded cron-session extraction turn that produces synthesized memory observations, a wiki page with provenance frontmatter, and temporal knowledge-graph facts. The original file moves to `processed/` on success or `quarantine/` after exhausting retries.

## Features Used

- [Knowledge inbox config](../configuration.md#full-config-reference) -- `knowledge.inbox.*` controls the drop folder, size limit, scan interval, retry/quarantine, extraction effort, and delivery
- [Memory](../workspace.md) -- synthesized findings are captured through `memory_observe` with `role='observation'` and host-bound inbox provenance
- [Wiki](../workspace.md) -- each processed file produces a wiki page under `<data_dir>/workspace/wiki/` with source-provenance frontmatter
- [Temporal KG](../workspace.md) -- extracted entity/predicate/value facts are stored in the knowledge graph (when enabled)
- [Wiki lint](../configuration.md#full-config-reference) -- the optional `knowledge.wiki_lint` job audits the wiki for broken links, unreachable pages, and provenance gaps
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
    effort: medium             # reasoning effort for the extraction turn

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
  │     └── memory findings, wiki page, KG facts
  │
  ├── merge turn (only when a page is already stored at the chosen slug;
  │   its own bounded cron session, 1 turn, no tools)
  │     └── integrated | unchanged | new, plus the merged body
  │
  ├── durable writes, once the merge is settled
  │     ├── memory findings  →  memory observations (role: observation)
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

Each turn gets its own bounded cron session (visible in the web UI sidebar under the job id), so the merge turn never reads the extraction turn's context. Both run with no outbound tools – the agent synthesizes and merges from the documents in its prompt alone.

### Extraction output

The extraction turn produces a structured JSON payload with three sections:

- **`memory_findings`** – one or more synthesized summaries, each captured as an observation prefixed with `Synthesized inbox finding from inbox/<filename>:`
- **`wiki_page`** – a slug, title, body, and confidence level (`high` / `medium` / `low`) written to `workspace/wiki/<slug>.md` with YAML frontmatter recording provenance, sources, confidence, and timestamps
- **`facts`** – temporal entity/predicate/value triples with ISO-8601 `valid_from` (required) and optional `valid_to`, inserted into the KG; conflicting facts are surfaced in the run report and excluded from the insert

Verbatim reproduction of the source is rejected at validation – the agent must synthesize, not copy. The check requires the *entire* normalized source as one contiguous substring, so a faithful restatement does not trip it; an output that does is a copy, and the file is quarantined (see [Troubleshooting](#troubleshooting)).

The extraction contract asks for complete transfer, not compression: a curated source should reach the wiki page with its named concepts, frameworks, enumerated lists, and citations intact. The instruction itself is the substantive half of that – over-compression is an instruction-following failure, and "completeness outranks brevity" is the instruction. `knowledge.inbox.effort` buys the turn more deliberation, which is a different lever: it does not raise an output ceiling, because the synthesis has to land in one assistant message either way.

### What the coverage report can and cannot tell you

`coverage` is source bytes against synthesized bytes, per file (`coverage: lossy.md 14.2KB->3.1KB (22%)`). It is the one coverage signal no prompt can talk around, and it measures the extraction turn's own synthesis – never the page it was merged into, which would credit this source with everything earlier batches contributed. There is no single right ratio – raw meeting notes should compress hard, an already-curated batch should not – so read it against the kind of source you are feeding, and calibrate per corpus rather than per run.

For the first two or three batches of a new source set, compare `workspace/wiki/<slug>.md` against the source still sitting in `processed/`. Note the clock: `processed/` purges at `processed_retention_days` (default 30), so the evidence that comparison needs expires.

If a large source cannot reach acceptable coverage at any effort setting, the binding constraint is the single-turn output budget rather than deliberation, and the fix is to split the source before dropping it in. Chunking inside the pipeline is not implemented.

### Wiki slug collisions

Slugs are chosen by the extraction turn, so a follow-up batch on a known topic usually lands on a page that already exists. DartClaw detects that in host code – a page is stored at the slug the extraction named – and then runs a second, page-scoped **merge turn** that is shown the stored page body and the new synthesis, both as data, and returns one of three declarations:

| Declaration | What DartClaw writes | Run summary |
|-------------|----------------------|-------------|
| `integrated` | the merged body replaces the stored body, under the page's existing title heading | `(integrated)`, or `(integrated, removed: …)` when the merge declared what it dropped |
| `unchanged` | nothing but the `sources` union – no content and no authorship field moves | `(unchanged, no new content)` |
| `new` | the new synthesis is appended under a `## Supplement from <source> (<date>)` heading, as before | `(supplement)` |

The model declares *how* to merge; DartClaw decides whether the declaration is admissible and performs the write. A declaration it cannot read – no `merge` value, one it does not recognise, one naming a different page, or an `integrated` with no body – quarantines the source with that reason and leaves the stored page untouched. So does an `integrated` body under **80%** of the stored body's size that declares nothing removed: the page is the only copy of every prior batch, so a merge that silently drops most of it is refused. That floor is fixed in the code, not a config key.

Nothing durable is written until the merge is settled, so a refused collision leaves no memory observation and no KG fact either. Every other rule is unchanged by which declaration arrives: the frontmatter `sources` list is the union of the stored and new sources, so the provenance chain stays complete. A page whose stored `provenance` differs from the writer's -- a hand-authored page an inbox batch merged into -- becomes `hybrid` rather than being relabelled as machine-authored, which keeps it ranked and labelled as trusted in search. A stored `provenance` value outside that vocabulary – anything this pipeline did not author and does not recognise – is written back untouched rather than promoted, and the wiki lint job reports it so you can classify it yourself. `confidence` becomes the weaker of the stored and incoming values, because a page mixing a curated section with a machine merge is only as strong as its weakest part; a stored value outside `high` / `medium` / `low` is written back untouched – the same rule as provenance – and the wiki lint job reports it as invalid. Frontmatter keys the pipeline does not own (`contradicts`, `related`, and anything you added by hand) are carried through unchanged.

Re-dropping a source the page already covers yields `unchanged`: the body is untouched and the file gains no section. A source new to the page is still added to `sources`, because its knowledge is demonstrably on the page. That is also what makes a retried ingestion safe – both model turns are retried, the durable writes run once.

A stored page the pipeline cannot parse – an unterminated frontmatter block, a leading `---` block whose content is not a YAML mapping, a file that is not valid UTF-8 – is **refused, never rewritten**. The inbox source quarantines with an error naming the wiki page, because the page is what you have to repair.

### Knowledge-graph contradiction handling

If an extracted fact conflicts with an existing KG entry (same entity + predicate, overlapping time interval, different value), the conflicting fact is excluded and reported in the run summary. It is never silently discarded.

## Wiki Lint

When `knowledge.wiki_lint.enabled: true`, a separate scheduled job audits the wiki on the configured interval. Every category is a structural claim the pass can check for itself:

- **Missing links** – internal `.md` links that point to non-existent pages, and links whose target lies outside `wiki/` (reported as `(outside wiki)` – page bodies are model-authored, so an out-of-tree link is never followed). A `#section` anchor after the path is understood and does not hide the link
- **Orphan pages** – pages no other page links to, so nothing in the wiki reaches them (excluding `README.md`; a page's link to itself does not count). Expect these while a wiki is young: an inbox-written page is only reachable once you link it from somewhere
- **Provenance inconsistencies** – pages missing required frontmatter fields, with an invalid confidence or `last_updated` value, with a `provenance` outside the vocabulary search ranks, with frontmatter this pipeline cannot parse, or carrying a `## Supplement from <source>` heading naming a source the page never recorded
- **KG contradictions** – open conflicts between the knowledge graph entries

The lint result is delivered via `knowledge.wiki_lint.delivery_mode`.

**This job is off by default.** It is the only surface that names a page whose frontmatter or links have drifted, so enable it alongside `knowledge.inbox` once your wiki has more than a handful of pages.

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
- **Tune retries**: `retry_attempts` applies to the model turns only – the steps that are nondeterministic and write nothing. Raise it when the model or provider is flaky. The durable writes that follow the settled merge run once; a failure there quarantines the file rather than repeating them.
- **Extend processed retention**: Increase `processed_retention_days` if you want to keep originals longer for reference.
- **Raise extraction fidelity**: Increase `effort` for dense or already-curated batches, and read the run report's `coverage:` ratio to see what actually landed.
- **Filter irrelevant topics**: Add a `## Not Relevant` section to your workspace `USER.md` – the extraction prompt reads it and omits those topics unless they provide essential supporting context.
- **Disable wiki lint**: Leave `knowledge.wiki_lint.enabled: false` (the default) if you only need memory/KG output.

## Troubleshooting

**File stays in `inbox/` after scan**
- Check server logs for the `knowledge-inbox` job – every run writes its full summary there, and files still changing within the stability window are deferred, not skipped.
- Verify the file extension is `.md`, `.txt`, `.json`, or `.ndjson`.

**File moved to `skipped/`**
- Unsupported extension (including `.pdf`) or file exceeded `max_bytes`.
- Check the skipped entry name – the reason is logged alongside the filename in the run summary.

**File moved to `quarantine/`**
- The extraction failed on every attempt, or a durable write failed. Read `quarantine/<filename>.error.json` for the error and attempt count.
- Common causes: extraction turn returned no findings, verbatim source reproduction detected (by either turn), an unsupported `confidence` value, malformed KG fact dates, a merge declaration DartClaw could not read, or a merge refused for shrinking the stored page without declaring a removal.
- `wiki page wiki/<slug>.md cannot be read` means the fault is in the **stored page**, not in your source: its frontmatter block is unterminated, is not parseable YAML, or the file is not valid UTF-8. Ingestion refuses rather than overwriting it. Repair or remove that page and re-drop the source. A page whose frontmatter this pipeline does not recognise is fine – it is merged and its keys preserved.
- `ingested but could not leave the inbox` means the ingestion succeeded but the source could not be moved to `processed/`; it is quarantined instead so the next run cannot ingest it a second time. Such a file is counted **both** as processed and as quarantined -- that is not double-reporting: its memory findings, KG facts, and wiki page all landed, and the file is nevertheless sitting in `quarantine/`. Both halves matter, because re-dropping it by hand would ingest the same source a second time.

**Wiki page not appearing**
- Confirm the extraction turn produced a non-empty `wiki_page.body` – an empty body is a quarantine signal.
- Check the run summary in the cron session (web UI sidebar) for contradiction or validation details.

**No memory observations captured**
- If the extraction returned findings but none are visible in memory search, check that `memory.enabled` is not set to `false` in your config.

## Gotchas & Limitations

- **No real-time watch**: Processing is periodic, not inotify-based. Files dropped between scans are picked up on the next interval tick.
- **No exactly-once guarantee**: If the server crashes mid-write after some findings are committed, the file is reprocessed on the next run. Duplicate observations may result.
- **KG storage is optional**: When the temporal KG service is not wired (e.g. in minimal deployments), `facts` from the extraction are ignored without error.
- **`announce` delivery**: Posts a run summary to the active session or channel – processed/skipped/quarantine counts plus the `wiki merges` and `coverage` lines. The same summary is written to the server log on every run, so it survives `delivery_mode: none` and a run nobody was watching. It does not push individual memory findings – query memory or the wiki directly to review extracted content.
