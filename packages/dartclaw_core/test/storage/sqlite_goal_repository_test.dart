import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  group('SqliteGoalRepository', () {
    late Database db;
    late SqliteTaskRepository taskRepository;
    late SqliteGoalRepository repository;

    setUp(() async {
      db = openTaskDbInMemory();
      taskRepository = SqliteTaskRepository(db);
      repository = await SqliteGoalRepository.open(SqliteBackend(db));
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

      test('stores released scalar types including a non-null token budget', () async {
        final goal = _goal(maxTokens: 12000);

        await repository.insert(goal);

        final row = db
            .select(
              '''
          SELECT created_at, max_tokens, typeof(created_at) AS created_at_type, typeof(max_tokens) AS max_tokens_type
          FROM goals
          WHERE id = ?
        ''',
              [goal.id],
            )
            .single;
        expect(row['created_at'], goal.createdAt.toIso8601String());
        expect(row['max_tokens'], 12000);
        expect(row['created_at_type'], 'text');
        expect(row['max_tokens_type'], 'integer');
      });

      test('reads a raw released 0.25 goal row', () async {
        final releasedDb = sqlite3.openInMemory();
        releasedDb.execute('''
          CREATE TABLE goals (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            parent_goal_id TEXT,
            mission TEXT NOT NULL,
            created_at TEXT NOT NULL
          )
        ''');
        releasedDb.execute('CREATE INDEX idx_goals_parent ON goals(parent_goal_id)');
        releasedDb.execute('ALTER TABLE goals ADD COLUMN max_tokens INTEGER');
        releasedDb.execute(
          '''
          INSERT INTO goals (id, title, parent_goal_id, mission, created_at, max_tokens)
          VALUES (?, ?, ?, ?, ?, ?)
        ''',
          [
            'released-child',
            'Released child',
            'released-parent',
            'Keep every field.',
            '2026-03-10T09:30:00.000Z',
            4096,
          ],
        );
        final releasedBackend = SqliteBackend(releasedDb);
        final releasedRepository = await SqliteGoalRepository.open(releasedBackend);

        try {
          final loaded = await releasedRepository.getById('released-child');

          expect(loaded?.id, 'released-child');
          expect(loaded?.title, 'Released child');
          expect(loaded?.parentGoalId, 'released-parent');
          expect(loaded?.mission, 'Keep every field.');
          expect(loaded?.createdAt, DateTime.parse('2026-03-10T09:30:00.000Z'));
          expect(loaded?.maxTokens, 4096);
        } finally {
          await releasedRepository.dispose();
          await releasedBackend.close();
        }
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

      test('orders timestamp ties by id descending', () async {
        final createdAt = DateTime.parse('2026-03-10T10:00:00Z');
        await repository.insert(_goal(id: 'goal-a', createdAt: createdAt));
        await repository.insert(_goal(id: 'goal-b', createdAt: createdAt));

        expect((await repository.list()).map((goal) => goal.id), ['goal-b', 'goal-a']);
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
  int? maxTokens,
}) {
  return Goal(
    id: id,
    title: title,
    parentGoalId: parentGoalId,
    mission: mission,
    createdAt: createdAt ?? DateTime.parse('2026-03-10T10:00:00Z'),
    maxTokens: maxTokens,
  );
}
