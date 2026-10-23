import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show Task, TaskStatus, workflowFollowUp;
import 'package:dartclaw_workflow/src/workflow/follow_up_draft.dart' show createFollowUpDraft, workflowFollowUpTaskId;
import 'package:test/test.dart';

import 'workflow_builtin_test_support.dart';

void main() {
  final driver = BuiltInWorkflowDriver();
  setUpAll(driver.setUpAll);
  setUp(driver.setUp);
  tearDown(driver.tearDown);

  test('code-review integration binds project-aware steps to the workflow PROJECT', () async {
    final trace = await driver.executeBuiltInWorkflow(
      workflowFileName: 'code-review.yaml',
      variables: {
        'TARGET': 'Project binding check',
        'BRANCH': 'feature/project-binding',
        'PR_NUMBER': '',
        'BASE_BRANCH': 'main',
        'PROJECT': 'demo-project',
      },
      responseForStep: (queued) async {
        return switch (queued.stepKey) {
          'review-code' => StubResponse(
            outputs: reviewReportContext(
              queued.stepKey,
              stepArtifactsDir: stepArtifactsDirForTask(queued.task),
              findingsCount: 0,
            ),
          ),
          'remediate' => StubResponse(outputs: {'remediation_summary': 'No remediation needed'}),
          're-review' => StubResponse(
            outputs: reviewReportContext(
              queued.stepKey,
              stepArtifactsDir: stepArtifactsDirForTask(queued.task),
              findingsCount: 0,
            ),
          ),
          _ => throw StateError('Unexpected step: ${queued.stepKey}'),
        };
      },
    );

    expect(trace.finalRun?.status, WorkflowRunStatus.completed);
    expect(trace.tasksForStep('review-code').single.projectId, 'demo-project');
    expect(trace.tasksForStep('review-code').single.configJson.containsKey('_continueSessionId'), isFalse);
    expect(trace.tasksForStep('review-code').single.configJson.containsKey('_continueProviderSessionId'), isFalse);
    expect(trace.tasksForStep('review-code').single.configJson['needsWorktree'], isTrue);
    // File-backed review must stay writable: no readOnly flag applied to review-code.
    expect(trace.tasksForStep('review-code').single.configJson.containsKey('readOnly'), isFalse);
    expectReviewOutputDir(trace.tasksForStep('review-code').single);
    expect(trace.tasksForStep('remediate'), isEmpty);
    expect(trace.tasksForStep('re-review'), isEmpty);
  });

  test('code-review integration keeps looping until re-review findings reach zero', () async {
    final trace = await driver.executeBuiltInWorkflow(
      workflowFileName: 'code-review.yaml',
      variables: {
        'TARGET': 'feature branch',
        'BRANCH': 'feature/validate',
        'PR_NUMBER': '',
        'BASE_BRANCH': 'main',
        'PROJECT': 'demo-project',
      },
      responseForStep: (queued) async {
        return switch (queued.stepKey) {
          'review-code' => StubResponse(
            outputs: reviewReportContext(
              queued.stepKey,
              stepArtifactsDir: stepArtifactsDirForTask(queued.task),
              findingsCount: 1,
            ),
          ),
          'remediate' => StubResponse(
            outputs: {'remediation_summary': 'Applied remediation pass ${queued.occurrence + 1}'},
          ),
          're-review' => StubResponse(
            outputs: reviewReportContext(
              queued.stepKey,
              stepArtifactsDir: stepArtifactsDirForTask(queued.task),
              findingsCount: queued.occurrence == 0 ? 1 : 0,
            ),
          ),
          _ => throw StateError('Unexpected step: ${queued.stepKey}'),
        };
      },
    );

    expect(trace.finalRun?.status, WorkflowRunStatus.completed);
    expect(trace.count('remediate'), 2);
    expect(trace.count('re-review'), 2);
    expect(trace.queuedStepOrder.where((step) => step == 'remediate' || step == 're-review'), [
      'remediate',
      're-review',
      'remediate',
      're-review',
    ]);
    for (final task in trace.tasksForStep('re-review')) {
      expectReviewOutputDir(task);
    }
  });
  group('follow-up draft', () {
    Map<String, Object?> finding(String severity, String where) => {
      'severity': severity,
      'location': where,
      'description': 'problem at $where',
    };

    Map<String, Object?> verdict(List<Map<String, Object?>> findings) => {
      'pass': true,
      'findings_count': findings.length,
      'findings': findings,
      'summary': 's',
    };

    /// Review step outputs: the report, the model-written counts and the verdict, all under [stepId].
    Map<String, Object?> review(QueuedStep queued, List<Map<String, Object?>> findings, {required int gating}) => {
      ...reviewReportContext(
        queued.stepKey,
        stepArtifactsDir: stepArtifactsDirForTask(queued.task),
        findingsCount: findings.length,
        gatingFindingsCount: gating,
      ),
      '${queued.stepKey}.verdict': verdict(findings),
    };

    const variables = {
      'TARGET': 'feature branch',
      'BRANCH': 'feature/validate',
      'PR_NUMBER': '42',
      'BASE_BRANCH': 'main',
      'PROJECT': 'demo-project',
    };

    Future<List<Task>> drafts() => driver.harness.taskService.list(status: TaskStatus.draft);

    test('S01: a clean review with minor findings yields one linked draft', () async {
      final trace = await driver.executeBuiltInWorkflow(
        workflowFileName: 'code-review.yaml',
        variables: variables,
        responseForStep: (queued) async => StubResponse(
          outputs: review(queued, [finding('medium', 'a.dart:1'), finding('low', 'b.dart:2')], gating: 0),
        ),
      );

      final run = trace.finalRun!;
      expect(run.status, WorkflowRunStatus.completed, reason: run.errorMessage);
      final draft = (await drafts()).single;
      expect(draft.id, workflowFollowUpTaskId(run.id));
      expect(draft.workflowRunId, isNull);
      expect(draft.stepIndex, isNull);
      expect(draft.projectId, 'demo-project');
      expect(draft.description, contains('[medium] a.dart:1: problem at a.dart:1'));
      expect(draft.description, contains('[low] b.dart:2: problem at b.dart:2'));
      expect(draft.description, contains('/workflows/${run.id}'));
      expect(draft.description, contains('feature/validate'));
      expect(draft.configJson['followUpOfRunId'], run.id);
      expect(workflowFollowUp(run), (taskId: draft.id, count: 2));
    });

    test('S02: a remediated review lists only the final verdict', () async {
      final trace = await driver.executeBuiltInWorkflow(
        workflowFileName: 'code-review.yaml',
        variables: variables,
        responseForStep: (queued) async => switch (queued.stepKey) {
          'review-code' => StubResponse(
            outputs: review(queued, [finding('high', 'old.dart:1'), finding('low', 'old.dart:2')], gating: 1),
          ),
          'remediate' => StubResponse(outputs: {'remediation_summary': 'fixed'}),
          're-review' => StubResponse(outputs: review(queued, [finding('medium', 'new.dart:3')], gating: 0)),
          _ => throw StateError('Unexpected step: ${queued.stepKey}'),
        },
      );

      expect(trace.finalRun?.status, WorkflowRunStatus.completed, reason: trace.finalRun?.errorMessage);
      final draft = (await drafts()).single;
      expect(draft.description, contains('new.dart:3'));
      expect(draft.description, isNot(contains('old.dart')));
      expect(workflowFollowUp(trace.finalRun!)?.count, 1);
    });

    test('S04: a run with nothing to follow up creates no draft and records no entry', () async {
      final trace = await driver.executeBuiltInWorkflow(
        workflowFileName: 'code-review.yaml',
        variables: variables,
        responseForStep: (queued) async => StubResponse(outputs: review(queued, [], gating: 0)),
      );

      expect(trace.finalRun?.status, WorkflowRunStatus.completed);
      expect(await drafts(), isEmpty);
      expect(workflowFollowUp(trace.finalRun!), isNull);
    });

    test('S04: a run that fails creates no draft even though a verdict carried minor findings', () async {
      final trace = await driver.executeBuiltInWorkflow(
        workflowFileName: 'code-review.yaml',
        variables: variables,
        responseForStep: (queued) async => switch (queued.stepKey) {
          'remediate' => StubResponse(outputs: {'remediation_summary': 'tried'}),
          _ => StubResponse(
            outputs: review(queued, [finding('high', 'a.dart:1'), finding('low', 'b.dart:2')], gating: 1),
          ),
        },
      );

      expect(trace.finalRun?.status, WorkflowRunStatus.failed);
      expect(await drafts(), isEmpty);
      expect(workflowFollowUp(trace.finalRun!), isNull);
    });

    test('creating the draft twice for one run yields one task', () async {
      final trace = await driver.executeBuiltInWorkflow(
        workflowFileName: 'code-review.yaml',
        variables: variables,
        responseForStep: (queued) async =>
            StubResponse(outputs: review(queued, [finding('low', 'b.dart:2')], gating: 0)),
      );
      final run = trace.finalRun!;
      final again = await createFollowUpDraft(
        run: run,
        findings: [(severity: 'low', location: 'b.dart:2', description: 'problem at b.dart:2')],
        taskService: driver.harness.taskService,
        projectId: 'demo-project',
      );

      expect(again, workflowFollowUp(run));
      expect(await drafts(), hasLength(1));
    });
  });
}
