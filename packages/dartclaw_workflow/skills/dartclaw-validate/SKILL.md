---
name: dartclaw-validate
description: Validate workflow YAML definitions and packaged workflow assets.
argument-hint: "<workflow-yaml-path>"
user-invocable: true
---

# DartClaw Validate

Validate workflow definitions and related packaged assets with the local CLI.

## Instructions

- Use `dart run dartclaw_cli:dartclaw workflow validate <path>` for workflow YAML files.
- Treat validation errors as blocking and warnings as informational.
- When checking a release archive, confirm the packaged workflow skill bundle includes the expected skill files.
- Keep the check focused on workflow definitions and packaging integrity.
