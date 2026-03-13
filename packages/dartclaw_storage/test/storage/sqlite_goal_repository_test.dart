import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  group('SqliteGoalRepository', () {
    late Database db;
    late SqliteTaskRepository taskRepository;
    late SqliteGoalRepository repository;

    setUp(() {
      db = openTaskDbInMemory();
      taskRepository = SqliteTaskRepository(db);
      repository = SqliteGoalRepository(db);
    });

    tearDown(() async {
      await repository.dispose();
      await taskRepository.dispose();
    });

    group('schema', () {
      test('creates goal table and index', () {
        final tables = db.select("SELECT name FROM sqlite_master WHERE type IN ('table', 'index') ORDER BY name");
        final names = tables.map((row) => row['name']).toList();

        expect(names, contains('goals'));
        expect(names, contains('idx_goals_parent'));
      });
    });

    group('insert and getById', () {
      test('inserts and retrieves goal', () async {
        final goal = _goal(parentGoalId: 'goal-root');

        await repository.insert(goal);
        final loaded = await repository.getById(goal.id);

        expect(loaded?.toJson(), goal.toJson());
      });

      test('returns null for missing goal', () async {
        expect(await repository.getById('missing'), isNull);
      });

      test('handles null parentGoalId', () async {
        final goal = _goal(parentGoalId: null);

        await repository.insert(goal);
        final loaded = await repository.getById(goal.id);

        expect(loaded?.parentGoalId, isNull);
      });
    });

    group('list', () {
      test('lists goals ordered by created_at desc', () async {
        await repository.insert(_goal(id: 'goal-old', createdAt: DateTime.parse('2026-03-10T08:00:00Z')));
        await repository.insert(_goal(id: 'goal-new', createdAt: DateTime.parse('2026-03-10T10:00:00Z')));
        await repository.insert(_goal(id: 'goal-mid', createdAt: DateTime.parse('2026-03-10T09:00:00Z')));

        final goals = await repository.list();

        expect(goals.map((goal) => goal.id), ['goal-new', 'goal-mid', 'goal-old']);
      });

      test('returns empty list when no goals exist', () async {
        expect(await repository.list(), isEmpty);
      });
    });

    group('delete', () {
      test('deletes goal', () async {
        final goal = _goal();
        await repository.insert(goal);

        await repository.delete(goal.id);

        expect(await repository.getById(goal.id), isNull);
      });

      test('is silent for missing goal', () async {
        await repository.delete('missing');
      });
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
