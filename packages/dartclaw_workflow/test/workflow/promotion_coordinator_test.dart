// `callPromote` is the promotion producer the iteration path consumes: it turns
// a port result into a typed outcome carrying the operator message as payload.
library;

import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        WorkflowGitPromotionConflict,
        WorkflowGitPromotionError,
        WorkflowGitPromotionResult,
        WorkflowGitPromotionSerializeRemaining,
        WorkflowGitPromotionSuccess,
        WorkflowPromotionConflictFailure,
        WorkflowPromotionFailure;
import 'package:dartclaw_workflow/src/workflow/promotion_coordinator.dart';
import 'package:test/test.dart';

void main() {
  Future<PromotionOutcome> promoteReturning(WorkflowGitPromotionResult result) => callPromote(
    promote: ({
      required String runId,
      required String projectId,
      required String branch,
      required String integrationBranch,
      required String strategy,
      String? storyId,
    }) async => result,
    runId: 'run-1',
    projectId: 'project-1',
    branch: 'story-s01',
    integrationBranch: 'integration',
    strategy: 'merge',
    storyId: 'S01',
    conflictingFiles: const [],
    conflictDetails: '',
    mergeResolveEnabled: false,
  );

  test('a port conflict becomes the conflict variant carrying its unchanged operator message', () async {
    final outcome = await promoteReturning(
      const WorkflowGitPromotionConflict(conflictingFiles: ['lib/a.dart', 'lib/b.dart'], details: 'detail'),
    );

    expect(outcome, isA<PromotionConflict>());
    final failure = (outcome as PromotionConflict).failure;
    expect(failure, isA<WorkflowPromotionConflictFailure>());
    expect(failure.message, equals('promotion-conflict: lib/a.dart, lib/b.dart'));
  });

  test('a conflict with no named files keeps the bare-conflict wording', () async {
    final outcome = await promoteReturning(const WorkflowGitPromotionConflict(conflictingFiles: [], details: 'detail'));

    expect((outcome as PromotionConflict).failure.message, equals('promotion-conflict: merge conflict'));
  });

  test('a port error becomes the promotion-failure variant carrying its unchanged operator message', () async {
    final outcome = await promoteReturning(const WorkflowGitPromotionError('remote rejected promotion'));

    expect(outcome, isA<PromotionError>());
    final failure = (outcome as PromotionError).failure;
    expect(failure, isA<WorkflowPromotionFailure>());
    expect(failure.message, equals('promotion failed: remote rejected promotion'));
  });

  test('success and the serialize-remaining sentinel carry no failure at all', () async {
    expect(await promoteReturning(const WorkflowGitPromotionSuccess(commitSha: 'abc')), isA<PromotionSuccess>());
    expect(await promoteReturning(const WorkflowGitPromotionSerializeRemaining()), isA<PromotionSerializeRemaining>());
  });
}
