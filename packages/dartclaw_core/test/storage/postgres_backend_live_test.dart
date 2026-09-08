@Tags(['integration'])
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:test/test.dart';

import 'postgres_live_support.dart';

void main() {
  test('portable operations and lifecycle', () async {
    await withPostgresBackend((backend, _) async {
      await backend.execute(
        'CREATE TABLE scalar_rows (id bigint PRIMARY KEY, i bigint, d double precision, s text, b bytea)',
      );
      final returned = await backend.query(
        'INSERT INTO scalar_rows (id, i, d, s, b) VALUES (?, ?, ?, ?, ?) RETURNING id',
        [
          1,
          2,
          3.5,
          'four',
          Uint8List.fromList([5]),
        ],
      );
      expect(returned.single['id'], 1);
      expect(await backend.execute('UPDATE scalar_rows SET s = ? WHERE id = ?', ['changed', 1]), 1);
      expect(
        (await backend.query('SELECT i, d, s, b, true AS flag, CURRENT_TIMESTAMP AS stamp FROM scalar_rows')).single,
        containsPair('flag', 1),
      );

      final statement = await backend.prepare('SELECT s FROM scalar_rows WHERE id = ?');
      expect((await statement.query([1])).single['s'], 'changed');
      expect((await statement.query([1])).single['s'], 'changed');
      await statement.close();
      await statement.close();

      await backend.close();
      await backend.close();
      await expectLater(() => backend.execute('SELECT 1'), throwsStateError);
    });
  });

  test('transaction joins owner calls, rolls back, and isolates foreign work', () async {
    await withPostgresBackend((backend, _) async {
      await backend.execute('CREATE TABLE tx_rows (id bigint PRIMARY KEY, label text NOT NULL)');
      final ownerStatement = await backend.prepare('INSERT INTO tx_rows (id, label) VALUES (?, ?)');
      expect(
        await backend.transaction((tx) async {
          await tx.execute('INSERT INTO tx_rows VALUES (?, ?)', [0, 'commit']);
          return 42;
        }),
        42,
      );
      DatabaseStatement? transactionStatement;
      final bodyStarted = Completer<void>();
      final releaseBody = Completer<void>();
      final transaction = backend.transaction<void>((tx) async {
        await tx.execute('INSERT INTO tx_rows VALUES (?, ?)', [1, 'tx']);
        await backend.execute('INSERT INTO tx_rows VALUES (?, ?)', [2, 'owner']);
        await ownerStatement.execute([3, 'statement']);
        transactionStatement = await tx.prepare('SELECT label FROM tx_rows WHERE id = ?');
        expect((await transactionStatement!.query([1])).single['label'], 'tx');
        await expectLater(() => tx.transaction<void>((_) async {}), throwsA(isA<NestedTransactionError>()));
        await expectLater(() => backend.transaction<void>((_) async {}), throwsA(isA<NestedTransactionError>()));
        bodyStarted.complete();
        await releaseBody.future;
        throw const _BodyFailure();
      });

      await bodyStarted.future;
      expect(await backend.query('SELECT id FROM tx_rows WHERE id > 0'), isEmpty);
      await backend.execute('INSERT INTO tx_rows VALUES (?, ?)', [4, 'concurrent']);
      releaseBody.complete();
      await expectLater(transaction, throwsA(isA<_BodyFailure>()));
      expect((await backend.query('SELECT id FROM tx_rows ORDER BY id')).map((row) => row['id']), [0, 4]);
      await expectLater(() => transactionStatement!.query([1]), throwsStateError);
      await transactionStatement!.close();
      await transactionStatement!.close();
      await ownerStatement.close();
    });
  });
}

final class _BodyFailure implements Exception {
  const new();
}
