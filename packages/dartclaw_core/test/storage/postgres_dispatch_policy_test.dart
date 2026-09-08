import 'dart:async';

import 'package:dartclaw_core/src/storage/postgres_dispatch_policy.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';

void main() {
  test('dispatch boundary', () async {
    const secret = 'postgres://secret-user:9sQ!@private-host/db?token=raw';
    const raw = 'driver leaked $secret';
    const identity = 'private-host:5432/db';
    const policy = PostgresDispatchPolicy(identity, retryDelay: Duration.zero);

    var attempts = 0;
    final recovered = await policy.run<int>('connect', (_) async {
      attempts++;
      if (attempts < 3) throw Exception(raw);
      return 7;
    }, timeoutMeansPoolExhausted: false);
    expect((recovered, attempts), (7, 3));

    attempts = 0;
    final exhausted = await _capture(
      () => policy.run<void>('connect', (_) async {
        attempts++;
        throw Exception(raw);
      }, timeoutMeansPoolExhausted: false),
    );
    expect(exhausted, isA<StorageConnectionException>());
    expect(attempts, 3);

    for (final operation in ['query', 'commit']) {
      attempts = 0;
      final failure = await _capture(
        () => policy.run<void>(operation, (markDispatched) async {
          attempts++;
          markDispatched();
          throw Exception(raw);
        }),
      );
      expect(failure, isA<StorageUnknownOutcomeException>());
      expect(attempts, 1);
      expect('$failure', isNot(contains(secret)));
      expect('$failure', isNot(contains(raw)));
    }

    attempts = 0;
    final serverFailure = await _capture(
      () => policy.run<void>('query', (markDispatched) async {
        attempts++;
        markDispatched();
        throw const PostgresServerFailure('23505');
      }),
    );
    expect(serverFailure, isA<StorageQueryException>());
    expect((serverFailure as StorageQueryException).sqlState, '23505');
    expect(attempts, 1);

    fakeAsync((async) {
      Object? failure;
      policy
          .run<void>(
            'acquire',
            (_) => Future<void>.delayed(policy.poolWaitCeiling).then((_) => throw TimeoutException(raw)),
          )
          .catchError((Object error) {
            failure = error;
          });
      async.elapse(policy.poolWaitCeiling);
      async.flushMicrotasks();
      expect(failure, isA<StoragePoolExhaustedException>());
      expect('$failure', isNot(contains(secret)));
      expect('$failure', isNot(contains(raw)));
    });

    final lease = Completer<void>();
    final released = policy.run<void>('acquire', (_) => lease.future);
    lease.complete();
    await expectLater(released, completes);
  });
}

Future<Object> _capture(Future<void> Function() operation) async {
  try {
    await operation();
    throw StateError('Expected operation to fail');
  } catch (error) {
    return error;
  }
}
