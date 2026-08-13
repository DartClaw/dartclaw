import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_core/src/memory/memory_corpus_service.dart'
    show MemoryCorpusPostCommitException, MemoryCorpusRecoveryRequired, MemoryCorpusTransition;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'canonical_memory_test.dart' show collectionId, entry, entryId, updated;

CanonicalMemoryCorpus _corpus({int revision = 12, String summary = 'Prefers concise answers'}) {
  final detail = entry();
  return CanonicalMemoryCorpus(
    index: MemoryIndexDocument(
      metadata: MemoryCollectionMetadata(collectionId: collectionId, revision: revision),
      entries: [
        MemoryIndexEntry(
          id: entryId,
          revision: detail.revision,
          topic: detail.topic,
          summary: summary,
          updated: detail.updated,
        ),
      ],
    ),
    topics: [
      MemoryTopicDocument(
        topic: 'preferences',
        entries: [
          CanonicalMemoryEntry(
            id: detail.id,
            revision: detail.revision,
            topic: detail.topic,
            summary: summary,
            content: detail.content,
            created: detail.created,
            updated: detail.updated,
            provenance: detail.provenance,
          ),
        ],
      ),
    ],
    archive: MemoryArchiveDocument(),
  );
}

CanonicalMemoryCorpus _allRoleCorpus() {
  final base = _corpus(revision: 16);
  return CanonicalMemoryCorpus(
    index: base.index,
    topics: base.topics,
    archive: base.archive,
    observations: [
      MemoryObservationDocument(
        date: '2026-08-11',
        observations: [
          MemoryObservation(
            id: '1166a7c8-2e4d-4c0c-bbf1-3aa5258b6019',
            recorded: updated,
            content: 'Observed preference',
            trustLabel: 'untrusted-user-content',
            provenance: MemorySourceRef(sourceLocator: 'journal/manual'),
          ),
        ],
      ),
    ],
    learnings: MemoryLearningDocument(
      entries: [
        CanonicalMemoryLearning(
          id: '09c311ca-e544-4488-906d-f521e764560f',
          revision: 1,
          summary: 'Parser lesson',
          content: 'Preserve canonical fields.',
          created: updated,
          updated: updated,
          provenance: MemorySourceRef(originKind: MemoryOriginKind.migration, sourceLocator: 'legacy/learnings.md'),
        ),
      ],
    ),
  );
}

CanonicalMemoryCorpus _corpusWithLegacy({
  int revision = 14,
  String summary = 'Prefers concise answers',
  String legacy = 'legacy',
}) {
  final base = _corpus(revision: revision, summary: summary);
  return CanonicalMemoryCorpus(
    index: base.index,
    topics: base.topics,
    archive: base.archive,
    verbatimMembers: [VerbatimMemoryMember(path: 'memory/legacy/raw.md', bytes: utf8.encode(legacy))],
  );
}

void _writeCorpus(Directory workspace, CanonicalMemoryCorpus corpus) {
  for (final member in corpus.byteInventory().entries) {
    final file = File(p.join(workspace.path, member.key));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(member.value, flush: true);
  }
}

void main() {
  late Directory workspace;

  setUp(() => workspace = Directory.systemTemp.createTempSync('memory_corpus_service_'));
  tearDown(() {
    if (workspace.existsSync()) workspace.deleteSync(recursive: true);
  });

  test('bounded snapshot does not read a document omitted by either budget', () async {
    _writeCorpus(workspace, _corpus());
    final authority = MemoryCorpusService(workspaceDir: workspace.path);
    await authority.snapshot(paths: const ['MEMORY.md'], maxDocuments: 1, maxBytes: 1024 * 1024);
    await authority.close();

    final reads = <String>[];
    final reopened = MemoryCorpusService(workspaceDir: workspace.path, readObserver: reads.add);
    await reopened.snapshot(paths: const ['MEMORY.md'], maxDocuments: 1, maxBytes: 1024 * 1024);
    reads.clear();
    final countBound = await reopened.snapshot(
      paths: const ['MEMORY.md', 'memory/topics/preferences.md', 'MEMORY.archive.md'],
      maxDocuments: 2,
      maxBytes: 1024 * 1024,
    );
    expect(countBound.documents.keys, ['MEMORY.md', 'memory/topics/preferences.md']);
    expect(countBound.omissions.single.reason, MemorySnapshotOmissionReason.documentLimit);
    expect(reads, isNot(contains('MEMORY.archive.md')));

    reads.clear();
    final indexLength = File(p.join(workspace.path, 'MEMORY.md')).lengthSync();
    final topicLength = File(p.join(workspace.path, 'memory/topics/preferences.md')).lengthSync();
    final byteBound = await reopened.snapshot(
      paths: const ['MEMORY.md', 'memory/topics/preferences.md', 'MEMORY.archive.md'],
      maxDocuments: 3,
      maxBytes: indexLength + topicLength,
    );
    expect(byteBound.documents.keys, ['MEMORY.md', 'memory/topics/preferences.md']);
    expect(byteBound.omissions.single.reason, MemorySnapshotOmissionReason.aggregateByteLimit);
    expect(reads, isNot(contains('MEMORY.archive.md')));
    expect(byteBound.collectionRevision, 12);
    await reopened.close();
  });

  test('bounded index prefix never invokes the whole-document read seam', () async {
    _writeCorpus(workspace, _corpus());
    final initial = MemoryCorpusService(workspaceDir: workspace.path);
    await initial.snapshot(paths: const ['MEMORY.md'], maxDocuments: 1, maxBytes: 1024 * 1024);
    await initial.close();
    final indexLength = File(p.join(workspace.path, 'MEMORY.md')).lengthSync();
    final maxBytes = indexLength - 1;
    final authority = MemoryCorpusService(
      workspaceDir: workspace.path,
      readObserver: (path) => throw StateError('whole document read: $path'),
    );

    final snapshot = await authority.snapshot(
      paths: const ['MEMORY.md'],
      maxDocuments: 1,
      maxBytes: maxBytes,
      allowIndexPrefix: true,
    );

    expect(snapshot.documents['MEMORY.md'], hasLength(maxBytes));
    expect(snapshot.prefixDocuments, {'MEMORY.md'});
    expect(snapshot.collectionRevision, 12);
    await authority.close();
  });

  test('multi-document change commits as exactly one revision', () async {
    _writeCorpus(workspace, _corpus());
    final authority = MemoryCorpusService(workspaceDir: workspace.path);
    await authority.snapshot(paths: const ['MEMORY.md'], maxDocuments: 1, maxBytes: 1024 * 1024);

    final result = await authority.commit(expectedRevision: 12, replacement: _corpus(summary: 'Uses brief answers'));
    expect(result.wasCommitted, isTrue);
    expect(result.collectionRevision, 13);
    final snapshot = await authority.snapshot(
      paths: const ['MEMORY.md', 'memory/topics/preferences.md', 'MEMORY.archive.md'],
      maxDocuments: 3,
      maxBytes: 1024 * 1024,
    );
    expect(snapshot.collectionRevision, 13);
    expect(utf8.decode(snapshot.documents['MEMORY.md']!), contains('Uses brief answers'));
    expect(utf8.decode(snapshot.documents['memory/topics/preferences.md']!), contains('Uses brief answers'));
    expect(result.fingerprint, snapshot.fingerprint);
    await authority.close();
  });

  test('invalid resulting corpus writes and indexes nothing', () async {
    _writeCorpus(workspace, _corpus());
    var derivedCalls = 0;
    final before = File(p.join(workspace.path, 'MEMORY.md')).readAsBytesSync();
    final invalid = CanonicalMemoryCorpus(
      index: _corpus().index,
      topics: _corpus().topics,
      archive: MemoryArchiveDocument(entries: [entry()]),
    );
    final authority = MemoryCorpusService(workspaceDir: workspace.path);
    await expectLater(
      authority.commit(expectedRevision: 12, replacement: invalid, afterCommit: (_) => derivedCalls++),
      throwsA(isA<MemoryCorpusValidationException>()),
    );
    expect(File(p.join(workspace.path, 'MEMORY.md')).readAsBytesSync(), before);
    expect(derivedCalls, 0);
    expect(File(p.join(workspace.path, '.dartclaw-memory-transaction.json')).existsSync(), isFalse);
    await authority.close();
  });

  test('sparse change cannot alter an unopened topic index row', () async {
    const otherId = 'c5ed3fde-f4c2-4c80-a637-011e18ff307a';
    final first = entry();
    final other = CanonicalMemoryEntry(
      id: otherId,
      revision: 1,
      topic: 'other',
      summary: 'Other summary',
      content: 'Other content',
      created: updated,
      updated: updated,
      provenance: MemorySourceRef(sourceLocator: 'test/other'),
    );
    final corpus = CanonicalMemoryCorpus(
      index: MemoryIndexDocument(
        metadata: MemoryCollectionMetadata(collectionId: collectionId, revision: 12),
        entries: [
          MemoryIndexEntry(
            id: first.id,
            revision: first.revision,
            topic: first.topic,
            summary: first.summary,
            updated: first.updated,
          ),
          MemoryIndexEntry(
            id: other.id,
            revision: other.revision,
            topic: other.topic,
            summary: other.summary,
            updated: other.updated,
          ),
        ],
      ),
      topics: [
        MemoryTopicDocument(topic: first.topic, entries: [first]),
        MemoryTopicDocument(topic: other.topic, entries: [other]),
      ],
    );
    _writeCorpus(workspace, corpus);
    final transitions = <MemoryCorpusTransition>[];
    final authority = MemoryCorpusService(
      workspaceDir: workspace.path,
      transitionHook: (transition, _) => transitions.add(transition),
    );
    final manifest = await authority.manifest();
    transitions.clear();
    final before = _tree(workspace);

    await expectLater(
      authority.changeSelected<void>(
        expectedRevision: manifest.collectionRevision,
        include: (_, path) => path == 'memory/topics/preferences.md',
        prepare: (selected) => MemoryCorpusChange(
          value: null,
          replacement: CanonicalMemoryCorpus(
            index: MemoryIndexDocument(
              metadata: selected.index.metadata,
              entries: selected.index.entries.map(
                (row) => row.id == otherId
                    ? MemoryIndexEntry(
                        id: row.id,
                        revision: row.revision,
                        topic: row.topic,
                        summary: 'Tampered unopened summary',
                        updated: row.updated,
                        priority: row.priority,
                      )
                    : row,
              ),
            ),
            topics: selected.topics,
          ),
        ),
      ),
      throwsA(
        isA<MemoryCorpusValidationException>().having(
          (error) => error.errors,
          'errors',
          contains('index row outside selected ownership changed: $otherId'),
        ),
      ),
    );

    expect(transitions, isEmpty);
    expect(_tree(workspace), before);
    expect((await authority.manifest()).collectionRevision, 12);
    await authority.close();
    final reopened = MemoryCorpusService(workspaceDir: workspace.path);
    expect((await reopened.manifest()).collectionRevision, 12);
    await reopened.close();
  });

  test('real-path and symlink contenders have one CAS winner', () async {
    if (Platform.isWindows) return;
    _writeCorpus(workspace, _corpus());
    final alias = Link('${workspace.path}-alias')..createSync(workspace.path);
    addTearDown(() {
      if (alias.existsSync()) alias.deleteSync();
    });
    final first = MemoryCorpusService(workspaceDir: workspace.path);
    final second = MemoryCorpusService(workspaceDir: alias.path);
    await Future.wait([
      first.snapshot(paths: const ['MEMORY.md'], maxDocuments: 1, maxBytes: 1024 * 1024),
      second.snapshot(paths: const ['MEMORY.md'], maxDocuments: 1, maxBytes: 1024 * 1024),
    ]);
    final results = await Future.wait([
      first.commit(expectedRevision: 12, replacement: _corpus(summary: 'First winner')),
      second.commit(expectedRevision: 12, replacement: _corpus(summary: 'Second winner')),
    ]);
    expect(results.where((result) => result.wasCommitted), hasLength(1));
    expect(results.where((result) => !result.wasCommitted).single.collectionRevision, 13);
    final markdown = File(p.join(workspace.path, 'MEMORY.md')).readAsStringSync();
    expect(markdown.contains('First winner') ^ markdown.contains('Second winner'), isTrue);
    await first.close();
    await second.close();
  });

  test('every pre-marker failure restores old bytes and retry advances once', () async {
    for (final transition in [
      MemoryCorpusTransition.stageWritten,
      MemoryCorpusTransition.backupWritten,
      MemoryCorpusTransition.targetReplaced,
      MemoryCorpusTransition.beforeCommitMarker,
    ]) {
      final caseDir = Directory(p.join(workspace.path, transition.name))..createSync();
      _writeCorpus(caseDir, _corpus(revision: 14));
      final before = _tree(caseDir);
      var failed = false;
      final authority = MemoryCorpusService(
        workspaceDir: caseDir.path,
        transitionHook: (actual, _) {
          if (!failed && actual == transition) {
            failed = true;
            throw StateError('injected ${transition.name}');
          }
        },
      );
      await expectLater(
        authority.commit(expectedRevision: 14, replacement: _corpus(revision: 14, summary: 'Changed')),
        throwsStateError,
        reason: transition.name,
      );
      expect(_canonicalTree(caseDir), _canonicalTreeFrom(before), reason: transition.name);
      await authority.close();

      final retry = MemoryCorpusService(workspaceDir: caseDir.path);
      final result = await retry.commit(expectedRevision: 14, replacement: _corpus(revision: 14, summary: 'Changed'));
      expect(result.collectionRevision, 15, reason: transition.name);
      await retry.close();
    }
  });

  test('restart recovery returns old pre-marker and new post-marker corpora', () async {
    for (final transition in [
      MemoryCorpusTransition.beforeCommitMarker,
      MemoryCorpusTransition.commitMarkerReplaced,
      MemoryCorpusTransition.beforeCleanup,
    ]) {
      final caseDir = Directory(p.join(workspace.path, transition.name))..createSync();
      _writeCorpus(caseDir, _corpus(revision: 15));
      var crashed = false;
      final authority = MemoryCorpusService(
        workspaceDir: caseDir.path,
        transitionHook: (actual, _) {
          if (!crashed && actual == transition) {
            crashed = true;
            throw MemoryCorpusSimulatedCrash(actual);
          }
        },
      );
      await expectLater(
        authority.commit(expectedRevision: 15, replacement: _corpus(revision: 15, summary: 'Committed')),
        throwsA(isA<MemoryCorpusSimulatedCrash>()),
      );
      await authority.close();

      final reopened = MemoryCorpusService(workspaceDir: caseDir.path);
      final snapshot = await reopened.snapshot(
        paths: const ['MEMORY.md', 'memory/topics/preferences.md'],
        maxDocuments: 2,
        maxBytes: 1024 * 1024,
      );
      final expectedRevision = transition == MemoryCorpusTransition.beforeCommitMarker ? 15 : 16;
      expect(snapshot.collectionRevision, expectedRevision, reason: transition.name);
      for (final bytes in snapshot.documents.values) {
        expect(utf8.decode(bytes).contains('Committed'), expectedRevision == 16, reason: transition.name);
      }
      expect(File(p.join(caseDir.path, '.dartclaw-memory-transaction.json')).existsSync(), isFalse);
      await reopened.close();
    }
  });

  test('injects ordinary failure at every pre-marker target transition occurrence', () async {
    final targets = const [
      (MemoryCorpusTransition.stageWritten, 'MEMORY.md'),
      (MemoryCorpusTransition.stageWritten, 'memory/legacy/raw.md'),
      (MemoryCorpusTransition.stageWritten, 'memory/topics/preferences.md'),
      (MemoryCorpusTransition.backupWritten, 'MEMORY.md'),
      (MemoryCorpusTransition.backupWritten, 'memory/legacy/raw.md'),
      (MemoryCorpusTransition.backupWritten, 'memory/topics/preferences.md'),
      (MemoryCorpusTransition.targetReplaced, 'memory/legacy/raw.md'),
      (MemoryCorpusTransition.targetReplaced, 'memory/topics/preferences.md'),
      (MemoryCorpusTransition.beforeCommitMarker, 'MEMORY.md'),
    ];
    for (var index = 0; index < targets.length; index++) {
      final target = targets[index];
      final caseDir = Directory(p.join(workspace.path, 'fault-$index'))..createSync();
      _writeCorpus(caseDir, _corpusWithLegacy());
      final before = _canonicalTree(caseDir);
      var injected = false;
      final authority = MemoryCorpusService(
        workspaceDir: caseDir.path,
        transitionHook: (transition, path) {
          if (!injected && transition == target.$1 && path == target.$2) {
            injected = true;
            throw StateError('injected ${transition.name} $path');
          }
        },
      );
      await expectLater(
        authority.commit(
          expectedRevision: 14,
          replacement: _corpusWithLegacy(summary: 'Changed', legacy: 'changed'),
        ),
        throwsStateError,
        reason: '${target.$1.name} ${target.$2}',
      );
      expect(injected, isTrue, reason: '${target.$1.name} ${target.$2}');
      expect(_canonicalTree(caseDir), before, reason: '${target.$1.name} ${target.$2}');
      await authority.close();
    }
  });

  test('ordinary post-marker failures acknowledge the revision recovery proved durable', () async {
    final targets = const [
      (MemoryCorpusTransition.targetReplaced, 'MEMORY.md'),
      (MemoryCorpusTransition.commitMarkerReplaced, 'MEMORY.md'),
      (MemoryCorpusTransition.fingerprintRecorded, '.dartclaw-memory-corpus.json'),
      (MemoryCorpusTransition.beforeCleanup, '.dartclaw-memory-transaction.json'),
    ];
    for (var index = 0; index < targets.length; index++) {
      final target = targets[index];
      final caseDir = Directory(p.join(workspace.path, 'recovered-$index'))..createSync();
      _writeCorpus(caseDir, _corpus(revision: 14));
      var injected = false;
      var derivedCalls = 0;
      final authority = MemoryCorpusService(
        workspaceDir: caseDir.path,
        transitionHook: (transition, path) {
          if (!injected && transition == target.$1 && path == target.$2) {
            injected = true;
            throw StateError('ordinary post-marker failure');
          }
        },
      );

      final result = await authority.commit(
        expectedRevision: 14,
        replacement: _corpus(revision: 14, summary: 'Recovered commit'),
        afterCommit: (_) => derivedCalls++,
      );

      expect(result.wasCommitted, isTrue, reason: '${target.$1.name} ${target.$2}');
      expect(result.collectionRevision, 15, reason: '${target.$1.name} ${target.$2}');
      expect(derivedCalls, 1, reason: '${target.$1.name} ${target.$2}');
      expect((await authority.readCorpus()).index.entries.single.summary, 'Recovered commit');
      await authority.close();
    }
  });

  test('canonical updateFiles acknowledges the recovered post-marker target', () async {
    final targets = const [
      (MemoryCorpusTransition.targetReplaced, 'MEMORY.md'),
      (MemoryCorpusTransition.commitMarkerReplaced, 'MEMORY.md'),
      (MemoryCorpusTransition.fingerprintRecorded, '.dartclaw-memory-corpus.json'),
      (MemoryCorpusTransition.beforeCleanup, '.dartclaw-memory-transaction.json'),
    ];
    for (var index = 0; index < targets.length; index++) {
      final target = targets[index];
      final caseDir = Directory(p.join(workspace.path, 'update-files-recovered-$index'))..createSync();
      _writeCorpus(caseDir, _corpus(revision: 14));
      var injected = false;
      var projected = 0;
      final authority = MemoryCorpusService(
        workspaceDir: caseDir.path,
        transitionHook: (transition, path) {
          if (!injected && transition == target.$1 && path == target.$2) {
            injected = true;
            throw StateError('ordinary post-marker failure');
          }
        },
      );
      final value = await authority.updateFiles<String>(
        paths: const [],
        prepare: (_) => throw StateError('legacy prepare must not run'),
        prepareCanonical: (_) => MemoryCorpusMutation(
          value: 'acknowledged',
          corpus: _corpus(revision: 14, summary: 'Recovered updateFiles'),
        ),
        afterCommit: (_) => projected++,
      );
      expect(value, 'acknowledged', reason: '${target.$1.name} ${target.$2}');
      expect(projected, 1, reason: '${target.$1.name} ${target.$2}');
      expect((await authority.readCorpus()).index.entries.single.summary, 'Recovered updateFiles');
      await authority.close();
    }
  });

  test('restart recovery covers every replacement and post-marker transition occurrence', () async {
    final targets = const [
      (MemoryCorpusTransition.targetReplaced, 'memory/legacy/raw.md', false),
      (MemoryCorpusTransition.targetReplaced, 'memory/topics/preferences.md', false),
      (MemoryCorpusTransition.beforeCommitMarker, 'MEMORY.md', false),
      (MemoryCorpusTransition.targetReplaced, 'MEMORY.md', true),
      (MemoryCorpusTransition.commitMarkerReplaced, 'MEMORY.md', true),
      (MemoryCorpusTransition.fingerprintRecorded, '.dartclaw-memory-corpus.json', true),
      (MemoryCorpusTransition.beforeCleanup, '.dartclaw-memory-transaction.json', true),
    ];
    for (var index = 0; index < targets.length; index++) {
      final target = targets[index];
      final caseDir = Directory(p.join(workspace.path, 'crash-$index'))..createSync();
      _writeCorpus(caseDir, _corpusWithLegacy(revision: 15));
      var injected = false;
      final authority = MemoryCorpusService(
        workspaceDir: caseDir.path,
        transitionHook: (transition, path) {
          if (!injected && transition == target.$1 && path == target.$2) {
            injected = true;
            throw MemoryCorpusSimulatedCrash(transition);
          }
        },
      );
      await expectLater(
        authority.commit(
          expectedRevision: 15,
          replacement: _corpusWithLegacy(revision: 15, summary: 'Committed', legacy: 'committed'),
        ),
        throwsA(isA<MemoryCorpusSimulatedCrash>()),
        reason: '${target.$1.name} ${target.$2}',
      );
      await authority.close();

      final reopened = MemoryCorpusService(workspaceDir: caseDir.path);
      final snapshot = await reopened.snapshot(
        paths: const ['MEMORY.md', 'memory/topics/preferences.md', 'memory/legacy/raw.md'],
        maxDocuments: 3,
        maxBytes: 1024 * 1024,
      );
      expect(snapshot.collectionRevision, target.$3 ? 16 : 15, reason: '${target.$1.name} ${target.$2}');
      for (final bytes in snapshot.documents.values) {
        expect(
          utf8.decode(bytes).toLowerCase().contains('committed'),
          target.$3,
          reason: '${target.$1.name} ${target.$2}',
        );
      }
      expect(File(p.join(caseDir.path, '.dartclaw-memory-transaction.json')).existsSync(), isFalse);
      await reopened.close();
    }
  });

  test('stopped edit advances once, reports role, and rejects stale CAS', () async {
    final base = _corpus(revision: 16);
    _writeCorpus(workspace, base);
    final initial = MemoryCorpusService(workspaceDir: workspace.path);
    await initial.snapshot(paths: const ['MEMORY.md'], maxDocuments: 1, maxBytes: 1024 * 1024);
    await initial.close();

    final topic = File(p.join(workspace.path, 'memory/topics/preferences.md'));
    topic.writeAsStringSync(topic.readAsStringSync().replaceFirst('Use concise answers.', 'Use direct answers.'));
    final reopened = MemoryCorpusService(workspaceDir: workspace.path);
    final snapshot = await reopened.snapshot(
      paths: const ['MEMORY.md', 'memory/topics/preferences.md'],
      maxDocuments: 2,
      maxBytes: 1024 * 1024,
    );
    expect(snapshot.collectionRevision, 17);
    expect(snapshot.externalChanges, hasLength(1));
    expect(snapshot.externalChanges.single.role, MemoryRole.topic);
    expect(snapshot.externalChanges.single.locator, 'memory/topics/preferences.md');
    final stale = await reopened.commit(expectedRevision: 16, replacement: base);
    expect(stale.wasCommitted, isFalse);
    expect(stale.collectionRevision, 17);
    await reopened.close();
  });

  test('reopened service authenticates same-size stopped edits with restored mtime', () async {
    final base = _corpus(revision: 16);
    _writeCorpus(workspace, base);
    final initial = MemoryCorpusService(workspaceDir: workspace.path);
    await initial.snapshot(paths: const ['MEMORY.md'], maxDocuments: 1, maxBytes: 1024 * 1024);
    await initial.close();

    final topic = File(p.join(workspace.path, 'memory/topics/preferences.md'));
    final originalModified = topic.lastModifiedSync();
    final originalBytes = topic.readAsBytesSync();
    final changedBytes = Uint8List.fromList(
      utf8.encode(utf8.decode(originalBytes).replaceFirst('Use concise answers.', 'Use compact answers.')),
    );
    expect(changedBytes, hasLength(originalBytes.length));
    topic.writeAsBytesSync(changedBytes, flush: true);
    topic.setLastModifiedSync(originalModified);

    final reopened = MemoryCorpusService(workspaceDir: workspace.path);
    final snapshot = await reopened.snapshot(
      paths: const ['MEMORY.md', 'memory/topics/preferences.md'],
      maxDocuments: 2,
      maxBytes: 1024 * 1024,
    );

    expect(snapshot.collectionRevision, 17);
    expect(snapshot.externalChanges.single.locator, 'memory/topics/preferences.md');
    expect(utf8.decode(snapshot.documents['memory/topics/preferences.md']!), contains('Use compact answers.'));
    await reopened.close();
  });

  test('reconciles runtime-learning and dated-observation edits and deletion', () async {
    final cases = <({String path, MemoryRole role, bool remove})>[
      (path: 'learnings.md', role: MemoryRole.learning, remove: false),
      (path: 'memory/2026-08-11.md', role: MemoryRole.observation, remove: false),
      (path: 'memory/2026-08-11.md', role: MemoryRole.observation, remove: true),
    ];
    for (var index = 0; index < cases.length; index++) {
      final testCase = cases[index];
      final caseDir = Directory(p.join(workspace.path, '$index'))..createSync();
      _writeCorpus(caseDir, _allRoleCorpus());
      final initial = MemoryCorpusService(workspaceDir: caseDir.path);
      await initial.snapshot(paths: const ['MEMORY.md'], maxDocuments: 1, maxBytes: 1024 * 1024);
      await initial.close();

      final file = File(p.join(caseDir.path, testCase.path));
      if (testCase.remove) {
        file.deleteSync();
      } else {
        file.writeAsStringSync(
          file.readAsStringSync().replaceFirst('Preserve', 'Keep').replaceFirst('Observed', 'Saw'),
        );
      }
      final reopened = MemoryCorpusService(workspaceDir: caseDir.path);
      final snapshot = await reopened.snapshot(paths: const ['MEMORY.md'], maxDocuments: 1, maxBytes: 1024 * 1024);
      expect(snapshot.collectionRevision, 17, reason: testCase.path);
      expect(snapshot.externalChanges.single.role, testCase.role, reason: testCase.path);
      expect(snapshot.externalChanges.single.locator, testCase.path, reason: testCase.path);
      expect(snapshot.externalChanges.single.wasRemoved, testCase.remove, reason: testCase.path);
      await reopened.close();
    }
  });

  test('invalid stopped edit leaves bytes and revision untouched', () async {
    _writeCorpus(workspace, _corpus(revision: 16));
    final initial = MemoryCorpusService(workspaceDir: workspace.path);
    await initial.snapshot(paths: const ['MEMORY.md'], maxDocuments: 1, maxBytes: 1024 * 1024);
    await initial.close();
    final index = File(p.join(workspace.path, 'MEMORY.md'));
    final before = index.readAsBytesSync();
    File(p.join(workspace.path, 'memory/topics/preferences.md')).writeAsStringSync('invalid canonical markdown');

    final reopened = MemoryCorpusService(workspaceDir: workspace.path);
    await expectLater(
      reopened.snapshot(paths: const ['MEMORY.md'], maxDocuments: 1, maxBytes: 1024 * 1024),
      throwsA(isA<MemoryCorpusRecoveryRequired>()),
    );
    expect(index.readAsBytesSync(), before);
    await reopened.close();
  });

  test('bootstrap starts at one and missing fingerprint adopts current revision', () async {
    Directory(p.join(workspace.path, 'memory')).createSync();
    final fresh = MemoryCorpusService(workspaceDir: workspace.path);
    final bootstrapped = await fresh.snapshot(paths: const ['MEMORY.md'], maxDocuments: 1, maxBytes: 1024 * 1024);
    expect(bootstrapped.collectionRevision, 1);
    expect(bootstrapped.externalChanges, isEmpty);
    await fresh.close();

    final state = File(p.join(workspace.path, '.dartclaw-memory-corpus.json'))..deleteSync();
    final reopened = MemoryCorpusService(workspaceDir: workspace.path);
    final adopted = await reopened.snapshot(paths: const ['MEMORY.md'], maxDocuments: 1, maxBytes: 1024 * 1024);
    expect(adopted.collectionRevision, 1);
    expect(adopted.externalChanges, isEmpty);
    expect(state.existsSync(), isTrue);
    await reopened.close();
  });

  test('snapshot ignores non-corpus selectors and deduplicates canonical selectors', () async {
    _writeCorpus(workspace, _corpus());
    File(p.join(workspace.path, 'secret.txt')).writeAsStringSync('do not read');
    final reads = <String>[];
    final authority = MemoryCorpusService(workspaceDir: workspace.path, readObserver: reads.add);
    final snapshot = await authority.snapshot(
      paths: const ['secret.txt', 'MEMORY.md', 'MEMORY.md'],
      maxDocuments: 3,
      maxBytes: 1024 * 1024,
    );
    expect(snapshot.documents.keys, ['MEMORY.md']);
    expect(reads, ['MEMORY.md']);
    await authority.close();
  });

  test('post-commit failure reports the durable canonical result', () async {
    _writeCorpus(workspace, _corpus());
    final authority = MemoryCorpusService(workspaceDir: workspace.path);
    await expectLater(
      authority.commit(
        expectedRevision: 12,
        replacement: _corpus(summary: 'Committed before index failure'),
        afterCommit: (_) => throw StateError('derived index failed'),
      ),
      throwsA(
        isA<MemoryCorpusPostCommitException>().having(
          (error) => error.result.collectionRevision,
          'committed revision',
          13,
        ),
      ),
    );
    final snapshot = await authority.snapshot(paths: const ['MEMORY.md'], maxDocuments: 1, maxBytes: 1024 * 1024);
    expect(snapshot.collectionRevision, 13);
    await authority.close();
  });

  test('fresh-workspace writers bootstrap before entering the canonical mutation path', () async {
    final authority = MemoryCorpusService(workspaceDir: workspace.path);
    final files = MemoryFileService(baseDir: workspace.path, corpusService: authority);

    await files.appendDailyLog('Bootstrapped canonical memory');

    final index = const MemoryMarkdownCodec().parse(File(p.join(workspace.path, 'MEMORY.md')).readAsStringSync());
    expect(index, isA<MemoryIndexDocument>().having((document) => document.metadata.revision, 'revision', 2));
    expect(File(p.join(workspace.path, '.dartclaw-memory-corpus.json')).existsSync(), isTrue);
    await authority.close();
  });

  test('malformed canonical marker without sidecar never enters the legacy fallback', () async {
    for (final lineEnding in ['\n', '\r\n', '\r']) {
      final caseDir = Directory(p.join(workspace.path, lineEnding.codeUnits.join('-')))..createSync();
      final index = File(p.join(caseDir.path, 'MEMORY.md'))
        ..writeAsStringSync('# DartClaw Canonical Memory${lineEnding}invalid$lineEnding');
      final before = index.readAsBytesSync();
      final authority = MemoryCorpusService(workspaceDir: caseDir.path);
      final files = MemoryFileService(baseDir: caseDir.path, corpusService: authority);

      await expectLater(files.appendDailyLog('Must not bypass recovery'), throwsA(isA<MemoryCorpusRecoveryRequired>()));

      expect(index.readAsBytesSync(), before, reason: lineEnding.codeUnits.toString());
      await authority.close();
    }
  });

  test('snapshot metadata check does not recurse into non-canonical subtrees', () async {
    _writeCorpus(workspace, _corpus());
    final initial = MemoryCorpusService(workspaceDir: workspace.path);
    await initial.snapshot(paths: const ['MEMORY.md'], maxDocuments: 1, maxBytes: 1024 * 1024);
    await initial.close();
    final unrelated = Directory(p.join(workspace.path, 'memory', 'unrelated', 'deep'))..createSync(recursive: true);
    for (var index = 0; index < 1100; index++) {
      File(p.join(unrelated.path, '$index.txt')).writeAsStringSync('not canonical');
    }

    final reopened = MemoryCorpusService(workspaceDir: workspace.path);
    final snapshot = await reopened.snapshot(paths: const ['MEMORY.md'], maxDocuments: 1, maxBytes: 1024 * 1024);

    expect(snapshot.collectionRevision, 12);
    await reopened.close();
  });

  test('authentication rejects symlinked canonical subtree roots without reading targets', () async {
    if (Platform.isWindows) return;
    for (final subtree in ['memory', 'memory/topics', 'memory/legacy']) {
      final caseDir = Directory(p.join(workspace.path, subtree.replaceAll('/', '-')))..createSync();
      final corpus = subtree == 'memory/legacy' ? _corpusWithLegacy() : _corpus();
      _writeCorpus(caseDir, corpus);
      final target = Directory.systemTemp.createTempSync('memory_corpus_symlink_target_');
      addTearDown(() {
        if (target.existsSync()) target.deleteSync(recursive: true);
      });
      final subtreeDirectory = Directory(p.join(caseDir.path, subtree));
      for (final entity in subtreeDirectory.listSync(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        final relative = p.relative(entity.path, from: subtreeDirectory.path);
        final copy = File(p.join(target.path, relative))..parent.createSync(recursive: true);
        copy.writeAsBytesSync(entity.readAsBytesSync());
      }
      subtreeDirectory.deleteSync(recursive: true);
      Link(subtreeDirectory.path).createSync(target.path);
      final reads = <String>[];
      final authority = MemoryCorpusService(workspaceDir: caseDir.path, readObserver: reads.add);

      await expectLater(
        authority.selectDocuments(include: (_, _) => true),
        throwsA(
          isA<MemoryCorpusRecoveryRequired>().having(
            (error) => error.message,
            'message',
            contains('not a regular directory'),
          ),
        ),
        reason: subtree,
      );

      expect(reads, isNot(contains('memory/topics/preferences.md')), reason: subtree);
      expect(reads, isNot(contains('memory/legacy/raw.md')), reason: subtree);
      await authority.close();
    }
  });

  test('canonical daily observation preserves the captured instant', () async {
    final authority = MemoryCorpusService(workspaceDir: workspace.path);
    final files = MemoryFileService(baseDir: workspace.path, corpusService: authority);
    final before = DateTime.now().toUtc();

    await files.appendDailyLog('Observed at this instant');

    final observationFile = Directory(
      p.join(workspace.path, 'memory'),
    ).listSync().whereType<File>().singleWhere((file) => RegExp(r'\d{4}-\d{2}-\d{2}\.md$').hasMatch(file.path));
    final document = const MemoryMarkdownCodec().parse(observationFile.readAsStringSync()) as MemoryObservationDocument;
    final recorded = document.observations.single.recorded;
    expect(recorded.isUtc, isTrue);
    expect(recorded.isBefore(before), isFalse);
    expect(recorded.isAfter(DateTime.now().toUtc().add(const Duration(seconds: 1))), isFalse);
    await authority.close();
  });

  test('legacy source ceilings fail before reads, preparation, or artifacts', () async {
    final first = File(p.join(workspace.path, 'MEMORY.md'));
    final second = File(p.join(workspace.path, 'learnings.md'));
    _writeSparse(first, MemoryCorpusService.maxCorpusBytes ~/ 2 + 1);
    _writeSparse(second, MemoryCorpusService.maxCorpusBytes ~/ 2);
    final reads = <String>[];
    var prepared = false;
    final authority = MemoryCorpusService(workspaceDir: workspace.path, readObserver: reads.add);

    await expectLater(
      authority.updateFiles<void>(
        paths: const ['MEMORY.md', 'learnings.md'],
        prepare: (_) {
          prepared = true;
          return MemoryCorpusFileMutation(value: null, writes: const {});
        },
      ),
      throwsA(isA<MemoryCorpusRecoveryRequired>().having((error) => error.message, 'message', contains('aggregate'))),
    );

    expect(prepared, isFalse);
    expect(reads, isEmpty);
    expect(_tree(workspace).keys, {'MEMORY.md', 'learnings.md'});
    await authority.close();
  });

  test('legacy member limit plus one fails before preparation or artifacts', () async {
    final source = File(p.join(workspace.path, 'MEMORY.md'));
    _writeSparse(source, MemoryCorpusService.maxCorpusBytes + 1);
    var prepared = false;
    final authority = MemoryCorpusService(workspaceDir: workspace.path);

    await expectLater(
      authority.updateFiles<void>(
        paths: const ['MEMORY.md'],
        prepare: (_) {
          prepared = true;
          return MemoryCorpusFileMutation(value: null, writes: const {});
        },
      ),
      throwsA(isA<FileSystemException>().having((error) => p.basename(error.path ?? ''), 'member', 'MEMORY.md')),
    );

    expect(prepared, isFalse);
    expect(_tree(workspace).keys, {'MEMORY.md'});
    await authority.close();
  });

  test('selection allows exactly 1000 bodies and rejects the next without opening it', () async {
    final base = CanonicalMemoryCorpus(
      index: MemoryIndexDocument(metadata: MemoryCollectionMetadata(collectionId: collectionId, revision: 1)),
    );
    _writeCorpus(workspace, base);
    final codec = MemoryMarkdownCodec();
    final firstDate = DateTime.utc(2020);
    final paths = <String>[];
    for (var index = 0; index < 1000; index++) {
      final date = firstDate.add(Duration(days: index)).toIso8601String().substring(0, 10);
      final path = 'memory/$date.md';
      paths.add(path);
      final file = File(p.join(workspace.path, path))..parent.createSync(recursive: true);
      file.writeAsStringSync(codec.render(MemoryObservationDocument(date: date)));
    }
    final reads = <String>[];
    final authority = MemoryCorpusService(workspaceDir: workspace.path, readObserver: reads.add);
    await authority.manifest();
    reads.clear();
    final exact = await authority.selectPaths(paths.take(999));
    expect(exact.paths, hasLength(1000));
    expect(reads, hasLength(1000));
    reads.clear();
    await expectLater(
      authority.selectDocuments(include: (role, _) => role == MemoryRole.observation),
      throwsA(isA<MemoryCorpusRecoveryRequired>().having((error) => error.message, 'message', contains('file-count'))),
    );
    expect(reads, isNot(contains(paths.last)));
    await authority.close();
  });

  test('selection allows exactly 64 MiB and rejects one additional byte', () async {
    final base = CanonicalMemoryCorpus(
      index: MemoryIndexDocument(metadata: MemoryCollectionMetadata(collectionId: collectionId, revision: 1)),
    );
    _writeCorpus(workspace, base);
    final indexLength = File(p.join(workspace.path, 'MEMORY.md')).lengthSync();
    final paths = <String>[];
    for (var index = 0; index < 7; index++) {
      final date = '2026-08-${(index + 1).toString().padLeft(2, '0')}';
      final path = p.join(workspace.path, 'memory', '$date.md');
      paths.add(path);
      _writeSizedObservation(
        File(path),
        date,
        '00000000-0000-4000-8000-${(index + 1).toString().padLeft(12, '0')}',
        8 * 1024 * 1024,
      );
    }
    final lastPath = p.join(workspace.path, 'memory', '2026-08-08.md');
    paths.add(lastPath);
    _writeSizedObservation(
      File(lastPath),
      '2026-08-08',
      '00000000-0000-4000-8000-000000000008',
      8 * 1024 * 1024 - indexLength,
    );
    var authority = MemoryCorpusService(workspaceDir: workspace.path);
    final exact = await authority.selectDocuments(include: (role, _) => role == MemoryRole.observation);
    expect(exact.paths, hasLength(9));
    expect(indexLength + paths.fold<int>(0, (total, path) => total + File(path).lengthSync()), 64 * 1024 * 1024);
    await authority.close();

    _writeSizedObservation(
      File(lastPath),
      '2026-08-08',
      '00000000-0000-4000-8000-000000000008',
      8 * 1024 * 1024 - indexLength + 1,
    );
    authority = MemoryCorpusService(workspaceDir: workspace.path);
    await expectLater(
      authority.selectDocuments(include: (role, _) => role == MemoryRole.observation),
      throwsA(isA<MemoryCorpusRecoveryRequired>().having((error) => error.message, 'message', contains('aggregate'))),
    );
    await authority.close();
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('first-process authentication rejects semantically forged manifest metadata', () async {
    _writeCorpus(workspace, _corpus());
    var authority = MemoryCorpusService(workspaceDir: workspace.path);
    await authority.manifest();
    await authority.close();
    final stateFile = File(p.join(workspace.path, '.dartclaw-memory-corpus.json'));
    final original = jsonDecode(stateFile.readAsStringSync()) as Map<String, dynamic>;
    final variants = <void Function(Map<String, dynamic>)>[
      (state) =>
          ((state['members'] as Map<String, dynamic>)['memory/topics/preferences.md'] as Map<String, dynamic>)['role'] =
              'archive',
      (state) =>
          ((state['members'] as Map<String, dynamic>)['memory/topics/preferences.md']
                  as Map<String, dynamic>)['recordIds'] =
              const <String>[],
      (state) => ((state['members'] as Map<String, dynamic>)['MEMORY.md'] as Map<String, dynamic>)['length'] = -1,
      (state) => (state['status'] as Map<String, dynamic>)['topicCount'] = 99,
    ];
    for (final mutate in variants) {
      final state = jsonDecode(jsonEncode(original)) as Map<String, dynamic>;
      mutate(state);
      stateFile.writeAsStringSync(jsonEncode(state));
      authority = MemoryCorpusService(workspaceDir: workspace.path);
      await expectLater(authority.manifest(), throwsA(isA<MemoryCorpusRecoveryRequired>()));
      await authority.close();
    }
  });

  test('close drains accepted work and rejects later mutations', () async {
    final authority = MemoryCorpusService(workspaceDir: workspace.path);
    final entered = Completer<void>();
    final release = Completer<void>();
    final accepted = authority.updateFiles<int>(
      paths: const ['learnings.md'],
      prepare: (files) async {
        entered.complete();
        await release.future;
        return MemoryCorpusFileMutation(value: 1, writes: {'learnings.md': utf8.encode('legacy bytes\n')});
      },
    );
    await entered.future;
    final closing = authority.close();
    release.complete();
    expect(await accepted, 1);
    await closing;
    expect(
      () => authority.updateFiles<int>(
        paths: const ['learnings.md'],
        prepare: (_) => MemoryCorpusFileMutation(value: 2, writes: const {}),
      ),
      throwsStateError,
    );
  });

  test('queue overflow completes the returned mutation future', () async {
    final authority = MemoryCorpusService(workspaceDir: workspace.path);
    final entered = Completer<void>();
    final release = Completer<void>();
    Future<int> enqueue(int value) => authority.updateFiles<int>(
      paths: const ['learnings.md'],
      prepare: (_) async {
        if (value == 0) {
          entered.complete();
          await release.future;
        }
        return MemoryCorpusFileMutation(value: value, writes: const {});
      },
    );

    final accepted = <Future<int>>[enqueue(0)];
    await entered.future;
    for (var index = 1; index < 1000; index++) {
      accepted.add(enqueue(index));
    }
    await expectLater(enqueue(1000), throwsA(isA<StateError>()));
    release.complete();
    await Future.wait(accepted);
    await authority.close();
  });
}

Map<String, List<int>> _tree(Directory root) => {
  for (final entity in root.listSync(recursive: true).whereType<File>())
    p.relative(entity.path, from: root.path): entity.readAsBytesSync(),
};

void _writeSparse(File file, int length) {
  file.parent.createSync(recursive: true);
  final handle = file.openSync(mode: FileMode.write);
  try {
    handle.setPositionSync(length - 1);
    handle.writeByteSync(0);
  } finally {
    handle.closeSync();
  }
}

void _writeSizedObservation(File file, String date, String id, int length) {
  const codec = MemoryMarkdownCodec();
  MemoryObservationDocument document(String content) => MemoryObservationDocument(
    date: date,
    observations: [
      MemoryObservation(
        id: id,
        recorded: DateTime.parse('${date}T12:00:00Z'),
        content: content,
        trustLabel: 'untrusted-user-content',
        provenance: MemorySourceRef(sourceLocator: 'test'),
      ),
    ],
  );
  final overhead = utf8.encode(codec.render(document('x'))).length - 1;
  final bytes = utf8.encode(codec.render(document('x' * (length - overhead))));
  expect(bytes, hasLength(length));
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(bytes);
}

Map<String, List<int>> _canonicalTree(Directory root) => {
  for (final entry in _tree(root).entries)
    if (!entry.key.startsWith('.dartclaw-memory-')) entry.key: entry.value,
};

Map<String, List<int>> _canonicalTreeFrom(Map<String, List<int>> tree) => {
  for (final entry in tree.entries)
    if (!entry.key.startsWith('.dartclaw-memory-')) entry.key: entry.value,
};
