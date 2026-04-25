// Fast unit tests for workflow budget monitoring: threshold semantics,
// single-warning dedup, edge thresholds, and token accounting.
library;

import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart' show EventBus, WorkflowBudgetWarningEvent;
import 'package:dartclaw_models/dartclaw_models.dart'
    show WorkflowDefinition, WorkflowRun, WorkflowRunStatus, WorkflowStep;
import 'package:dartclaw_workflow/src/workflow/workflow_budget_monitor.dart'
    show checkWorkflowBudgetWarning, workflowBudgetExceeded;
import 'package:test/test.dart';

// Minimal fake repository that stores a single run and supports update.
class _FakeRepo {
  WorkflowRun? _stored;

  Future<void> update(WorkflowRun run) async => _stored = run;
  Future<WorkflowRun?> getById(String id) async => _stored?.id == id ? _stored : null;
}

WorkflowDefinition _def({required int maxTokens}) => WorkflowDefinition(
  name: 'test',
  description: 'test',
  steps: const [WorkflowStep(id: 's1', name: 'S1', prompts: ['p'])],
  maxTokens: maxTokens,
);

WorkflowDefinition _defNoLimit() => WorkflowDefinition(
  name: 'test',
  description: 'test',
  steps: const [WorkflowStep(id: 's1', name: 'S1', prompts: ['p'])],
);

WorkflowRun _run({required int tokens, Map<String, dynamic> contextJson = const {}}) {
  final now = DateTime.now();
  return WorkflowRun(
    id: 'run-1',
    definitionName: 'test',
    status: WorkflowRunStatus.running,
    startedAt: now,
    updatedAt: now,
    currentStepIndex: 0,
    totalTokens: tokens,
    contextJson: contextJson,
  );
}

void main() {
  group('workflowBudgetExceeded', () {
    test('returns false when definition has no maxTokens', () {
      expect(workflowBudgetExceeded(_run(tokens: 9999), _defNoLimit()), isFalse);
    });

    test('returns false when tokens below limit', () {
      expect(workflowBudgetExceeded(_run(tokens: 99), _def(maxTokens: 100)), isFalse);
    });

    test('returns true when tokens equal to limit', () {
      expect(workflowBudgetExceeded(_run(tokens: 100), _def(maxTokens: 100)), isTrue);
    });

    test('returns true when tokens exceed limit', () {
      expect(workflowBudgetExceeded(_run(tokens: 150), _def(maxTokens: 100)), isTrue);
    });

    test('returns false at zero tokens with non-zero limit', () {
      expect(workflowBudgetExceeded(_run(tokens: 0), _def(maxTokens: 1000)), isFalse);
    });
  });

  group('checkWorkflowBudgetWarning', () {
    late EventBus eventBus;

    setUp(() => eventBus = EventBus());
    tearDown(() async => eventBus.dispose());

    test('no warning when maxTokens is null', () async {
      final warnings = <WorkflowBudgetWarningEvent>[];
      final sub = eventBus.on<WorkflowBudgetWarningEvent>().listen(warnings.add);
      await checkWorkflowBudgetWarning(
        run: _run(tokens: 9999),
        definition: _defNoLimit(),
        eventBus: eventBus,
        repository: _FakeRepo(),
      );
      await sub.cancel();
      expect(warnings, isEmpty);
    });

    test('no warning below 80% threshold', () async {
      final warnings = <WorkflowBudgetWarningEvent>[];
      final sub = eventBus.on<WorkflowBudgetWarningEvent>().listen(warnings.add);
      await checkWorkflowBudgetWarning(
        run: _run(tokens: 7999),
        definition: _def(maxTokens: 10000),
        eventBus: eventBus,
        repository: _FakeRepo(),
      );
      await sub.cancel();
      expect(warnings, isEmpty);
    });

    test('fires warning at exactly 80% (8000/10000)', () async {
      final warnings = <WorkflowBudgetWarningEvent>[];
      final sub = eventBus.on<WorkflowBudgetWarningEvent>().listen(warnings.add);
      await checkWorkflowBudgetWarning(
        run: _run(tokens: 8000),
        definition: _def(maxTokens: 10000),
        eventBus: eventBus,
        repository: _FakeRepo(),
      );
      await sub.cancel();
      expect(warnings, hasLength(1));
      expect(warnings.first.consumed, equals(8000));
      expect(warnings.first.limit, equals(10000));
    });

    test('fires warning above 80% threshold', () async {
      final warnings = <WorkflowBudgetWarningEvent>[];
      final sub = eventBus.on<WorkflowBudgetWarningEvent>().listen(warnings.add);
      await checkWorkflowBudgetWarning(
        run: _run(tokens: 9500),
        definition: _def(maxTokens: 10000),
        eventBus: eventBus,
        repository: _FakeRepo(),
      );
      await sub.cancel();
      expect(warnings, hasLength(1));
    });

    test('fires warning at 100% (budget exactly exhausted)', () async {
      final warnings = <WorkflowBudgetWarningEvent>[];
      final sub = eventBus.on<WorkflowBudgetWarningEvent>().listen(warnings.add);
      await checkWorkflowBudgetWarning(
        run: _run(tokens: 10000),
        definition: _def(maxTokens: 10000),
        eventBus: eventBus,
        repository: _FakeRepo(),
      );
      await sub.cancel();
      expect(warnings, hasLength(1));
    });

    test('fires warning above 100% (budget exceeded)', () async {
      final warnings = <WorkflowBudgetWarningEvent>[];
      final sub = eventBus.on<WorkflowBudgetWarningEvent>().listen(warnings.add);
      await checkWorkflowBudgetWarning(
        run: _run(tokens: 12000),
        definition: _def(maxTokens: 10000),
        eventBus: eventBus,
        repository: _FakeRepo(),
      );
      await sub.cancel();
      expect(warnings, hasLength(1));
    });

    test('dedup: second call with warning already fired emits no new warning', () async {
      final warnings = <WorkflowBudgetWarningEvent>[];
      final sub = eventBus.on<WorkflowBudgetWarningEvent>().listen(warnings.add);
      final repo = _FakeRepo();
      // Seed the already-warned run.
      final alreadyWarned = _run(tokens: 8500, contextJson: {'_budget.warningFired': true});
      await checkWorkflowBudgetWarning(
        run: alreadyWarned,
        definition: _def(maxTokens: 10000),
        eventBus: eventBus,
        repository: repo,
      );
      await sub.cancel();
      expect(warnings, isEmpty);
    });

    test('dedup: warning flag set in returned run after first firing', () async {
      final repo = _FakeRepo();
      final sub = eventBus.on<WorkflowBudgetWarningEvent>().listen((_) {});
      final updatedRun = await checkWorkflowBudgetWarning(
        run: _run(tokens: 8000),
        definition: _def(maxTokens: 10000),
        eventBus: eventBus,
        repository: repo,
      );
      await sub.cancel();
      expect(updatedRun.contextJson['_budget.warningFired'], isTrue);
    });

    test('consumedPercent in event is accurate (0.80 for 8000/10000)', () async {
      final warnings = <WorkflowBudgetWarningEvent>[];
      final sub = eventBus.on<WorkflowBudgetWarningEvent>().listen(warnings.add);
      await checkWorkflowBudgetWarning(
        run: _run(tokens: 8000),
        definition: _def(maxTokens: 10000),
        eventBus: eventBus,
        repository: _FakeRepo(),
      );
      await sub.cancel();
      expect(warnings.first.consumedPercent, closeTo(0.80, 0.001));
    });

    test('no warning at zero tokens even with maxTokens set', () async {
      final warnings = <WorkflowBudgetWarningEvent>[];
      final sub = eventBus.on<WorkflowBudgetWarningEvent>().listen(warnings.add);
      await checkWorkflowBudgetWarning(
        run: _run(tokens: 0),
        definition: _def(maxTokens: 10000),
        eventBus: eventBus,
        repository: _FakeRepo(),
      );
      await sub.cancel();
      expect(warnings, isEmpty);
    });
  });
}
