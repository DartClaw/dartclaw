# dartclaw_workflow

Workflow control plane for the DartClaw agent runtime — YAML parsing, validation, runtime skill preflight, registry, and execution.

`dartclaw_workflow` owns the full lifecycle of declarative multi-step workflows: loading built-in and custom
YAML definitions, validating their structure, executing steps (sequential, parallel, loop, foreach), managing
execution context, and provisioning skills to agent harnesses. The three built-in workflows
(`spec-and-implement`, `plan-and-implement`, `code-review`) ship inside this package.

> **Status: Pre-1.0**. APIs may be refined before 1.0.

## Installation

```sh
dart pub add dartclaw_workflow
```

## Quick Start

```dart
import 'package:dartclaw_workflow/dartclaw_workflow.dart';

// Parse and validate a workflow definition from YAML
final parser = WorkflowDefinitionParser();
final validator = WorkflowDefinitionValidator();
final definition = parser.parse(yamlString);
final report = validator.validate(definition);
if (!report.hasErrors) {
  print('Workflow "${definition.name}" is valid');
}

// Load workflows from a directory and look one up by name
final registry = WorkflowRegistry(parser: parser, validator: validator);
await registry.loadFromDirectory('/path/to/workflows');
final found = registry.getByName('my-workflow');
```

## Key Types

- `WorkflowExecutor` — drives workflow execution: step dispatch, context management, parallel/loop orchestration.
- `WorkflowDefinitionParser` — parses YAML workflow definitions into typed `WorkflowDefinition` models.
- `WorkflowDefinitionValidator` — validates parsed definitions against structural and constraint rules.
- `WorkflowRegistry` — manages available workflow definitions (built-in + custom); lookup by name.
- `SkillIntrospector` — probes the configured provider CLI for runtime-visible skill references before execution.
- `SkillProvisioner` — copies DC-native skills into data-dir provider skill roots.
- `WorkflowDefinition` — typed model for a workflow: name, description, variables, and ordered steps.
- `WorkflowStep` — atomic unit of work within a workflow (types: `agent`, `bash`, `approval`, `foreach`, `loop`).
- `WorkflowRun` — single execution instance of a workflow definition with its own lifecycle and context.

## When to Use This Package

- Compose and execute workflows outside the full DartClaw server.
- Embed workflow execution in a custom host or tooling layer.
- Customize or extend built-in step types or skill provisioning.
- Parse and validate workflow YAML files programmatically.

## Related Packages

- [`dartclaw_core`](https://pub.dev/packages/dartclaw_core) — runtime primitives; host seam for turn execution.
- [`dartclaw_models`](https://pub.dev/packages/dartclaw_models) — shared workflow domain models (`WorkflowDefinition`, `WorkflowRun`, `OutputConfig`).
- [`dartclaw_config`](https://pub.dev/packages/dartclaw_config) — config loading used by workflow executor.
- [`dartclaw_security`](https://pub.dev/packages/dartclaw_security) — guard framework used during step execution.

## Documentation

- [API Reference](https://pub.dev/documentation/dartclaw_workflow/latest/)
- [Repository](https://github.com/DartClaw/dartclaw/tree/main/packages/dartclaw_workflow)

## License

MIT - see [LICENSE](LICENSE).
