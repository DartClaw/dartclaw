part of 'memory_corpus_service.dart';

MemoryIndexDocument _parseBoundedIndex(Uint8List bytes, int collectionRevision) {
  var source = utf8.decode(bytes, allowMalformed: true);
  if (!source.endsWith('\n')) {
    final locator = source.lastIndexOf('\nLocator: ');
    if (locator >= 0) {
      final end = source.indexOf('\n', locator + 1);
      if (end >= 0) source = source.substring(0, end + 1);
    } else {
      final revision = source.indexOf('\nCollection-Revision: ');
      if (revision < 0) throw const MemoryCorpusRecoveryRequired('bounded index omits canonical metadata');
      final end = source.indexOf('\n', revision + 1);
      if (end < 0) throw const MemoryCorpusRecoveryRequired('bounded index truncates canonical metadata');
      source = source.substring(0, end + 1);
    }
  }
  final document = const MemoryMarkdownCodec().parse(source);
  if (document is! MemoryIndexDocument || document.metadata.revision != collectionRevision) {
    throw const MemoryCorpusRecoveryRequired('bounded index revision does not match collection state');
  }
  return document;
}

bool _isObservationPath(String path) => RegExp(r'^memory/\d{4}-\d{2}-\d{2}\.md$').hasMatch(path);
Map<String, Object?> _curationEntryJson(CanonicalMemoryEntry entry) => {
  'id': entry.id,
  'revision': entry.revision,
  'topic': entry.topic,
  'summary': entry.summary,
  'content': entry.content,
  'created': entry.created.toIso8601String(),
  'updated': entry.updated.toIso8601String(),
  'provenance': _curationSourceJson(entry.provenance),
};
Map<String, Object?> _curationObservationJson(MemoryObservation observation) => {
  'id': observation.id,
  'recorded': observation.recorded.toIso8601String(),
  'content': observation.content,
  'trustLabel': observation.trustLabel,
  'truncated': observation.isTruncated,
  'resultingEntryIds': observation.resultingEntryIds,
  'provenance': _curationSourceJson(observation.provenance),
};
Map<String, Object?> _curationSourceJson(MemorySourceRef source) => {
  if (source.originKind != null) 'originKind': source.originKind!.name,
  'sourceLocator': source.sourceLocator,
  if (source.sourceEvent != null) 'sourceEvent': source.sourceEvent,
  if (source.caller != null) 'caller': source.caller,
  if (source.sessionRef != null) 'sessionRef': source.sessionRef,
};

final class _PreparedManifest {
  const new({required this.root, required this.state, this.externalChanges = const []});
  final String root;
  final _CorpusState state;
  final List<MemoryCorpusExternalChange> externalChanges;
}

final class _CorpusState {
  const new({
    required this.collectionId,
    required this.revision,
    required this.fingerprint,
    required this.members,
    required this.status,
  });
  final String collectionId;
  final int revision;
  final String fingerprint;
  final Map<String, _CorpusMemberState> members;
  final MemoryCorpusStatusSnapshot? status;
  bool get hasCompleteManifest =>
      members.isNotEmpty &&
      members.values.every(
        (member) =>
            member.length != null && member.modifiedMicros != null && member.role != null && member.recordCount != null,
      );
}

final class _CorpusMemberState {
  const new({
    required this.fingerprint,
    this.length,
    this.modifiedMicros,
    this.role,
    this.recordIds = const [],
    this.recordCount,
    this.oldestMicros,
    this.newestMicros,
  });
  final String fingerprint;
  final int? length, modifiedMicros;
  final String? role;
  final List<String> recordIds;
  final int? recordCount, oldestMicros, newestMicros;
  Map<String, Object?> toJson() => {
    'fingerprint': fingerprint,
    'length': length,
    'modifiedMicros': modifiedMicros,
    'role': role,
    'recordIds': recordIds,
    'recordCount': recordCount,
    if (oldestMicros != null) 'oldestMicros': oldestMicros,
    if (newestMicros != null) 'newestMicros': newestMicros,
  };
}

final class _TransactionEntry {
  const new({required this.path, required this.stagePath, required this.backupPath});
  factory fromJson(Map<String, dynamic> json) {
    final path = json['path'];
    final stagePath = json['stage'];
    final backupPath = json['backup'];
    if (path is! String || stagePath is! String? || backupPath is! String?) {
      throw const MemoryCorpusRecoveryRequired('transaction entry is malformed');
    }
    return _TransactionEntry(path: _normalizeTransactionPath(path), stagePath: stagePath, backupPath: backupPath);
  }
  final String path;
  final String? stagePath, backupPath;
  Map<String, Object?> toJson() => {'path': path, 'stage': stagePath, 'backup': backupPath};
}

final class _TransactionJournal {
  const new({
    required this.collectionId,
    required this.baseRevision,
    required this.targetRevision,
    required this.baseFingerprint,
    required this.targetFingerprint,
    required this.entries,
  });
  factory fromJson(Map<String, dynamic> json) {
    final baseRevision = json['baseRevision'];
    final targetRevision = json['targetRevision'];
    final collectionId = json['collectionId'];
    final baseFingerprint = json['baseFingerprint'];
    final targetFingerprint = json['targetFingerprint'];
    final entries = json['entries'];
    if (baseRevision is! int ||
        baseRevision < 0 ||
        targetRevision is! int ||
        targetRevision < 1 ||
        collectionId is! String ||
        baseFingerprint is! String ||
        targetFingerprint is! String ||
        entries is! List<dynamic>) {
      throw const MemoryCorpusRecoveryRequired('transaction journal is malformed');
    }
    return _TransactionJournal(
      collectionId: collectionId,
      baseRevision: baseRevision,
      targetRevision: targetRevision,
      baseFingerprint: baseFingerprint,
      targetFingerprint: targetFingerprint,
      entries: entries.map((entry) => _TransactionEntry.fromJson(entry as Map<String, dynamic>)).toList(),
    );
  }
  final String collectionId;
  final int baseRevision, targetRevision;
  final String baseFingerprint, targetFingerprint;
  final List<_TransactionEntry> entries;
  Map<String, Object?> toJson() => {
    'collectionId': collectionId,
    'baseRevision': baseRevision,
    'targetRevision': targetRevision,
    'baseFingerprint': baseFingerprint,
    'targetFingerprint': targetFingerprint,
    'entries': entries.map((entry) => entry.toJson()).toList(),
  };
}

String _normalizeTransactionPath(String path) {
  if (p.isAbsolute(path) || path.contains(r'\')) {
    throw const MemoryCorpusRecoveryRequired('transaction path escapes the workspace');
  }
  final normalized = p.posix.normalize(path);
  if (normalized == '.' || normalized == '..' || normalized.startsWith('../')) {
    throw const MemoryCorpusRecoveryRequired('transaction path escapes the workspace');
  }
  return normalized;
}
