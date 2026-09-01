part of 'memory_corpus_service.dart';

Future<_CorpusState> _scanCorpusState(String root) async {
  final members = <String, _CorpusMemberState>{};
  MemoryIndexDocument? canonicalIndex;
  final activeIds = <String>{};
  final nonActiveIds = <String>{};
  final retiredIds = <String>{};
  var batchFiles = 0;
  var batchBytes = 0;
  await for (final path in _corpusPaths(root)) {
    final file = File(p.join(root, path));
    if (FileSystemEntity.typeSync(file.path, followLinks: false) != FileSystemEntityType.file) {
      throw MemoryCorpusRecoveryRequired('$path is not a regular file');
    }
    final length = file.lengthSync();
    final sourceLimit = _isObservationPath(path)
        ? MemoryResourceLimits.observationPartitionBytes
        : MemoryResourceLimits.sourceBytes;
    if (length > sourceLimit) {
      throw MemoryResourceLimitException(
        role: _roleForPath(path) ?? MemoryRole.topic,
        locator: path,
        observedBytes: length,
        limitBytes: sourceLimit,
      );
    }
    if (batchFiles >= MemoryCorpusService.maxCorpusFiles || batchBytes + length > MemoryCorpusService.maxCorpusBytes) {
      batchFiles = 0;
      batchBytes = 0;
    }
    final bytes = Uint8List.fromList(file.readAsBytesSync());
    batchFiles++;
    batchBytes += length;
    final member = _describeMember(path, bytes, file.lastModifiedSync().microsecondsSinceEpoch);
    members[path] = member;
    if (path.startsWith('memory/legacy/')) continue;
    final document = MemoryCorpusService._codec.parse(utf8.decode(bytes));
    switch (document) {
      case MemoryIndexDocument():
        canonicalIndex = document;
      case MemoryTopicDocument():
        final indexById = {for (final row in canonicalIndex!.entries) row.id: row};
        for (final entry in document.entries) {
          if (!activeIds.add(entry.id)) {
            throw MemoryCorpusValidationException(['duplicate active entry ID: ${entry.id}']);
          }
          final row = indexById[entry.id];
          if (row == null ||
              row.topic != entry.topic ||
              row.locator != entry.id ||
              row.revision != entry.revision ||
              row.summary != entry.summary ||
              row.updated != entry.updated) {
            throw MemoryCorpusValidationException(['index metadata mismatch for ${entry.id}']);
          }
        }
      case MemoryArchiveDocument():
        for (final entry in document.entries) {
          if (!nonActiveIds.add(entry.id)) throw MemoryCorpusValidationException(['duplicate record ID: ${entry.id}']);
        }
      case MemoryObservationDocument():
        for (final entry in document.observations) {
          if (!nonActiveIds.add(entry.id)) throw MemoryCorpusValidationException(['duplicate record ID: ${entry.id}']);
        }
      case MemoryLearningDocument():
        for (final entry in document.entries) {
          if (!nonActiveIds.add(entry.id)) throw MemoryCorpusValidationException(['duplicate record ID: ${entry.id}']);
        }
      case MemoryErrorDocument():
        for (final entry in document.entries) {
          if (!nonActiveIds.add(entry.id)) throw MemoryCorpusValidationException(['duplicate record ID: ${entry.id}']);
        }
      case MemoryAuditDocument():
        for (final record in document.records) {
          if (!retiredIds.add(record.entryId)) {
            throw MemoryCorpusValidationException(['duplicate deletion-audit entry ID: ${record.entryId}']);
          }
        }
      default:
        throw MemoryCorpusRecoveryRequired('$path has an unsupported canonical role');
    }
  }
  if (canonicalIndex == null) throw const MemoryCorpusRecoveryRequired('missing required MEMORY.md');
  final index = canonicalIndex;
  final indexIds = index.entries.map((entry) => entry.id).toList(growable: false);
  final errors = <String>[];
  if (indexIds.toSet().length != indexIds.length) errors.add('duplicate index entry ID');
  if (indexIds.toSet().difference(activeIds).isNotEmpty || activeIds.difference(indexIds.toSet()).isNotEmpty) {
    errors.add('index entries do not match active topic records');
  }
  for (final id in activeIds) {
    if (nonActiveIds.contains(id)) errors.add('entry ID exists in active and non-active documents: $id');
  }
  for (final id in retiredIds) {
    if (activeIds.contains(id) || nonActiveIds.contains(id)) {
      errors.add('retired entry ID is present in the canonical corpus: $id');
    }
  }
  if (errors.isNotEmpty) throw MemoryCorpusValidationException(errors);
  if (!await _contentMatches(root, members)) {
    throw const MemoryCorpusRecoveryRequired('canonical corpus changed during reconciliation');
  }
  final fingerprint = _fingerprintMembers(members);
  return _CorpusState(
    collectionId: index.metadata.collectionId,
    revision: index.metadata.revision,
    fingerprint: fingerprint,
    members: Map.unmodifiable(members),
    status: _statusFromMembers(root, index.metadata.revision, fingerprint, members),
  );
}
