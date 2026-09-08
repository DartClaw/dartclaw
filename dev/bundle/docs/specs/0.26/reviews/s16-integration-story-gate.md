Intent Context: dev/bundle/docs/specs/0.26/s16-declarative-workflow-step-type-rule-source.md

No accepted findings. The prior S16 code, gap and Critic finding closures remain satisfied. The integrated source and test bytes match accepted tip `5c38a922`; only the intended combined S05/S16 documentation differs. Diagnostic parity, parser/validator metadata consumption, corrected TI05/TI06 selectors, and the combined fitness baseline were rechecked at the frozen integration snapshot.

Verification Evidence: `workflow_dsl_rules_test.dart` 13 passed; focused loop-policy, structure, step-type and built-in workflow suites 146 passed; strict `fitness-shape` 4 passed; focused analyzer reported no issues.

Guardrails Coverage: 12 checked, 0 findings

Files: dev/architecture/workflow-architecture.md, docs/guide/workflows-reference.md, packages/dartclaw_workflow/CLAUDE.md, packages/dartclaw_workflow/lib/src/workflow/schema_presets.dart, packages/dartclaw_workflow/lib/src/workflow/validation/workflow_loop_policy_rules.dart, packages/dartclaw_workflow/lib/src/workflow/validation/workflow_step_type_rules.dart, packages/dartclaw_workflow/lib/src/workflow/validation/workflow_structure_rules.dart, packages/dartclaw_workflow/lib/src/workflow/workflow_definition.dart, packages/dartclaw_workflow/lib/src/workflow/workflow_definition_parser.dart, packages/dartclaw_workflow/lib/src/workflow/workflow_definition_validator.dart, packages/dartclaw_workflow/lib/src/workflow/workflow_dsl_rules.dart, packages/dartclaw_workflow/test/fitness_baseline.json, packages/dartclaw_workflow/test/workflow/goldens/workflow_definition_reports.txt, packages/dartclaw_workflow/test/workflow/goldens/workflow_diagnostics.txt, packages/dartclaw_workflow/test/workflow/goldens/workflow_parser_diagnostics.txt, packages/dartclaw_workflow/test/workflow/workflow_dsl_rules_test.dart

Story-Gate: PASS @ 589da3a9d214+54975f2508e1
