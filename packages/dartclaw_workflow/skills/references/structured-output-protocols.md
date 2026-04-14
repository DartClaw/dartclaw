# DartClaw Structured Output Protocols

Use these protocols whenever a workflow step needs to surface ambiguity, missing input, or partial confidence without pausing for interactive clarification.

## CONFUSION

Use when the available context conflicts or the target cannot be resolved safely.

Format:

```text
CONFUSION:
- What conflicts: ...
- Why it matters: ...
- What would resolve it: ...
```

Use this instead of guessing when two valid interpretations lead to different outputs.

## NOTICED BUT NOT TOUCHING

Use when you observe a relevant issue, but it is outside the current scope.

Format:

```text
NOTICED BUT NOT TOUCHING:
- Observation: ...
- Why it is out of scope: ...
- Suggested follow-up: ...
```

Use this to keep the main deliverable focused while still preserving useful signal.

## MISSING REQUIREMENT

Use when the request depends on information that is not available in the current context.

Format:

```text
MISSING REQUIREMENT:
- Missing input: ...
- Impact on execution: ...
- Best current assumption: ...
```

Use this when the correct next step is to continue with a clearly labeled assumption.

## ASSUMPTION

Use when the workflow must proceed and the missing detail can be handled conservatively.

Format:

```text
ASSUMPTION:
- Assumed value: ...
- Why this assumption is safe enough: ...
- How to validate later: ...
```

Use assumptions sparingly. A good assumption should be explicit, narrow, and easy to revoke later.

## Guidance

- Keep each block short and machine-readable.
- Prefer one concrete issue per block.
- Do not bury uncertainty inside long prose.
- If a block needs more than a few bullets, the underlying problem likely needs to be split.

