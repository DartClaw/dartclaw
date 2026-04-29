import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_models/dartclaw_models.dart' show WorkflowRunStatus;
import 'package:dartclaw_server/dartclaw_server.dart' show LogService;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'workflow_e2e_test_support.dart';

void main() {
  group('workflow e2e prerequisites', () {
    test('codex absent skips with actionable message', () async {
      final result = await evaluateWorkflowE2ePrerequisites(
        environment: const {},
        runProcess: _fakeProcessRunner({('codex', '--version'): ProcessResult(1, 1, '', 'missing')}),
      );

      expect(result.shouldSkip, isTrue);
      expect(result.skipReason, allOf(contains('Codex'), contains('install Codex')));
    });

    test('git auth absent runs branch-only when fixture clone is reachable', () async {
      final result = await evaluateWorkflowE2ePrerequisites(
        environment: const {},
        runProcess: _fakeProcessRunner({
          ('codex', '--version'): ProcessResult(1, 0, 'codex 1.0', ''),
          ('gh', 'auth status'): ProcessResult(2, 1, '', 'not logged in'),
          ('git', 'ls-remote --exit-code https://github.com/DartClaw/workflow-test-todo-app.git HEAD'): ProcessResult(
            3,
            0,
            'ref',
            '',
          ),
        }),
      );

      expect(result.shouldSkip, isFalse);
      expect(result.canCreateGitHubPr, isFalse);
    });

    test('gh auth without branch push auth runs branch-only when fixture clone is reachable', () async {
      final result = await evaluateWorkflowE2ePrerequisites(
        environment: const {},
        runProcess: _fakeProcessRunner({
          ('codex', '--version'): ProcessResult(1, 0, 'codex 1.0', ''),
          ('gh', 'auth status'): ProcessResult(2, 0, 'logged in', ''),
          ('ssh', '-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -T git@github.com'):
              ProcessResult(3, 255, '', 'Permission denied'),
          ('git', 'ls-remote --exit-code https://github.com/DartClaw/workflow-test-todo-app.git HEAD'): ProcessResult(
            4,
            0,
            'ref',
            '',
          ),
        }),
      );

      expect(result.shouldSkip, isFalse);
      expect(result.canCreateGitHubPr, isFalse);
    });

    test('fixture clone unavailable skips with actionable message', () async {
      final result = await evaluateWorkflowE2ePrerequisites(
        environment: const {},
        runProcess: _fakeProcessRunner({
          ('codex', '--version'): ProcessResult(1, 0, 'codex 1.0', ''),
          ('gh', 'auth status'): ProcessResult(2, 1, '', 'not logged in'),
          ('git', 'ls-remote --exit-code https://github.com/DartClaw/workflow-test-todo-app.git HEAD'): ProcessResult(
            3,
            128,
            '',
            'network unavailable',
          ),
        }),
      );

      expect(result.shouldSkip, isTrue);
      expect(result.skipReason, allOf(contains('Public HTTPS access'), contains('GITHUB_TOKEN')));
    });

    test('logger level env default and FINE install correctly', () async {
      expect(e2eLogLevelFromEnv(const {}), 'INFO');
      expect(e2eLogLevelFromEnv(const {'DARTCLAW_E2E_LOG_LEVEL': ''}), 'INFO');
      expect(e2eLogLevelFromEnv(const {'DARTCLAW_E2E_LOG_LEVEL': 'FINE'}), 'FINE');

      final service = LogService.fromConfig(level: e2eLogLevelFromEnv(const {'DARTCLAW_E2E_LOG_LEVEL': 'FINE'}));
      service.install();
      addTearDown(service.dispose);

      expect(Logger.root.level, Level.FINE);
    });

    test('canCreateGitHubPr is re-evaluated on every setup call', () async {
      var ghCalls = 0;
      final runner = _recordingProcessRunner((executable, arguments) {
        if (executable == 'gh' && arguments.join(' ') == 'auth status') {
          ghCalls++;
          return ProcessResult(ghCalls, 1, '', 'not logged in');
        }
        return ProcessResult(99, 1, '', 'unexpected');
      });

      await canCreateGitHubPrForEnv(environment: const {}, runProcess: runner);
      await canCreateGitHubPrForEnv(environment: const {}, runProcess: runner);

      expect(ghCalls, 2);
    });
  });

  group('final status gate', () {
    test('strict mode rejects paused', () {
      expect(
        () => expectWorkflowFinalStatus(
          finalStatus: WorkflowRunStatus.paused,
          requireCompleted: true,
          runId: 'run-strict',
        ),
        throwsA(isA<TestFailure>()),
      );
    });

    test('soft mode accepts paused and warns with run id', () async {
      final records = <LogRecord>[];
      Logger.root.level = Level.ALL;
      final sub = Logger.root.onRecord.listen(records.add);
      addTearDown(sub.cancel);

      expectWorkflowFinalStatus(
        finalStatus: WorkflowRunStatus.paused,
        requireCompleted: false,
        runId: 'run-soft',
        logger: Logger('E2E'),
      );

      await Future<void>.delayed(Duration.zero);
      expect(
        records,
        contains(
          predicate<LogRecord>((record) {
            return record.level == Level.WARNING &&
                record.message.contains('paused') &&
                record.message.contains('run-soft');
          }),
        ),
      );
    });
  });

  group('step assertions', () {
    test('strict order rejects unexpected interleaving', () {
      expectStepOrderStrict(
        ['discover-project', 'spec', 'implement', 'integrated-review'],
        ['discover-project', 'spec', 'implement', 'integrated-review'],
      );

      expect(
        () => expectStepOrderStrict(
          ['discover-project', 'unexpected-step', 'spec', 'implement'],
          ['discover-project', 'spec', 'implement'],
        ),
        throwsA(isA<TestFailure>()),
      );
    });

    test('project_index input must be non-empty and carry required keys', () {
      expectStepInputsContainProjectIndex([
        {
          'project_index': {'framework': 'AndThen', 'state_protocol': 'edit-in-place'},
        },
      ], 'spec');

      expect(
        () => expectStepInputsContainProjectIndex([
          {'project_index': <String, dynamic>{}},
        ], 'spec'),
        throwsA(isA<TestFailure>()),
      );
      expect(
        () => expectStepInputsContainProjectIndex([
          {
            'project_index': {'framework': 'AndThen'},
          },
        ], 'spec'),
        throwsA(predicate((error) => '$error'.contains('state_protocol'))),
      );
    });

    test('remediate prompts carry one report source each', () {
      expectStepInputContainsAll(
        ['<review_findings>docs/specs/review.md</review_findings>'],
        'remediate',
        ['<review_findings>'],
      );
      expectStepInputContainsAll(
        ['<architecture_review_findings>docs/specs/architecture-review.md</architecture_review_findings>'],
        'remediate-architecture',
        ['<architecture_review_findings>'],
      );
    });
  });

  group('artifact assertions', () {
    test('token mirroring fails when one agent artifact is all zero', () {
      final dir = Directory.systemTemp.createTempSync('workflow_e2e_tokens_');
      addTearDown(() => dir.deleteSync(recursive: true));
      _writeArtifact(dir, 'discover-project', {'_workflowInputTokensNew': 10});
      _writeArtifact(dir, 'spec', {
        '_workflowInputTokensNew': 0,
        '_workflowCacheReadTokens': 0,
        '_workflowOutputTokens': 0,
      });

      expect(
        () => expectPreservedArtifactsHaveNonZeroTokenKeys(dir, agentSteps: const ['discover-project', 'spec']),
        throwsA(isA<TestFailure>()),
      );
    });

    test('token mirroring passes when every agent artifact has a non-zero key', () {
      final dir = Directory.systemTemp.createTempSync('workflow_e2e_tokens_');
      addTearDown(() => dir.deleteSync(recursive: true));
      _writeArtifact(dir, 'discover-project', {'_workflowInputTokensNew': 10});
      _writeArtifact(dir, 'spec', {'_workflowOutputTokens': 1});

      expectPreservedArtifactsHaveNonZeroTokenKeys(dir, agentSteps: const ['discover-project', 'spec']);
    });
  });

  group('fixture and cleanup assertions', () {
    test('fixture seed assertion fails fast when a BUG entry is missing', () {
      final dir = Directory.systemTemp.createTempSync('workflow_e2e_backlog_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final docs = Directory(p.join(dir.path, 'docs'))..createSync(recursive: true);
      File(p.join(docs.path, 'PRODUCT-BACKLOG.md')).writeAsStringSync('BUG-001\nBUG-003\n');

      expect(
        () => assertKnownDefectsBacklogEntries(dir.path),
        throwsA(
          predicate((error) {
            return '$error'.contains(fixtureSeedRegressionMessage);
          }),
        ),
      );
    });

    test('fixture seed assertion leaves complete backlog unchanged', () {
      final dir = Directory.systemTemp.createTempSync('workflow_e2e_backlog_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final docs = Directory(p.join(dir.path, 'docs'))..createSync(recursive: true);
      final backlog = File(p.join(docs.path, 'PRODUCT-BACKLOG.md'));
      backlog.writeAsStringSync('BUG-001\nBUG-002\nBUG-003\n');
      final before = backlog.readAsStringSync();

      assertKnownDefectsBacklogEntries(dir.path);

      expect(backlog.readAsStringSync(), before);
    });

    test('branch tracking is idempotent for cleanup', () {
      final createdBranches = <String>{};
      createdBranches
        ..add('dartclaw/workflow/run/integration')
        ..add('dartclaw/workflow/run/integration');

      expect(createdBranches, hasLength(1));
    });

    test('branch is tracked before a later assertion can fail', () {
      final createdBranches = <String>{};

      expect(() {
        final branch = 'dartclaw/workflow/run/integration';
        createdBranches.add(branch);
        assertTouchedFilesMatchAllowlist(
          touched: const [],
          publishedBranch: 'origin/$branch',
          bugAllowlist: bugFileAllowlist,
          activeBugs: const ['BUG-001'],
        );
      }, throwsA(isA<TestFailure>()));
      expect(createdBranches, contains('dartclaw/workflow/run/integration'));
    });

    test('cleanup warns exactly once when gh and git deletion both fail', () async {
      final records = <LogRecord>[];
      final logger = Logger('E2E.Cleanup.Test');
      final sub = Logger.root.onRecord.listen(records.add);
      addTearDown(sub.cancel);

      await closePrByBranch(
        branch: 'dartclaw/workflow/run/integration',
        repo: 'DartClaw/workflow-test-todo-app',
        projectDir: '/tmp/project',
        logger: logger,
        runProcess: _fakeProcessRunner({
          ('gh', 'pr close dartclaw/workflow/run/integration --repo DartClaw/workflow-test-todo-app --delete-branch'):
              ProcessResult(1, 1, '', 'gh stderr'),
          ('git', 'push origin --delete dartclaw/workflow/run/integration'): ProcessResult(2, 1, '', 'git stderr'),
        }),
      );

      await Future<void>.delayed(Duration.zero);
      final warnings = records.where((record) => record.level == Level.WARNING).toList();
      expect(warnings, hasLength(1));
      expect(
        warnings.single.message,
        allOf(contains('dartclaw/workflow/run/integration'), contains('gh stderr'), contains('git stderr')),
      );
    });

    test('cleanup does not warn when git fallback succeeds', () async {
      final records = <LogRecord>[];
      final logger = Logger('E2E.Cleanup.Test');
      final sub = Logger.root.onRecord.listen(records.add);
      addTearDown(sub.cancel);

      await closePrByBranch(
        branch: 'dartclaw/workflow/run/integration',
        repo: 'DartClaw/workflow-test-todo-app',
        projectDir: '/tmp/project',
        logger: logger,
        runProcess: _fakeProcessRunner({
          ('gh', 'pr close dartclaw/workflow/run/integration --repo DartClaw/workflow-test-todo-app --delete-branch'):
              ProcessResult(1, 1, '', 'gh stderr'),
          ('git', 'push origin --delete dartclaw/workflow/run/integration'): ProcessResult(2, 0, '', ''),
        }),
      );

      await Future<void>.delayed(Duration.zero);
      expect(records.where((record) => record.level == Level.WARNING), isEmpty);
    });

    test('cleanup does not warn when gh succeeds', () async {
      final records = <LogRecord>[];
      final logger = Logger('E2E.Cleanup.Test');
      final sub = Logger.root.onRecord.listen(records.add);
      addTearDown(sub.cancel);

      await closePrByBranch(
        branch: 'dartclaw/workflow/run/integration',
        repo: 'DartClaw/workflow-test-todo-app',
        projectDir: '/tmp/project',
        logger: logger,
        runProcess: _fakeProcessRunner({
          ('gh', 'pr close dartclaw/workflow/run/integration --repo DartClaw/workflow-test-todo-app --delete-branch'):
              ProcessResult(1, 0, '', ''),
        }),
      );

      await Future<void>.delayed(Duration.zero);
      expect(records.where((record) => record.level == Level.WARNING), isEmpty);
    });
  });

  group('diff and worktree assertions', () {
    test('diff helper rejects empty and unrelated changes', () {
      expect(
        () => assertTouchedFilesMatchAllowlist(
          touched: const [],
          publishedBranch: 'origin/dartclaw/workflow/run/integration',
          bugAllowlist: bugFileAllowlist,
          activeBugs: const ['BUG-001'],
        ),
        throwsA(isA<TestFailure>()),
      );
      expect(
        () => assertTouchedFilesMatchAllowlist(
          touched: const ['unrelated.py'],
          publishedBranch: 'origin/dartclaw/workflow/run/integration',
          bugAllowlist: const {
            'BUG-001': ['routes/todos.py'],
          },
          activeBugs: const ['BUG-001'],
        ),
        throwsA(predicate((error) => '$error'.contains('routes/todos.py') && '$error'.contains('unrelated.py'))),
      );
    });

    test('diff helper accepts substring path matches', () {
      assertTouchedFilesMatchAllowlist(
        touched: const ['src/app/routes/todos.py'],
        publishedBranch: 'origin/dartclaw/workflow/run/integration',
        bugAllowlist: const {
          'BUG-001': ['routes/todos.py'],
        },
        activeBugs: const ['BUG-001'],
      );
    });

    test('bug allow-list has exactly the three known defects', () {
      expect(bugFileAllowlist.keys.toSet(), {'BUG-001', 'BUG-002', 'BUG-003'});
      for (final paths in bugFileAllowlist.values) {
        expect(paths, isNotEmpty);
      }
    });

    test('duplicate implement worktree paths fail', () {
      expect(() => expectDistinctWorktreePaths(['/tmp/worktree-a', '/tmp/worktree-a']), throwsA(isA<TestFailure>()));
    });
  });

  group('forced remediation transformer', () {
    test('targets plan review, architecture review, or both', () {
      final cleanPlan = {'findings_count': 0, 'plan-review.findings_count': 0};
      final cleanArchitecture = {'findings_count': 0, 'architecture-review.findings_count': 0};

      final planOnly = forcedReviewRemediationOutputs(
        stepId: 'plan-review',
        outputs: cleanPlan,
        targetReviews: const {'plan-review'},
        remediationPlan: 'remediate',
        implementationSummary: 'summary',
      );
      expect(planOnly['plan-review.findings_count'], 1);
      expect(
        forcedReviewRemediationOutputs(
          stepId: 'architecture-review',
          outputs: cleanArchitecture,
          targetReviews: const {'plan-review'},
          remediationPlan: 'remediate',
          implementationSummary: 'summary',
        ),
        same(cleanArchitecture),
      );

      final architectureOnly = forcedReviewRemediationOutputs(
        stepId: 'architecture-review',
        outputs: cleanArchitecture,
        targetReviews: const {'architecture-review'},
        remediationPlan: 'remediate',
        implementationSummary: 'summary',
      );
      expect(architectureOnly['architecture-review.findings_count'], 1);

      expect(
        forcedReviewRemediationOutputs(
          stepId: 'plan-review',
          outputs: cleanPlan,
          targetReviews: const {'plan-review', 'architecture-review'},
          remediationPlan: 'remediate',
          implementationSummary: 'summary',
        )['plan-review.findings_count'],
        1,
      );
      expect(
        forcedReviewRemediationOutputs(
          stepId: 'architecture-review',
          outputs: cleanArchitecture,
          targetReviews: const {'plan-review', 'architecture-review'},
          remediationPlan: 'remediate',
          implementationSummary: 'summary',
        )['architecture-review.findings_count'],
        1,
      );
    });
  });
}

WorkflowE2eProcessRunner _fakeProcessRunner(Map<(String, String), ProcessResult> responses) {
  return (executable, arguments, {workingDirectory, environment}) async {
    final key = (executable, arguments.join(' '));
    return responses[key] ?? ProcessResult(0, 1, '', 'unexpected command: $key');
  };
}

WorkflowE2eProcessRunner _recordingProcessRunner(ProcessResult Function(String, List<String>) handler) {
  return (executable, arguments, {workingDirectory, environment}) async => handler(executable, arguments);
}

void _writeArtifact(Directory dir, String stepKey, Map<String, dynamic> configJson) {
  final count = dir.listSync().length + 1;
  File(
    p.join(dir.path, '$count-$stepKey.json'),
  ).writeAsStringSync(jsonEncode({'stepKey': stepKey, 'configJson': configJson}));
}
