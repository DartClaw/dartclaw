import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:uuid/uuid.dart';

import 'behavior/self_improvement_service.dart';
import 'knowledge/knowledge_inbox_read_service.dart' show KnowledgeInboxReadService;
import 'memory/live_memory_source_resolver.dart';
import 'memory/memory_apply_service.dart';

/// Maximum number of results accepted by the retrieval tools.
const maxMemorySearchResults = 50;

/// Maximum character count accepted by one capture.
const maxMemoryCaptureTextLength = 64 * 1024;

/// Maximum UTF-8 response size returned by `memory_read`.
const maxMemoryReadResponseBytes = 64 * 1024;

/// Host-owned provenance for a canonical memory capture.
final class MemoryCaptureContext {
  const new({
    this.userId = 'owner',
    this.originKind,
    required this.sourceLocator,
    this.sourceEvent,
    this.caller,
    this.sessionRef,
  });

  final String userId;
  final MemoryOriginKind? originKind;
  final String sourceLocator;
  final String? sourceEvent;
  final String? caller;
  final String? sessionRef;

  MemorySourceRef toSourceRef() => MemorySourceRef(
    originKind: originKind,
    sourceLocator: sourceLocator,
    sourceEvent: sourceEvent,
    caller: caller,
    sessionRef: sessionRef,
  );
}

typedef MemoryObserveWithContext = Future<Map<String, dynamic>> Function(
  Map<String, dynamic> params,
  MemoryCaptureContext context,
);

/// Complete callback set for the built-in memory tools.
typedef MemoryHandlers = ({
  MemoryApplyService applyService,
  Future<Map<String, dynamic>> Function(Map<String, dynamic>) onApply,
  MemoryObserveWithContext apply,
  Future<Map<String, dynamic>> Function(Map<String, dynamic>) onObserve,
  MemoryObserveWithContext observe,
  Future<Map<String, dynamic>> Function(Map<String, dynamic>) onSearch,
  Future<Map<String, dynamic>> Function(Map<String, dynamic>) onRead,
});

/// Creates the canonical memory capture and retrieval handlers.
MemoryHandlers createMemoryHandlers({
  required MemoryService memory,
  required MemoryFileService memoryFile,
  MemoryCorpusService? corpusService,
  required SearchBackend searchBackend,
  LiveMemorySourceResolver? nativeSourceResolver,
  SelfImprovementService? selfImprovement,
  MemoryCaptureContext Function(String toolName)? captureContext,
  MemoryIndexReconciler? reconcileIndex,
  DateTime Function()? now,
  String Function()? createCaptureId,
}) {
  const uuid = Uuid();
  final newCaptureId = createCaptureId ?? uuid.v4;
  final corpus = corpusService ?? memoryFile.corpusService;
  final indexHealth = IndexHealthStore(workspaceDir: corpus.workspaceDir);
  final clock = now ?? DateTime.now;
  MemoryCaptureContext defaultContext(String toolName) =>
      captureContext?.call(toolName) ??
      MemoryCaptureContext(sourceLocator: 'tool:$toolName', caller: 'mcp-gateway:$toolName');

  Future<void> reconcileCanonical(
    CanonicalMemoryCorpus replacement,
    Set<String> priorRecordIds,
    int baseRevision,
    String baseFingerprint,
    String userId,
  ) async {
    final manifest = await corpus.manifest();
    if (corpus.hasPostCommitProjection) {
      final health = await indexHealth.read(
        canonicalRevision: manifest.collectionRevision,
        canonicalFingerprint: manifest.fingerprint,
      );
      if (health.state != IndexHealthState.healthy) {
        throw StateError(health.reason ?? 'memory index projection is degraded');
      }
      return;
    }
    try {
      final priorHealth = await indexHealth.read(
        canonicalRevision: baseRevision,
        canonicalFingerprint: baseFingerprint,
      );
      final baseHealthy = priorHealth.isCurrent(baseRevision, baseFingerprint);
      final rows = MemoryService.canonicalIndexRows(replacement);
      memory.replaceMemoryRecords(rows, priorRecordIds, userId: userId);
      await searchBackend.indexAfterWrite();
      memory.validateMemoryRecords(rows, priorRecordIds, userId: userId);
      if (!baseHealthy) throw StateError('incremental projection requires a healthy base index');
      await indexHealth.recordHealthy(
        canonicalRevision: manifest.collectionRevision,
        canonicalFingerprint: manifest.fingerprint,
      );
    } on Object catch (error) {
      await indexHealth.recordDegraded(
        canonicalRevision: manifest.collectionRevision,
        canonicalFingerprint: manifest.fingerprint,
        stage: 'incrementalProjection',
        reason: error,
      );
      rethrow;
    }
  }

  final applyService = MemoryApplyService(
    corpus: corpus,
    now: clock,
    reconcileIndex:
        reconcileIndex ??
        (replacement, priorRecordIds, baseRevision, baseFingerprint, userId) =>
            reconcileCanonical(replacement, priorRecordIds, baseRevision, baseFingerprint, userId),
  );

  Future<Map<String, dynamic>> capture(Map<String, dynamic> params, MemoryCaptureContext context) async {
    _requireOnlyKeys(params, const {'text', 'role'});
    final text = _requiredString(params, 'text');
    if (text.trim().isEmpty) throw ArgumentError.value(text, 'text', 'must not be empty');
    if (text.length > maxMemoryCaptureTextLength) {
      throw ArgumentError.value(text, 'text', 'must not exceed $maxMemoryCaptureTextLength characters');
    }
    final role = _observationRole(_requiredString(params, 'role'));
    final capturedAt = clock().toUtc();
    final id = newCaptureId();
    final provenance = context.toSourceRef();
    late final int entryRevision;
    var indexState = 'current';
    late int collectionRevision;

    while (true) {
      final manifest = await corpus.manifest();
      late CanonicalMemoryCorpus replacement;
      var priorRecordIds = <String>{};
      entryRevision = 1;
      final result = await corpus.changeSelected<int>(
        expectedRevision: manifest.collectionRevision,
        include: (_, _) => false,
        paths: [
          if (role == MemoryRole.observation)
            'memory/${capturedAt.toIso8601String().substring(0, 10)}.md'
          else
            'learnings.md',
        ],
        prepare: (current) {
          priorRecordIds = _corpusRecordIds(current);
          replacement = switch (role) {
            MemoryRole.observation => _addObservation(
              current,
              id: id,
              text: text,
              at: capturedAt,
              provenance: provenance,
            ),
            MemoryRole.learning => _addLearning(
              current,
              id: id,
              text: text,
              at: capturedAt,
              provenance: provenance,
              maxEntries: selfImprovement?.maxEntries ?? 50,
            ),
            _ => throw StateError('Unsupported capture role: ${role.wireName}'),
          };
          return MemoryCorpusChange(value: 0, replacement: replacement);
        },
        afterCommit: (_, _) async {
          try {
            await reconcileCanonical(
              replacement,
              priorRecordIds,
              manifest.collectionRevision,
              manifest.fingerprint,
              context.userId,
            );
          } on Object {
            indexState = 'degraded';
          }
        },
      );
      if (!result.wasCommitted) continue;
      collectionRevision = result.collectionRevision;
      break;
    }

    return _toolJson({
      'locator': id,
      'role': role.wireName,
      'entryRevision': entryRevision,
      'collectionRevision': collectionRevision,
      'indexState': indexState,
    });
  }

  Future<Map<String, dynamic>> apply(Map<String, dynamic> params, MemoryCaptureContext context) async =>
      _toolJson(await applyService.apply(params, userId: context.userId, provenance: context.toSourceRef()));

  return (
    applyService: applyService,
    onApply: (params) => apply(params, defaultContext('memory_apply')),
    apply: apply,
    onObserve: (params) => capture(params, defaultContext('memory_observe')),
    observe: capture,
    onSearch: (Map<String, dynamic> params) async {
      _requireOnlyKeys(params, const {'query', 'limit'});
      final query = _requiredString(params, 'query');
      final limit = _memoryLimit(params['limit']);
      if (query.trim().isEmpty) {
        final collectionRevision = (await corpus.manifest()).collectionRevision;
        return _toolJson({'collectionRevision': collectionRevision, 'results': const <Object>[]});
      }
      final outcome = await searchBackend.search(query, limit: limit, userId: 'owner');
      final collectionRevision = outcome.canonicalRevision ?? (await corpus.manifest()).collectionRevision;
      return _toolJson({
        'collectionRevision': collectionRevision,
        'results': outcome.results.take(limit).map((result) => result.toRetrievalJson()).toList(growable: false),
        'degradedLayers': outcome.degradedLayers,
        'degradations': outcome.degradations.map((item) => item.toJson()).toList(growable: false),
      });
    },
    onRead: (Map<String, dynamic> params) async {
      _requireOnlyKeys(params, const {'locator', 'role', 'topic', 'limit'});
      final locator = _optionalString(params, 'locator');
      final roleName = _optionalString(params, 'role');
      final topic = _optionalString(params, 'topic');
      final hasLocator = locator != null;
      final hasRoleSelector = roleName != null || topic != null;
      if (hasLocator == hasRoleSelector || (!hasLocator && (roleName == null || topic == null))) {
        throw ArgumentError('provide exactly one selector: locator, or role with topic');
      }
      final limit = _memoryLimit(params['limit']);
      final records = <Map<String, Object?>>[];
      late final int collectionRevision;
      if (locator != null) {
        if (_isAuditDocumentLocator(locator)) {
          throw ArgumentError.value(locator, 'locator', 'audit records are not model-readable');
        }
        if (!_isMemoryLocator(locator)) {
          throw ArgumentError.value(locator, 'locator', 'must be a canonical UUID or recognized native locator');
        }
        final selection = await corpus.selectRecord(locator);
        collectionRevision = selection?.collectionRevision ?? (await corpus.manifest()).collectionRevision;
        final current = selection?.corpus;
        final canonical = current == null ? null : _canonicalByLocator(current, locator);
        if (canonical != null) {
          records.add(canonical);
        } else if (current != null && _isAuditLocator(current, locator)) {
          throw ArgumentError.value(locator, 'locator', 'audit records are not model-readable');
        } else {
          MemorySearchResult? native;
          if (nativeSourceResolver != null && _isSourceOwnedNativeLocator(locator)) {
            native = await nativeSourceResolver.resolve(locator, userId: 'owner');
          } else if (!_isCanonicalMemoryLocator(locator)) {
            native = await searchBackend.resolve(locator, userId: 'owner');
          }
          if (native != null && native.role != 'audit') {
            records.add(_readResult(native));
          }
        }
      } else {
        final role = _readTopicRole(roleName!);
        validateMemoryTopic(topic!);
        final selection = await corpus.selectDocuments(
          include: (candidate, locator) =>
              candidate == role && locator == 'memory/topics/$topic.md' ||
              candidate == role && locator == 'MEMORY.archive.md',
        );
        collectionRevision = selection.collectionRevision;
        final current = selection.corpus;
        records.addAll(_canonicalByTopic(current, role, topic).take(limit));
      }
      return _boundedReadResult(records.take(limit).toList(growable: false), collectionRevision: collectionRevision);
    },
  );
}

CanonicalMemoryCorpus _addObservation(
  CanonicalMemoryCorpus corpus, {
  required String id,
  required String text,
  required DateTime at,
  required MemorySourceRef provenance,
}) {
  final date = at.toIso8601String().substring(0, 10);
  final entry = MemoryObservation(
    id: id,
    recorded: at,
    content: text.trim(),
    trustLabel: 'untrusted-agent-observation',
    provenance: provenance,
  );
  final observations = [...corpus.observations];
  final index = observations.indexWhere((document) => document.date == date);
  if (index < 0) {
    observations.add(MemoryObservationDocument(date: date, observations: [entry]));
  } else {
    observations[index] = MemoryObservationDocument(
      date: date,
      observations: [...observations[index].observations, entry],
    );
  }
  return _replaceCorpus(corpus, observations: observations);
}

CanonicalMemoryCorpus _addLearning(
  CanonicalMemoryCorpus corpus, {
  required String id,
  required String text,
  required DateTime at,
  required MemorySourceRef provenance,
  required int maxEntries,
}) {
  final prior = corpus.learnings?.entries ?? const <CanonicalMemoryLearning>[];
  final newEntry = CanonicalMemoryLearning(
    id: id,
    revision: 1,
    summary: _summary(text),
    content: text.trim(),
    created: at,
    updated: at,
    provenance: provenance,
  );
  final existingLimit = maxEntries - 1;
  final retained = maxEntries <= 0
      ? const <CanonicalMemoryLearning>[]
      : [...prior.skip(prior.length > existingLimit ? prior.length - existingLimit : 0), newEntry];
  return _replaceCorpus(corpus, learnings: MemoryLearningDocument(entries: retained));
}

CanonicalMemoryCorpus _replaceCorpus(
  CanonicalMemoryCorpus corpus, {
  MemoryIndexDocument? index,
  List<MemoryTopicDocument>? topics,
  List<MemoryObservationDocument>? observations,
  MemoryLearningDocument? learnings,
}) => CanonicalMemoryCorpus(
  index: index ?? corpus.index,
  topics: topics ?? corpus.topics,
  archive: corpus.archive,
  observations: observations ?? corpus.observations,
  learnings: learnings ?? corpus.learnings,
  errors: corpus.errors,
  audit: corpus.audit,
  verbatimMembers: corpus.verbatimMembers,
);

Set<String> _corpusRecordIds(CanonicalMemoryCorpus corpus) => {
  for (final document in corpus.topics) ...document.entries.map((entry) => entry.id),
  ...?corpus.archive?.entries.map((entry) => entry.id),
  for (final document in corpus.observations) ...document.observations.map((entry) => entry.id),
  ...?corpus.learnings?.entries.map((entry) => entry.id),
};

Map<String, Object?>? _canonicalByLocator(CanonicalMemoryCorpus corpus, String locator) {
  for (final document in corpus.topics) {
    for (final entry in document.entries) {
      if (entry.locator == locator) return _entryResult(entry, 'topic');
    }
  }
  for (final entry in corpus.archive?.entries ?? const <CanonicalMemoryEntry>[]) {
    if (entry.locator == locator) return _entryResult(entry, 'archive');
  }
  for (final document in corpus.observations) {
    for (final entry in document.observations) {
      if (entry.id == locator) {
        return {
          'role': 'observation',
          'provenance': entry.provenance.sourceLocator,
          'locator': entry.id,
          'entryId': entry.id,
          'entryRevision': 1,
          'content': entry.content,
        };
      }
    }
  }
  for (final entry in corpus.learnings?.entries ?? const <CanonicalMemoryLearning>[]) {
    if (entry.locator == locator) {
      return {
        'role': 'learning',
        'provenance': entry.provenance.sourceLocator,
        'locator': entry.locator,
        'entryId': entry.id,
        'entryRevision': entry.revision,
        'content': entry.content,
      };
    }
  }
  return null;
}

Iterable<Map<String, Object?>> _canonicalByTopic(CanonicalMemoryCorpus corpus, MemoryRole role, String topic) sync* {
  final entries = role == MemoryRole.topic
      ? corpus.topics.where((document) => document.topic == topic).expand((document) => document.entries)
      : (corpus.archive?.entries ?? const <CanonicalMemoryEntry>[]).where((entry) => entry.topic == topic);
  for (final entry in entries) {
    yield _entryResult(entry, role.wireName);
  }
}

Map<String, Object?> _entryResult(CanonicalMemoryEntry entry, String role) => {
  'role': role,
  'provenance': entry.provenance.sourceLocator,
  'locator': entry.locator,
  'entryId': entry.id,
  'entryRevision': entry.revision,
  'content': entry.content,
};

Map<String, Object?> _readResult(MemorySearchResult result) => {
  'role': result.role,
  'provenance': result.provenance,
  'locator': result.locator,
  if (result.entryId != null) 'entryId': result.entryId,
  if (result.entryRevision != null) 'entryRevision': result.entryRevision,
  'content': result.text,
};

bool _isAuditLocator(CanonicalMemoryCorpus corpus, String locator) =>
    corpus.audit?.records.any((record) => record.entryId == locator) ?? false;

bool _isMemoryLocator(String locator) {
  if (_isCanonicalMemoryLocator(locator)) return true;
  final normalized = locator.replaceAll('\\', '/');
  if (normalized.startsWith('wiki/') && normalized.endsWith('.md')) {
    return !normalized.split('/').any((segment) => segment.isEmpty || segment == '.' || segment == '..');
  }
  if (RegExp(r'^[1-9][0-9]*$').hasMatch(locator) || KnowledgeInboxReadService.supportsLocator(locator)) {
    return true;
  }
  final uri = Uri.tryParse(locator);
  if (uri == null || uri.scheme != 'qmd' || uri.hasAuthority || uri.hasQuery || uri.hasFragment) return false;
  final segments = uri.path.split('/').where((segment) => segment.isNotEmpty).toList(growable: false);
  return uri.path.startsWith('/') &&
      segments.isNotEmpty &&
      !segments.any((segment) => segment == '.' || segment == '..');
}

bool _isCanonicalMemoryLocator(String locator) =>
    RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$').hasMatch(locator);

bool _isSourceOwnedNativeLocator(String locator) {
  final normalized = locator.replaceAll('\\', '/');
  return RegExp(r'^[1-9][0-9]*$').hasMatch(locator) ||
      KnowledgeInboxReadService.supportsLocator(locator) ||
      normalized.startsWith('wiki/');
}

bool _isAuditDocumentLocator(String locator) {
  if (locator == 'MEMORY.audit.md') return true;
  final uri = Uri.tryParse(locator);
  return uri?.scheme == 'qmd' && uri?.path.replaceFirst(RegExp(r'^/'), '') == 'MEMORY.audit.md';
}

MemoryRole _observationRole(String value) => switch (value) {
  'observation' => MemoryRole.observation,
  'learning' => MemoryRole.learning,
  _ => throw ArgumentError.value(value, 'role', 'must be observation or learning'),
};

MemoryRole _readTopicRole(String value) => switch (value) {
  'topic' => MemoryRole.topic,
  'archive' => MemoryRole.archive,
  'audit' => throw ArgumentError.value(value, 'role', 'audit records are not model-readable'),
  _ => throw ArgumentError.value(value, 'role', 'does not support topic selection'),
};

int _memoryLimit(Object? value) {
  if (value == null) return 5;
  if (value is! int || value < 1 || value > maxMemorySearchResults) {
    throw ArgumentError.value(value, 'limit', 'must be an integer from 1 to $maxMemorySearchResults');
  }
  return value;
}

String _summary(String text) => text.trim().split('\n').first;

String _requiredString(Map<String, dynamic> params, String key) {
  final value = params[key];
  if (value is! String) throw ArgumentError.value(value, key, 'must be a string');
  return value;
}

String? _optionalString(Map<String, dynamic> params, String key) {
  final value = params[key];
  if (value == null) return null;
  if (value is! String || value.trim().isEmpty) throw ArgumentError.value(value, key, 'must be a nonblank string');
  return value;
}

void _requireOnlyKeys(Map<String, dynamic> params, Set<String> allowed) {
  final unknown = params.keys.where((key) => !allowed.contains(key)).toList(growable: false);
  if (unknown.isNotEmpty) throw ArgumentError.value(unknown, 'params', 'contains unsupported fields');
}

Map<String, dynamic> _toolJson(Map<String, Object?> value) => {
  'content': [
    {'type': 'text', 'text': jsonEncode(value)},
  ],
};

Map<String, dynamic> _boundedReadResult(List<Map<String, Object?>> records, {required int collectionRevision}) {
  final retained = records.map(Map<String, Object?>.of).toList(growable: true);
  var truncated = false;
  String encode() =>
      jsonEncode({'collectionRevision': collectionRevision, 'results': retained, 'truncated': truncated});
  while (utf8.encode(encode()).length > maxMemoryReadResponseBytes && retained.length > 1) {
    retained.removeLast();
    truncated = true;
  }
  if (utf8.encode(encode()).length > maxMemoryReadResponseBytes && retained.isNotEmpty) {
    final content = retained.single['content'] as String;
    var budget = maxMemoryReadResponseBytes - 512;
    while (budget > 0) {
      retained.single['content'] = _headTailTruncateUtf8(content, budget);
      truncated = true;
      if (utf8.encode(encode()).length <= maxMemoryReadResponseBytes) break;
      budget -= 128;
    }
  }
  if (utf8.encode(encode()).length > maxMemoryReadResponseBytes) {
    throw ArgumentError('selected record metadata exceeds the memory_read response limit');
  }
  return _toolJson({'collectionRevision': collectionRevision, 'results': retained, 'truncated': truncated});
}

/// Keeps the head and the tail of an over-budget [content], marking the cut in
/// the middle. Native sources grow by appending – a wiki page gains supplement
/// sections at its end – so a head-only cut would drop exactly the newest
/// content from every oversized read.
String _headTailTruncateUtf8(String content, int budget) {
  final encoded = utf8.encode(content);
  if (encoded.length <= budget) return content;
  final tailBudget = budget ~/ 2;
  var tailStart = encoded.length - tailBudget;
  while (tailStart < encoded.length && (encoded[tailStart] & 0xC0) == 0x80) {
    tailStart++;
  }
  return '${truncateUtf8Bytes(content, budget - tailBudget)}\n'
      '...[truncated ${encoded.length - budget} bytes]...\n'
      '${utf8.decode(encoded.sublist(tailStart))}';
}
