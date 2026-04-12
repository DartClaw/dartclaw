---
name: dartclaw-spec
description: Create a concise Feature Implementation Specification with scenarios, proof paths, and implementation guidance.
argument-hint: "<feature description | requirements file | plan story>"
user-invocable: true
---

# DartClaw Spec

Generate a Feature Implementation Specification for a single feature or story. Use the project codebase, docs, and relevant research to produce a practical, testable FIS.

## Instructions

- Analyze the codebase before writing the FIS.
- Read project learnings and relevant architecture or guideline docs first.
- Write scenarios before the rest of the spec.
- Keep the FIS concise but complete.
- Every success criterion must have a proof path.
- Use canonical project language and concrete verification steps.

## FIS Structure

Use the local template and include:

- summary
- scenarios
- success criteria
- scope and boundaries
- architecture or implementation notes
- verification approach
- open questions or assumptions when needed

## Output Contract

The spec should be usable by an implementation skill without extra interpretation. Avoid describing file edits as the goal; describe what must be true when complete.

