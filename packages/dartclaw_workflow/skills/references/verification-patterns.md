# DartClaw Verification Patterns

Use this reference when writing task verification criteria, review checklists, or implementation gates.

The goal is not to sound thorough. The goal is to prove the change exists, is substantive, is wired in, and behaves correctly.

## The Four Dimensions of Verification

### 1. Exists
- Confirm the artifact is present at the expected path.
- Confirm the symbol, file, route, or config entry exists in the workspace.
- Prefer direct path or symbol checks over inferred claims.
- A missing artifact is a hard failure.

### 2. Substantive
- Confirm the artifact contains real domain content, not a stub.
- Look for actual logic, actual prose, actual defaults, or actual data.
- A file with only headings is not substantive.
- A function that only returns a constant empty value is usually not substantive.

### 3. Wired
- Confirm the artifact is reachable from an entrypoint, registry, export, or loader.
- Confirm the new file is imported, discovered, registered, or referenced by at least one consumer.
- For support content, confirm it is materialized alongside the relevant root.
- A dead artifact can exist without being useful.

### 4. Functional
- Confirm the artifact performs the behavior described by the task.
- Use observable output, filesystem state, registry state, or runtime behavior as evidence.
- Prefer a narrow proof that matches the requested change.
- Avoid broad claims when a single targeted check can prove the outcome.

## Stub Detection Patterns

### Dart stub indicators
- `throw UnimplementedError()`
- `throw UnimplementedError('...')`
- `TODO`
- `FIXME`
- empty method bodies that do nothing meaningful
- getters that always return empty collections without real backing state
- setters that ignore their input
- `late` fields that are declared but never assigned before use
- fallback paths that always return `null`, `false`, `0`, or an empty string to avoid implementing behavior

### Structural stub indicators
- a file that only contains headings and no instructions
- a placeholder constant that is never replaced
- a test that only checks that code runs, not that it does anything useful
- a registry or loader that scans a directory but never exposes the new entries
- a generated asset file that omits the support directory tree even though the source tree contains it

### Review heuristics
- If the code path is short and looks suspiciously easy, inspect for a stub.
- If the content is all boilerplate, inspect for a stub.
- If the file name suggests domain knowledge but the body is generic, inspect for a stub.
- If the implementation only satisfies compilation, inspect for a stub.

## Wiring Check Patterns

### Barrel and export wiring
- Confirm the new symbol is exported from the package barrel when consumers import the umbrella package.
- Confirm nested files use the correct relative path from their location.
- Confirm the path still resolves after materialization into installed harness roots.

### Registry and discovery wiring
- Confirm the registry discovers only items that satisfy the skill contract.
- Confirm support directories are not mistaken for discoverable skills.
- Confirm discovery remains non-recursive unless recursion is explicitly part of the design.

### Service and command wiring
- Confirm the new file or function is reachable from a command, service, or loader.
- Confirm the command path uses the same source tree that the build step embeds.
- Confirm the service startup path can see the installed copy, not just the source copy.

### Data and asset wiring
- Confirm the file is included in the embedded asset map.
- Confirm the materializer writes the same path into both harness roots.
- Confirm support content is copied as a sibling directory, not flattened into the skill directory.

### UI and routing wiring
- Confirm a page, route, or action is registered in the main navigation or handler table.
- Confirm the route is not just defined in isolation.
- Confirm a template or fragment is referenced by at least one render path.

## Practical Use

- When writing verification criteria, name the observable artifact first.
- Then name the path, registry, or entrypoint that should expose it.
- Then name the expected behavior in the smallest possible testable form.
- If a verification item cannot be observed directly, the criterion is probably too vague.

## Quick Checklist

- Artifact exists at the expected path.
- Artifact contains substantive content.
- Artifact is wired into a consumer.
- Artifact behaves correctly under the requested scenario.
- Support content stays adjacent to the skill root after materialization.

