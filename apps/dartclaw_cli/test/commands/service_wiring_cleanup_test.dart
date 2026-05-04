import 'package:dartclaw_cli/src/commands/service_wiring.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  test('buildWorkflowCleanupPlan includes per-map-item and bootstrap branches/worktrees', () {
    final tasks = <Task>[
      Task(
        id: 'task-1',
        title: 'Story 1',
        description: 'x',
        type: TaskType.coding,
        createdAt: DateTime.parse('2026-01-01T00:00:00Z'),
        workflowRunId: 'run-123',
        worktreeJson: {
          'path': '/tmp/worktrees/task-1',
          'branch': 'dartclaw/task-task-1',
          'createdAt': DateTime.parse('2026-01-01T00:00:00Z').toIso8601String(),
        },
      ),
      Task(
        id: 'task-2',
        title: 'Story 2',
        description: 'x',
        type: TaskType.coding,
        createdAt: DateTime.parse('2026-01-01T00:00:01Z'),
        workflowRunId: 'run-123',
        worktreeJson: {
          'path': '/tmp/worktrees/task-2',
          'branch': 'dartclaw/task-task-2',
          'createdAt': DateTime.parse('2026-01-01T00:00:01Z').toIso8601String(),
        },
      ),
    ];

    final plan = buildWorkflowCleanupPlan('run-123', tasks);

    expect(plan.worktreePaths, containsAll(['/tmp/worktrees/task-1', '/tmp/worktrees/task-2']));
    expect(
      plan.branches,
      containsAll([
        'dartclaw/task-task-1',
        'dartclaw/task-task-2',
        'dartclaw/workflow/run123',
        'dartclaw/workflow/run123/integration',
      ]),
    );
  });
}
