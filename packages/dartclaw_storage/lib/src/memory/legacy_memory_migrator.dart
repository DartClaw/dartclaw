import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:path/path.dart' as p;

part 'memory_preflight_result.dart';

/// Converts the retained preview memory dialect into the canonical corpus once.
final class LegacyMemoryMigrator {
  /// Creates a preflight against [workspaceDir] using the shared corpus authority.
  LegacyMemoryMigrator({required this.workspaceDir, required this.corpusService});

  /// Maximum records transformed per migration batch.
  static const maxBatchRecords = 256;

  /// Maximum diagnostics retained in a report.
  static const maxDiagnostics = 100;

  /// Maximum UTF-8 report size.
  static const maxReportBytes = 64 * 1024;
  static const _snapshotName = '.dartclaw-memory-migration-snapshot';

  /// Workspace containing legacy or canonical memory files.
  final String workspaceDir;

  /// Shared canonical corpus mutation authority.
  final MemoryCorpusService corpusService;

  /// Migrates, reconciles, or validates the corpus before indexing.
  Future<MemoryPreflightResult> preflight() async {
    try {
      return await _preflight();
    } on MemoryPreflightException {
      rethrow;
    } on Object catch (error) {
      throw MemoryPreflightException.bounded(stage: 'validate-classify-or-commit', error: error);
    }
  }

  Future<MemoryPreflightResult> _preflight() async {
    final root = Directory(p.absolute(workspaceDir));
    final memoryFile = File(p.join(root.path, 'MEMORY.md'));
    final sourcePaths = _legacySourcePaths(root);
    final hasLegacySource = sourcePaths.any(
      (path) => FileSystemEntity.typeSync(p.join(root.path, path), followLinks: false) != FileSystemEntityType.notFound,
    );
    final hasCanonicalMarker = memoryFile.existsSync() && _hasCanonicalMarker(memoryFile);
    final retainedSnapshot = Directory(p.join(root.path, _snapshotName));
    if (!hasCanonicalMarker && !hasLegacySource && retainedSnapshot.existsSync()) {
      throw MemoryPreflightException.bounded(
        stage: 'snapshot-check',
        error:
            'Retained snapshot no longer has any matching legacy sources. '
            'Inspect and delete ${retainedSnapshot.path} before retrying.',
      );
    }
    if (hasCanonicalMarker || !hasLegacySource) {
      final snapshot = await corpusService.snapshot(
        paths: const ['MEMORY.md'],
        maxDocuments: 1,
        maxBytes: MemoryCorpusService.maxCorpusBytes,
      );
      return MemoryPreflightResult._(
        status: snapshot.externalChanges.isEmpty
            ? MemoryPreflightStatus.alreadyCurrent
            : MemoryPreflightStatus.reconciled,
        collectionRevision: snapshot.collectionRevision,
        fingerprint: snapshot.fingerprint,
        totalDiagnostics: snapshot.externalChanges.length,
        diagnostics: snapshot.externalChanges
            .take(maxDiagnostics)
            .map(
              (change) => _MemoryPreflightDiagnostic(
                role: change.role?.wireName ?? 'verbatim',
                locator: change.locator,
                stage: 'reconcile',
                reason: change.wasRemoved ? 'supported canonical member removed' : 'supported canonical member changed',
              ),
            ),
        roleCounts: const {},
        defaultTopicCount: 0,
      );
    }

    final migrated = await corpusService.updateFiles<MemoryPreflightResult>(
      paths: sourcePaths,
      discoverPaths: () => _legacySourcePaths(root),
      prepare: (_) => throw StateError('Legacy migration requires canonical preparation'),
      prepareLegacyCanonical: (files) {
        final prepared = _prepareMigration(root, files);
        _retainSnapshot(root, files, prepared.sourceFingerprint);
        return MemoryCorpusMutation(value: prepared.result, corpus: prepared.corpus);
      },
    );
    final committed = await corpusService.snapshot(
      paths: const ['MEMORY.md'],
      maxDocuments: 1,
      maxBytes: MemoryCorpusService.maxCorpusBytes,
    );
    return MemoryPreflightResult._(
      status: migrated.status,
      collectionRevision: committed.collectionRevision,
      fingerprint: committed.fingerprint,
      totalDiagnostics: migrated.totalDiagnostics,
      diagnostics: migrated._diagnostics,
      roleCounts: migrated.roleCounts,
      defaultTopicCount: migrated.defaultTopicCount,
      snapshotPath: migrated.snapshotPath,
    );
  }

  _PreparedMigration _prepareMigration(Directory root, Map<String, Uint8List?> files) {
    final sourceFingerprint = _fingerprint(files);
    final topics = <String, List<CanonicalMemoryEntry>>{};
    final archive = <CanonicalMemoryEntry>[];
    final observations = <String, List<MemoryObservation>>{};
    final learnings = <CanonicalMemoryLearning>[];
    final verbatim = <VerbatimMemoryMember>[];
    final diagnostics = <_MemoryPreflightDiagnostic>[];
    var totalDiagnostics = 0;
    var defaultTopicCount = 0;
    var parsedBatchSize = 0;

    void diagnostic(_MemoryPreflightDiagnostic value) {
      totalDiagnostics++;
      if (diagnostics.length < maxDiagnostics) diagnostics.add(value);
    }

    void preserve(String sourcePath, Uint8List sourceBytes, String text, List<(int, int)> recognized) {
      final opaque = _opaqueText(text, recognized);
      final hasBom =
          sourceBytes.length >= 3 && sourceBytes[0] == 0xef && sourceBytes[1] == 0xbb && sourceBytes[2] == 0xbf;
      if (opaque.isEmpty && !hasBom) return;
      final target = 'memory/legacy/${sourcePath.replaceAll('/', '__')}';
      verbatim.add(
        VerbatimMemoryMember(
          path: target,
          bytes: Uint8List.fromList([
            if (hasBom) ...const [0xef, 0xbb, 0xbf],
            ...utf8.encode(opaque),
          ]),
        ),
      );
      diagnostic(
        _MemoryPreflightDiagnostic(
          role: 'verbatim',
          locator: target,
          stage: 'classify',
          reason: 'opaque legacy Markdown preserved byte-for-byte from $sourcePath',
        ),
      );
    }

    void processEntries(String sourcePath, void Function(MemoryEntry, String, DateTime) add) {
      final bytes = files[sourcePath];
      if (bytes == null) return;
      final text = _decodeLegacy(sourcePath, bytes);
      final recognized = <(int, int)>[];
      parseMemoryEntries(
        text,
        batchSize: maxBatchRecords,
        onBatch: (batch) {
          parsedBatchSize = batch.length > parsedBatchSize ? batch.length : parsedBatchSize;
          for (final entry in batch) {
            final start = entry.sourceStart;
            final end = entry.sourceEnd;
            final timestamp = entry.timestamp;
            if (start == null || end == null || timestamp == null) continue;
            final topic = _migrationTopic(entry.category);
            if (entry.categoryWasDefaulted) defaultTopicCount++;
            add(entry, topic, timestamp.toUtc());
            recognized.add((start, end));
          }
        },
      );
      preserve(sourcePath, bytes, text, recognized);
    }

    processEntries('MEMORY.md', (entry, topic, timestamp) {
      final value = _canonicalEntry('topic', 'MEMORY.md', entry, topic, timestamp);
      topics.putIfAbsent(topic, () => []).add(value);
    });
    processEntries('MEMORY.archive.md', (entry, topic, timestamp) {
      archive.add(_canonicalEntry('archive', 'MEMORY.archive.md', entry, topic, timestamp));
    });
    processEntries('learnings.md', (entry, _, timestamp) {
      final locator = _locator('learnings.md', entry);
      learnings.add(
        CanonicalMemoryLearning(
          id: _stableId('learning:$locator'),
          revision: 1,
          summary: _migrationSummary(entry.rawText),
          content: entry.rawText,
          created: timestamp,
          updated: timestamp,
          provenance: MemorySourceRef(originKind: MemoryOriginKind.migration, sourceLocator: locator),
        ),
      );
    });

    for (final sourcePath in files.keys.where((path) => RegExp(r'^memory/\d{4}-\d{2}-\d{2}\.md$').hasMatch(path))) {
      final bytes = files[sourcePath];
      if (bytes == null) continue;
      final text = _decodeLegacy(sourcePath, bytes);
      final recognized = <(int, int)>[];
      for (final block in _dailyBlocks(sourcePath, text)) {
        final recorded = block.timestamp.toUtc();
        final date = recorded.toIso8601String().substring(0, 10);
        final locator = '$sourcePath#${block.start}-${block.end}';
        observations
            .putIfAbsent(date, () => [])
            .add(
              MemoryObservation(
                id: _stableId('observation:$locator'),
                recorded: recorded,
                content: block.content,
                trustLabel: 'untrusted-user-content',
                provenance: MemorySourceRef(originKind: MemoryOriginKind.migration, sourceLocator: locator),
              ),
            );
        recognized.add((block.start, block.end));
      }
      preserve(sourcePath, bytes, text, recognized);
    }

    final collectionId = _stableId('collection:$sourceFingerprint');
    final corpus = CanonicalMemoryCorpus(
      index: MemoryIndexDocument(
        metadata: MemoryCollectionMetadata(collectionId: collectionId, revision: 1),
        entries: topics.values
            .expand((entries) => entries)
            .map(
              (entry) => MemoryIndexEntry(
                id: entry.id,
                revision: entry.revision,
                topic: entry.topic,
                summary: entry.summary,
                updated: entry.updated,
              ),
            ),
      ),
      topics: topics.entries.map((entry) => MemoryTopicDocument(topic: entry.key, entries: entry.value)),
      archive: archive.isEmpty ? null : MemoryArchiveDocument(entries: archive),
      observations: observations.entries.map(
        (entry) => MemoryObservationDocument(date: entry.key, observations: entry.value),
      ),
      learnings: learnings.isEmpty ? null : MemoryLearningDocument(entries: learnings),
      verbatimMembers: verbatim,
    );
    const MemoryCorpusValidator().validate(corpus);
    final roleCounts = <MemoryRole, int>{
      MemoryRole.topic: topics.values.fold(0, (count, entries) => count + entries.length),
      MemoryRole.archive: archive.length,
      MemoryRole.observation: observations.values.fold(0, (count, entries) => count + entries.length),
      MemoryRole.learning: learnings.length,
    }..removeWhere((_, count) => count == 0);
    totalDiagnostics++;
    diagnostics.insert(
      0,
      _MemoryPreflightDiagnostic(
        role: 'migration',
        locator: 'batch',
        stage: 'classify',
        reason: 'maximum parsed-record batch=$parsedBatchSize limit=$maxBatchRecords',
      ),
    );
    if (diagnostics.length > maxDiagnostics) diagnostics.removeLast();
    final result = MemoryPreflightResult._(
      status: MemoryPreflightStatus.migrated,
      collectionRevision: 1,
      fingerprint: _fingerprintInventory(corpus.byteInventory()),
      totalDiagnostics: totalDiagnostics,
      diagnostics: diagnostics,
      roleCounts: roleCounts,
      defaultTopicCount: defaultTopicCount,
      snapshotPath: p.join(root.path, _snapshotName),
    );
    return _PreparedMigration(corpus: corpus, result: result, sourceFingerprint: sourceFingerprint);
  }

  void _retainSnapshot(Directory root, Map<String, Uint8List?> files, String sourceFingerprint) {
    final snapshot = Directory(p.join(root.path, _snapshotName));
    if (snapshot.existsSync()) {
      final manifest = _readSnapshotManifest(snapshot);
      if (manifest['sourceFingerprint'] != sourceFingerprint) {
        throw MemoryPreflightException.bounded(
          stage: 'snapshot-check',
          error:
              'Retained snapshot does not match current legacy sources. Inspect and delete ${snapshot.path} before retrying.',
        );
      }
      _verifySnapshot(snapshot, manifest, files);
      return;
    }
    final temporary = Directory('${snapshot.path}.new');
    if (temporary.existsSync()) temporary.deleteSync(recursive: true);
    temporary.createSync();
    final members = <String, Object?>{};
    try {
      for (final entry in files.entries) {
        final bytes = entry.value;
        if (bytes == null) {
          members[entry.key] = null;
          continue;
        }
        final name = base64Url.encode(utf8.encode(entry.key)).replaceAll('=', '');
        File(p.join(temporary.path, name)).writeAsBytesSync(bytes, flush: true);
        members[entry.key] = name;
      }
      File(p.join(temporary.path, 'manifest.json'))
          .writeAsStringSync(jsonEncode({'sourceFingerprint': sourceFingerprint, 'members': members}), flush: true);
      temporary.renameSync(snapshot.path);
    } finally {
      if (temporary.existsSync()) temporary.deleteSync(recursive: true);
    }
  }

  static Map<String, dynamic> _readSnapshotManifest(Directory snapshot) {
    try {
      final value = jsonDecode(File(p.join(snapshot.path, 'manifest.json')).readAsStringSync());
      if (value is Map<String, dynamic> && value['sourceFingerprint'] is String && value['members'] is Map) {
        return value;
      }
    } on Object {
      // One stable recovery report is emitted below.
    }
    throw MemoryPreflightException.bounded(
      stage: 'snapshot-check',
      error: 'Retained snapshot is unreadable. Inspect ${snapshot.path} before retrying.',
    );
  }

  static void _verifySnapshot(Directory snapshot, Map<String, dynamic> manifest, Map<String, Uint8List?> sources) {
    try {
      final members = Map<String, dynamic>.from(manifest['members'] as Map);
      if (members.keys.toSet().difference(sources.keys.toSet()).isNotEmpty ||
          sources.keys.toSet().difference(members.keys.toSet()).isNotEmpty) {
        throw const FormatException('snapshot member inventory differs from legacy sources');
      }
      final expectedPayloadNames = <String>{};
      var presentMembers = 0;
      for (final entry in sources.entries) {
        final member = members[entry.key];
        final sourceBytes = entry.value;
        if (sourceBytes == null) {
          if (member != null) throw FormatException('snapshot records present bytes for absent ${entry.key}');
          continue;
        }
        if (member is! String || member.isEmpty || p.basename(member) != member || member == 'manifest.json') {
          throw FormatException('snapshot member mapping is invalid for ${entry.key}');
        }
        presentMembers++;
        expectedPayloadNames.add(member);
        final payload = File(p.join(snapshot.path, member));
        if (FileSystemEntity.typeSync(payload.path, followLinks: false) != FileSystemEntityType.file ||
            !_bytesEqual(payload.readAsBytesSync(), sourceBytes)) {
          throw FormatException('snapshot payload differs for ${entry.key}');
        }
      }
      if (expectedPayloadNames.length != presentMembers) {
        throw const FormatException('snapshot payload names are not unique');
      }
      final actualPayloads = snapshot
          .listSync(followLinks: false)
          .where((entity) => p.basename(entity.path) != 'manifest.json')
          .toList();
      final actualPayloadNames = actualPayloads.map((entity) => p.basename(entity.path)).toSet();
      if (actualPayloads.any(
        (entity) => FileSystemEntity.typeSync(entity.path, followLinks: false) != FileSystemEntityType.file,
      )) {
        throw const FormatException('snapshot contains a non-file payload');
      }
      if (actualPayloadNames.length != expectedPayloadNames.length ||
          !actualPayloadNames.containsAll(expectedPayloadNames)) {
        throw const FormatException('snapshot payload inventory is incomplete');
      }
    } on Object catch (error) {
      throw MemoryPreflightException.bounded(
        stage: 'snapshot-check',
        error: 'Retained snapshot is corrupt ($error). Inspect and delete ${snapshot.path} before retrying.',
      );
    }
  }

  static bool _bytesEqual(List<int> left, List<int> right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }

  static List<String> _legacySourcePaths(Directory root) {
    final paths = <String>['MEMORY.md', 'MEMORY.archive.md', 'learnings.md'];
    final memoryDir = Directory(p.join(root.path, 'memory'));
    if (!memoryDir.existsSync()) return paths;
    for (final entity in memoryDir.listSync(followLinks: false)) {
      final name = p.basename(entity.path);
      if (RegExp(r'^\d{4}-\d{2}-\d{2}\.md$').hasMatch(name)) paths.add('memory/$name');
    }
    paths.sort();
    return paths;
  }

  static bool _hasCanonicalMarker(File file) {
    final handle = file.openSync();
    try {
      return RegExp(r'^# DartClaw Canonical Memory(?:\r\n|\n|\r|$)')
          .hasMatch(utf8.decode(handle.readSync(64), allowMalformed: true));
    } finally {
      handle.closeSync();
    }
  }

  static CanonicalMemoryEntry _canonicalEntry(
    String role,
    String sourcePath,
    MemoryEntry entry,
    String topic,
    DateTime timestamp,
  ) {
    final locator = _locator(sourcePath, entry);
    return CanonicalMemoryEntry(
      id: _stableId('$role:$locator'),
      revision: 1,
      topic: topic,
      summary: _migrationSummary(entry.rawText),
      content: entry.rawText,
      created: timestamp,
      updated: timestamp,
      provenance: MemorySourceRef(originKind: MemoryOriginKind.migration, sourceLocator: locator),
    );
  }

  static String _locator(String path, MemoryEntry entry) => '$path#${entry.sourceStart}-${entry.sourceEnd}';

  static String _migrationTopic(String category) {
    var value = category.toLowerCase().replaceAll(RegExp(r'\s+'), '-').replaceAll(RegExp('[^a-z0-9-]'), '');
    value = value.replaceAll(RegExp('-+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
    if (value.isEmpty) value = 'general';
    if (value.length > 64) value = value.substring(0, 64).replaceFirst(RegExp(r'-+$'), '');
    return value.isEmpty ? 'general' : value;
  }

  static String _opaqueText(String text, List<(int, int)> recognized) {
    if (recognized.isEmpty) return text;
    recognized.sort((left, right) => left.$1.compareTo(right.$1));
    final result = StringBuffer();
    var offset = 0;
    for (final span in recognized) {
      if (span.$1 > offset) result.write(text.substring(offset, span.$1));
      if (span.$2 > offset) offset = span.$2;
    }
    if (offset < text.length) result.write(text.substring(offset));
    return result.toString();
  }

  static Iterable<_DailyBlock> _dailyBlocks(String path, String text) sync* {
    final date = p.basenameWithoutExtension(path);
    final lines = _sourceLines(text);
    for (var index = 0; index < lines.length; index++) {
      final heading = lines[index];
      if (!heading.text.startsWith('##')) continue;
      final match = RegExp(r'^## (\d{2}):(\d{2}) — (.+)$').firstMatch(heading.text);
      if (match == null || index + 3 >= lines.length) continue;
      final payload = lines.sublist(index, index + 4);
      if (payload.skip(1).any((line) => line.text.startsWith('##')) ||
          !_isDailyPayload(match.group(3)!, payload.map((line) => line.text).toList())) {
        continue;
      }
      final timestamp = DateTime.tryParse('${date}T${match.group(1)}:${match.group(2)}:00');
      if (timestamp == null ||
          timestamp.toIso8601String().substring(0, 16) != '${date}T${match.group(1)}:${match.group(2)}') {
        continue;
      }
      final end = payload.last.contentEnd;
      yield _DailyBlock(
        start: heading.start,
        end: end,
        timestamp: timestamp,
        content: text.substring(heading.start, end),
      );
    }
  }

  static List<_SourceLine> _sourceLines(String text) {
    final lines = <_SourceLine>[];
    var start = 0;
    while (start < text.length) {
      final newline = text.indexOf('\n', start);
      final lineEnd = newline < 0 ? text.length : newline;
      final contentEnd = lineEnd > start && text.codeUnitAt(lineEnd - 1) == 0x0d ? lineEnd - 1 : lineEnd;
      lines.add(_SourceLine(start: start, contentEnd: contentEnd, text: text.substring(start, contentEnd)));
      if (newline < 0) break;
      start = newline + 1;
    }
    return lines;
  }

  static bool _isDailyPayload(String title, List<String> lines) {
    (String, Object?) decode(String prefix, String line) {
      if (!line.startsWith(prefix)) throw const FormatException('wrong field');
      final source = line.substring(prefix.length);
      return (source, jsonDecode(source));
    }

    try {
      final decodedTitle = jsonDecode(title);
      final user = decode('**User**: ', lines[1]);
      final tools = decode('**Tools**: ', lines[2]);
      final result = decode('**Result**: ', lines[3]);
      return decodedTitle is String &&
          jsonEncode(decodedTitle) == title &&
          user.$2 is String &&
          jsonEncode(user.$2) == user.$1 &&
          tools.$2 is List &&
          (tools.$2 as List).every((value) => value is String) &&
          jsonEncode(tools.$2) == tools.$1 &&
          result.$2 is String &&
          jsonEncode(result.$2) == result.$1;
    } on FormatException {
      return false;
    }
  }

  static String _decodeLegacy(String sourcePath, Uint8List bytes) {
    try {
      return utf8.decode(bytes);
    } on FormatException catch (error) {
      throw FormatException('Invalid UTF-8 in legacy source $sourcePath: ${error.message}');
    }
  }

  static String _stableId(String value) {
    final hex = '${_fnv64(utf8.encode(value))}${_fnv64(utf8.encode('dartclaw:$value'))}';
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  static String _fnv64(List<int> bytes) {
    var hash = BigInt.parse('cbf29ce484222325', radix: 16);
    final prime = BigInt.parse('100000001b3', radix: 16);
    final mask = BigInt.parse('ffffffffffffffff', radix: 16);
    for (final byte in bytes) {
      hash = ((hash ^ BigInt.from(byte)) * prime) & mask;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }

  static String _fingerprint(Map<String, Uint8List?> files) => _fingerprintInventory({
    for (final entry in files.entries)
      if (entry.value != null) entry.key: entry.value!,
  });

  static String _fingerprintInventory(Map<String, Uint8List> files) {
    final bytes = <int>[];
    for (final path in files.keys.toList()..sort()) {
      bytes
        ..addAll(utf8.encode(path))
        ..add(0)
        ..addAll(files[path]!)
        ..add(0xff);
    }
    return _fnv64(bytes);
  }

  static String _failureReport(String stage, Object error) {
    final value =
        'Memory preflight: failed\n'
        'Stage: $stage\n'
        'Diagnostics: total=1 returned=1 omitted=0\n'
        'Recovery: $error\n';
    if (utf8.encode(value).length <= maxReportBytes) return value;
    return 'Memory preflight: failed\n'
        'Stage: $stage\n'
        'Diagnostics: total=1 returned=0 omitted=1\n'
        'Recovery: diagnostic omitted by the $maxReportBytes-byte report limit\n';
  }
}
