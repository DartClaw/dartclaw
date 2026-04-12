# Correctness Checklist

Use this checklist for behavior, integration, and regression review.

## Behavior

- [ ] The implementation matches the explicit requirements.
- [ ] Happy path and edge cases are both handled.
- [ ] Error paths fail loudly and predictably.
- [ ] Defaults are intentional and documented.

## Integration

- [ ] The feature is wired end-to-end, not just defined locally.
- [ ] New code is imported, referenced, or invoked by a real path.
- [ ] Interacting systems receive the expected shape of data.
- [ ] Existing flows still work after the change.

## Maintainability

- [ ] Names are accurate and match project language.
- [ ] Code follows nearby established patterns unless there is a reason not to.
- [ ] There is no unnecessary abstraction or duplication.
- [ ] The smallest effective change was used.

## Proof

- [ ] Tests cover the behavior that matters.
- [ ] Verification evidence is stronger than a superficial existence check.
- [ ] Stubs, TODOs, and placeholders are not mistaken for finished code.

