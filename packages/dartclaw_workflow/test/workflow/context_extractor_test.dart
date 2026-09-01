@Tags(['component'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show ArtifactKind, MessageService, OutputConfig, OutputFormat, OutputMode, SessionService;
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show ContextExtractor;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show SchemaValidator, executionEnvelopeMarkerKey, executionEnvelopeVersion;
import 'package:dartclaw_workflow/src/workflow/execution_envelope_schema.dart' show buildExecutionEnvelopeSchema;
import 'package:dartclaw_runtime/dartclaw_runtime.dart' show TaskService;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'context_extractor_test_support.dart';

void main() {
  late ContextExtractorTestHarness harness;
  late Directory tempDir;
  late TaskService taskService;
  late MessageService messageService;
  late SessionService sessionService;
  late ContextExtractor extractor;

  setUp(() {
    harness = ContextExtractorTestHarness()..setUp();
    tempDir = harness.tempDir;
    taskService = harness.taskService;
    messageService = harness.messageService;
    sessionService = harness.sessionService;
    extractor = harness.extractor;
  });

  tearDown(() => harness.tearDown());

  test('returns empty map when step has no outputs', () async {
    final task = await harness.createTask();
    final step = harness.makeStep(outputs: {});
    final outputs = await extractor.extract(step, task);
    expect(outputs, isEmpty);
  });

  test('leaves a declared key absent with no artifacts or session', () async {
    // Fabricating '' here would be indistinguishable downstream from a real
    // empty value; absence is the honest answer and the gate seam depends on it.
    final task = await harness.createTask();
    final step = harness.makeStep(outputs: {'research_notes': OutputConfig()});
    final outputs = await extractor.extract(step, task);
    expect(outputs, isNot(contains('research_notes')));
  });

  test('a .md artifact is not substituted for an unresolved text output', () async {
    // `_extractFirstMdArtifact` returned the first `.md` file in the task's
    // artifacts for ANY unresolved text output — a name-agnostic substitution,
    // not an artifact read. The envelope is the only source now.
    final task = await harness.createTaskWithArtifact(
      name: 'output.md',
      content: '# Research Notes\nThis is the research output.',
    );

    final step = harness.makeStep(outputs: {'research_notes': OutputConfig()});
    final outputs = await extractor.extract(step, task);
    expect(outputs, isNot(contains('research_notes')));
  });

  test('extracts declared text outputs from the execution envelope', () async {
    final taskWithSession = await harness.buildTaskWithContext('task-session-1', {
      'research_notes': 'Found important findings about X.',
      'summary': 'Brief summary here.',
    }, prefix: 'Here is my response.');

    final step = harness.makeStep(outputs: {'research_notes': OutputConfig()});
    final outputs = await extractor.extract(step, taskWithSession);
    expect(outputs['research_notes'], equals('Found important findings about X.'));
  });

  test('extracts structured JSON values from the execution envelope', () async {
    final taskWithSession = await harness.buildTaskWithContext('task-json-1', {
      'research_notes': 'JSON extracted value',
      'summary': 'JSON summary',
    });

    final step = harness.makeStep(outputs: {'research_notes': OutputConfig()});
    final outputs = await extractor.extract(step, taskWithSession);
    expect(outputs['research_notes'], equals('JSON extracted value'));
  });

  test('leaves an unclaimed source output unset rather than asserting a provenance', () async {
    // A blank `*_source` used to be back-filled with 'synthesized', so a step
    // that never claimed provenance still satisfied `entryGate: "x_source ==
    // synthesized"`. Absence is now absence, like any other declared output.
    final task = await harness.createTask();
    final step = harness.makeStep(outputs: {'plan_source': OutputConfig()});

    final outputs = await extractor.extract(step, task);

    expect(outputs['plan_source'], isNot('synthesized'));
    expect(outputs, isNot(contains('plan_source')));
  });

  test('uses envelope values for narrative-only outputs', () async {
    final taskWithSession = await harness.buildTaskWithContext('task-narrative-inline', {
      'summary': 'Envelope summary',
      'confidence': 8,
    });
    final fallbackCalls = <String>[];
    final localExtractor = ContextExtractor(
      taskService: taskService,
      messageService: messageService,
      dataDir: tempDir.path,
      workflowStepExecutionRepository: harness.workflowStepExecutions,
      structuredOutputFallbackRecorder:
          (_, {required stepId, required outputKey, required failureReason, String? providerSubtype}) {
            fallbackCalls.add(outputKey);
          },
    );
    final step = harness.makeStep(
      outputs: const {
        'summary': OutputConfig(format: OutputFormat.text),
        'confidence': OutputConfig(format: OutputFormat.json, schema: 'non_negative_integer'),
      },
    );

    final outputs = await localExtractor.extract(step, taskWithSession);

    expect(outputs['summary'], 'Envelope summary');
    expect(outputs['confidence'], 8);
    expect(fallbackCalls, isEmpty);
  });

  test('resolves mixed filesystem and narrative outputs from one envelope', () async {
    final worktree = Directory(p.join(tempDir.path, 'worktree-mixed'))..createSync();
    File(p.join(worktree.path, 'fis', 's01-foo.md'))
      ..createSync(recursive: true)
      ..writeAsStringSync('# Foo\n');
    File(p.join(worktree.path, 'fis', 's02-bar.md'))
      ..createSync(recursive: true)
      ..writeAsStringSync('# Bar\n');
    final localExtractor = harness.extractorFor();
    final taskWithWorktree = await harness.buildTaskWithContext('task-mixed-output', {
      'fis_paths': ['fis/s02-bar.md', 'fis/s01-foo.md'],
      'summary': 'Envelope summary',
      'confidence': 9,
    }, worktreePath: worktree.path);
    final step = harness.makeStep(
      outputs: const {
        'fis_paths': OutputConfig(format: OutputFormat.lines),
        'summary': OutputConfig(format: OutputFormat.text),
        'confidence': OutputConfig(format: OutputFormat.json, schema: 'non_negative_integer'),
      },
    );

    final outputs = await localExtractor.extract(step, taskWithWorktree);

    expect(outputs['fis_paths'], ['fis/s01-foo.md', 'fis/s02-bar.md']);
    expect(outputs['summary'], 'Envelope summary');
    expect(outputs['confidence'], 9);
  });

  test('S02 a declared key absent from the envelope is recovered from no prose route', () async {
    // All four retired routes are present in one fixture: a tagged block, a
    // ```json fence, a bare brace run, and a `.md` task artifact. None supplies
    // a value, and the envelope schema the step would have been asked for
    // requires the key — so the step fails validation rather than resolving.
    const planValue = '{"steps":["a","b"]}';
    final task = await harness.createTaskWithArtifact(
      taskId: 'task-s02-recovery-routes',
      name: 'plan.md',
      content: '# Plan from an artifact\n',
    );
    final session = await sessionService.getOrCreateMainSession();
    await messageService.insertMessage(
      sessionId: session.id,
      role: 'assistant',
      content:
          'Here is the plan.\n\n<workflow-context>{"plan":$planValue}</workflow-context>\n\n'
          '```json\n{"plan":$planValue}\n```\n\n'
          '{"plan":$planValue}\n',
    );
    await taskService.updateFields(task.id, sessionId: session.id);
    await harness.seedEnvelopeOutputs(task.id, const {'summary': 'unrelated'});

    const outputs = {
      'plan': OutputConfig(
        format: OutputFormat.json,
        schema: {
          'type': 'object',
          'additionalProperties': false,
          'required': ['steps'],
          'properties': {
            'steps': {
              'type': 'array',
              'items': {'type': 'string'},
            },
          },
        },
      ),
    };
    final step = harness.makeStep(outputs: outputs);

    final extracted = await extractor.extract(step, (await taskService.get(task.id))!);
    expect(
      extracted,
      isNot(contains('plan')),
      reason: 'no recovery route supplies a value, so the key is absent rather than fabricated',
    );

    // The step never reaches extraction in production: the envelope schema
    // requires `plan`, so a finalizer omitting it fails host-side validation.
    final schema = buildExecutionEnvelopeSchema(step, outputs)!;
    expect((schema['properties'] as Map)['outputs']['required'], contains('plan'));
    expect(
      const SchemaValidator().validate({
        'outputs': const <String, dynamic>{},
        'step_outcome': const {'outcome': 'succeeded', 'reason': 'done'},
      }, schema),
      isNotEmpty,
    );
  });

  test('a lines output normalizes the envelope value it was given', () async {
    final taskWithSession = await harness.buildTaskWithContext('task-lines-1', {
      'result': 'alpha\n  beta  \n\n gamma ',
    });

    final step = harness.makeStep(outputs: {'result': const OutputConfig(format: OutputFormat.lines)});

    final outputs = await extractor.extract(step, taskWithSession);
    expect(outputs['result'], equals(['alpha', 'beta', 'gamma']));
  });

  test('schema preset warnings stay soft for a non-strict envelope output', () async {
    final previousLevel = Logger.root.level;
    Logger.root.level = Level.ALL;
    final records = <LogRecord>[];
    final sub = Logger('ContextExtractor').onRecord.listen(records.add);
    addTearDown(() async {
      Logger.root.level = previousLevel;
      await sub.cancel();
    });

    final taskWithSession = await harness.buildTaskWithContext('task-schema-1', {
      'result': {'summary': 'Only summary'},
    });

    final step = harness.makeStep(
      outputs: {'result': const OutputConfig(format: OutputFormat.json, schema: 'verdict')},
    );

    final outputs = await extractor.extract(step, taskWithSession);
    final result = outputs['result'] as Map<String, dynamic>;

    expect(result['summary'], equals('Only summary'));
    expect(
      records.any(
        (record) =>
            record.level == Level.WARNING &&
            record.message.contains('Schema validation for "result"') &&
            record.message.contains('"pass"'),
      ),
      isTrue,
    );
  });

  test('extracts diff.json artifact for canonical diff_summary key', () async {
    final task = await harness.createTaskWithArtifact(
      name: 'diff.json',
      kind: ArtifactKind.data,
      content: jsonEncode({'files': 3, 'additions': 45, 'deletions': 12}),
    );

    final step = harness.makeStep(outputs: {'diff_summary': OutputConfig()});
    final outputs = await extractor.extract(step, task);
    expect(outputs['diff_summary'], contains('3 files changed'));
    expect(outputs['diff_summary'], contains('+45'));
    expect(outputs['diff_summary'], contains('-12'));
  });

  test('large content value (>10K chars) is returned without truncation', () async {
    final largeContent = 'x' * 15000;
    final task = await harness.buildTaskWithContext('task-large', {'large_output': largeContent});

    final step = harness.makeStep(outputs: {'large_output': OutputConfig()});
    final outputs = await extractor.extract(step, task);
    // Content should not be truncated – only a warning is logged.
    expect(outputs['large_output'], equals(largeContent));
  });

  test('dead diff/changes convention fallback does not read diff.json', () async {
    final task = await harness.createTaskWithArtifact(
      name: 'diff.json',
      kind: ArtifactKind.data,
      content: jsonEncode({'files': 1, 'additions': 5, 'deletions': 2}),
    );

    final step = harness.makeStep(outputs: {'notes': OutputConfig(), 'diff_changes': OutputConfig()});
    final outputs = await extractor.extract(step, task);
    expect(outputs, isNot(contains('notes')));
    expect(outputs, isNot(contains('diff_changes')));
  });

  test('structured output mode reads the declared value from the envelope', () async {
    final task = await harness.buildTaskWithContext('task-structured-config', {
      'verdict': {'pass': true, 'findings_count': 0, 'findings': <Object?>[], 'summary': 'Clean'},
    });

    final step = harness.makeStep(
      outputs: const {
        'verdict': OutputConfig(format: OutputFormat.json, outputMode: OutputMode.structured, schema: 'verdict'),
      },
    );
    final outputs = await extractor.extract(step, task);

    expect(outputs['verdict'], isA<Map<Object?, Object?>>());
    expect((outputs['verdict'] as Map<Object?, Object?>)['pass'], isTrue);
  });

  test('structured output mode rejects an envelope value that violates schema', () async {
    final task = await harness.buildTaskWithContext('task-structured-invalid', {'count': -1});

    final step = harness.makeStep(
      outputs: const {
        'count': OutputConfig(
          format: OutputFormat.json,
          outputMode: OutputMode.structured,
          schema: 'non_negative_integer',
        ),
      },
    );

    await expectLater(
      extractor.extract(step, task),
      throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('failed schema validation'))),
    );
  });

  test('structured output mode records a fallback and resolves nothing when the envelope omits the key', () async {
    final task = await harness.buildTaskWithAssistantMessage(
      'task-structured-fallback',
      '{"verdict":{"pass":true,"findings_count":0,"findings":[],"summary":"Clean"}}',
    );
    await harness.seedEnvelopeOutputs(task.id, const {'unrelated': 'x'});

    final fallbackCalls = <Map<String, Object?>>[];
    final localExtractor = ContextExtractor(
      taskService: taskService,
      messageService: messageService,
      dataDir: tempDir.path,
      workflowStepExecutionRepository: harness.workflowStepExecutions,
      structuredOutputFallbackRecorder:
          (taskId, {required stepId, required outputKey, required failureReason, String? providerSubtype}) {
            fallbackCalls.add({
              'taskId': taskId,
              'stepId': stepId,
              'outputKey': outputKey,
              'failureReason': failureReason,
              'providerSubtype': providerSubtype,
            });
          },
    );

    final step = harness.makeStep(
      outputs: const {
        'verdict': OutputConfig(format: OutputFormat.json, outputMode: OutputMode.structured, schema: 'verdict'),
      },
    );
    final outputs = await localExtractor.extract(step, task);

    expect(
      outputs,
      isNot(contains('verdict')),
      reason: 'the JSON in the transcript is inert text, so nothing is produced for the key',
    );
    expect(fallbackCalls, [
      {
        'taskId': 'task-structured-fallback',
        'stepId': 'step1',
        'outputKey': 'verdict',
        'failureReason': 'missing_payload',
        'providerSubtype': null,
      },
    ]);
  });

  test('derived outputs reuse fields from an earlier parsed JSON output', () async {
    final task = await harness.buildTaskWithContext('task-session-json', {
      'review_summary': {
        'pass': false,
        'findings_count': 2,
        'findings': [
          {'severity': 'high', 'location': 'lib/a.dart:10', 'description': 'Issue A'},
          {'severity': 'low', 'location': 'lib/b.dart:12', 'description': 'Issue B'},
        ],
        'summary': 'Two findings remain.',
      },
    });

    final step = harness.makeStep(
      outputs: const {
        'review_summary': OutputConfig(format: OutputFormat.json, schema: 'verdict'),
        'findings_count': OutputConfig(format: OutputFormat.text),
      },
    );

    final outputs = await extractor.extract(step, task);
    expect(outputs['review_summary'], isA<Map<String, dynamic>>());
    expect((outputs['review_summary'] as Map<String, dynamic>)['findings_count'], 2);
    expect(outputs['findings_count'], 2);
  });

  test('review producer outputs preserve distinct total and gating findings counts', () async {
    for (final producer in reviewSummaryProducers) {
      for (final gatingCount in const [0, 1]) {
        final payload = <String, Object?>{'findings_count': 3, producer.totalKey: 3, producer.gatingKey: gatingCount};
        final summaryKey = producer.summaryKey;
        if (summaryKey != null) {
          payload[summaryKey] = {
            'pass': gatingCount == 0,
            'findings_count': 3,
            'findings': [
              {
                'severity': gatingCount == 0 ? 'low' : 'high',
                'location': 'lib/workflow.dart:1',
                'description': 'Representative review finding',
              },
              {'severity': 'low', 'location': 'lib/workflow.dart:2', 'description': 'Low severity review finding'},
              {
                'severity': 'low',
                'location': 'lib/workflow.dart:3',
                'description': 'Another low severity review finding',
              },
            ],
            'summary': gatingCount == 0 ? 'Only LOW findings remain.' : 'A HIGH finding remains.',
          };
        }
        final taskId = 'task-${producer.stepId}-$gatingCount';
        final task = await harness.buildTaskWithContext(taskId, payload);
        final step = harness.makeStep(
          id: producer.stepId,
          outputs: harness.reviewCountOutputs(producer, includeSummary: true),
        );

        final outputs = await extractor.extract(step, task);

        expect(outputs[producer.totalKey], 3, reason: producer.name);
        expect(outputs[producer.gatingKey], gatingCount, reason: producer.name);
      }
    }
  });

  test('review counts are the emitted integers even when a verdict in the same payload disagrees', () async {
    // OC04: the host does not recompute a count by scanning nested verdict maps.
    // The verdict here holds six findings and its own findings_count of 6; the
    // declared count outputs must still be exactly what the step emitted.
    const stepId = 'review-code';
    const verdict = {
      'pass': false,
      'findings_count': 6,
      'findings': [
        {'severity': 'critical', 'location': 'lib/a.dart:1', 'description': 'one'},
        {'severity': 'critical', 'location': 'lib/a.dart:2', 'description': 'two'},
        {'severity': 'high', 'location': 'lib/a.dart:3', 'description': 'three'},
        {'severity': 'medium', 'location': 'lib/a.dart:4', 'description': 'four'},
        {'severity': 'low', 'location': 'lib/a.dart:5', 'description': 'five'},
        {'severity': 'low', 'location': 'lib/a.dart:6', 'description': 'six'},
      ],
      'summary': 'Six findings remain.',
    };
    final task = await harness.buildTaskWithEnvelope('task-schema-trusted-counts', {
      'outputs': {'$stepId.findings_count': 4, '$stepId.gating_findings_count': 2, 'verdict': verdict},
      'step_outcome': {'outcome': 'succeeded', 'reason': 'reviewed'},
      executionEnvelopeMarkerKey: executionEnvelopeVersion,
    });
    final step = harness.makeStep(
      id: stepId,
      outputs: const {
        '$stepId.findings_count': OutputConfig(
          format: OutputFormat.json,
          schema: 'non_negative_integer',
          outputMode: OutputMode.structured,
        ),
        '$stepId.gating_findings_count': OutputConfig(
          format: OutputFormat.json,
          schema: 'non_negative_integer',
          outputMode: OutputMode.structured,
        ),
        'verdict': OutputConfig(format: OutputFormat.json, schema: 'verdict'),
      },
    );

    final outputs = await extractor.extract(step, task);

    expect(outputs['$stepId.findings_count'], 4);
    expect(outputs['$stepId.gating_findings_count'], 2);
  });

  test('a declared count key carrying no integer fails schema validation instead of being derived', () async {
    // The verdict object is emitted under the count key. Nothing derives 2 from
    // its findings list — the strict count schema rejects the payload outright.
    const stepId = 'review-code';
    final task = await harness.buildTaskWithEnvelope('task-uncountable-payload', {
      'outputs': {
        '$stepId.findings_count': {
          'findings': [
            {'severity': 'critical', 'location': 'lib/a.dart:1', 'description': 'one'},
            {'severity': 'high', 'location': 'lib/a.dart:2', 'description': 'two'},
          ],
        },
      },
      'step_outcome': {'outcome': 'succeeded', 'reason': 'reviewed'},
      executionEnvelopeMarkerKey: executionEnvelopeVersion,
    });
    final step = harness.makeStep(
      id: stepId,
      outputs: const {
        '$stepId.findings_count': OutputConfig(
          format: OutputFormat.json,
          schema: 'non_negative_integer',
          outputMode: OutputMode.structured,
        ),
      },
    );

    await expectLater(
      extractor.extract(step, task),
      throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('failed schema validation'))),
    );
  });

  test('review producer outputs prefer explicit counters over structured verdict counts', () async {
    for (final producer in reviewSummaryProducers.where((producer) => producer.summaryKey != null)) {
      final payload = <String, Object?>{
        'findings_count': 0,
        'gating_findings_count': 0,
        producer.totalKey: 0,
        producer.gatingKey: 0,
        producer.summaryKey!: {
          'pass': false,
          'findings_count': 2,
          'findings': [
            {'severity': 'critical', 'location': 'lib/workflow.dart:1', 'description': 'Critical finding'},
            {'severity': 'low', 'location': 'lib/workflow.dart:2', 'description': 'Low finding'},
          ],
          'summary': 'A critical finding remains.',
        },
      };
      final task = await harness.buildTaskWithContext('task-${producer.stepId}-contradictory-counts', payload);
      final step = harness.makeStep(
        id: producer.stepId,
        outputs: harness.reviewCountOutputs(producer, includeSummary: true),
      );

      final outputs = await extractor.extract(step, task);

      expect(outputs[producer.totalKey], 0, reason: producer.name);
      expect(outputs[producer.gatingKey], 0, reason: producer.name);
    }
  });

  test('file-backed review producers do not substitute total count when gating count is missing', () async {
    const producers = <ReviewProducer>[
      (
        name: 'dartclaw-review',
        stepId: 'plan-review',
        summaryKey: null,
        totalKey: 'plan-review.findings_count',
        gatingKey: 'plan-review.gating_findings_count',
      ),
      (
        name: 'dartclaw-architecture',
        stepId: 'architecture-review',
        summaryKey: null,
        totalKey: 'architecture-review.findings_count',
        gatingKey: 'architecture-review.gating_findings_count',
      ),
    ];

    for (final producer in producers) {
      for (final findingsCount in const [0, 2]) {
        final payload = <String, Object?>{
          'review_report_path': 'docs/specs/review.md',
          producer.totalKey: findingsCount,
        };
        final taskId = 'task-${producer.stepId}-file-backed-$findingsCount';
        final task = await harness.buildTaskWithContext(taskId, payload);
        final step = harness.makeStep(id: producer.stepId, outputs: harness.reviewCountOutputs(producer));

        final outputs = await extractor.extract(step, task);

        expect(outputs[producer.totalKey], findingsCount, reason: producer.name);
        expect(outputs[producer.gatingKey], isNot(findingsCount), reason: producer.name);
      }
    }
  });

  test('file-backed review producers keep the scoped gating count independent from the scoped total', () async {
    final payload = <String, Object?>{'plan-review.findings_count': 2, 'plan-review.gating_findings_count': 0};
    final task = await harness.buildTaskWithContext('task-plan-review-scoped-total-wins', payload);
    final step = harness.makeStep(
      id: 'plan-review',
      outputs: const {
        'plan-review.findings_count': OutputConfig(format: OutputFormat.json, schema: 'non_negative_integer'),
        'plan-review.gating_findings_count': OutputConfig(format: OutputFormat.json, schema: 'non_negative_integer'),
      },
    );

    final outputs = await extractor.extract(step, task);

    expect(outputs['plan-review.findings_count'], 2);
    expect(outputs['plan-review.gating_findings_count'], 0);
  });

  test(
    'file-backed review producers keep already-extracted unscoped gating alias independent from scoped total',
    () async {
      final payload = <String, Object?>{'plan-review.findings_count': 2, 'gating_findings_count': 0};
      final task = await harness.buildTaskWithContext('task-plan-review-extracted-unscoped-gating', payload);
      final step = harness.makeStep(
        id: 'plan-review',
        outputs: const {
          'gating_findings_count': OutputConfig(format: OutputFormat.json, schema: 'non_negative_integer'),
          'plan-review.findings_count': OutputConfig(format: OutputFormat.json, schema: 'non_negative_integer'),
          'plan-review.gating_findings_count': OutputConfig(format: OutputFormat.json, schema: 'non_negative_integer'),
        },
      );

      final outputs = await extractor.extract(step, task);

      expect(outputs['gating_findings_count'], 0);
      expect(outputs['plan-review.findings_count'], 2);
      expect(outputs['plan-review.gating_findings_count'], 0);
    },
  );

  group('worktree source outputs', () {
    for (final testCase in const [
      (
        name: 'branch extracts branch from task.worktreeJson',
        id: 'task-wt1',
        outputKey: 'branch',
        source: 'worktree.branch',
        branch: 'feat/fix-bug-123',
        path: '/worktrees/fix-bug-123',
        expected: 'feat/fix-bug-123',
      ),
      (
        name: 'path extracts path from task.worktreeJson',
        id: 'task-wt2',
        outputKey: 'worktree_path',
        source: 'worktree.path',
        branch: 'feat/fix-bug',
        path: '/opt/worktrees/fix-bug',
        expected: '/opt/worktrees/fix-bug',
      ),
      (
        name: 'branch returns empty string when task has no worktreeJson',
        id: 'task-wt3',
        outputKey: 'branch',
        source: 'worktree.branch',
        branch: null,
        path: null,
        expected: '',
      ),
    ]) {
      test('source: worktree.${testCase.name}', () async {
        final task = await harness.buildTaskWithWorktreeSource(
          testCase.id,
          branch: testCase.branch,
          path: testCase.path,
        );
        final outputs = await extractor.extract(harness.worktreeSourceStep(testCase.outputKey, testCase.source), task);
        expect(outputs[testCase.outputKey], equals(testCase.expected));
      });
    }
  });

  group('execution envelope outputs', () {
    test('extracts declared outputs from the envelope outputs subobject', () async {
      final task = await harness.buildTaskWithEnvelope('task-envelope-outputs', {
        'outputs': {'summary': 'X'},
        'step_outcome': {'outcome': 'succeeded', 'reason': 'ok'},
        executionEnvelopeMarkerKey: executionEnvelopeVersion,
      });
      final step = harness.makeStep(outputs: {'summary': const OutputConfig(format: OutputFormat.text)});

      final outputs = await extractor.extract(step, task);

      expect(outputs['summary'], 'X');
    });

    test('S06 a pre-envelope flat payload fails the step with a re-run instruction', () async {
      // A run started before 0.25 persisted its outputs on a channel that no
      // longer exists. Resolving whatever the flat payload happened to contain
      // would advance the run on a partial context.
      final task = await harness.buildTaskWithLegacyStructuredOutput('task-legacy-flat', '{"summary":"Y"}');
      final step = harness.makeStep(outputs: {'summary': const OutputConfig(format: OutputFormat.text)});

      await expectLater(
        extractor.extract(step, task),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('pre-0.25'), contains('re-run the workflow under 0.25')),
          ),
        ),
      );
    });

    test('a task with no persisted structured output takes the missing-envelope path', () async {
      // Absent is not legacy: the finalizer's own re-ask already charged for it,
      // so extraction leaves the key unset rather than failing a second time.
      final task = await harness.buildTask('task-no-payload');
      final step = harness.makeStep(outputs: {'summary': const OutputConfig(format: OutputFormat.text)});

      expect(await extractor.extract(step, task), isNot(contains('summary')));
    });

    test('does not crash on a malformed envelope whose outputs is missing or not a map', () async {
      final cases = <(String, Map<String, dynamic>)>[
        (
          'missing',
          {
            'step_outcome': {'outcome': 'succeeded', 'reason': 'ok'},
            executionEnvelopeMarkerKey: executionEnvelopeVersion,
          },
        ),
        ('nonmap', {'outputs': 'not-a-map', executionEnvelopeMarkerKey: executionEnvelopeVersion}),
      ];
      for (final (label, envelope) in cases) {
        final task = await harness.buildTaskWithEnvelope('task-malformed-envelope-$label', envelope);
        final step = harness.makeStep(outputs: {'summary': const OutputConfig(format: OutputFormat.text)});

        final outputs = await extractor.extract(step, task);

        expect(outputs, isNot(contains('summary')), reason: label);
      }
    });

    test('S01 the envelope value wins over a well-formed inline block, which is inert on its own', () async {
      final session = await sessionService.getOrCreateMainSession();
      await messageService.insertMessage(
        sessionId: session.id,
        role: 'assistant',
        content: 'Done.\n\n<workflow-context>{"summary":"from prose"}</workflow-context>',
      );
      final step = harness.makeStep(outputs: {'summary': const OutputConfig(format: OutputFormat.text)});

      final withEnvelope = await harness.buildTaskWithEnvelope('task-envelope-wins-over-inline', {
        'outputs': {'summary': 'from envelope'},
        'step_outcome': {'outcome': 'succeeded', 'reason': 'ok'},
        executionEnvelopeMarkerKey: executionEnvelopeVersion,
      }, sessionId: session.id);
      expect((await extractor.extract(step, withEnvelope))['summary'], 'from envelope');

      // Same transcript, no envelope: the block is text, not a channel.
      final withoutEnvelope = await harness.buildTask('task-inline-only', sessionId: session.id);
      expect(await extractor.extract(step, withoutEnvelope), isNot(contains('summary')));
    });
  });

  group('*_source outputs', () {
    final sourceOutputs = {
      'spec_source': const OutputConfig(format: OutputFormat.text, schema: 'narrative_text'),
      'summary': const OutputConfig(format: OutputFormat.text),
    };

    test('S03 spec_source travels in the envelope like any other declared claim', () async {
      final task = await harness.buildTaskWithEnvelope('task-source-envelope', {
        'outputs': {'spec_source': 'existing', 'summary': 'X'},
        'step_outcome': {'outcome': 'succeeded', 'reason': 'ok'},
        executionEnvelopeMarkerKey: executionEnvelopeVersion,
      });

      final outputs = await extractor.extract(harness.makeStep(outputs: sourceOutputs), task);

      expect(outputs['spec_source'], 'existing');
      expect(outputs['summary'], 'X');
    });

    test('an inline-emitted spec_source is ignored when the envelope omits it', () async {
      final session = await sessionService.getOrCreateMainSession();
      await messageService.insertMessage(
        sessionId: session.id,
        role: 'assistant',
        content: 'Classified.\n\n<workflow-context>{"spec_source":"existing"}</workflow-context>',
      );
      final task = await harness.buildTaskWithEnvelope('task-source-inline-ignored', {
        'outputs': {'summary': 'X'},
        'step_outcome': {'outcome': 'succeeded', 'reason': 'ok'},
        executionEnvelopeMarkerKey: executionEnvelopeVersion,
      }, sessionId: session.id);

      final outputs = await extractor.extract(harness.makeStep(outputs: sourceOutputs), task);

      expect(outputs, isNot(contains('spec_source')));
      expect(outputs['summary'], 'X');
    });

    test('an omitted spec_source stays unset instead of defaulting to synthesized', () async {
      // Inventing 'synthesized' told `entryGate: "spec_source == synthesized"`
      // that a new spec had been authored when none had.
      final task = await harness.buildTaskWithEnvelope('task-source-omitted-default', {
        'outputs': {'summary': 'X'},
        'step_outcome': {'outcome': 'succeeded', 'reason': 'ok'},
        executionEnvelopeMarkerKey: executionEnvelopeVersion,
      });

      final outputs = await extractor.extract(harness.makeStep(outputs: sourceOutputs), task);

      expect(outputs['spec_source'], isNot('synthesized'));
      expect(outputs, isNot(contains('spec_source')));
      expect(outputs['summary'], 'X');
    });
  });
}
