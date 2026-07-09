import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowRunStatus;
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
            assistantContent: contextOutput(
              reviewReportContext(
                queued.stepKey,
                stepArtifactsDir: stepArtifactsDirForTask(queued.task),
                findingsCount: 0,
              ),
            ),
          ),
          'remediate' => StubResponse(
            assistantContent: contextOutput({'remediation_summary': 'No remediation needed'}),
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
          _ => throw StateError('Unexpected step: ${queued.stepKey}'),
        };
      },
    );

    expect(trace.finalRun?.status, WorkflowRunStatus.completed);
    expect(trace.tasksForStep('review-code').single.projectId, 'demo-project');
    expect(trace.tasksForStep('review-code').single.configJson.containsKey('_continueSessionId'), isFalse);
    expect(trace.tasksForStep('review-code').single.configJson.containsKey('_continueProviderSessionId'), isFalse);
    expect(trace.tasksForStep('review-code').single.configJson['_workflowNeedsWorktree'], isTrue);
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
              'remediation_summary': 'Applied remediation pass ${queued.occurrence + 1}',
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
}
