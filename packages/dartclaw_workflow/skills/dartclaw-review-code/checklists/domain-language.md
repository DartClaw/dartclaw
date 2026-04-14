# Domain Language Checklist

Use this checklist when the review needs to verify terminology against the project's ubiquitous language.

Skip when no `UBIQUITOUS_LANGUAGE.md` exists.

## Pre-Review
- [ ] Read `UBIQUITOUS_LANGUAGE.md` if it exists.
- [ ] Identify the bounded contexts touched by the change.
## Terminology Consistency
- [ ] Canonical terms are used instead of ad hoc synonyms.
- [ ] The same concept is named consistently across files, modules, and UI labels.
- [ ] Terms are not borrowed across bounded context boundaries without justification.
## Domain Model Alignment
- [ ] Entities, value objects, and domain actions match the glossary.
- [ ] States, enums, and labels mirror the domain model rather than implementation detail.
## New Term Detection
- [ ] New domain concepts are called out so the glossary can be updated.
- [ ] New names are descriptive instead of cryptic shorthand.

## Issue Classification

### CRITICAL

- A term is used with the wrong meaning.
- A bounded context boundary is crossed in a way that will confuse the model or the team.

### HIGH

- A non-canonical synonym is used where the glossary already has a preferred term.
- Related files use different names for the same concept.

### MEDIUM

- A new term should probably be added to the glossary.
- Naming can be improved to better match the ubiquitous language.
