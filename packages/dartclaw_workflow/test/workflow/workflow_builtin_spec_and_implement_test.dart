import 'dart:io';

import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show WorkflowGitIntegrationBranchResult, WorkflowGitPublishResult, WorkflowPublishStatus, WorkflowRunStatus;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'workflow_builtin_test_support.dart';
import 'workflow_executor_test_support.dart' show standardTurnAdapter;

void main() {
  final driver = BuiltInWorkflowDriver();
  setUpAll(driver.setUpAll);
  setUp(driver.setUp);
  tearDown(driver.tearDown);

  test('spec-and-implement integration preserves the step context chain when validation passes', () async {
    final trace = await driver.executeBuiltInWorkflow(
      workflowFileName: 'spec-and-implement.yaml',
      variables: {'FEATURE': 'Add validate step', 'PROJECT': 'demo-project', 'BRANCH': 'main'},
      responseForStep: (queued) async {
        return switch (queued.stepKey) {
          'spec' => StubResponse(
            assistantContent: contextOutput({
              'spec_path': 'docs/specs/test/spec.md',
              'spec_source': 'synthesized',
              'spec_confidence': 9,
            }),
          ),
          'implement' => StubResponse(assistantContent: contextOutput({'diff_summary': 'IMPLEMENT_DIFF_MARKER'})),
          'integrated-review' => StubResponse(
            assistantContent: contextOutput(
              reviewReportContext(
                queued.stepKey,
                stepArtifactsDir: stepArtifactsDirForTask(queued.task),
                findingsCount: 0,
              ),
            ),
          ),
          'remediate' => StubResponse(
            assistantContent: contextOutput({
              'remediation_summary': 'No remediation needed',
              'diff_summary': 'IMPLEMENT_DIFF_MARKER',
            }),
          ),
          're-review' => StubResponse(
            assistantContent: contextOutput(
              reviewReportContext(
                queued.stepKey,
                stepArtifactsDir: stepArtifactsDirForTask(queued.task),
                findingsCount: 0,
              ),
            ),
          ),
          'architecture-review' => architectureReviewStub(),
          'integrated-review-council' => integratedReviewCouncilStub(),
          _ => throw StateError('Unexpected step: ${queued.stepKey}'),
        };
      },
    );

    expect(trace.finalRun?.status, WorkflowRunStatus.completed);
    expect(trace.descriptionsByStep['spec']!.single, contains('Add validate step'));
    expect(trace.descriptionsByStep['implement']!.single, contains('docs/specs/test/spec.md'));
    expect(trace.descriptionsByStep['integrated-review']!.single, contains('docs/specs/test/spec.md'));
    expectReviewOutputDir(trace.tasksForStep('integrated-review').single);
  });

  test('spec-and-implement: revise-spec is skipped when spec reuses an existing FIS (spec_confidence == 0)', () async {
    final trace = await driver.executeBuiltInWorkflow(
      workflowFileName: 'spec-and-implement.yaml',
      variables: {'FEATURE': 'dev/specs/test/s01-pre-authored.md', 'PROJECT': 'demo-project', 'BRANCH': 'main'},
      responseForStep: (queued) async {
        return switch (queued.stepKey) {
          'spec' => StubResponse(
            assistantContent: contextOutput({
              'spec_path': 'dev/specs/test/s01-pre-authored.md',
              'spec_source': 'existing',
              'spec_confidence': 0,
            }),
          ),
          'implement' => StubResponse(assistantContent: contextOutput({'diff_summary': 'DIFF'})),
          'integrated-review' => StubResponse(
            assistantContent: contextOutput(
              reviewReportContext(
                queued.stepKey,
                stepArtifactsDir: stepArtifactsDirForTask(queued.task),
                findingsCount: 0,
              ),
            ),
          ),
          'architecture-review' => architectureReviewStub(),
          'integrated-review-council' => integratedReviewCouncilStub(),
          _ => throw StateError('Unexpected step: ${queued.stepKey}'),
        };
      },
    );

    expect(trace.finalRun?.status, WorkflowRunStatus.completed);
    // Reuse path: spec emitted confidence 0; revise-spec must not run.
    expect(trace.tasksForStep('revise-spec'), isEmpty);
    // Downstream steps still execute against the reused spec.
    expect(trace.tasksForStep('implement').single.description, contains('dev/specs/test/s01-pre-authored.md'));
    expect(trace.tasksForStep('integrated-review'), isNotEmpty);
  });

  test('spec-and-implement: revise-spec runs when synthesized spec has low confidence', () async {
    final trace = await driver.executeBuiltInWorkflow(
      workflowFileName: 'spec-and-implement.yaml',
      variables: {'FEATURE': 'A vague feature description', 'PROJECT': 'demo-project', 'BRANCH': 'main'},
      responseForStep: (queued) async {
        return switch (queued.stepKey) {
          'spec' => StubResponse(
            assistantContent: contextOutput({
              'spec_path': 'docs/specs/test/spec.md',
              'spec_source': 'synthesized',
              'spec_confidence': 4,
            }),
          ),
          // revise-spec declares no `outputs:` – it edits the FIS in place.
          // An empty workflow-context payload is enough to satisfy the protocol.
          'revise-spec' => StubResponse(assistantContent: contextOutput(const {})),
          'implement' => StubResponse(assistantContent: contextOutput({'diff_summary': 'DIFF'})),
          'integrated-review' => StubResponse(
            assistantContent: contextOutput(
              reviewReportContext(
                queued.stepKey,
                stepArtifactsDir: stepArtifactsDirForTask(queued.task),
                findingsCount: 0,
              ),
            ),
          ),
          'architecture-review' => architectureReviewStub(),
          'integrated-review-council' => integratedReviewCouncilStub(),
          _ => throw StateError('Unexpected step: ${queued.stepKey}'),
        };
      },
    );

    expect(trace.finalRun?.status, WorkflowRunStatus.completed);
    expect(trace.tasksForStep('revise-spec'), hasLength(1));
    // Downstream pipeline must still execute after the revise-spec detour.
    expect(trace.tasksForStep('implement'), hasLength(1));
    expect(trace.tasksForStep('integrated-review'), hasLength(1));
    expect(trace.tasksForStep('architecture-review'), hasLength(1));
    // Step order: revise-spec runs after spec and before implement.
    final order = trace.queuedStepOrder;
    expect(order.indexOf('spec'), lessThan(order.indexOf('revise-spec')));
    expect(order.indexOf('revise-spec'), lessThan(order.indexOf('implement')));
  });

  test('spec-and-implement integration binds project-aware steps to the workflow PROJECT', () async {
    final trace = await driver.executeBuiltInWorkflow(
      workflowFileName: 'spec-and-implement.yaml',
      variables: {'FEATURE': 'Project binding check', 'PROJECT': 'demo-project', 'BRANCH': 'main'},
      responseForStep: (queued) async {
        return switch (queued.stepKey) {
          'spec' => StubResponse(
            assistantContent: contextOutput({
              'spec_path': 'docs/specs/test/spec.md',
              'spec_source': 'synthesized',
              'spec_confidence': 9,
            }),
          ),
          'implement' => StubResponse(assistantContent: contextOutput({'diff_summary': 'DIFF'})),
          'integrated-review' => StubResponse(
            assistantContent: contextOutput(
              reviewReportContext(
                queued.stepKey,
                stepArtifactsDir: stepArtifactsDirForTask(queued.task),
                findingsCount: 0,
              ),
            ),
          ),
          'remediate' => StubResponse(
            assistantContent: contextOutput({'remediation_summary': 'none', 'diff_summary': 'DIFF'}),
          ),
          're-review' => StubResponse(
            assistantContent: contextOutput(
              reviewReportContext(
                queued.stepKey,
                stepArtifactsDir: stepArtifactsDirForTask(queued.task),
                findingsCount: 0,
              ),
            ),
          ),
          'architecture-review' => architectureReviewStub(),
          'integrated-review-council' => integratedReviewCouncilStub(),
          _ => throw StateError('Unexpected step: ${queued.stepKey}'),
        };
      },
    );

    expect(trace.finalRun?.status, WorkflowRunStatus.completed);
    expect(trace.tasksForStep('spec').single.projectId, 'demo-project');
    expect(trace.tasksForStep('spec').single.configJson.containsKey('_continueSessionId'), isFalse);
    expect(trace.tasksForStep('spec').single.configJson.containsKey('_continueProviderSessionId'), isFalse);
    expect(trace.tasksForStep('implement').single.projectId, 'demo-project');
    expect(trace.tasksForStep('integrated-review').single.projectId, 'demo-project');
    expect(trace.tasksForStep('remediate'), isEmpty);
    expect(trace.tasksForStep('integrated-review').single.configJson['_workflowNeedsWorktree'], isTrue);
    // File-backed reviews must stay writable: no readOnly flag on spec/implement/integrated-review.
    expect(trace.tasksForStep('integrated-review').single.configJson.containsKey('readOnly'), isFalse);
    expect(trace.tasksForStep('spec').single.configJson.containsKey('readOnly'), isFalse);
    expect(trace.tasksForStep('implement').single.configJson.containsKey('readOnly'), isFalse);
    expect(trace.tasksForStep('re-review'), isEmpty);
  });

  test('spec-and-implement: spec step receives FEATURE but does not leak BRANCH text', () async {
    const feature = 'FEATURE_SENTINEL_VALUE';
    final trace = await driver.executeBuiltInWorkflow(
      workflowFileName: 'spec-and-implement.yaml',
      variables: {'FEATURE': feature, 'PROJECT': 'demo-project', 'BRANCH': 'feature/discovery-baseline'},
      responseForStep: (queued) async {
        return switch (queued.stepKey) {
          'spec' => StubResponse(
            assistantContent: contextOutput({
              'spec_path': 'docs/specs/test/spec.md',
              'spec_source': 'synthesized',
              'spec_confidence': 9,
            }),
          ),
          'implement' => StubResponse(assistantContent: contextOutput({'diff_summary': 'DIFF'})),
          'integrated-review' => StubResponse(
            assistantContent: contextOutput(
              reviewReportContext(
                queued.stepKey,
                stepArtifactsDir: stepArtifactsDirForTask(queued.task),
                findingsCount: 0,
              ),
            ),
          ),
          'remediate' => StubResponse(
            assistantContent: contextOutput({'remediation_summary': 'none', 'diff_summary': 'DIFF'}),
          ),
          're-review' => StubResponse(
            assistantContent: contextOutput(
              reviewReportContext(
                queued.stepKey,
                stepArtifactsDir: stepArtifactsDirForTask(queued.task),
                findingsCount: 0,
              ),
            ),
          ),
          'architecture-review' => architectureReviewStub(),
          'integrated-review-council' => integratedReviewCouncilStub(),
          _ => throw StateError('Unexpected step: ${queued.stepKey}'),
        };
      },
    );

    // spec opts in to FEATURE via workflowVariables; the spec step's prompt
    // explicitly inlines `{{FEATURE}}` so the value flows in directly rather
    // than via an auto-framed <FEATURE>…</FEATURE> block. BRANCH must not leak.
    final spec = trace.tasksForStep('spec').single.description;
    expect(spec, contains('--auto $feature'));
    expect(spec, isNot(contains('feature/discovery-baseline')));
  });

  test(
    'spec-and-implement integration enters remediation when integrated-review finds issues and exits after re-review is clean',
    () async {
      final trace = await driver.executeBuiltInWorkflow(
        workflowFileName: 'spec-and-implement.yaml',
        variables: {'FEATURE': 'Simplify-code workflows', 'PROJECT': 'demo-project', 'BRANCH': 'main'},
        responseForStep: (queued) async {
          return switch (queued.stepKey) {
            'spec' => StubResponse(
              assistantContent: contextOutput({
                'spec_path': 'docs/specs/test/spec-loop.md',
                'spec_source': 'synthesized',
                'spec_confidence': 9,
              }),
            ),
            'implement' => StubResponse(assistantContent: contextOutput({'diff_summary': 'LOOP_DIFF_MARKER'})),
            'integrated-review' => StubResponse(
              assistantContent: contextOutput(
                reviewReportContext(
                  queued.stepKey,
                  stepArtifactsDir: stepArtifactsDirForTask(queued.task),
                  findingsCount: 1,
                ),
              ),
            ),
            'remediate' => StubResponse(
              assistantContent: contextOutput({
                'remediation_summary': 'Fixed the lint findings',
                'diff_summary': 'LOOP_DIFF_MARKER_AFTER_FIX',
              }),
            ),
            're-review' => StubResponse(
              assistantContent: contextOutput(
                reviewReportContext(
                  queued.stepKey,
                  stepArtifactsDir: stepArtifactsDirForTask(queued.task),
                  findingsCount: 0,
                ),
              ),
            ),
            'architecture-review' => architectureReviewStub(),
            'integrated-review-council' => integratedReviewCouncilStub(),
            _ => throw StateError('Unexpected step: ${queued.stepKey}'),
          };
        },
      );

      expect(trace.finalRun?.status, WorkflowRunStatus.completed, reason: trace.finalRun?.errorMessage);
      expect(trace.count('remediate'), 1);
      expect(trace.count('re-review'), 1);
      expect(
        trace.descriptionsByStep['remediate']!.single,
        contains('/runtime-artifacts/reviews/aggregated-review-aggregate.md'),
      );
      expectReviewOutputDir(trace.tasksForStep('re-review').single);
    },
  );

  test(
    'spec-and-implement narrows to the re-review report after the first remediation pass clears architecture inputs',
    () async {
      final trace = await driver.executeBuiltInWorkflow(
        workflowFileName: 'spec-and-implement.yaml',
        variables: {'FEATURE': 'Harden remediation loop', 'PROJECT': 'demo-project', 'BRANCH': 'main'},
        responseForStep: (queued) async {
          return switch (queued.stepKey) {
            'spec' => StubResponse(
              assistantContent: contextOutput({
                'spec_path': 'docs/specs/test/spec-loop.md',
                'spec_source': 'synthesized',
                'spec_confidence': 9,
              }),
            ),
            'implement' => StubResponse(assistantContent: contextOutput({'diff_summary': 'ARCH_ONLY_DIFF'})),
            'integrated-review' => StubResponse(
              assistantContent: contextOutput(
                reviewReportContext(
                  queued.stepKey,
                  stepArtifactsDir: stepArtifactsDirForTask(queued.task),
                  findingsCount: 0,
                ),
              ),
            ),
            'architecture-review' => architectureReviewStub(
              findingsCount: 1,
              stepArtifactsDir: stepArtifactsDirForTask(queued.task),
            ),
            'integrated-review-council' => integratedReviewCouncilStub(),
            'remediate' => StubResponse(
              assistantContent: contextOutput({
                'remediation_summary': 'Fixed the findings',
                'diff_summary': queued.occurrence == 0
                    ? 'ARCH_ONLY_DIFF_AFTER_FIRST_FIX'
                    : 'ARCH_ONLY_DIFF_AFTER_REREVIEW_FIX',
              }),
            ),
            're-review' => StubResponse(
              assistantContent: contextOutput(
                reviewReportContext(
                  queued.stepKey,
                  stepArtifactsDir: stepArtifactsDirForTask(queued.task),
                  findingsCount: queued.occurrence == 0 ? 1 : 0,
                ),
              ),
            ),
            _ => throw StateError('Unexpected step: ${queued.stepKey}'),
          };
        },
      );

      expect(trace.finalRun?.status, WorkflowRunStatus.completed, reason: trace.finalRun?.errorMessage);
      expect(trace.count('remediate'), 2);
      expect(trace.count('re-review'), 2);
      // Iteration 1: the aggregator collapses integrated + architecture reports
      // into a single file path for remediation.
      final firstRemediate = trace.descriptionsByStep['remediate']![0];
      expect(firstRemediate, contains('/runtime-artifacts/reviews/aggregated-review-aggregate.md'));
      // Iteration 2: the loop consumes only the fresh re-review report, captured
      // from the re-review step's host-owned artifacts dir.
      final secondRemediate = trace.descriptionsByStep['remediate']![1];
      expect(secondRemediate, contains('/runtime-artifacts/steps/re-review/re-review-codex-2026-04-29.md'));
      expect(secondRemediate, isNot(contains('architecture-review-codex')));
    },
  );

  test(
    'spec-and-implement commits generated artifacts to a local-path workflow branch and publishes to origin',
    () async {
      final tempDir = driver.tempDir;
      final projectId = 'local-path-project';
      final repoDir = Directory(p.join(tempDir.path, 'projects', projectId))..createSync(recursive: true);
      final originDir = Directory(p.join(tempDir.path, 'origin.git'))..createSync(recursive: true);

      ProcessResult runGit(List<String> args, {String? workingDirectory}) {
        final result = Process.runSync('git', args, workingDirectory: workingDirectory ?? repoDir.path);
        if (result.exitCode != 0) {
          fail('git ${args.join(' ')} failed in ${workingDirectory ?? repoDir.path}: ${result.stderr}');
        }
        return result;
      }

      runGit(['init', '--bare'], workingDirectory: originDir.path);
      runGit(['init', '-b', 'main']);
      runGit(['config', 'user.name', 'Workflow Test']);
      runGit(['config', 'user.email', 'workflow-test@example.com']);
      File(p.join(repoDir.path, 'README.md')).writeAsStringSync('# local-path\n');
      File(p.join(repoDir.path, 'docs', 'specs', 'test', 'architecture-review-codex-2026-04-29.md'))
        ..createSync(recursive: true)
        ..writeAsStringSync('# Architecture Review\n');
      runGit(['add', 'README.md', 'docs/specs/test/architecture-review-codex-2026-04-29.md']);
      runGit(['commit', '-m', 'initial']);
      runGit(['remote', 'add', 'origin', originDir.path]);
      runGit(['push', '-u', 'origin', 'main']);
      final mainHeadBefore = (runGit(['rev-parse', 'main']).stdout as String).trim();

      String? workflowBranch;
      final turnAdapter = standardTurnAdapter(
        initializeWorkflowGit: ({required runId, required projectId, required baseRef, required perMapItem}) async {
          workflowBranch = 'workflow/$runId';
          runGit(['checkout', '-b', workflowBranch!, baseRef]);
          return WorkflowGitIntegrationBranchResult(integrationBranch: workflowBranch!);
        },
        publishWorkflowBranch: ({required runId, required projectId, required branch}) async {
          runGit(['push', 'origin', branch]);
          runGit(['checkout', 'main']);
          return WorkflowGitPublishResult(
            status: WorkflowPublishStatus.success,
            branch: branch,
            remote: 'origin',
            prUrl: '',
          );
        },
      );

      final trace = await driver.executeBuiltInWorkflow(
        workflowFileName: 'spec-and-implement.yaml',
        variables: {'FEATURE': 'Local-path workflow publish', 'PROJECT': projectId, 'BRANCH': 'main'},
        turnAdapter: turnAdapter,
        responseForStep: (queued) async {
          return switch (queued.stepKey) {
            'spec' => () {
              final specFile = File(p.join(repoDir.path, 'docs', 'specs', 'test', 'spec.md'));
              specFile.parent.createSync(recursive: true);
              specFile.writeAsStringSync('Local-path spec artifact\n');
              return StubResponse(
                assistantContent: contextOutput({
                  'spec_path': 'docs/specs/test/spec.md',
                  'spec_source': 'synthesized',
                  'spec_confidence': 9,
                }),
                worktreeJson: {
                  'path': repoDir.path,
                  'branch': workflowBranch ?? 'workflow/spec-and-implement-run',
                  'createdAt': DateTime.now().toIso8601String(),
                },
              );
            }(),
            'implement' => StubResponse(assistantContent: contextOutput({'diff_summary': 'IMPLEMENT_DIFF_MARKER'})),
            'integrated-review' => StubResponse(
              assistantContent: contextOutput(
                reviewReportContext(
                  queued.stepKey,
                  stepArtifactsDir: stepArtifactsDirForTask(queued.task),
                  findingsCount: 0,
                ),
              ),
            ),
            'remediate' => StubResponse(
              assistantContent: contextOutput({
                'remediation_summary': 'No remediation needed',
                'diff_summary': 'IMPLEMENT_DIFF_MARKER',
              }),
            ),
            're-review' => StubResponse(
              assistantContent: contextOutput(
                reviewReportContext(
                  queued.stepKey,
                  stepArtifactsDir: stepArtifactsDirForTask(queued.task),
                  findingsCount: 0,
                ),
              ),
            ),
            'architecture-review' => architectureReviewStub(),
            'integrated-review-council' => integratedReviewCouncilStub(),
            _ => throw StateError('Unexpected step: ${queued.stepKey}'),
          };
        },
      );

      expect(trace.finalRun?.status, WorkflowRunStatus.completed, reason: trace.finalRun?.errorMessage);
      expect(workflowBranch, isNotNull);

      final branchFile = runGit(['show', '${workflowBranch!}:docs/specs/test/spec.md']);
      expect((branchFile.stdout as String), contains('Local-path spec artifact'));

      final lsRemote = Process.runSync('git', ['ls-remote', '--heads', originDir.path, workflowBranch!]);
      expect(lsRemote.exitCode, 0);
      expect((lsRemote.stdout as String), contains('refs/heads/$workflowBranch'));

      final pushedFile = Process.runSync('git', [
        '--git-dir',
        originDir.path,
        'show',
        'refs/heads/$workflowBranch:docs/specs/test/spec.md',
      ]);
      expect(pushedFile.exitCode, 0);
      expect((pushedFile.stdout as String), contains('Local-path spec artifact'));

      final mainHeadAfter = (runGit(['rev-parse', 'main']).stdout as String).trim();
      expect(mainHeadAfter, mainHeadBefore);
      expect((runGit(['status', '--short', '--untracked-files=all']).stdout as String).trim(), isEmpty);
    },
  );
}
