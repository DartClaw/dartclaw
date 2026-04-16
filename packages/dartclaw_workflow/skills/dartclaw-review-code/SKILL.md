---
description: Perform implementation-focused review covering code quality, security, architecture, and UI/UX. Use when you explicitly want code review rather than the general `review` router. Trigger on 'review this code', 'review this PR', 'audit these changes'.
user-invocable: true
argument-hint: "[scope/files] [--inline-findings] [--to-issue] [--to-pr <number>]"
---

# Code Review Skill

Comprehensive code review covering correctness, security, architecture, maintainability, and UI/UX where relevant.

Most users should start with `dartclaw-review`. Use this skill directly when you already know the target is implementation/code.

## VARIABLES
ARGUMENTS: $ARGUMENTS

### Optional Output Flags
- `--inline-findings` → return findings inline and skip report-file output (for delegated use by `dartclaw-review` or other orchestration skills)
- `--to-issue` → PUBLISH_ISSUE
- `--to-pr <number>` → PUBLISH_PR

## INSTRUCTIONS
- Analysis only. Do not modify code.
- If `--inline-findings` is present, do not write a report file. Return findings inline to the parent skill instead.
- Calibrate severity with `../references/review-calibration.md` and `references/code-review-calibration.md`.
- Read project learnings if they exist.
- Exclude generated, vendored, and lockfile noise.
- Run applicable project verification commands that strengthen review signal when they are discoverable and safe to run read-only: linting, static analysis, type checks, and formatter/compile sanity checks where relevant.
- When invoked standalone, treat those checks as part of the review evidence. When invoked by an orchestrator that already ran them, reuse fresh results when available instead of rerunning broad project checks unnecessarily.
- Report which verification commands were run, which were skipped, and why. Do not claim a clean review if a critical available check failed or could not be interpreted.
- When the review touches browser state, AI/agent flows, logs, stack traces, error output, scraped content, tool results, or other external-data flows, apply `../references/trust-boundaries.md`.

## GOTCHAS
- Over-reporting nits
- Treating review as eyeballing only when cheap high-signal project checks are available
- Forgetting Semgrep when it is available
- Reviewing generated output instead of human-authored code

### Helper Scripts
- `../scripts/run-security-scan.sh <path>`

## ORCHESTRATION
When supported, delegate parallel reviewers for:
1. Code quality
2. Security
3. Architecture
4. Domain language
5. UI/UX

If sub-agents are unavailable, run the same lenses sequentially.

## WORKFLOW

### 1. Scope
Determine scope from conversation context, explicit paths, PR number, or current pending changes. Build a quick codebase overview, identify affected files, choose the applicable review lenses, and verify external technical claims against authoritative sources when needed.

Identify the project checks relevant to the review scope by inspecting the repo's existing automation surfaces first: package scripts, Make targets, Justfiles, CI workflows, language-native config files, or documented contributor commands. Prefer the narrowest commands that still give trustworthy signal for the changed scope.

**Gate**: Scope and applicable review lenses are clear

### 2. Review
- **Verification evidence** — run the applicable project linting, static-analysis, type-checking, and formatter/compile sanity commands when available. Record pass/fail/skip status and treat failures as review inputs, not as optional background noise.
- **Code quality** — use [CODE-REVIEW-CHECKLIST.md](checklists/CODE-REVIEW-CHECKLIST.md): correctness, edge cases, readability, naming, maintainability, performance, duplication
- **Architecture** — use [ARCHITECTURAL-REVIEW-CHECKLIST.md](checklists/ARCHITECTURAL-REVIEW-CHECKLIST.md): pattern adherence, coupling/cohesion, CUPID, DDD where relevant, resilience/performance trade-offs
- **Domain language** — use [DOMAIN-LANGUAGE-REVIEW-CHECKLIST.md](checklists/DOMAIN-LANGUAGE-REVIEW-CHECKLIST.md) when the `Ubiquitous Language` document (see **Project Document Index**) exists: terminology consistency
- **UI/UX** — use [UI-UX-REVIEW-CHECKLIST.md](checklists/UI-UX-REVIEW-CHECKLIST.md) when UI changed: usability, responsiveness, accessibility, interaction quality

#### Security Review
Select the applicable checklist(s):

| Checklist | Standard | Apply when... |
|-----------|----------|---------------|
| [SECURITY-CHECKLIST-WEB.md](checklists/SECURITY-CHECKLIST-WEB.md) | OWASP Top 10:2025 | Web apps, server-rendered pages, general backends |
| [SECURITY-CHECKLIST-API.md](checklists/SECURITY-CHECKLIST-API.md) | OWASP API Security Top 10:2023 | REST, GraphQL, gRPC, microservices, HTTP-exposed code |
| [SECURITY-CHECKLIST-LLM.md](checklists/SECURITY-CHECKLIST-LLM.md) | OWASP LLM Top 10:2025 | LLM, RAG, agentic, AI-generated-output systems |
| [SECURITY-CHECKLIST-MOBILE.md](checklists/SECURITY-CHECKLIST-MOBILE.md) | OWASP Mobile Top 10:2024 | Native or cross-platform mobile apps |
| [SECURITY-CHECKLIST-CICD.md](checklists/SECURITY-CHECKLIST-CICD.md) | OWASP CI/CD Risks | Pipelines, IaC, deployment, build scripts, supply chain |

Assess input validation, injection risks, authz/authn, crypto, secret handling, API security, and supply-chain integrity. Run available security tooling such as Semgrep when possible.

**Gate**: Applicable review lenses complete

### 3. Findings and Report
Categorize findings as:
- **CRITICAL**: security vulnerabilities, data loss, or broken core behavior
- **HIGH**: significant maintainability, performance, or correctness issues
- **SUGGESTIONS**: worthwhile improvements or cleanup

Also flag obsolete files, unmotivated complexity, and cleanup candidates.

Generate a markdown report unless `--inline-findings` is present. When `--inline-findings` is present, return the same content inline in concise structured form instead of writing a file.

Standard report sections: Summary, CRITICAL ISSUES (title/impact/location/fix), HIGH PRIORITY (title/impact/location/recommendation), SUGGESTIONS, Cleanup Required, Compliance (guidelines/architecture/security/UI-UX), Verification Evidence (commands run/skipped with results/reasons), Next Steps.

## Structured Output

- findings_count: <integer>
- verdict: <PASS|FAIL>
- critical_count: <integer>
- high_count: <integer>

Emit this block in every inline or report-backed review result so workflow gates can evaluate the outcome reliably.

**Report output conventions**: Follow `../references/report-output-conventions.md` with:
- **Report suffix**: `code-review` / **Scope placeholder**: `feature-name`
- **Spec-directory rule**: reviewed files correspond to a feature with an associated spec directory from the Project Document Index
- **Target-directory rule**: review target is a specific file or localized directory, so report belongs next to the primary target

### Publish to GitHub
If PUBLISH_ISSUE is `true`: follow the GitHub publishing flow in `../references/report-output-conventions.md` with title template `[Code Review] {scope}: Review Report`. Print the issue URL.

If PUBLISH_PR is set: follow the GitHub publishing flow in `../references/report-output-conventions.md`, publishing as a typed PR comment. If the posting command does not return a direct comment URL, resolve it via follow-up GitHub lookup. Print the direct comment URL.
