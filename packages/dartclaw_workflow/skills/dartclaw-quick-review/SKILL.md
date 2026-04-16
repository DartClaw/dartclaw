---
description: Quick in-conversation review of recent changes using a fresh-context sub-agent for adversarial critique. Use mid-conversation to sanity-check work before moving on. Trigger on 'quick review this', 'sanity-check this', 'give this a quick pass'.
user-invocable: true
argument-hint: "[optional focus or scope]"
---

# Quick Review

Lightweight, ad-hoc review of recent work. Spawns a fresh-context sub-agent to catch errors, inconsistencies, and missed edge cases that in-context work overlooks. For thorough reviews, use `dartclaw-review`.

## VARIABLES
FOCUS: $ARGUMENTS

## INSTRUCTIONS
- This is a fast, focused checkpoint scoped to recent changes rather than a full formal pass.
- Read-only analysis. Do not modify files.
- Sub-agent reviews in a fresh context to avoid confirmation bias.
- Anti-leniency: if the sub-agent identifies a problem, it IS a problem. Do not rationalize issues away.
- Output findings inline — no separate report file.

## GOTCHAS
- Sending too little context (sub-agent needs to understand what was done and why)
- Sending too much context (entire files when only a section changed)
- Rationalizing away findings; using this as a substitute for proper review on significant changes

## WORKFLOW

### 1. Determine Scope

Identify what to review, in priority order:

1. **Explicit focus**: If `FOCUS` is provided, use it to narrow scope
2. **Pending changes**: Run `git diff --stat` and `git diff` for uncommitted changes
3. **Recent conversation work**: If no pending changes, identify artifacts created or modified in this conversation (specs, configs, docs, etc.)

Collect the **change set** — the specific content to review. Keep it focused: only include what actually changed, with enough surrounding context for comprehension.

**Gate**: Change set is identified and bounded

### 2. Classify and Frame

Determine what type of work was done to frame the review appropriately:

| Change type | Review lens |
|---|---|
| Code (new or modified) | Correctness, edge cases, consistency with existing patterns, error handling |
| Specification / plan | Completeness, clarity, implementability, contradictions |
| Configuration | Safety, correctness, environment consistency |
| Documentation | Accuracy, clarity, completeness |
| Prompt / skill | Clarity of intent, edge case handling, instruction consistency |
| Mixed | Apply relevant lenses per artifact |

### 3. Sub-Agent Review

Spawn a **single sub-agent** (`general-purpose` agent type) with the following prompt structure:

```
You are a critical reviewer performing an adversarial review of recent changes.
Find real problems: errors, inconsistencies, missed edge cases, contradictions, gaps.

## Anti-Leniency Rules
- If you identify a problem, it IS a problem. Do not talk yourself out of it.
- "Works on the happy path" is not a pass — check edge cases and error paths.
- Be definitive, not hedging. Substance over surface.

## Context
{what was done and why}

## Review Lens
{applicable lens from classification step}

## Changes to Review
{the change set}

## Instructions
1. Review through the specified lens
2. Check internal consistency and consistency with surrounding codebase
3. Concrete issues only — no speculative problems
4. Each finding: what's wrong, where, why it matters
5. No significant issues? Say so plainly — do not invent findings

One finding per item. No preamble, no summary, no severity table.
```

Include relevant diffs, file excerpts, and project context inline so the sub-agent can review without exploring the codebase.

**Gate**: Sub-agent review complete

### 4. Evaluate and Report

Review the sub-agent's findings. **Accept** valid, actionable findings. **Dismiss** findings based on context misunderstanding (explain briefly). Present accepted findings as a concise inline list. Offer to fix actionable issues. No report file, no summary preamble.

## Structured Output

- findings_count: <integer>
- verdict: <PASS|FAIL>
- critical_count: <integer>
- high_count: <integer>

Emit the block inline after the findings list. Use `PASS` when no accepted findings remain after evaluation.
