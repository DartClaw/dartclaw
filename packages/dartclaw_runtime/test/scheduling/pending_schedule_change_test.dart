import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_runtime/src/scheduling/pending_schedule_change.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late File file;

  PendingScheduleChange change(String id, {String prompt = 'Run it'}) => PendingScheduleChange(
    changeId: 'change-$id',
    jobId: id,
    kind: PendingChangeKind.created,
    job: {'id': id, 'type': 'prompt', 'schedule': '0 9 * * *', 'prompt': prompt},
    requester: 'schedule_upsert',
    requestedAt: DateTime.utc(2026, 9, 6),
  );

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_pending_schedule_change_');
    file = File(p.join(tempDir.path, 'pending-schedule-changes.json'));
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('concurrent adds persist both acknowledged changes in either invocation order', () async {
    for (final ids in const [
      ['first', 'second'],
      ['second', 'first'],
    ]) {
      final firstWriteStarted = Completer<void>();
      final releaseFirstWrite = Completer<void>();
      var writes = 0;
      final store = PendingScheduleChangeStore(
        file,
        writeJson: (target, value) async {
          writes++;
          if (writes == 1) {
            firstWriteStarted.complete();
            await releaseFirstWrite.future;
          }
          await atomicWriteJson(target, value);
        },
      );

      final first = store.add(change(ids[0]));
      await firstWriteStarted.future;
      final second = store.add(change(ids[1]));
      await pumpEventQueue();
      expect(writes, 1, reason: 'the second snapshot must wait for the first durable write');
      releaseFirstWrite.complete();
      await Future.wait([first, second]);

      final rebooted = PendingScheduleChangeStore(file);
      await rebooted.load();
      expect(rebooted.values.map((entry) => entry.jobId).toSet(), {'first', 'second'});
      file.deleteSync();
    }
  });

  test('a failed add publishes neither memory nor durable state', () async {
    final store = PendingScheduleChangeStore(
      file,
      writeJson: (_, _) async => throw const FileSystemException('injected add failure'),
    );

    await expectLater(store.add(change('weekly')), throwsA(isA<FileSystemException>()));

    expect(store.values, isEmpty);
    expect(file.existsSync(), isFalse);
  });

  test('a failed remove leaves memory and restart state unchanged', () async {
    var failWrites = false;
    final store = PendingScheduleChangeStore(
      file,
      writeJson: (target, value) async {
        if (failWrites) throw const FileSystemException('injected remove failure');
        await atomicWriteJson(target, value);
      },
    );
    await store.add(change('weekly'));
    final before = file.readAsBytesSync();
    failWrites = true;

    await expectLater(store.remove('change-weekly'), throwsA(isA<FileSystemException>()));

    expect(store.values.single.jobId, 'weekly');
    expect(file.readAsBytesSync(), before);
    final rebooted = PendingScheduleChangeStore(file);
    await rebooted.load();
    expect(rebooted.values.single.jobId, 'weekly');
  });

  test('the count bound refuses entry 101 without changing persisted state', () async {
    final store = PendingScheduleChangeStore(file);
    for (var index = 0; index < PendingScheduleChangeStore.maxEntries; index++) {
      await store.add(change('$index'));
    }
    final before = file.readAsBytesSync();

    await expectLater(store.add(change('overflow')), throwsA(isA<PendingScheduleChangeCapacityExceeded>()));

    expect(store.values, hasLength(PendingScheduleChangeStore.maxEntries));
    expect(file.readAsBytesSync(), before);
  });

  test('the byte bound accepts exactly 1 MiB and refuses the next byte without changing state', () async {
    final empty = change('bytes', prompt: '');
    final overhead = utf8.encode(jsonEncode([empty.toJson()])).length;
    final exact = change('bytes', prompt: 'x' * (PendingScheduleChangeStore.maxBytes - overhead));
    expect(utf8.encode(jsonEncode([exact.toJson()])), hasLength(PendingScheduleChangeStore.maxBytes));
    final store = PendingScheduleChangeStore(file);

    await store.add(exact);
    final before = file.readAsBytesSync();
    await expectLater(
      store.add(change('overflow', prompt: 'x')),
      throwsA(isA<PendingScheduleChangeCapacityExceeded>()),
    );

    expect(store.values.single.jobId, 'bytes');
    expect(file.readAsBytesSync(), before);
  });

  test('legacy over-limit queues load with a warning and remain removable', () async {
    final entries = [
      for (var index = 0; index <= PendingScheduleChangeStore.maxEntries; index++) change('$index').toJson(),
    ];
    file.writeAsStringSync(jsonEncode(entries));
    final warnings = <String>[];
    final subscription = Logger.root.onRecord
        .where((record) => record.loggerName == 'PendingScheduleChangeStore' && record.level >= Level.WARNING)
        .listen((record) => warnings.add(record.message));
    addTearDown(subscription.cancel);
    final store = PendingScheduleChangeStore(file);

    await store.load();
    await store.remove('change-0');

    expect(store.values, hasLength(PendingScheduleChangeStore.maxEntries));
    expect(warnings, contains(startsWith('Loaded a legacy pending schedule queue over the current')));
    final rebooted = PendingScheduleChangeStore(file);
    await rebooted.load();
    expect(rebooted.values, hasLength(PendingScheduleChangeStore.maxEntries));
  });
}
