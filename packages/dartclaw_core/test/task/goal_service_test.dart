import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  late _InMemoryGoalRepository repo;
  late GoalService service;

  setUp(() {
    repo = _InMemoryGoalRepository();
    service = GoalService(repo);
  });

  group('create', () {
    test('creates goal without parent', () async {
      final goal = await service.create(
        id: 'goal-1',
        title: 'Ship 0.8',
        mission: 'Deliver the release safely.',
        now: DateTime.parse('2026-03-10T10:00:00Z'),
      );

      expect(goal.parentGoalId, isNull);
      expect(goal.createdAt, DateTime.parse('2026-03-10T10:00:00Z'));
      expect((await repo.getById(goal.id))?.toJson(), goal.toJson());
    });

    test('creates goal with valid parent', () async {
      await repo.insert(_goal(id: 'goal-root'));

      final goal = await service.create(
        id: 'goal-1',
        title: 'Ship 0.8',
        mission: 'Deliver the release safely.',
        parentGoalId: 'goal-root',
      );

      expect(goal.parentGoalId, 'goal-root');
    });

    test('throws on missing parent', () {
      expect(
        () => service.create(
          id: 'goal-1',
          title: 'Ship 0.8',
          mission: 'Deliver the release safely.',
          parentGoalId: 'missing',
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('throws on nested parent beyond two levels', () async {
      await repo.insert(_goal(id: 'goal-root'));
      await repo.insert(_goal(id: 'goal-child', parentGoalId: 'goal-root'));

      expect(
        () => service.create(
          id: 'goal-grandchild',
          title: 'Grandchild',
          mission: 'Too deep.',
          parentGoalId: 'goal-child',
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('allows two-level hierarchy', () async {
      await repo.insert(_goal(id: 'goal-root'));

      final child = await service.create(
        id: 'goal-child',
        title: 'Child',
        mission: 'Ship the slice.',
        parentGoalId: 'goal-root',
      );

      expect(child.parentGoalId, 'goal-root');
    });
  });

  group('get and list', () {
    test('gets goal by id', () async {
      await repo.insert(_goal());

      final goal = await service.get('goal-1');

      expect(goal?.id, 'goal-1');
    });

    test('returns null for missing goal', () async {
      expect(await service.get('missing'), isNull);
    });

    test('lists all goals ordered by repository', () async {
      await repo.insert(_goal(id: 'goal-1', createdAt: DateTime.parse('2026-03-10T10:00:00Z')));
      await repo.insert(_goal(id: 'goal-2', createdAt: DateTime.parse('2026-03-10T10:05:00Z')));
      await repo.insert(_goal(id: 'goal-3', createdAt: DateTime.parse('2026-03-10T10:10:00Z')));

      final goals = await service.list();

      expect(goals.map((goal) => goal.id), ['goal-3', 'goal-2', 'goal-1']);
    });
  });

  group('delete', () {
    test('deletes existing goal', () async {
      await repo.insert(_goal());

      await service.delete('goal-1');

      expect(await repo.getById('goal-1'), isNull);
    });

    test('is silent on missing goal', () async {
      await service.delete('missing');
    });
  });

  group('resolveGoalContext', () {
    test('returns null for null goalId', () async {
      expect(await service.resolveGoalContext(null), isNull);
    });

    test('returns null for missing goal', () async {
      expect(await service.resolveGoalContext('missing'), isNull);
    });

    test('returns goal mission for standalone goal', () async {
      await repo.insert(_goal(title: 'Ship 0.8', mission: 'Deliver the release safely.'));

      final context = await service.resolveGoalContext('goal-1');

      expect(context, '## Goal: Ship 0.8\nDeliver the release safely.');
    });

    test('includes parent goal mission', () async {
      await repo.insert(_goal(id: 'goal-root', title: 'Platform', mission: 'Strengthen the platform.'));
      await repo.insert(
        _goal(id: 'goal-1', title: 'Ship 0.8', mission: 'Deliver the release safely.', parentGoalId: 'goal-root'),
      );

      final context = await service.resolveGoalContext('goal-1');

      expect(
        context,
        '## Goal: Ship 0.8\nDeliver the release safely.\n\n## Parent Goal: Platform\nStrengthen the platform.',
      );
    });

    test('handles missing parent gracefully', () async {
      await repo.insert(
        _goal(id: 'goal-1', title: 'Ship 0.8', mission: 'Deliver the release safely.', parentGoalId: 'goal-root'),
      );

      final context = await service.resolveGoalContext('goal-1');

      expect(context, '## Goal: Ship 0.8\nDeliver the release safely.');
    });

    test('truncates oversized combined context to budget', () async {
      await repo.insert(_goal(id: 'goal-root', title: 'Platform', mission: 'P' * 420));
      await repo.insert(_goal(id: 'goal-1', title: 'Ship 0.8', mission: 'C' * 420, parentGoalId: 'goal-root'));

      final context = await service.resolveGoalContext('goal-1');

      expect(context, hasLength(800));
      expect(context, endsWith('...'));
    });
  });

  group('dispose', () {
    test('disposes repository', () async {
      await service.dispose();

      expect(repo.disposed, isTrue);
    });
  });
}

Goal _goal({
  String id = 'goal-1',
  String title = 'Ship 0.8',
  String? parentGoalId,
  String mission = 'Deliver the release safely.',
  DateTime? createdAt,
}) {
  return Goal(
    id: id,
    title: title,
    parentGoalId: parentGoalId,
    mission: mission,
    createdAt: createdAt ?? DateTime.parse('2026-03-10T10:00:00Z'),
  );
}

class _InMemoryGoalRepository implements GoalRepository {
  final Map<String, Goal> _goals = {};
  bool disposed = false;

  @override
  Future<void> insert(Goal goal) async {
    _goals[goal.id] = goal;
  }

  @override
  Future<Goal?> getById(String id) async => _goals[id];

  @override
  Future<List<Goal>> list() async {
    final goals = _goals.values.toList(growable: false);
    goals.sort((a, b) {
      final byCreated = b.createdAt.compareTo(a.createdAt);
      if (byCreated != 0) return byCreated;
      return b.id.compareTo(a.id);
    });
    return goals;
  }

  @override
  Future<void> delete(String id) async {
    _goals.remove(id);
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}
