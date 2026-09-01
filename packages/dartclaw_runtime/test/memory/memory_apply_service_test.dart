import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_core/src/memory/memory_corpus_service.dart' show MemoryCorpusTransition;
import 'package:dartclaw_runtime/src/memory/memory_apply_service.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

const _a = '00000000-0000-4000-8000-00000000000a';
const _b = '00000000-0000-4000-8000-00000000000b';
const _c = '00000000-0000-4000-8000-00000000000c';
const _d = '00000000-0000-4000-8000-00000000000d';
const _e = '00000000-0000-4000-8000-00000000000e';
const _added = '00000000-0000-4000-8000-00000000000f';
const _observation = '00000000-0000-4000-8000-000000000010';
const _learning = '00000000-0000-4000-8000-000000000011';
const _error = '00000000-0000-4000-8000-000000000012';

void main() {
  late Directory workspace;
  late Database db;
  late MemoryService index;
  late MemoryCorpusService corpus;
  late MemorySourceRef provenance;
  late DateTime now;
  late int reconciliations;

  setUp(() async {
    workspace = Directory.systemTemp.createTempSync('memory_apply_service_test_');
    db = sqlite3.openInMemory();
    index = MemoryService(db);
    corpus = MemoryCorpusService(workspaceDir: workspace.path);
    provenance = MemorySourceRef(
      originKind: MemoryOriginKind.curation,
      sourceLocator: 'session:curator',
      sourceEvent: 'turn:apply',
      caller: 'agent:main',
      sessionRef: 'curator',
    );
    now = DateTime.utc(2026, 8, 12, 12);
    reconciliations = 0;
    await corpus.readCorpus();
  });

  tearDown(() async {
    await corpus.close();
    db.close();
    workspace.deleteSync(recursive: true);
  });

  MemoryApplyService service({MemoryIndexReconciler? reconcile, String Function()? createId}) => MemoryApplyService(
    corpus: corpus,
    now: () => now,
    createId: createId ?? () => _added,
    reconcileIndex:
        reconcile ??
        (committed, _, _, _, userId) {
          reconciliations++;
          index.replaceMemoryRows(MemoryService.canonicalIndexRows(committed), userId: userId);
        },
  );

  group('run scope', () {
    // The set names A (in scope), B (in scope) and C (in the corpus but never
    // shown to the run). A whole-set refusal is the contract: partial application
    // would let one out-of-scope reference drag in-scope writes along with it.
    Map<String, dynamic> outOfScopeRequest(int revision) => {
      'expectedRevision': revision,
      'operations': [
        {
          'kind': 'revise',
          'correlationId': 'revise-a',
          'targetId': _a,
          'expectedEntryRevision': 1,
          'topic': 'general',
          'content': 'A revised',
          'state': 'active',
        },
        {
          'kind': 'merge',
          'correlationId': 'merge-b-d',
          'targetId': _b,
          'expectedEntryRevision': 1,
          'sources': [
            {'id': _d, 'expectedEntryRevision': 1},
          ],
          'topic': 'general',
          'content': 'B merged',
          'state': 'active',
          'reason': 'merged duplicate',
        },
        {
          'kind': 'merge',
          'correlationId': 'merge-e-c',
          'targetId': _e,
          'expectedEntryRevision': 1,
          'sources': [
            {'id': _c, 'expectedEntryRevision': 1},
          ],
          'topic': 'general',
          'content': 'E merged',
          'state': 'active',
          'reason': 'merged duplicate',
        },
      ],
    };

    // C exists in the corpus but is deliberately left out of every scope below.
    Future<int> seedCorpus() async {
      await _seed(corpus, [
        _entry(_a, 'A old'),
        _entry(_b, 'B old'),
        _entry(_c, 'C old'),
        _entry(_d, 'D old'),
        _entry(_e, 'E old'),
      ]);
      return (await corpus.readCorpus()).index.metadata.revision;
    }

    test('an operation reaching outside the scope refuses the whole set at the current revision', () async {
      final revision = await seedCorpus();
      final applyService = service()..registerRunScope('curator', {_a, _b, _d, _e});

      final result = await applyService.apply(outOfScopeRequest(revision), userId: 'owner', provenance: provenance);

      final operations = result['operations']! as Map<String, Object?>;
      expect(result['canonicalOutcome'], 'rejected');
      expect((operations['merge-e-c']! as Map)['reason'], 'source $_c was not included in the bounded snapshot');
      expect((operations['revise-a']! as Map)['reason'], 'not applied because the proposal was rejected');
      expect((operations['merge-b-d']! as Map)['reason'], 'not applied because the proposal was rejected');
      expect(operations.values.map((record) => (record! as Map)['outcome']), everyElement('rejected'));
      expect((await corpus.readCorpus()).index.metadata.revision, revision);
      expect(reconciliations, 0);
    });

    test('a target outside the scope is refused even when the corpus holds it', () async {
      final revision = await seedCorpus();
      final applyService = service()..registerRunScope('curator', {_a});

      final result = await applyService.apply(
        {
          'expectedRevision': revision,
          'operations': [
            {
              'kind': 'remove',
              'correlationId': 'remove-c',
              'targetId': _c,
              'expectedEntryRevision': 1,
              'reason': 'forgotten by request',
            },
          ],
        },
        userId: 'owner',
        provenance: provenance,
      );

      expect(result['canonicalOutcome'], 'rejected');
      expect(
        ((result['operations']! as Map)['remove-c']! as Map)['reason'],
        'targetId was not included in the bounded snapshot',
      );
      expect((await corpus.readCorpus()).index.metadata.revision, revision);
    });

    // A run's useful output is mostly new entries and in-scope merges; a guard that
    // constrained those would leave curation unable to write anything at all.
    test('an add and an all-in-scope merge commit while the scope is active', () async {
      final revision = await seedCorpus();
      final applyService = service()..registerRunScope('curator', {_a, _b, _d});

      final result = await applyService.apply(
        {
          'expectedRevision': revision,
          'operations': [
            {'kind': 'add', 'correlationId': 'add-new', 'topic': 'general', 'content': 'A brand new entry'},
            {
              'kind': 'merge',
              'correlationId': 'merge-b-d',
              'targetId': _b,
              'expectedEntryRevision': 1,
              'sources': [
                {'id': _d, 'expectedEntryRevision': 1},
              ],
              'topic': 'general',
              'content': 'B merged',
              'state': 'active',
              'reason': 'merged duplicate',
            },
          ],
        },
        userId: 'owner',
        provenance: provenance,
      );

      final operations = result['operations']! as Map<String, Object?>;
      expect(result['canonicalOutcome'], 'committed');
      expect((operations['add-new']! as Map)['outcome'], 'changed');
      expect((operations['merge-b-d']! as Map)['outcome'], 'changed');
    });

    test('the same set applies when no scope is registered', () async {
      final revision = await seedCorpus();

      final result = await service().apply(outOfScopeRequest(revision), userId: 'owner', provenance: provenance);

      expect(result['canonicalOutcome'], 'committed');
      expect((await corpus.readCorpus()).index.metadata.revision, greaterThan(revision));
    });

    // A scope that outlived its run would be a *different* bounded set for the
    // next turn on the same session, admitting IDs the current snapshot never showed.
    test('a released scope does not constrain a later call on the same session', () async {
      final revision = await seedCorpus();
      final applyService = service()
        ..registerRunScope('curator', {_a, _b, _d, _e})
        ..releaseRunScope('curator');

      final result = await applyService.apply(outOfScopeRequest(revision), userId: 'owner', provenance: provenance);

      expect(result['canonicalOutcome'], 'committed');
    });

    test('a scope constrains only the session that registered it', () async {
      final revision = await seedCorpus();
      final applyService = service()..registerRunScope('other-session', {_a});

      final result = await applyService.apply(outOfScopeRequest(revision), userId: 'owner', provenance: provenance);

      expect(result['canonicalOutcome'], 'committed');
    });

    test('registering a second scope for a live session is refused', () {
      final applyService = service()..registerRunScope('curator', {_a});

      expect(() => applyService.registerRunScope('curator', {_b}), throwsStateError);
    });
  });

  test('mixed add revise merge remove and exact-no-op commit once with exact records', () async {
    await _seed(corpus, [
      _entry(_a, 'A old'),
      _entry(_b, 'B old'),
      _entry(_c, 'C old'),
      _entry(_d, 'REMOVE-ME-9f8c'),
      _entry(_e, 'E same'),
    ]);
    final revision = (await corpus.readCorpus()).index.metadata.revision;

    final result = await service().apply(
      {
        'expectedRevision': revision,
        'operations': [
          {'kind': 'add', 'correlationId': 'add', 'topic': 'preferences', 'content': 'New preference'},
          {
            'kind': 'revise',
            'correlationId': 'revise-a',
            'targetId': _a,
            'expectedEntryRevision': 1,
            'topic': 'general',
            'content': 'A revised',
            'state': 'active',
          },
          {
            'kind': 'merge',
            'correlationId': 'merge-b-c',
            'targetId': _b,
            'expectedEntryRevision': 1,
            'sources': [
              {'id': _c, 'expectedEntryRevision': 1},
            ],
            'topic': 'general',
            'content': 'B merged',
            'state': 'active',
            'reason': 'merged duplicate',
          },
          {
            'kind': 'remove',
            'correlationId': 'remove-d',
            'targetId': _d,
            'expectedEntryRevision': 1,
            'reason': 'forgotten by request',
          },
          {
            'kind': 'revise',
            'correlationId': 'noop-e',
            'targetId': _e,
            'expectedEntryRevision': 1,
            'topic': 'general',
            'content': 'E same',
            'state': 'active',
          },
        ],
      },
      userId: 'owner',
      provenance: provenance,
    );

    expect(result['canonicalOutcome'], 'committed');
    expect(result['indexOutcome'], 'current');
    expect(result['collectionRevision'], revision + 1);
    final records = (result['operations'] as Map).cast<String, Map<String, Object?>>();
    expect(records.keys, unorderedEquals(['add', 'revise-a', 'merge-b-c', 'remove-d', 'noop-e']));
    expect(records['add'], containsPair('entryId', _added));
    expect(records['noop-e'], containsPair('outcome', 'exactNoOp'));
    expect(records.values.every((record) => record['collectionRevision'] == revision + 1), isTrue);
    expect(reconciliations, 1);

    final current = await corpus.readCorpus();
    final active = current.topics.expand((topic) => topic.entries).toList();
    expect(active.map((entry) => entry.id), unorderedEquals([_a, _b, _e, _added]));
    expect(active.singleWhere((entry) => entry.id == _a).revision, 2);
    expect(active.singleWhere((entry) => entry.id == _b).content, 'B merged');
    expect(active.singleWhere((entry) => entry.id == _e).revision, 1);
    expect(current.audit!.records.map((record) => record.entryId), unorderedEquals([_c, _d]));
    expect(current.audit!.records.singleWhere((record) => record.entryId == _c).reason, 'merged duplicate');
    expect(_allCorpusText(workspace), isNot(contains('REMOVE-ME-9f8c')));
    expect(index.listRecent().map((row) => row.text).join('\n'), isNot(contains('REMOVE-ME-9f8c')));
  });

  test('wholly exact-no-op performs no canonical audit or index write', () async {
    await _seed(corpus, [_entry(_e, 'E same')]);
    final revision = (await corpus.readCorpus()).index.metadata.revision;
    final before = _corpusBytes(workspace);

    final result = await service().apply(
      {
        'expectedRevision': revision,
        'operations': [
          {
            'kind': 'revise',
            'correlationId': 'noop-e',
            'targetId': _e,
            'expectedEntryRevision': 1,
            'topic': 'general',
            'content': 'E same',
            'state': 'active',
          },
        ],
      },
      userId: 'owner',
      provenance: provenance,
    );

    expect(result['canonicalOutcome'], 'unchanged');
    expect(result['collectionRevision'], revision);
    expect(((result['operations'] as Map)['noop-e'] as Map)['outcome'], 'exactNoOp');
    expect(reconciliations, 0);
    expect(_corpusBytes(workspace), before);
  });

  test('one invalid operation rejects every operation without canonical index or audit effects', () async {
    await _seed(corpus, [_entry(_a, 'A'), _entry(_b, 'B')]);
    final revision = (await corpus.readCorpus()).index.metadata.revision;
    index.replaceMemoryRows(MemoryService.canonicalIndexRows(await corpus.readCorpus()));
    final beforeCorpus = _corpusBytes(workspace);
    final beforeRows = index.listRecent();

    final result = await service().apply(
      {
        'expectedRevision': revision,
        'operations': [
          {'kind': 'add', 'correlationId': 'valid-add', 'topic': 'general', 'content': 'Would be valid'},
          {
            'kind': 'merge',
            'correlationId': 'bad-merge',
            'targetId': _a,
            'expectedEntryRevision': 1,
            'sources': [
              {'id': _b, 'expectedEntryRevision': 1},
            ],
            'topic': 'general',
            'content': 'Merged',
            'state': 'active',
            'reason': 'merge',
          },
          {
            'kind': 'remove',
            'correlationId': 'overlap',
            'targetId': _b,
            'expectedEntryRevision': 1,
            'reason': 'duplicate target',
          },
        ],
      },
      userId: 'owner',
      provenance: provenance,
    );

    expect(result['canonicalOutcome'], 'rejected');
    final records = (result['operations'] as Map).cast<String, dynamic>();
    expect((records['bad-merge'] as Map)['reason'], contains('also used'));
    expect((records['overlap'] as Map)['reason'], contains('also used'));
    expect((records['valid-add'] as Map)['reason'], contains('not applied'));
    expect(records.values.every((record) => (record as Map)['outcome'] == 'rejected'), isTrue);
    expect(_corpusBytes(workspace), beforeCorpus);
    expect(index.listRecent().map((row) => row.locator), beforeRows.map((row) => row.locator));
    expect(reconciliations, 0);
  });

  test('concurrent callers from one revision produce one commit and one typed conflict', () async {
    await _seed(corpus, [_entry(_a, 'A')]);
    final revision = (await corpus.readCorpus()).index.metadata.revision;
    var id = 0;
    final apply = service(createId: () => '00000000-0000-4000-8000-${(++id).toString().padLeft(12, '0')}');
    Map<String, Object?> request(String correlation) => {
      'expectedRevision': revision,
      'operations': [
        {'kind': 'add', 'correlationId': correlation, 'topic': 'general', 'content': correlation},
      ],
    };

    final results = await Future.wait([
      apply.apply(request('first'), userId: 'owner', provenance: provenance),
      apply.apply(request('second'), userId: 'owner', provenance: provenance),
    ]);

    expect(results.map((result) => result['canonicalOutcome']), unorderedEquals(['committed', 'conflict']));
    expect((await corpus.readCorpus()).index.metadata.revision, revision + 1);
    expect(reconciliations, 1);
  });

  test('post-commit index failure reports degradation and preserves durable canonical success', () async {
    await _seed(corpus, [_entry(_a, 'A')]);
    final revision = (await corpus.readCorpus()).index.metadata.revision;
    final apply = service(reconcile: (_, _, _, _, _) => throw StateError('derived sentinel failure'));

    final result = await apply.apply(
      {
        'expectedRevision': revision,
        'operations': [
          {'kind': 'add', 'correlationId': 'durable', 'topic': 'general', 'content': 'Durable content'},
        ],
      },
      userId: 'owner',
      provenance: provenance,
    );

    expect(result['canonicalOutcome'], 'committed');
    expect(result['indexOutcome'], 'degraded');
    expect(result['collectionRevision'], revision + 1);
    expect(result['failure'], containsPair('kind', 'indexReconciliation'));
    expect(result['failure'], containsPair('currentCollectionRevision', revision + 1));
    expect(_allCorpusText(workspace), contains('Durable content'));
  });

  test('failures before marker and at audit replacement roll back the whole canonical transaction', () async {
    for (final failure in [
      (MemoryCorpusTransition.beforeCommitMarker, 'MEMORY.md'),
      (MemoryCorpusTransition.targetReplaced, 'MEMORY.audit.md'),
    ]) {
      final localDir = Directory.systemTemp.createTempSync('memory_apply_fault_test_');
      var inject = false;
      final localCorpus = MemoryCorpusService(
        workspaceDir: localDir.path,
        transitionHook: (transition, path) {
          if (inject && transition == failure.$1 && path == failure.$2) throw StateError('injected failure');
        },
      );
      try {
        await localCorpus.readCorpus();
        await _seed(localCorpus, [_entry(_d, 'Durability sentinel')]);
        final revision = (await localCorpus.readCorpus()).index.metadata.revision;
        final before = _corpusBytes(localDir);
        var indexed = false;
        final apply = MemoryApplyService(
          corpus: localCorpus,
          now: () => now,
          createId: () => _added,
          reconcileIndex: (_, _, _, _, _) => indexed = true,
        );
        inject = true;

        final result = await apply.apply(
          {
            'expectedRevision': revision,
            'operations': [
              {
                'kind': 'remove',
                'correlationId': 'remove',
                'targetId': _d,
                'expectedEntryRevision': 1,
                'reason': 'fault matrix',
              },
            ],
          },
          userId: 'owner',
          provenance: provenance,
        );

        expect(result['canonicalOutcome'], 'rejected', reason: '${failure.$1}:${failure.$2}');
        expect(result['failure'], containsPair('kind', 'canonicalCommit'));
        expect(result['failure'], containsPair('stage', 'canonicalCommit'));
        expect(result['failure'], containsPair('currentCollectionRevision', revision));
        expect(_corpusBytes(localDir), before, reason: '${failure.$1}:${failure.$2}');
        expect(indexed, isFalse);
      } finally {
        await localCorpus.close();
        localDir.deleteSync(recursive: true);
      }
    }
  });

  test('an ordinary post-marker fault reports the recovered durable commit as success', () async {
    for (final failure in [
      (MemoryCorpusTransition.commitMarkerReplaced, 'MEMORY.md'),
      (MemoryCorpusTransition.fingerprintRecorded, '.dartclaw-memory-corpus.json'),
      (MemoryCorpusTransition.beforeCleanup, '.dartclaw-memory-transaction.json'),
    ]) {
      final localDir = Directory.systemTemp.createTempSync('memory_apply_post_marker_fault_test_');
      var inject = false;
      final localCorpus = MemoryCorpusService(
        workspaceDir: localDir.path,
        transitionHook: (transition, path) {
          if (inject && transition == failure.$1 && path == failure.$2) throw StateError('post-marker fault');
        },
      );
      try {
        await localCorpus.readCorpus();
        await _seed(localCorpus, [_entry(_a, 'A')]);
        final revision = (await localCorpus.readCorpus()).index.metadata.revision;
        var indexed = false;
        final apply = MemoryApplyService(
          corpus: localCorpus,
          now: () => now,
          createId: () => _added,
          reconcileIndex: (_, _, _, _, _) => indexed = true,
        );
        inject = true;

        final result = await apply.apply(
          {
            'expectedRevision': revision,
            'operations': [
              {'kind': 'add', 'correlationId': 'durable', 'topic': 'general', 'content': 'Recovered durable content'},
            ],
          },
          userId: 'owner',
          provenance: provenance,
        );

        expect(result['canonicalOutcome'], 'committed', reason: '${failure.$1}:${failure.$2}');
        expect(result['collectionRevision'], revision + 1, reason: '${failure.$1}:${failure.$2}');
        expect(_allCorpusText(localDir), contains('Recovered durable content'), reason: '${failure.$1}:${failure.$2}');
        expect(indexed, isTrue, reason: '${failure.$1}:${failure.$2}');
      } finally {
        await localCorpus.close();
        localDir.deleteSync(recursive: true);
      }
    }
  });

  test('a simulated post-marker crash throws and recovery exposes the durable commit without indexing', () async {
    for (final failure in [
      (MemoryCorpusTransition.commitMarkerReplaced, 'MEMORY.md'),
      (MemoryCorpusTransition.fingerprintRecorded, '.dartclaw-memory-corpus.json'),
      (MemoryCorpusTransition.beforeCleanup, '.dartclaw-memory-transaction.json'),
    ]) {
      final localDir = Directory.systemTemp.createTempSync('memory_apply_post_marker_crash_test_');
      var inject = false;
      final localCorpus = MemoryCorpusService(
        workspaceDir: localDir.path,
        transitionHook: (transition, path) {
          if (inject && transition == failure.$1 && path == failure.$2) {
            throw MemoryCorpusSimulatedCrash(transition);
          }
        },
      );
      try {
        await localCorpus.readCorpus();
        await _seed(localCorpus, [_entry(_a, 'A')]);
        final revision = (await localCorpus.readCorpus()).index.metadata.revision;
        var indexed = false;
        final apply = MemoryApplyService(
          corpus: localCorpus,
          now: () => now,
          createId: () => _added,
          reconcileIndex: (_, _, _, _, _) => indexed = true,
        );
        inject = true;

        await expectLater(
          apply.apply(
            {
              'expectedRevision': revision,
              'operations': [
                {'kind': 'add', 'correlationId': 'durable', 'topic': 'general', 'content': 'Recovered after restart'},
              ],
            },
            userId: 'owner',
            provenance: provenance,
          ),
          throwsA(isA<MemoryCorpusSimulatedCrash>()),
          reason: '${failure.$1}:${failure.$2}',
        );
        expect(indexed, isFalse, reason: '${failure.$1}:${failure.$2}');
      } finally {
        await localCorpus.close();
      }

      final reopened = MemoryCorpusService(workspaceDir: localDir.path);
      try {
        final current = await reopened.readCorpus();
        expect(current.index.metadata.revision, 3, reason: '${failure.$1}:${failure.$2}');
        expect(
          current.topics.expand((topic) => topic.entries).map((entry) => entry.content),
          contains('Recovered after restart'),
        );
      } finally {
        await reopened.close();
        localDir.deleteSync(recursive: true);
      }
    }
  });

  test('remove stores the at-cap reason verbatim and never copies entry content into audit', () async {
    await _seed(corpus, [_entry(_d, 'REMOVE-ME-9f8c'), _entry(_e, 'Unicode reason target')]);
    final revision = (await corpus.readCorpus()).index.metadata.revision;
    final reason = 'r' * maxMemoryApplyReasonLength;

    final result = await service().apply(
      {
        'expectedRevision': revision,
        'operations': [
          {'kind': 'remove', 'correlationId': 'remove', 'targetId': _d, 'expectedEntryRevision': 1, 'reason': reason},
        ],
      },
      userId: 'owner',
      provenance: provenance,
    );

    expect(result['canonicalOutcome'], 'committed');
    final audit = (await corpus.readCorpus()).audit!.records.single;
    expect(audit.reason, reason);
    expect(audit.provenance.caller, 'agent:main');
    expect(_allCorpusText(workspace), isNot(contains('REMOVE-ME-9f8c')));

    final scalarReason = '😀' * maxMemoryApplyReasonLength;
    final scalarResult = await service().apply(
      {
        'expectedRevision': result['collectionRevision'],
        'operations': [
          {
            'kind': 'remove',
            'correlationId': 'scalar-limit',
            'targetId': _e,
            'expectedEntryRevision': 1,
            'reason': scalarReason,
          },
        ],
      },
      userId: 'owner',
      provenance: provenance,
    );
    expect(scalarResult['canonicalOutcome'], 'committed');
    expect(
      (await corpus.readCorpus()).audit!.records.singleWhere((record) => record.entryId == _e).reason,
      scalarReason,
    );

    final rejected = await service().apply(
      {
        'expectedRevision': scalarResult['collectionRevision'],
        'operations': [
          {'kind': 'add', 'correlationId': 'keep', 'topic': 'general', 'content': 'kept'},
          {
            'kind': 'remove',
            'correlationId': 'too-long',
            'targetId': _d,
            'expectedEntryRevision': 1,
            'reason': '$scalarReason😀',
          },
        ],
      },
      userId: 'owner',
      provenance: provenance,
    );
    expect(rejected['canonicalOutcome'], 'rejected');
    expect(rejected['failure'], containsPair('reason', contains('1024')));
    final records = (rejected['operations'] as Map).cast<String, dynamic>();
    expect(records.keys, unorderedEquals(['keep', 'too-long']));
    expect((records['keep'] as Map)['reason'], contains('not applied'));
    expect((records['too-long'] as Map)['reason'], contains('1024'));
    expect(records.values.every((record) => (record as Map)['outcome'] == 'rejected'), isTrue);
  });

  test('one-entry apply does not open unrelated observation partitions', () async {
    await _seed(corpus, [_entry(_a, 'A old')]);
    final memoryDir = Directory('${workspace.path}/memory');
    for (var index = 0; index < 1001; index++) {
      final date = DateTime.utc(2020).add(Duration(days: index)).toIso8601String().substring(0, 10);
      final file = File('${memoryDir.path}/$date.md');
      if (index < 9) {
        _writeSizedObservation(file, date, index, 8 * 1024 * 1024);
      } else {
        file.writeAsStringSync(const MemoryMarkdownCodec().render(MemoryObservationDocument(date: date)));
      }
    }
    await corpus.close();
    final reads = <String>[];
    corpus = MemoryCorpusService(workspaceDir: workspace.path, readObserver: reads.add);
    await corpus.manifest();
    reads.clear();
    final revision = (await corpus.manifest()).collectionRevision;
    final result = await service().apply(
      {
        'expectedRevision': revision,
        'operations': [
          {
            'kind': 'revise',
            'correlationId': 'revise-a',
            'targetId': _a,
            'expectedEntryRevision': 1,
            'topic': 'general',
            'content': 'A revised',
            'state': 'active',
          },
        ],
      },
      userId: 'owner',
      provenance: provenance,
    );
    expect(result['canonicalOutcome'], 'committed');
    expect(reads.where((path) => path.startsWith('memory/20')), isEmpty);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('archive un-archive and re-topic retain identity and indexed archived rows', () async {
    await _seed(corpus, [_entry(_a, 'Active'), _entry(_b, 'Archived', topic: 'travel')], archivedIds: {_b});
    final revision = (await corpus.readCorpus()).index.metadata.revision;

    final result = await service().apply(
      {
        'expectedRevision': revision,
        'operations': [
          {
            'kind': 'revise',
            'correlationId': 'archive-a',
            'targetId': _a,
            'expectedEntryRevision': 1,
            'topic': 'general',
            'content': 'Active',
            'state': 'archived',
          },
          {
            'kind': 'revise',
            'correlationId': 'retopic-b',
            'targetId': _b,
            'expectedEntryRevision': 1,
            'topic': 'logistics',
            'content': 'Archived',
            'state': 'archived',
          },
        ],
      },
      userId: 'owner',
      provenance: provenance,
    );

    expect(result['canonicalOutcome'], 'committed');
    final current = await corpus.readCorpus();
    expect(current.archive!.entries.map((entry) => entry.id), unorderedEquals([_a, _b]));
    expect(current.archive!.entries.singleWhere((entry) => entry.id == _b).topic, 'logistics');
    expect(current.index.entries, isEmpty);
    expect(index.listRecent().map((row) => row.locator), unorderedEquals([_a, _b]));
    expect(index.listRecent().every((row) => row.role == 'archive'), isTrue);
  });

  test('an archived entry can be removed and an already-removed target is rejected', () async {
    await _seed(corpus, [_entry(_a, 'Archived content')], archivedIds: {_a});
    final initial = await corpus.readCorpus();
    index.replaceMemoryRows(MemoryService.canonicalIndexRows(initial));

    final removed = await service().apply(
      {
        'expectedRevision': initial.index.metadata.revision,
        'operations': [
          {
            'kind': 'remove',
            'correlationId': 'remove-archived',
            'targetId': _a,
            'expectedEntryRevision': 1,
            'reason': 'explicitly forgotten',
          },
        ],
      },
      userId: 'owner',
      provenance: provenance,
    );

    expect(removed['canonicalOutcome'], 'committed');
    expect(index.listRecent(), isEmpty);
    final current = await corpus.readCorpus();
    expect(current.archive?.entries ?? const <CanonicalMemoryEntry>[], isEmpty);
    expect(current.audit!.records.single.entryId, _a);
    final beforeRetry = _corpusBytes(workspace);

    final retry = await service().apply(
      {
        'expectedRevision': current.index.metadata.revision,
        'operations': [
          {
            'kind': 'remove',
            'correlationId': 'already-removed',
            'targetId': _a,
            'expectedEntryRevision': 1,
            'reason': 'repeat removal',
          },
        ],
      },
      userId: 'owner',
      provenance: provenance,
    );

    expect(retry['canonicalOutcome'], 'rejected');
    final record = (retry['operations'] as Map)['already-removed'] as Map;
    expect(record['reason'], contains('does not exist'));
    expect(_corpusBytes(workspace), beforeRetry);
    expect(reconciliations, 1);
  });

  test('malformed operation records retain precise reasons and reject valid peers without effects', () async {
    await _seed(corpus, [_entry(_a, 'A')]);
    final revision = (await corpus.readCorpus()).index.metadata.revision;
    index.replaceMemoryRows(MemoryService.canonicalIndexRows(await corpus.readCorpus()));
    final beforeCorpus = _corpusBytes(workspace);
    final beforeRows = index.listRecent();

    final result = await service().apply(
      {
        'expectedRevision': revision,
        'operations': [
          {'kind': 'add', 'correlationId': 'valid', 'topic': 'general', 'content': 'Would be valid'},
          {
            'kind': 'remove',
            'correlationId': 'forged-provenance',
            'targetId': _a,
            'expectedEntryRevision': 1,
            'reason': 'remove',
            'actor': 'forged',
          },
          {
            'kind': 'remove',
            'correlationId': 'cross-store',
            'targetId': 'wiki/topic.md',
            'expectedEntryRevision': 1,
            'reason': 'remove',
          },
          {
            'kind': 'remove',
            'correlationId': 'fractional-revision',
            'targetId': _a,
            'expectedEntryRevision': 1.5,
            'reason': 'remove',
          },
        ],
      },
      userId: 'owner',
      provenance: provenance,
    );

    expect(result['canonicalOutcome'], 'rejected');
    final records = (result['operations'] as Map).cast<String, dynamic>();
    expect(records.keys, unorderedEquals(['valid', 'forged-provenance', 'cross-store', 'fractional-revision']));
    expect((records['valid'] as Map)['reason'], contains('not applied'));
    expect((records['forged-provenance'] as Map)['reason'], contains('unsupported fields'));
    expect((records['cross-store'] as Map)['reason'], contains('UUID'));
    expect((records['fractional-revision'] as Map)['reason'], contains('positive integer'));
    expect(records.values.every((record) => (record as Map)['outcome'] == 'rejected'), isTrue);
    expect(_corpusBytes(workspace), beforeCorpus);
    expect(index.listRecent().map((row) => row.locator), beforeRows.map((row) => row.locator));
    expect(reconciliations, 0);
  });

  test('failure conversion does not reopen a corrupt canonical corpus', () async {
    final revision = (await corpus.readCorpus()).index.metadata.revision;
    final indexFile = File('${workspace.path}/MEMORY.md');
    indexFile.writeAsStringSync('corrupt canonical index');

    final malformed = await service().apply(
      {'expectedRevision': revision, 'operations': const []},
      userId: 'owner',
      provenance: provenance,
    );
    final commitFailure = await service().apply(
      {
        'expectedRevision': revision,
        'operations': [
          {'kind': 'add', 'correlationId': 'add', 'topic': 'general', 'content': 'Not committed'},
        ],
      },
      userId: 'owner',
      provenance: provenance,
    );

    expect(malformed['canonicalOutcome'], 'rejected');
    expect((malformed['failure'] as Map)['kind'], 'validation');
    expect(malformed['collectionRevision'], revision);
    expect(commitFailure['canonicalOutcome'], 'rejected');
    expect((commitFailure['failure'] as Map)['kind'], 'canonicalCommit');
    expect(commitFailure['collectionRevision'], revision);
    expect(indexFile.readAsStringSync(), 'corrupt canonical index');
  });

  test('malformed-operation fallback keys cannot overwrite caller correlation records', () async {
    final revision = (await corpus.readCorpus()).index.metadata.revision;

    final result = await service().apply(
      {
        'expectedRevision': revision,
        'operations': [
          {'kind': 'add', 'correlationId': 'operation[1]', 'topic': 'general', 'content': 'Would be valid'},
          'not-an-operation',
        ],
      },
      userId: 'owner',
      provenance: provenance,
    );

    expect(result['canonicalOutcome'], 'rejected');
    final records = (result['operations'] as Map).cast<String, dynamic>();
    expect(records.keys, unorderedEquals(['operation[1]', 'operation[1]#1']));
    expect(records.values.every((record) => (record as Map)['outcome'] == 'rejected'), isTrue);
    expect(reconciliations, 0);

    final reversed = await service().apply(
      {
        'expectedRevision': revision,
        'operations': [
          {
            'kind': 'add',
            'correlationId': 'shared',
            'topic': 'general',
            'content': 'Malformed first',
            'source': 'forged',
          },
          {'kind': 'add', 'correlationId': 'shared', 'topic': 'general', 'content': 'Duplicate second'},
        ],
      },
      userId: 'owner',
      provenance: provenance,
    );

    final reversedRecords = (reversed['operations'] as Map).cast<String, dynamic>();
    expect(reversedRecords.keys, unorderedEquals(['shared', 'operation[1]']));
    expect((reversedRecords['shared'] as Map)['reason'], contains('unsupported fields'));
    expect((reversedRecords['operation[1]'] as Map)['reason'], contains('duplicate correlationId'));
    expect(reversedRecords.values.every((record) => (record as Map)['outcome'] == 'rejected'), isTrue);
    expect(reconciliations, 0);
  });

  // memory_apply rebuilds the whole corpus; a member it never selected
  // must survive byte-identical, or the fold silently drops errors and learnings.
  test('archiving a topic entry leaves the error and learning documents byte-identical', () async {
    await _seed(
      corpus,
      [_entry(_a, 'A active')],
      learnings: [
        CanonicalMemoryLearning(
          id: _learning,
          revision: 1,
          summary: 'Learning only',
          content: 'Learning only',
          created: now,
          updated: now,
          provenance: provenance,
        ),
      ],
      errors: [
        CanonicalMemoryError(
          id: _error,
          revision: 1,
          summary: 'GUARD_BLOCK',
          content: 'Blocked prompt injection attempt.',
          created: now,
          updated: now,
          provenance: MemorySourceRef(sourceLocator: 'runtime-error', sessionRef: 'sess-1'),
        ),
      ],
    );
    final before = _corpusBytes(workspace);
    final revision = (await corpus.readCorpus()).index.metadata.revision;

    final result = await service().apply(
      {
        'expectedRevision': revision,
        'operations': [
          {
            'kind': 'revise',
            'correlationId': 'archive-a',
            'targetId': _a,
            'expectedEntryRevision': 1,
            'topic': 'general',
            'content': 'A active',
            'state': 'archived',
          },
        ],
      },
      userId: 'owner',
      provenance: provenance,
    );

    expect(result['canonicalOutcome'], 'committed');
    final after = _corpusBytes(workspace);
    expect(after['errors.md'], before['errors.md']);
    expect(after['learnings.md'], before['learnings.md']);
    final current = await corpus.readCorpus();
    expect(current.errors!.entries.single.id, _error);
    expect(current.learnings!.entries.single.id, _learning);
    expect((await corpus.statusSnapshot()).errorEntryCount, 1);
    expect((await corpus.statusSnapshot()).learningEntryCount, 1);
  });

  test('unknown operations and non-personal targets reject the whole request without effects', () async {
    await _seed(
      corpus,
      [_entry(_a, 'A')],
      observations: [
        MemoryObservation(
          id: _observation,
          recorded: now,
          content: 'Observed only',
          trustLabel: 'untrusted-observation',
          provenance: provenance,
        ),
      ],
      learnings: [
        CanonicalMemoryLearning(
          id: _learning,
          revision: 1,
          summary: 'Learning only',
          content: 'Learning only',
          created: now,
          updated: now,
          provenance: provenance,
        ),
      ],
    );
    final revision = (await corpus.readCorpus()).index.metadata.revision;
    final before = _corpusBytes(workspace);
    final invalidOperations = <String, Map<String, Object?>>{
      'unknown-kind': {'kind': 'replace', 'correlationId': 'invalid'},
      'unknown-field': {
        'kind': 'remove',
        'correlationId': 'invalid',
        'targetId': _a,
        'expectedEntryRevision': 1,
        'reason': 'remove',
        'source': 'forged',
      },
      'wiki-locator': {
        'kind': 'remove',
        'correlationId': 'invalid',
        'targetId': 'wiki/topic.md',
        'expectedEntryRevision': 1,
        'reason': 'remove',
      },
      'kg-locator': {
        'kind': 'remove',
        'correlationId': 'invalid',
        'targetId': 'kg:person/alice',
        'expectedEntryRevision': 1,
        'reason': 'remove',
      },
      'observation-id': {
        'kind': 'remove',
        'correlationId': 'invalid',
        'targetId': _observation,
        'expectedEntryRevision': 1,
        'reason': 'remove',
      },
      'learning-id': {
        'kind': 'remove',
        'correlationId': 'invalid',
        'targetId': _learning,
        'expectedEntryRevision': 1,
        'reason': 'remove',
      },
    };

    for (final invalid in invalidOperations.entries) {
      final result = await service().apply(
        {
          'expectedRevision': revision,
          'operations': [
            {'kind': 'add', 'correlationId': 'valid', 'topic': 'general', 'content': 'Would be valid'},
            invalid.value,
          ],
        },
        userId: 'owner',
        provenance: provenance,
      );

      expect(result['canonicalOutcome'], 'rejected', reason: invalid.key);
      final records = (result['operations'] as Map).cast<String, dynamic>();
      expect((records['valid'] as Map)['reason'], contains('not applied'), reason: invalid.key);
      expect((records['invalid'] as Map)['outcome'], 'rejected', reason: invalid.key);
      expect(_corpusBytes(workspace), before, reason: invalid.key);
    }
    expect(reconciliations, 0);
  });

  test('host-generated IDs cannot overwrite an existing entry or alias two adds', () async {
    await _seed(corpus, [_entry(_a, 'Existing')]);
    final revision = (await corpus.readCorpus()).index.metadata.revision;
    final before = _corpusBytes(workspace);

    final existingCollision = await service(createId: () => _a).apply(
      {
        'expectedRevision': revision,
        'operations': [
          {'kind': 'add', 'correlationId': 'collides-existing', 'topic': 'general', 'content': 'Replacement'},
        ],
      },
      userId: 'owner',
      provenance: provenance,
    );
    expect(existingCollision['canonicalOutcome'], 'rejected');
    expect(((existingCollision['operations'] as Map)['collides-existing'] as Map)['reason'], contains('collides'));
    expect(_corpusBytes(workspace), before);

    final duplicateAdds = await service(createId: () => _added).apply(
      {
        'expectedRevision': revision,
        'operations': [
          {'kind': 'add', 'correlationId': 'first-add', 'topic': 'general', 'content': 'First'},
          {'kind': 'add', 'correlationId': 'second-add', 'topic': 'general', 'content': 'Second'},
        ],
      },
      userId: 'owner',
      provenance: provenance,
    );
    expect(duplicateAdds['canonicalOutcome'], 'rejected');
    final records = (duplicateAdds['operations'] as Map).cast<String, dynamic>();
    expect((records['first-add'] as Map)['reason'], contains('also used'));
    expect((records['second-add'] as Map)['reason'], contains('also used'));
    expect(_corpusBytes(workspace), before);
    expect(reconciliations, 0);

    final removed = await service().apply(
      {
        'expectedRevision': revision,
        'operations': [
          {
            'kind': 'remove',
            'correlationId': 'retire-existing',
            'targetId': _a,
            'expectedEntryRevision': 1,
            'reason': 'permanently retired',
          },
        ],
      },
      userId: 'owner',
      provenance: provenance,
    );
    final retiredBefore = _corpusBytes(workspace);

    final retiredCollision = await service(createId: () => _a).apply(
      {
        'expectedRevision': removed['collectionRevision'],
        'operations': [
          {'kind': 'add', 'correlationId': 'collides-retired', 'topic': 'general', 'content': 'Reused identity'},
        ],
      },
      userId: 'owner',
      provenance: provenance,
    );
    expect(retiredCollision['canonicalOutcome'], 'rejected');
    expect(((retiredCollision['operations'] as Map)['collides-retired'] as Map)['reason'], contains('retired'));
    expect(_corpusBytes(workspace), retiredBefore);
  });

  test('a resulting corpus above the canonical byte ceiling is rejected before any sink', () async {
    final revision = (await corpus.readCorpus()).index.metadata.revision;
    final before = _corpusBytes(workspace);
    final oversized = 'x'.padRight(MemoryCorpusService.maxCorpusBytes, 'x');

    final result = await service().apply(
      {
        'expectedRevision': revision,
        'operations': [
          {'kind': 'add', 'correlationId': 'oversized', 'topic': 'general', 'content': oversized},
        ],
      },
      userId: 'owner',
      provenance: provenance,
    );

    expect(result['canonicalOutcome'], 'rejected');
    expect(result['collectionRevision'], revision);
    expect(((result['operations'] as Map)['oversized'] as Map)['outcome'], 'rejected');
    expect(_corpusBytes(workspace), before);
    expect(reconciliations, 0);
  }, timeout: const Timeout(Duration(seconds: 30)));
}

CanonicalMemoryEntry _entry(String id, String content, {String topic = 'general'}) => CanonicalMemoryEntry(
  id: id,
  revision: 1,
  topic: topic,
  summary: content,
  content: content,
  created: DateTime.utc(2026, 8, 1),
  updated: DateTime.utc(2026, 8, 1),
  provenance: MemorySourceRef(
    originKind: MemoryOriginKind.migration,
    sourceLocator: 'migration:test',
    caller: 'migration',
    sessionRef: 'fixture',
  ),
);

Future<void> _seed(
  MemoryCorpusService corpus,
  List<CanonicalMemoryEntry> entries, {
  Set<String> archivedIds = const {},
  List<MemoryObservation> observations = const [],
  List<CanonicalMemoryLearning> learnings = const [],
  List<CanonicalMemoryError> errors = const [],
}) async {
  final current = await corpus.readCorpus();
  final active = entries.where((entry) => !archivedIds.contains(entry.id)).toList();
  final archived = entries.where((entry) => archivedIds.contains(entry.id)).toList();
  final byTopic = <String, List<CanonicalMemoryEntry>>{};
  for (final entry in active) {
    (byTopic[entry.topic] ??= []).add(entry);
  }
  final replacement = CanonicalMemoryCorpus(
    index: MemoryIndexDocument(
      metadata: current.index.metadata,
      entries: [
        for (final entry in active)
          MemoryIndexEntry(
            id: entry.id,
            revision: entry.revision,
            topic: entry.topic,
            summary: entry.summary,
            updated: entry.updated,
          ),
      ],
    ),
    topics: [for (final topic in byTopic.entries) MemoryTopicDocument(topic: topic.key, entries: topic.value)],
    archive: archived.isEmpty ? null : MemoryArchiveDocument(entries: archived),
    observations: observations.isEmpty
        ? const []
        : [
            MemoryObservationDocument(
              date: observations.first.recorded.toIso8601String().substring(0, 10),
              observations: observations,
            ),
          ],
    learnings: learnings.isEmpty ? null : MemoryLearningDocument(entries: learnings),
    errors: errors.isEmpty ? null : MemoryErrorDocument(entries: errors),
  );
  final result = await corpus.commit(expectedRevision: current.index.metadata.revision, replacement: replacement);
  expect(result.wasCommitted, isTrue);
}

Map<String, List<int>> _corpusBytes(Directory workspace) {
  final result = <String, List<int>>{};
  for (final entity in workspace.listSync(recursive: true)) {
    if (entity is! File) continue;
    final relative = entity.path.substring(workspace.path.length + 1);
    if (relative.startsWith('.dartclaw-memory')) continue;
    result[relative] = entity.readAsBytesSync();
  }
  return result;
}

String _allCorpusText(Directory workspace) =>
    _corpusBytes(workspace).values.expand((bytes) => bytes).map(String.fromCharCode).join();

void _writeSizedObservation(File file, String date, int index, int length) {
  const codec = MemoryMarkdownCodec();
  MemoryObservationDocument document(String content) => MemoryObservationDocument(
    date: date,
    observations: [
      MemoryObservation(
        id: '00000000-0000-4000-8000-${(index + 1).toString().padLeft(12, '0')}',
        recorded: DateTime.parse('${date}T12:00:00Z'),
        content: content,
        trustLabel: 'untrusted-user-content',
        provenance: MemorySourceRef(sourceLocator: 'test'),
      ),
    ],
  );
  final overhead = utf8.encode(codec.render(document('x'))).length - 1;
  file.writeAsStringSync(codec.render(document('x' * (length - overhead))));
}
