import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' show EventBus;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show InMemoryTaskRepository;
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowDefinition, WorkflowRun, WorkflowStep;
import 'package:dartclaw_workflow/testing.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import 'workflow_test_support.dart';

void main() {
  test('API list, detail and connected snapshot agree on incomplete lower bound and nullable step usage', () async {
    final definition = WorkflowDefinition(
      name: 'accounting',
      description: 'Account for both steps',
      steps: const [
        WorkflowStep(id: 'unknown', name: 'Unknown', prompts: ['a']),
        WorkflowStep(id: 'zero', name: 'Zero', prompts: ['b']),
      ],
    );
    final now = DateTime.utc(2026, 6, 1);
    final saved = WorkflowRun(
      id: 'run-1',
      definitionName: definition.name,
      status: WorkflowRunStatus.completed,
      startedAt: now,
      updatedAt: now,
      currentStepIndex: 2,
      totalTokens: 0,
      tokenUsageComplete: false,
      definitionJson: definition.toJson(),
      contextJson: const {
        'data': {
          'unknown.status': 'success',
          'unknown.tokenCount': null,
          'zero.status': 'success',
          'zero.tokenCount': 0,
        },
      },
    );
    final run = WorkflowRun.fromJson(saved.toJson());
    final tempDir = Directory.systemTemp.createTempSync('workflow_accounting_api_');
    final eventBus = EventBus();
    final tasks = TaskService(InMemoryTaskRepository(), eventBus: eventBus);
    final workflows = FakeWorkflowService(taskService: tasks, eventBus: eventBus, dataDir: tempDir.path)
      ..getResult = run
      ..listResult = [run]
      ..recordListCalls = true;
    final handler = workflowRoutes(workflows, tasks, InMemoryDefinitionSource([definition]), eventBus: eventBus).call;
    try {
      final list = await handler(Request('GET', Uri.parse('http://localhost/api/workflows/runs')));
      final detail = await handler(Request('GET', Uri.parse('http://localhost/api/workflows/runs/run-1')));
      final stream = await handler(Request('GET', Uri.parse('http://localhost/api/workflows/runs/run-1/events')));
      final listJson = jsonDecode(await list.readAsString()) as List<dynamic>;
      final detailJson = jsonDecode(await detail.readAsString()) as Map<String, dynamic>;
      final firstFrame = utf8.decode(await stream.read().first);
      final connected = jsonDecode(firstFrame.split('data: ')[1].split('\n').first) as Map<String, dynamic>;

      expect(listJson.single['totalTokens'], 0);
      expect(listJson.single['tokenUsageComplete'], false);
      expect(detailJson['tokenUsageComplete'], false);
      expect((detailJson['steps'] as List)[0]['tokenCount'], isNull);
      expect((detailJson['steps'] as List)[1]['tokenCount'], 0);
      expect(connected['run']['totalTokens'], 0);
      expect(connected['run']['tokenUsageComplete'], false);
      expect((connected['steps'] as List)[0]['tokenCount'], isNull);
      expect((connected['steps'] as List)[1]['tokenCount'], 0);
    } finally {
      await workflows.dispose();
      await tasks.dispose();
      await eventBus.dispose();
      tempDir.deleteSync(recursive: true);
    }
  });
}
