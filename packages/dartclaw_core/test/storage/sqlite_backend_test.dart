import 'dart:async';
import 'dart:typed_data';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  group('SqliteBackend', () {
    late Database database;
    late SqliteBackend backend;

    setUp(() {
      database = sqlite3.openInMemory();
      backend = SqliteBackend(database);
    });

    tearDown(() async {
      await backend.close();
    });

    group('marshalling and statements', () {
      test('preserves portable scalars and reports affected rows', () async {
        await backend.execute('''
          CREATE TABLE values_table (
            id INTEGER PRIMARY KEY,
            integer_value INTEGER,
            real_value REAL,
            text_value TEXT,
            blob_value BLOB,
            null_value TEXT
          )
        ''');
        final blob = Uint8List.fromList([0, 127, 255]);

        expect(
          await backend.execute(
            '''
              INSERT INTO values_table
                (id, integer_value, real_value, text_value, blob_value, null_value)
              VALUES (?, ?, ?, ?, ?, ?)
            ''',
            [1, 42, 3.5, 'hello', blob, null],
          ),
          1,
        );
        await backend.execute('INSERT INTO values_table (id, integer_value) VALUES (?, ?)', [2, 7]);

        final rows = await backend.execute('UPDATE values_table SET text_value = ?', ['updated']);
        final returned = await backend.query(
          'INSERT INTO values_table (id, integer_value) VALUES (?, ?) RETURNING id',
          [3, 9],
        );
        final stored = await backend.query('SELECT * FROM values_table WHERE id = ?', [1]);

        expect(rows, 2);
        expect(returned, [
          {'id': 3},
        ]);
        expect(stored.single['integer_value'], 42);
        expect(stored.single['real_value'], 3.5);
        expect(stored.single['text_value'], 'updated');
        expect(stored.single['blob_value'], blob);
        expect(stored.single['null_value'], isNull);
      });

      test('owner statement is reusable and close is idempotent', () async {
        await backend.execute('CREATE TABLE records (value TEXT NOT NULL)');
        final statement = await backend.prepare('INSERT INTO records (value) VALUES (?)');

        expect(await statement.execute(['first']), 1);
        expect(await statement.execute(['second']), 1);
        await statement.close();
        await statement.close();

        await expectLater(statement.execute(['third']), throwsStateError);
        await expectLater(statement.query(['third']), throwsStateError);
      });

      test('backend close is idempotent', () async {
        await backend.close();
        await backend.close();
      });

      test('owner statement can be cleaned up after backend close', () async {
        await backend.execute('CREATE TABLE records (value TEXT NOT NULL)');
        final statement = await backend.prepare('INSERT INTO records (value) VALUES (?)');

        await backend.close();
        await statement.close();
        await statement.close();

        await expectLater(() => statement.execute(['late']), throwsStateError);
        await expectLater(() => statement.query(['late']), throwsStateError);
      });
    });

    test('concurrent operations wait for the open transaction', () async {
      await backend.execute('CREATE TABLE records (value TEXT NOT NULL)');
      final statement = await backend.prepare('INSERT INTO records (value) VALUES (?)');
      final bodyStarted = Completer<void>();
      final releaseBody = Completer<void>();
      final completions = <String>[];

      final transaction = backend
          .transaction<void>((tx) async {
            await tx.execute('INSERT INTO records (value) VALUES (?)', ['A']);
            bodyStarted.complete();
            await releaseBody.future;
            await tx.execute('INSERT INTO records (value) VALUES (?)', ['B']);
            throw StateError('force rollback');
          })
          .then<void>(
            (_) => completions.add('transaction'),
            onError: (Object error, StackTrace stackTrace) {
              completions.add('transaction');
              Error.throwWithStackTrace(error, stackTrace);
            },
          );

      await bodyStarted.future;
      final directWrite = backend
          .execute('INSERT INTO records (value) VALUES (?)', ['C'])
          .then((_) => completions.add('direct'));
      final statementWrite = statement.execute(['D']).then((_) => completions.add('statement'));
      expect(completions, isEmpty);

      releaseBody.complete();
      await expectLater(transaction, throwsStateError);
      await Future.wait([directWrite, statementWrite]);

      expect(completions.first, 'transaction');
      expect(completions.sublist(1), containsAll(['direct', 'statement']));
      expect((await backend.query('SELECT value FROM records ORDER BY value')).map((row) => row['value']), ['C', 'D']);
      await statement.close();
    });

    group('reentrancy and transaction-bound lifetimes', () {
      test('explicit transaction paths remain usable from the root zone', () async {
        await backend.execute('CREATE TABLE records (value TEXT NOT NULL)');
        final bodyError = StateError('force rollback');
        late List<Map<String, Object?>> directRows;
        late List<Map<String, Object?>> statementRows;

        await expectLater(
          backend
              .transaction<void>((tx) async {
                await Zone.root.run(() async {
                  await tx.execute('INSERT INTO records (value) VALUES (?)', ['direct']);
                  directRows = await tx.query('SELECT value FROM records');

                  final insert = await tx.prepare('INSERT INTO records (value) VALUES (?)');
                  await insert.execute(['statement']);
                  await insert.close();
                  await insert.close();

                  final query = await tx.prepare('SELECT value FROM records ORDER BY value');
                  statementRows = await query.query();
                  await query.close();
                });
                throw bodyError;
              })
              .timeout(const Duration(seconds: 2)),
          throwsA(same(bodyError)),
        );

        expect(directRows, [
          {'value': 'direct'},
        ]);
        expect(statementRows, [
          {'value': 'direct'},
          {'value': 'statement'},
        ]);
        expect(await backend.query('SELECT value FROM records'), isEmpty);
      });

      test('owner operations inside a transaction join its rollback', () async {
        await backend.execute('CREATE TABLE records (value TEXT NOT NULL)');
        final ownerStatement = await backend.prepare('INSERT INTO records (value) VALUES (?)');

        await expectLater(
          backend.transaction<void>((tx) async {
            await tx.execute('INSERT INTO records (value) VALUES (?)', ['transaction']);
            await backend.execute('INSERT INTO records (value) VALUES (?)', ['owner']);
            await ownerStatement.execute(['statement']);
            throw StateError('force rollback');
          }),
          throwsStateError,
        );

        expect(await backend.query('SELECT value FROM records'), isEmpty);
        await ownerStatement.close();
      });

      for (final throughHandle in [false, true]) {
        test(
          'nested transaction through ${throughHandle ? 'handle' : 'owner'} is rejected without aborting outer',
          () async {
            await backend.execute('CREATE TABLE records (value TEXT NOT NULL)');

            await backend
                .transaction<void>((tx) async {
                  await tx.execute('INSERT INTO records (value) VALUES (?)', ['before']);
                  await expectLater(
                    (throughHandle ? tx : backend).transaction<void>((_) async {}),
                    throwsA(isA<NestedTransactionError>()),
                  );
                  await tx.execute('INSERT INTO records (value) VALUES (?)', ['after']);
                })
                .timeout(const Duration(seconds: 2));

            expect((await backend.query('SELECT value FROM records ORDER BY rowid')).map((row) => row['value']), [
              'before',
              'after',
            ]);
          },
        );
      }

      test('transaction handles and statements expire after commit', () async {
        await backend.execute('CREATE TABLE records (value TEXT NOT NULL)');
        late DatabaseBackend escaped;
        late DatabaseStatement handleStatement;
        late DatabaseStatement ownerStatement;

        await backend.transaction<void>((tx) async {
          escaped = tx;
          handleStatement = await tx.prepare('INSERT INTO records (value) VALUES (?)');
          ownerStatement = await backend.prepare('INSERT INTO records (value) VALUES (?)');
          await handleStatement.execute(['handle']);
          await ownerStatement.execute(['owner']);
        });

        for (final statement in [handleStatement, ownerStatement]) {
          await expectLater(statement.execute(['late']), throwsStateError);
          await expectLater(statement.query(['late']), throwsStateError);
          await statement.close();
          await statement.close();
        }
        await expectLater(escaped.execute('SELECT 1'), throwsStateError);
        await expectLater(escaped.close(), throwsStateError);
      });

      test('transaction statements expire after rollback', () async {
        await backend.execute('CREATE TABLE records (value TEXT NOT NULL)');
        late DatabaseStatement statement;

        await expectLater(
          backend.transaction<void>((tx) async {
            statement = await tx.prepare('INSERT INTO records (value) VALUES (?)');
            await statement.execute(['rolled back']);
            throw StateError('force rollback');
          }),
          throwsStateError,
        );

        await expectLater(statement.execute(['late']), throwsStateError);
        await expectLater(statement.query(['late']), throwsStateError);
        await statement.close();
        await statement.close();
        expect(await backend.query('SELECT value FROM records'), isEmpty);
      });

      test('stale transaction zones wait outside a later transaction', () async {
        await backend.execute('CREATE TABLE records (value TEXT NOT NULL)');
        final startStaleWrite = Completer<void>();
        late Future<void> staleWrite;

        await backend.transaction<void>((_) async {
          staleWrite = () async {
            await startStaleWrite.future;
            await backend.execute('INSERT INTO records (value) VALUES (?)', ['stale']);
          }();
        });

        final laterBodyStarted = Completer<void>();
        final releaseLaterBody = Completer<void>();
        final laterTransaction = backend.transaction<void>((tx) async {
          await tx.execute('INSERT INTO records (value) VALUES (?)', ['rolled back']);
          laterBodyStarted.complete();
          await releaseLaterBody.future;
          throw StateError('force rollback');
        });

        await laterBodyStarted.future;
        var staleWriteCompleted = false;
        Object? staleWriteError;
        unawaited(
          staleWrite.then<void>(
            (_) => staleWriteCompleted = true,
            onError: (Object error) {
              staleWriteError = error;
              staleWriteCompleted = true;
            },
          ),
        );
        try {
          startStaleWrite.complete();
          await pumpEventQueue();
          expect(staleWriteCompleted, isFalse);
        } finally {
          releaseLaterBody.complete();
          await expectLater(laterTransaction, throwsStateError);
        }
        await staleWrite;

        expect(staleWriteError, isNull);
        expect((await backend.query('SELECT value FROM records')).map((row) => row['value']), ['stale']);
      });

      test('preserves the body error when rollback finds no transaction', () async {
        await backend.execute('CREATE TABLE records (value TEXT NOT NULL)');
        final bodyError = StateError('original body failure');

        late StackTrace bodyStack;
        Object? caughtError;
        StackTrace? caughtStack;
        try {
          await backend.transaction<void>((tx) async {
            await tx.execute('ROLLBACK');
            bodyStack = StackTrace.current;
            Error.throwWithStackTrace(bodyError, bodyStack);
          });
        } catch (error, stackTrace) {
          caughtError = error;
          caughtStack = stackTrace;
        }
        expect(caughtError, same(bodyError));
        expect(caughtStack.toString(), bodyStack.toString());

        await backend.execute('INSERT INTO records (value) VALUES (?)', ['usable']);
        expect((await backend.query('SELECT value FROM records')).single['value'], 'usable');
      });
    });
  });
}
