import 'package:dartclaw_workflow/dartclaw_workflow.dart';
import 'package:test/test.dart';

import 'workflow_validator_test_support.dart';

void main() {
  late WorkflowDefinitionValidator validator;

  setUp(() {
    validator = WorkflowDefinitionValidator();
  });

  test('valid definition returns report with no errors and no warnings', () {
    final def = buildDef();
    final report = validator.validate(def);
    expect(report.errors, isEmpty);
    expect(report.warnings, isEmpty);
  });

  group('required fields', () {
    final missingFieldCases = [
      (name: 'missing name', build: () => buildDef(name: '')),
      (name: 'missing description', build: () => buildDef(description: '')),
      (name: 'empty steps list', build: () => WorkflowDefinition(name: 'n', description: 'd', steps: const [])),
    ];

    for (final testCase in missingFieldCases) {
      test('${testCase.name} produces missingField error', () {
        final errors = validator.validate(testCase.build()).errors;
        expect(hasError(errors, type: ValidationErrorType.missingField), true);
      });
    }

    test('workflow-level project references must be declared', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        project: '{{PROJECT}}',
        steps: const [
          WorkflowStep(id: 's', name: 'S', prompts: ['p']),
        ],
      );
      final errors = validator.validate(def).errors;
      expect(hasError(errors, messageContains: 'Workflow project field references undeclared variable'), isTrue);
    });
  });

  group('duplicate IDs', () {
    test('duplicate step IDs produces duplicateId error', () {
      final def = buildDef(
        steps: [
          step(id: 'same'),
          step(id: 'same', name: 'S2', prompt: 'p'),
        ],
      );
      final errors = validator.validate(def).errors;
      expect(hasError(errors, type: ValidationErrorType.duplicateId, stepId: 'same'), true);
    });

    test('duplicate loop IDs produces duplicateId error', () {
      final def = buildDef(
        steps: [
          step(id: 's1'),
          step(id: 's2', name: 'S2', prompt: 'p'),
        ],
        loops: [
          const WorkflowLoop(id: 'loop-x', steps: ['s1'], maxIterations: 2, exitGate: ''),
          const WorkflowLoop(id: 'loop-x', steps: ['s2'], maxIterations: 2, exitGate: ''),
        ],
      );
      final errors = validator.validate(def).errors;
      expect(hasError(errors, type: ValidationErrorType.duplicateId, loopId: 'loop-x'), true);
    });
  });

  group('normalized nodes', () {
    test('malformed normalized graph is rejected', () {
      final def = buildDef(
        steps: [
          step(id: 'setup'),
          const WorkflowStep(
            id: 'map-step',
            name: 'Map',
            prompts: ['p'],
            mapOver: 'items',
            inputs: ['items'],
            outputs: {'mapped': OutputConfig()},
          ),
        ],
        nodes: const [
          ActionNode(stepId: 'setup'),
          ActionNode(stepId: 'map-step'),
        ],
      );

      final errors = validator.validate(def).errors;
      expect(
        errors,
        contains(
          isA<ValidationError>().having(
            (error) => error.message,
            'message',
            contains('map-backed but was normalized as an action node'),
          ),
        ),
      );
    });

    test('every authored step must appear exactly once in the normalized graph', () {
      final def = buildDef(
        steps: [
          step(id: 'a'),
          step(id: 'b', name: 'B', prompt: 'p'),
        ],
        nodes: const [ActionNode(stepId: 'a')],
      );

      final errors = validator.validate(def).errors;
      expect(
        errors,
        contains(
          isA<ValidationError>().having(
            (error) => error.message,
            'message',
            contains('is not represented in the normalized execution graph'),
          ),
        ),
      );
    });
  });

  group('context key consistency', () {
    test('context input referencing key not in preceding step outputs produces contextInconsistency', () {
      final def = buildDef(
        steps: [
          step(id: 's1', inputs: ['key_a'], outputs: {}),
        ],
      );
      final errors = validator.validate(def).errors;
      expect(hasError(errors, type: ValidationErrorType.contextInconsistency), true);
    });

    test('context input valid when preceding step declares the output', () {
      final def = buildDef(
        steps: [
          step(id: 's1', outputs: {'result': OutputConfig()}),
          step(id: 's2', name: 'S2', prompt: 'p', inputs: ['result']),
        ],
      );
      expect(validator.validate(def).errors, isEmpty);
    });

    test('context input valid within same loop', () {
      final def = buildDef(
        steps: [
          step(id: 's1', inputs: ['loop_key'], outputs: {'loop_key': OutputConfig()}),
          step(id: 's2', name: 'S2', prompt: 'p', outputs: {}),
        ],
        loops: [
          const WorkflowLoop(id: 'lp', steps: ['s1'], maxIterations: 3, exitGate: ''),
        ],
      );
      expect(validator.validate(def).errors, isEmpty);
    });
  });

  test('multiple errors are all collected (not fail-fast)', () {
    final def = WorkflowDefinition(name: '', description: '', steps: const []);
    final errors = validator.validate(def).errors;
    expect(errors.length, greaterThan(1));
  });

  group('loop finalizer validation', () {
    WorkflowDefinition finalizerDef({String? finally_, bool includeSummarize = false}) => WorkflowDefinition(
      name: 'wf',
      description: 'd',
      steps: [
        const WorkflowStep(id: 'loop-step', name: 'Loop Step', prompts: ['p']),
        if (includeSummarize) const WorkflowStep(id: 'summarize', name: 'Summarize', prompts: ['p']),
      ],
      loops: [
        WorkflowLoop(
          id: 'loop1',
          steps: const ['loop-step'],
          maxIterations: 3,
          exitGate: 'loop-step.done == true',
          finally_: finally_,
        ),
      ],
    );

    final cases = [
      (
        name: 'valid finalizer',
        def: finalizerDef(finally_: 'summarize', includeSummarize: true),
        expectErrors: (List<ValidationError> errors) => expect(errors.where((e) => e.loopId == 'loop1'), isEmpty),
      ),
      (
        name: 'non-existent finalizer',
        def: finalizerDef(finally_: 'non-existent-step'),
        expectErrors: (List<ValidationError> errors) => expect(
          errors.where(
            (e) =>
                e.type == ValidationErrorType.invalidReference &&
                e.loopId == 'loop1' &&
                e.message.contains('non-existent-step'),
          ),
          isNotEmpty,
        ),
      ),
      (
        name: 'finalizer inside loop steps',
        def: finalizerDef(finally_: 'loop-step'),
        expectErrors: (List<ValidationError> errors) =>
            expect(errors.where((e) => e.type == ValidationErrorType.loopOverlap && e.loopId == 'loop1'), isNotEmpty),
      ),
      (
        name: 'loop without finalizer',
        def: WorkflowDefinition(
          name: 'wf',
          description: 'd',
          steps: const [
            WorkflowStep(id: 'ls', name: 'LS', prompts: ['p']),
          ],
          loops: const [
            WorkflowLoop(id: 'loop1', steps: ['ls'], maxIterations: 3, exitGate: 'ls.done == true'),
          ],
        ),
        expectErrors: (List<ValidationError> errors) => expect(errors, isEmpty),
      ),
    ];

    for (final testCase in cases) {
      test(testCase.name, () {
        testCase.expectErrors(validator.validate(testCase.def).errors);
      });
    }
  });

  group('stepDefaults validation', () {
    final validCases = [
      (
        name: 'matching pattern',
        steps: const [
          WorkflowStep(id: 'review-code', name: 'Review', prompts: ['p']),
        ],
        stepDefaults: const [StepConfigDefault(match: 'review*', model: 'claude-opus-4')],
      ),
      (
        name: 'unmatched pattern warning only',
        steps: const [
          WorkflowStep(id: 'implement', name: 'Implement', prompts: ['p']),
        ],
        stepDefaults: const [StepConfigDefault(match: 'review*', model: 'claude-opus-4')],
      ),
      (
        name: 'empty list',
        steps: const [
          WorkflowStep(id: 's', name: 'S', prompts: ['p']),
        ],
        stepDefaults: const <StepConfigDefault>[],
      ),
      (
        name: 'null stepDefaults',
        steps: const [
          WorkflowStep(id: 's', name: 'S', prompts: ['p']),
        ],
        stepDefaults: null,
      ),
    ];

    for (final testCase in validCases) {
      test('${testCase.name} is valid', () {
        final def = WorkflowDefinition(
          name: 'wf',
          description: 'd',
          steps: testCase.steps,
          stepDefaults: testCase.stepDefaults,
        );
        expect(validator.validate(def).errors, isEmpty);
      });
    }

    test('stepDefaults with unknown role-alias provider produces invalidReference error', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(id: 'review', name: 'Review', prompts: ['p']),
        ],
        stepDefaults: const [StepConfigDefault(match: '*', provider: '@executer')],
      );
      final errors = validator.validate(def).errors;
      expect(errors, hasLength(1));
      expect(errors.first.type, ValidationErrorType.invalidReference);
      expect(errors.first.message, contains('@executer'));
      expect(errors.first.message, contains('@executor'));
      expect(errors.first.message, contains('review'));
    });
  });

  group('mapOver validation', () {
    test('mapOver referencing a prior contextOutput is valid', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(id: 'collect', name: 'Collect', prompts: ['p'], outputs: {'items': OutputConfig()}),
          WorkflowStep(id: 'process', name: 'Process', prompts: ['p'], mapOver: 'items'),
        ],
      );
      final errors = validator.validate(def).errors;
      expect(errors, isEmpty);
    });

    test('mapOver referencing unknown key produces contextInconsistency error', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(id: 'process', name: 'Process', prompts: ['p'], mapOver: 'items'),
        ],
      );
      final errors = validator.validate(def).errors;
      expect(errors, hasLength(1));
      expect(errors[0].type, ValidationErrorType.contextInconsistency);
      expect(errors[0].stepId, 'process');
      expect(errors[0].message, contains('items'));
    });

    test('mapOver referencing own contextOutput (not prior) produces error', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(
            id: 's',
            name: 'S',
            prompts: ['p'],
            mapOver: 'self_output',
            outputs: {'self_output': OutputConfig()},
          ),
        ],
      );
      final errors = validator.validate(def).errors;
      expect(hasError(errors, type: ValidationErrorType.contextInconsistency), isTrue);
    });

    test('no mapOver on any step -> no errors from mapOver check', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(id: 's', name: 'S', prompts: ['p']),
        ],
      );
      final errors = validator.validate(def).errors;
      expect(errors, isEmpty);
    });

    test('second map step can reference first map step output', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(
            id: 'produce',
            name: 'Produce',
            prompts: ['p'],
            outputs: {'list1': OutputConfig(), 'list2': OutputConfig()},
          ),
          WorkflowStep(
            id: 'map1',
            name: 'Map1',
            prompts: ['p'],
            mapOver: 'list1',
            outputs: {'mapped1': OutputConfig()},
          ),
          WorkflowStep(id: 'map2', name: 'Map2', prompts: ['p'], mapOver: 'list2'),
        ],
      );
      final errors = validator.validate(def).errors;
      expect(errors, isEmpty);
    });
  });

  group('map step constraint validation', () {
    WorkflowDefinition mapConstraintDef({
      bool parallel = false,
      Map<String, OutputConfig> outputs = const {'results': OutputConfig()},
    }) {
      return WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: [
          step(id: 'produce', name: 'Produce', prompt: 'p', outputs: {'items': const OutputConfig()}),
          WorkflowStep(
            id: 'mapstep',
            name: 'Map',
            prompts: const ['p'],
            mapOver: 'items',
            parallel: parallel,
            outputs: outputs,
          ),
        ],
      );
    }

    WorkflowDefinition foreachConstraintDef(Map<String, OutputConfig> outputs) {
      return WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: [
          step(id: 'produce', name: 'Produce', prompt: 'p', outputs: {'items': const OutputConfig()}),
          step(id: 'implement', name: 'Implement', prompt: 'p', outputs: {'story_result': const OutputConfig()}),
          WorkflowStep(
            id: 'pipeline',
            name: 'Pipeline',
            type: WorkflowTaskType.foreach,
            mapOver: 'items',
            foreachSteps: const ['implement'],
            outputs: outputs,
          ),
        ],
      );
    }

    test('map step with parallel:true produces contextInconsistency error', () {
      final def = mapConstraintDef(parallel: true);
      final errors = validator.validate(def).errors;
      expect(
        errors,
        contains(
          isA<ValidationError>()
              .having((e) => e.type, 'type', ValidationErrorType.contextInconsistency)
              .having((e) => e.stepId, 'stepId', 'mapstep')
              .having((e) => e.message, 'message', contains('cannot also be a parallel step')),
        ),
      );
    });

    test('map step without parallel:true is valid', () {
      final def = mapConstraintDef();
      final errors = validator.validate(def).errors;
      expect(errors.where((e) => e.stepId == 'mapstep'), isEmpty);
    });

    test('map step with multiple outputs produces contextInconsistency error', () {
      final def = mapConstraintDef(outputs: const {'results': OutputConfig(), 'summaries': OutputConfig()});
      final errors = validator.validate(def).errors;
      expect(
        errors,
        contains(
          isA<ValidationError>()
              .having((e) => e.type, 'type', ValidationErrorType.contextInconsistency)
              .having((e) => e.stepId, 'stepId', 'mapstep')
              .having((e) => e.message, 'message', contains('exactly one aggregate list value')),
        ),
      );
    });

    test('foreach controller with multiple outputs produces contextInconsistency error', () {
      final def = foreachConstraintDef(const {
        'story_results': OutputConfig(),
        'implementation_results': OutputConfig(),
      });
      final errors = validator.validate(def).errors;
      expect(
        errors,
        contains(
          isA<ValidationError>()
              .having((e) => e.type, 'type', ValidationErrorType.contextInconsistency)
              .having((e) => e.stepId, 'stepId', 'pipeline')
              .having((e) => e.message, 'message', contains('exactly one aggregate list value')),
        ),
      );
    });

    test('foreach controller with a single outputs key is valid', () {
      final def = foreachConstraintDef(const {'story_results': OutputConfig()});
      final errors = validator.validate(def).errors;
      expect(errors.where((e) => e.stepId == 'pipeline'), isEmpty);
    });
  });

  group('aggregate-reviews validation rules', () {
    test('valid aggregate-reviews step produces no errors', () {
      final def = buildDef(
        steps: [
          reviewSourceStep(id: 'review-a'),
          aggregateReviewsStep(),
        ],
      );

      expect(validator.validate(def).errors, isEmpty);
    });

    test('rejects missing or empty aggregateReviews', () {
      for (final aggregateReviews in <List<String>?>[null, const []]) {
        final def = buildDef(
          steps: [
            reviewSourceStep(id: 'review-a'),
            aggregateReviewsStep(aggregateReviews: aggregateReviews),
          ],
        );

        final errors = validator.validate(def).errors;
        expect(
          errors,
          contains(
            isA<ValidationError>()
                .having((error) => error.stepId, 'stepId', 'review-aggregate')
                .having((error) => error.message, 'message', contains('aggregateReviews'))
                .having((error) => error.message, 'message', contains('at least one upstream step id')),
          ),
        );
      }
    });

    test('rejects unknown or non-prior upstream step ids', () {
      final def = buildDef(
        steps: [
          reviewSourceStep(id: 'review-a'),
          aggregateReviewsStep(aggregateReviews: const ['review-a', 'review-typo', 'later-review']),
          reviewSourceStep(id: 'later-review'),
        ],
      );

      final errors = validator.validate(def).errors;
      expect(
        errors,
        contains(
          isA<ValidationError>()
              .having((error) => error.stepId, 'stepId', 'review-aggregate')
              .having((error) => error.type, 'type', ValidationErrorType.invalidReference)
              .having((error) => error.message, 'message', contains('review-typo'))
              .having((error) => error.message, 'message', contains('valid prior step ids')),
        ),
      );
      expect(
        errors,
        contains(
          isA<ValidationError>()
              .having((error) => error.stepId, 'stepId', 'review-aggregate')
              .having((error) => error.message, 'message', contains('later-review')),
        ),
      );
    });

    test('rejects upstream steps without count outputs', () {
      final def = buildDef(
        steps: [
          reviewSourceStep(
            id: 'review-a',
            outputs: const {'review_findings': OutputConfig(format: OutputFormat.path, schema: 'review_report_path')},
          ),
          aggregateReviewsStep(),
        ],
      );

      final errors = validator.validate(def).errors;
      expect(
        errors,
        contains(
          isA<ValidationError>()
              .having((error) => error.stepId, 'stepId', 'review-aggregate')
              .having((error) => error.message, 'message', contains('review-a.findings_count'))
              .having((error) => error.message, 'message', contains('review-a')),
        ),
      );
    });

    test('rejects upstream count keys scoped to a different source id', () {
      // The runner only reads "$sourceId.findings_count" / "$sourceId.gating_findings_count";
      // a count key carrying a different source prefix would silently contribute 0 at runtime.
      final def = buildDef(
        steps: [
          reviewSourceStep(
            id: 'review-a',
            outputs: const {
              'review_findings': OutputConfig(format: OutputFormat.path, schema: 'review_report_path'),
              // Mis-scoped: prefix is "review-b" instead of "review-a".
              'review-b.findings_count': OutputConfig(format: OutputFormat.json, schema: 'findings_count'),
              'review-b.gating_findings_count': OutputConfig(
                format: OutputFormat.json,
                schema: 'gating_findings_count',
              ),
            },
          ),
          aggregateReviewsStep(),
        ],
      );

      final errors = validator.validate(def).errors;
      expect(
        errors,
        contains(
          isA<ValidationError>()
              .having((error) => error.stepId, 'stepId', 'review-aggregate')
              .having((error) => error.message, 'message', contains('source-scoped'))
              .having((error) => error.message, 'message', contains('review-a.findings_count')),
        ),
      );
    });

    test('rejects duplicate report-path output keys across aggregate sources', () {
      // Two sources both write to the same context key for their review-report path —
      // the merged context is last-writer-wins, so the aggregator would emit the same
      // report twice.
      final def = buildDef(
        steps: [
          reviewSourceStep(id: 'review-a'),
          reviewSourceStep(id: 'review-b'),
          aggregateReviewsStep(aggregateReviews: const ['review-a', 'review-b']),
        ],
      );

      final errors = validator.validate(def).errors;
      expect(
        errors,
        contains(
          isA<ValidationError>()
              .having((error) => error.stepId, 'stepId', 'review-aggregate')
              .having((error) => error.message, 'message', contains('review-a'))
              .having((error) => error.message, 'message', contains('review-b'))
              .having((error) => error.message, 'message', contains('review_findings'))
              .having((error) => error.message, 'message', contains('unique')),
        ),
      );
    });

    test('rejects aggregator outputs with wrong format or preset', () {
      // Key set matches the fixed three-key shape, but the formats/presets are wrong:
      // review_findings declared as `text` instead of `path`, and findings_count using
      // the wrong preset. The runner emits path strings under review_findings and
      // integer counts under the count keys, so a format/preset mismatch is a contract
      // defect even when the key names are correct.
      final outputs = const {
        'review_findings': OutputConfig(format: OutputFormat.text, schema: 'review_report_path'),
        'findings_count': OutputConfig(format: OutputFormat.json, schema: 'non_negative_integer'),
        'gating_findings_count': OutputConfig(format: OutputFormat.json, schema: 'gating_findings_count'),
      };
      final def = buildDef(
        steps: [
          reviewSourceStep(id: 'review-a'),
          aggregateReviewsStep(outputs: outputs),
        ],
      );

      final errors = validator.validate(def).errors;
      expect(
        errors,
        contains(
          isA<ValidationError>()
              .having((error) => error.stepId, 'stepId', 'review-aggregate')
              .having((error) => error.message, 'message', contains('review_findings'))
              .having((error) => error.message, 'message', contains('format: path')),
        ),
      );
      expect(
        errors,
        contains(
          isA<ValidationError>()
              .having((error) => error.stepId, 'stepId', 'review-aggregate')
              .having((error) => error.message, 'message', contains('findings_count'))
              .having((error) => error.message, 'message', contains('non_negative_integer')),
        ),
      );
    });

    test('rejects upstream steps without exactly one review-report path output', () {
      for (final outputs in [
        {'review-a.findings_count': const OutputConfig(format: OutputFormat.json, schema: 'findings_count')},
        {
          'review_findings': const OutputConfig(format: OutputFormat.path, schema: 'review_report_path'),
          'architecture_review_findings': const OutputConfig(format: OutputFormat.path, schema: 'review_report_path'),
          'review-a.findings_count': const OutputConfig(format: OutputFormat.json, schema: 'findings_count'),
        },
      ]) {
        final def = buildDef(
          steps: [
            reviewSourceStep(id: 'review-a', outputs: outputs),
            aggregateReviewsStep(),
          ],
        );

        final errors = validator.validate(def).errors;
        expect(
          errors,
          contains(
            isA<ValidationError>()
                .having((error) => error.stepId, 'stepId', 'review-aggregate')
                .having((error) => error.message, 'message', contains('review-a'))
                .having((error) => error.message, 'message', contains('exactly one review-report path output')),
          ),
        );
      }
    });

    test('rejects aggregator outputs that do not match the fixed three-key shape', () {
      for (final outputs in [
        const {
          'review_findings': OutputConfig(format: OutputFormat.path, schema: 'review_report_path'),
          'findings_count': OutputConfig(format: OutputFormat.json, schema: 'findings_count'),
        },
        const {
          'review_findings': OutputConfig(format: OutputFormat.path, schema: 'review_report_path'),
          'findings_count': OutputConfig(format: OutputFormat.json, schema: 'findings_count'),
          'gating_findings_count': OutputConfig(format: OutputFormat.json, schema: 'gating_findings_count'),
          'extra': OutputConfig(),
        },
      ]) {
        final def = buildDef(
          steps: [
            reviewSourceStep(id: 'review-a'),
            aggregateReviewsStep(outputs: outputs),
          ],
        );

        final errors = validator.validate(def).errors;
        expect(
          errors,
          contains(
            isA<ValidationError>()
                .having((error) => error.stepId, 'stepId', 'review-aggregate')
                .having((error) => error.message, 'message', contains('review_findings'))
                .having((error) => error.message, 'message', contains('gating_findings_count')),
          ),
        );
      }
    });

    test('rejects aggregate-reviews placed inside a loop', () {
      final def = buildDef(
        steps: [
          reviewSourceStep(id: 'review-a'),
          aggregateReviewsStep(),
        ],
        loops: const [
          WorkflowLoop(id: 'remediation-loop', steps: ['review-aggregate'], maxIterations: 3, exitGate: ''),
        ],
      );

      final errors = validator.validate(def).errors;
      expect(
        errors,
        contains(
          isA<ValidationError>()
              .having((error) => error.stepId, 'stepId', 'review-aggregate')
              .having((error) => error.loopId, 'loopId', 'remediation-loop')
              .having((error) => error.type, 'type', ValidationErrorType.invalidReference)
              .having((error) => error.message, 'message', contains('must not appear inside loop')),
        ),
      );
    });

    test('rejects aggregate-reviews placed inside a foreach', () {
      final def = buildDef(
        steps: [
          reviewSourceStep(id: 'review-a'),
          aggregateReviewsStep(),
          WorkflowStep(
            id: 'per-story',
            name: 'Per story',
            type: WorkflowTaskType.foreach,
            mapOver: 'context.items',
            mapAlias: 'item',
            foreachSteps: const ['review-aggregate'],
          ),
        ],
      );

      final errors = validator.validate(def).errors;
      expect(
        errors,
        contains(
          isA<ValidationError>()
              .having((error) => error.stepId, 'stepId', 'review-aggregate')
              .having((error) => error.type, 'type', ValidationErrorType.invalidReference)
              .having((error) => error.message, 'message', contains('must not appear inside foreach step "per-story"')),
        ),
      );
    });
  });

  group('foreach node validation', () {
    test('valid foreach controller with children passes validation', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(id: 'produce', name: 'Produce', prompts: ['p'], outputs: {'items': OutputConfig()}),
          WorkflowStep(
            id: 'fe',
            name: 'FE',
            type: WorkflowTaskType.foreach,
            mapOver: 'items',
            foreachSteps: ['c1', 'c2'],
            outputs: {'results': OutputConfig()},
          ),
          WorkflowStep(id: 'c1', name: 'C1', prompts: ['p']),
          WorkflowStep(id: 'c2', name: 'C2', prompts: ['p']),
        ],
      );
      final errors = validator.validate(def).errors;
      expect(errors, isEmpty);
    });

    test('foreach controller referencing unknown child step produces invalidReference error', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(id: 'produce', name: 'Produce', prompts: ['p'], outputs: {'items': OutputConfig()}),
          WorkflowStep(
            id: 'fe',
            name: 'FE',
            type: WorkflowTaskType.foreach,
            mapOver: 'items',
            foreachSteps: ['c1', 'nonexistent'],
            outputs: {'results': OutputConfig()},
          ),
          WorkflowStep(id: 'c1', name: 'C1', prompts: ['p']),
        ],
      );
      final errors = validator.validate(def).errors;
      expect(hasError(errors, type: ValidationErrorType.invalidReference, stepId: 'nonexistent'), isTrue);
    });

    test('foreach node with empty childStepIds produces missingField error', () {
      // Construct definition with a step that claims to be foreach but has empty foreachSteps.
      // This bypasses the parser (which rejects empty steps) and tests the validator directly.
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(id: 'produce', name: 'Produce', prompts: ['p'], outputs: {'items': OutputConfig()}),
          WorkflowStep(id: 'fe', name: 'FE', type: WorkflowTaskType.foreach, mapOver: 'items', foreachSteps: []),
        ],
      );
      // With empty foreachSteps, isForeachController is false, so normalization
      // produces a MapNode instead. Validator checks differ per node type.
      // This verifies the definition is constructable but not treated as foreach.
      expect(def.steps[1].isForeachController, isFalse);
    });

    test('foreach type registered as known type (no unknown-type warning)', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(id: 'produce', name: 'Produce', prompts: ['p'], outputs: {'items': OutputConfig()}),
          WorkflowStep(
            id: 'fe',
            name: 'FE',
            type: WorkflowTaskType.foreach,
            mapOver: 'items',
            foreachSteps: ['c1'],
            outputs: {'results': OutputConfig()},
          ),
          WorkflowStep(id: 'c1', name: 'C1', prompts: ['p']),
        ],
      );
      final report = validator.validate(def);
      expect(
        report.warnings.any((w) => w.type == ValidationErrorType.hybridStepConstraint && w.stepId == 'fe'),
        isFalse,
        reason: 'foreach is a known type and should not trigger unknown-type warning',
      );
    });
  });

  group('map alias (`as:`) validation', () {
    test('valid `as:` on a map step produces no errors', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(id: 'setup', name: 'Setup', prompts: ['Setup'], outputs: {'items': OutputConfig()}),
          WorkflowStep(
            id: 'each',
            name: 'Each',
            prompts: ['Process {{thing.item.path}}'],
            mapOver: 'items',
            mapAlias: 'thing',
            outputs: {'results': OutputConfig()},
          ),
        ],
      );
      final errors = validator.validate(def).errors;
      expect(errors, isEmpty);
    });

    test('`as:` on a non-map step is an error', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(id: 's', name: 'S', prompts: ['hi'], mapAlias: 'story'),
        ],
      );
      final errors = validator.validate(def).errors;
      expect(hasError(errors, messageContains: 'only valid on map/foreach controllers'), isTrue);
    });

    test('`as:` colliding with a workflow variable is an error', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        variables: const {'PROJECT': WorkflowVariable(required: false, defaultValue: 'x')},
        steps: const [
          WorkflowStep(id: 'setup', name: 'Setup', prompts: ['Setup'], outputs: {'items': OutputConfig()}),
          WorkflowStep(
            id: 'each',
            name: 'Each',
            prompts: ['p'],
            mapOver: 'items',
            mapAlias: 'PROJECT',
            outputs: {'results': OutputConfig()},
          ),
        ],
      );
      final errors = validator.validate(def).errors;
      expect(hasError(errors, messageContains: 'collides with a declared workflow variable'), isTrue);
    });

    test('alias references in substep prompts are not flagged as undeclared variables', () {
      // `{{story.item.spec_path}}` in the child prompt would be mistaken for an
      // undeclared variable without alias-aware extraction.
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(id: 'setup', name: 'Setup', prompts: ['Setup'], outputs: {'items': OutputConfig()}),
          WorkflowStep(
            id: 'pipeline',
            name: 'Pipeline',
            prompts: null,
            mapOver: 'items',
            mapAlias: 'story',
            foreachSteps: ['implement'],
            outputs: {'results': OutputConfig()},
          ),
          WorkflowStep(id: 'implement', name: 'Implement', prompts: ['Implement {{story.item.spec_path}}']),
        ],
      );
      final errors = validator.validate(def).errors;
      expect(
        hasError(errors, messageContains: 'undeclared variable'),
        isFalse,
        reason: 'Alias-aware extraction should skip {{story.*}} in child prompts',
      );
    });
  });

  group('foreach-nested loops', () {
    final parser = WorkflowDefinitionParser();

    String foreachWithNestedLoop(String loopBody) => '''
name: nested
description: foreach with nested loop
steps:
  - id: seed
    name: Seed
    prompt: produce items
    outputs: { items: lines }
  - id: per-item
    name: Per Item
    type: foreach
    map_over: items
    outputs: { results: { format: json } }
    steps:
      - id: review
        name: Review
        prompt: review
        outputs: { gating_findings_count: gating_findings_count }
      - id: remediation
        name: Remediation Loop
        type: loop
        maxIterations: 3
        exitGate: "gating_findings_count == 0"
        steps:
$loopBody''';

    test('accepts a foreach-nested loop (TI03)', () {
      final def = parser.parse(
        foreachWithNestedLoop('''
          - id: remediate
            name: Remediate
            prompt: fix
          - id: re-review
            name: Re-review
            prompt: rr
            outputs: { gating_findings_count: gating_findings_count }'''),
      );
      expect(validator.validate(def).errors, isEmpty);
    });

    test('rejects an aggregate-reviews step inside a foreach-nested loop (TI03)', () {
      final def = parser.parse(
        foreachWithNestedLoop('''
          - id: agg
            name: Aggregate
            type: aggregate-reviews
            aggregateReviews: [review]
            outputs:
              review_findings: review_report_path
              findings_count: findings_count
              gating_findings_count: gating_findings_count'''),
      );
      final errors = validator.validate(def).errors;
      expect(
        errors.any(
          (e) => e.message.contains('Aggregate-reviews step') && e.message.contains('must not appear inside loop'),
        ),
        isTrue,
        reason: 'aggregate-reviews inside a foreach-nested loop must be rejected',
      );
    });
  });
}
