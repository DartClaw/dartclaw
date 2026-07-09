import 'package:dartclaw_cli/src/commands/workflow/workflow_run_digest.dart';
import 'package:dartclaw_core/dartclaw_core.dart' show Task, TaskStatus, TaskType;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show WorkflowDefinition, WorkflowRun, WorkflowRunStatus, WorkflowStep;
import 'package:test/test.dart';

WorkflowDefinition _definition() => WorkflowDefinition(
  name: 'multi-story',
  description: 'Multi-story run',
  steps: const [
    WorkflowStep(id: 's01', name: 'S01', prompts: ['a']),
    WorkflowStep(id: 's02', name: 'S02', prompts: ['b']),
    WorkflowStep(id: 's03', name: 'S03', prompts: ['c']),
    WorkflowStep(id: 's04', name: 'S04', prompts: ['d']),
  ],
);

WorkflowRun _run(WorkflowRunStatus status, Map<String, dynamic> data) {
  final definition = _definition();
  final now = DateTime(2026, 6, 1);
  return WorkflowRun(
    id: 'run-1',
    definitionName: definition.name,
    status: status,
    startedAt: now,
    updatedAt: now,
    currentStepIndex: 2,
    definitionJson: definition.toJson(),
    contextJson: {'data': data, 'variables': <String, dynamic>{}},
  );
}

Task _task(String id, int stepIndex, TaskStatus status, {DateTime? startedAt, DateTime? completedAt}) => Task(
  id: id,
  title: 'Task $id',
  description: '',
  type: TaskType.coding,
  status: status,
  createdAt: DateTime(2026, 6, 1),
  workflowRunId: 'run-1',
  stepIndex: stepIndex,
  startedAt: startedAt,
  completedAt: completedAt,
);

void main() {
  group('buildWorkflowRunDigest', () {
    test('enumerates every story with status, reason, and next-actions for a paused run', () {
      final run = _run(WorkflowRunStatus.paused, {
        'step.s01.outcome': 'failed',
        'step.s01.outcome.reason': 'loop did not converge',
        's01.tokenCount': 1200,
        'step.s02.outcome': 'blocked',
        'step.s02.outcome.reason': 'Docker Desktop must be started',
        's02.tokenCount': 300,
        'step.s03.outcome': 'succeeded',
        's03.tokenCount': 800,
      });
      final tasks = [
        _task(
          't1',
          0,
          TaskStatus.failed,
          startedAt: DateTime(2026, 6, 1, 10),
          completedAt: DateTime(2026, 6, 1, 10, 0, 45),
        ),
        _task('t2', 1, TaskStatus.review),
        _task('t3', 2, TaskStatus.accepted),
      ];

      final digest = buildWorkflowRunDigest(run: run, definition: _definition(), childTasks: tasks);

      expect(digest.rows, hasLength(4));
      expect(digest.rows[0].status, equals('failed'));
      expect(digest.rows[0].reason, equals('loop did not converge'));
      expect(digest.rows[0].tokens, equals(1200));
      // Duration is sourced from the timed child task (FIS: tokens/duration per row).
      expect(digest.rows[0].duration, isNotNull);
      expect(digest.rows[0].toJson(), containsPair('duration', digest.rows[0].duration));
      expect(digest.rows[1].status, equals('blocked'));
      expect(digest.rows[1].reason, equals('Docker Desktop must be started'));
      expect(digest.rows[2].status, equals('completed'));
      expect(digest.rows[3].status, equals('not started'));
      // An untimed task leaves duration null (not rendered).
      expect(digest.rows[2].duration, isNull);
      expect(digest.nextActions, contains('dartclaw workflow resume run-1 --standalone'));
      expect(digest.nextActions, contains('dartclaw workflow cancel run-1 --standalone'));

      // The human renderer prints the duration in the timed row's metrics group.
      final lines = renderWorkflowRunDigestLines(digest);
      expect(lines.any((l) => l.contains('1. s01: failed') && l.contains(digest.rows[0].duration!)), isTrue);
    });

    test('deterministic steps (persisted status, no task, no outcome) render as completed/failed', () {
      // Engine gates and aggregators settle with `<step>.status` only — no task
      // row and no `step.<id>.outcome` — and must not be mislabelled "pending".
      final run = _run(WorkflowRunStatus.completed, {'s01.status': 'success', 's02.status': 'failed'});
      final digest = buildWorkflowRunDigest(run: run, definition: _definition(), childTasks: const []);

      expect(digest.rows[0].status, equals('completed'));
      expect(digest.rows[1].status, equals('failed'));
      final lines = renderWorkflowRunDigestLines(digest);
      expect(lines.any((l) => l.contains('1. s01: completed')), isTrue);
      expect(lines.any((l) => l.contains('1. s01: pending')), isFalse);
    });

    test('scrubs ANSI/CSI and control characters from persisted reasons at the builder', () {
      final run = _run(WorkflowRunStatus.paused, {
        'step.s01.outcome': 'failed',
        'step.s01.outcome.reason': 'residual\x1b[2Jfindings\r\nnoise\x0731m',
      });
      final digest = buildWorkflowRunDigest(run: run, definition: _definition(), childTasks: const []);

      // Builder-level scrub: both the human lines and toJson carry the clean value.
      expect(digest.rows[0].reason, equals('residualfindings noise31m'));
      expect(digest.rows[0].toJson()['reason'], equals('residualfindings noise31m'));
      final lines = renderWorkflowRunDigestLines(digest);
      expect(lines.any((l) => l.contains('\x1b[2J') || l.contains('\r') || l.contains('\x07')), isFalse);
    });

    test('a cancelled task under a paused run rolls up as interrupted (resumable)', () {
      final run = _run(WorkflowRunStatus.paused, const {});
      final tasks = [_task('t1', 0, TaskStatus.cancelled)];
      final digest = buildWorkflowRunDigest(run: run, definition: _definition(), childTasks: tasks);

      expect(digest.rows[0].status, equals('interrupted'));
    });

    test('a cancelled task under a terminally cancelled run stays cancelled', () {
      final run = _run(WorkflowRunStatus.cancelled, const {});
      final tasks = [_task('t1', 0, TaskStatus.cancelled)];
      final digest = buildWorkflowRunDigest(run: run, definition: _definition(), childTasks: tasks);

      expect(digest.rows[0].status, equals('cancelled'));
    });

    test('a teardown-cancelled outcome rolls up as interrupted regardless of run status', () {
      final run = _run(WorkflowRunStatus.paused, {'step.s01.outcome': 'cancelled'});
      final digest = buildWorkflowRunDigest(run: run, definition: _definition(), childTasks: const []);

      expect(digest.rows[0].status, equals('interrupted'));
    });

    test('cancelled run suggests no next-actions (retry is failed-only)', () {
      final run = _run(WorkflowRunStatus.cancelled, const {});
      final digest = buildWorkflowRunDigest(run: run, definition: _definition(), childTasks: const []);
      expect(digest.nextActions, isEmpty);
    });

    test('completed run has no next-actions', () {
      final run = _run(WorkflowRunStatus.completed, const {});
      final digest = buildWorkflowRunDigest(run: run, definition: _definition(), childTasks: const []);
      expect(digest.nextActions, isEmpty);
      expect(digest.status, equals(WorkflowRunStatus.completed));
    });

    test('failed run offers a retry --standalone next-action', () {
      final run = _run(WorkflowRunStatus.failed, const {});
      final digest = buildWorkflowRunDigest(run: run, definition: _definition(), childTasks: const []);
      expect(digest.nextActions, equals(['dartclaw workflow retry run-1 --standalone']));
    });

    test('renders the digest as parseable JSON with a per-story array', () {
      final run = _run(WorkflowRunStatus.paused, {'step.s01.outcome': 'failed', 'step.s01.outcome.reason': 'boom'});
      final digest = buildWorkflowRunDigest(run: run, definition: _definition(), childTasks: const []);
      final json = digest.toJson();
      expect(json['type'], equals('workflow_run_digest'));
      expect(json['runId'], equals('run-1'));
      expect(json['status'], equals('paused'));
      expect(json['steps'], isA<List<dynamic>>());
      expect((json['steps'] as List).first, containsPair('stepId', 's01'));
      expect(json['nextActions'], isA<List<dynamic>>());
    });

    test('human renderer prints one row per story plus next-action commands', () {
      final run = _run(WorkflowRunStatus.paused, {'step.s01.outcome': 'failed', 'step.s01.outcome.reason': 'boom'});
      final digest = buildWorkflowRunDigest(run: run, definition: _definition(), childTasks: const []);
      final lines = renderWorkflowRunDigestLines(digest);

      expect(lines.first, contains('Run run-1'));
      expect(lines.any((l) => l.contains('1. s01: failed') && l.contains('boom')), isTrue);
      expect(lines.any((l) => l.contains('dartclaw workflow resume run-1 --standalone')), isTrue);
    });

    test('color renderer wraps statuses in ANSI and strips back to the plain form', () {
      final run = _run(WorkflowRunStatus.completed, {'s01.status': 'success', 's02.status': 'failed'});
      final digest = buildWorkflowRunDigest(run: run, definition: _definition(), childTasks: const []);
      final colored = renderWorkflowRunDigestLines(digest, color: true);

      // Per-status color: completed run header green, failed step red, completed step green.
      expect(colored.first, contains('\x1b[32mcompleted\x1b[0m')); // green header status
      expect(colored.any((l) => l.contains('\x1b[31mfailed\x1b[0m')), isTrue); // red failed step
      // Stripping every SGR sequence yields the byte-exact plain rendering.
      final stripPattern = RegExp(r'\x1b\[[0-9;?]*[A-Za-z]');
      final stripped = colored.map((l) => l.replaceAll(stripPattern, '')).toList();
      expect(stripped, equals(renderWorkflowRunDigestLines(digest)));
    });
  });
}
