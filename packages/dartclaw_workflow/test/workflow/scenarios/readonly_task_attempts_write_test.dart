import 'package:dartclaw_core/dartclaw_core.dart' show TaskStatus, TaskType;
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeProjectService;
import 'package:test/test.dart';

import '../scenario_test_support.dart';

// scenario-types: bash, plain

void main() {
  test('read-only task mutation is detected and failed', () async {
    final harness = await ScenarioTaskHarness.create();
    addTearDown(harness.dispose);

    harness.setWorkerResponseText('Done.');
    harness.writeRelativeOnTurn('notes/leak.md', content: '# leaked\n');
    final project = await harness.createProjectRepo('my-app');
    final executor = harness.buildExecutor(
      projectService: FakeProjectService(
        projects: [project],
        includeLocalProjectInGetAll: false,
        defaultProjectId: 'my-app',
      ),
    );
    addTearDown(executor.stop);

    await harness.tasks.create(
      id: 'task-readonly-dirty',
      title: 'Read-only task',
      description: 'Must not mutate the repo.',
      type: TaskType.research,
      autoStart: true,
      projectId: 'my-app',
      configJson: const {'readOnly': true},
    );

    final processed = await executor.pollOnce();
    final task = await harness.tasks.get('task-readonly-dirty');

    expect(processed, isTrue);
    expect(task?.status, TaskStatus.failed);
    expect(task?.configJson['errorSummary'], contains('Read-only task modified project files'));
    expect(task?.configJson['errorSummary'], contains('notes/leak.md'));
  });
}
