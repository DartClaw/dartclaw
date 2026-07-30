# Reconciliation Ledger

> Durable, greppable record of deliberate spec-vs-code drift. Entries are written by implementation and remediation skills and transitioned by review / remediation. See `reconciliation-ledger.md` for the schema, stable-ID derivation, status lifecycle, and match/recurrence/escalation rules.

## Entries

### S13-FONT-VARIABLE-NOT-SIX-FILES
- Status: CLOSED
- Class: design-changed
- Stale targets: `docs/specs/0.22.1/prd.md` FR8 description ("JetBrains Mono 400/500/600 latin + latin-ext woff2 (~30.6 KB each)", implying six per-weight files); `docs/specs/0.22.1/vendoring-analysis.md` § Font subsetting ("Self-hosting needs only **latin + latin-ext = 6 files**")
- Source run: S13 exec-spec 2026-07-30
- Recurrence: 1
- Falsifier: –
- Override reason: –
- Created: 2026-07-30
- Updated: 2026-07-30
- Notes: Evidence — `curl` the Google CSS2 endpoint for `JetBrains+Mono:wght@400;500;600` with a browser User-Agent and count distinct `fonts.gstatic.com` URLs: 18 `@font-face` rules resolve to 6 URLs (one per unicode-range), not 18; the latin URL is byte-identical across weights 400/500/600, and both vendored files carry `fvar`/`gvar`/`avar`/`STAT` tables. Six per-weight files would be three byte-identical copies per subset. As built: two subset files (`fonts/jetbrains-mono-latin.woff2`, `fonts/jetbrains-mono-latin-ext.woff2`) with six `@font-face` rules differing only in `font-weight`, and one font preload rather than two. No Expected Outcome is weakened — all three weights were proven to load and to render distinctly (weight 600 draws ~1.18x the ink of 400) against the compiled binary with every external origin blocked. Detail in the FIS's Implementation Observations. Reconciled 2026-07-30 — both stale upstream targets amended to as-built truth in the private canonical repo. (1) `dartclaw-private/docs/specs/0.22.1/prd.md` FR8 Description: no longer says "JetBrains Mono 400/500/600 latin + latin-ext woff2 (~30.6 KB each)"; now names the latin + latin-ext subsets covering all three weights, with an inline amendment note carrying the evidence. (2) `dartclaw-private/docs/specs/0.22.1/vendoring-analysis.md`: the Font subsetting section no longer concludes "latin + latin-ext = 6 files" but states that the 18 `@font-face` rules resolve to 6 distinct URLs and that self-hosting latin+latin-ext needs 2 files; the Cost section's six-file-derived estimate (~181 KB static / ~241 KB base64 / ~72% increase) is replaced with measured as-built figures (130.9 KB static, 174.6 KB base64, ~51% increase over 258.8 KB already vendored, generated file 1.64 MB), preserving the original estimate in an italic note; the summary table row now records 30.6 KB latin + 11.3 KB latin-ext with the variable-font explanation. Duplication avoided: 83.9 KB on disk, 111.8 KB base64.
