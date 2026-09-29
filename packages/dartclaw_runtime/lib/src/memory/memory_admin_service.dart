import 'dart:math';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import '../runtime/storage_wiring.dart';
import 'memory_apply_service.dart';

/// A selector that does not name a host-validated private corpus.
final class MemoryAdminUnavailable implements Exception {
  const new();
}

/// Owner administration over the already wired private canonical corpora.
final class MemoryAdminService {
  new({required StorageWiring storage}) : _storage = storage;

  final StorageWiring _storage;
  final Map<String, String> _selectors = {'owner': 'owner'};
  final Random _random = Random.secure();

  static const pageSize = 20;
  static const removalDisclosure =
      'Removing a curated entry does not erase retained source observations, transcripts, audit records, or backups.';

  String _selectorFor(String principal) {
    for (final entry in _selectors.entries) {
      if (entry.value == principal) return entry.key;
    }
    final selector = List<int>.generate(
      18,
      (_) => _random.nextInt(256),
    ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    _selectors[selector] = principal;
    return selector;
  }

  WorkspaceMemoryContext _resolve(String? selector) {
    final principal = _selectors[selector ?? 'owner'];
    if (principal == null) throw const MemoryAdminUnavailable();
    for (final context in _storage.adminMemoryContexts) {
      if (context.principal == principal) return context;
    }
    throw const MemoryAdminUnavailable();
  }

  Future<Map<String, Object?>> inventory() async {
    final configured = _storage.memoryContexts.map((context) => context.principal).toSet();
    final corpora = <Map<String, Object?>>[];
    for (final context in _storage.adminMemoryContexts) {
      try {
        final manifest = await context.corpus.manifest();
        final health = await context.health.read(
          canonicalRevision: manifest.collectionRevision,
          canonicalFingerprint: manifest.fingerprint,
        );
        corpora.add({
          'selector': _selectorFor(context.principal),
          'label': context.workspace?.agentId ?? 'Default agent',
          'kind': context.principal == 'owner'
              ? 'default'
              : configured.contains(context.principal)
              ? 'configured'
              : 'retained',
          'principal': context.principal,
          'collectionRevision': manifest.collectionRevision,
          'health': health.toJson(),
        });
      } on Object {
        // A previously valid corpus can become unreadable after startup.
        corpora.add({
          'selector': _selectorFor(context.principal),
          'label': context.workspace?.agentId ?? 'Default agent',
          'kind': context.principal == 'owner'
              ? 'default'
              : configured.contains(context.principal)
              ? 'configured'
              : 'retained',
          'principal': context.principal,
          'collectionRevision': null,
          'health': const {'state': 'unavailable'},
        });
      }
    }
    return {'corpora': corpora, 'selectedDefault': 'owner'};
  }

  Future<Map<String, Object?>> list({String? selector, String query = '', int page = 1}) async {
    if (page < 1 || page > 1000 || query.length > 200) throw ArgumentError('Invalid memory list request');
    final context = _resolve(selector);
    final selection = await context.corpus.selectDocuments(include: (_, _) => true);
    final health = await context.health.read(
      canonicalRevision: selection.collectionRevision,
      canonicalFingerprint: selection.fingerprint,
    );
    final corpus = selection.corpus;
    final entries = <({CanonicalMemoryEntry entry, String state})>[
      for (final topic in corpus.topics)
        for (final entry in topic.entries) (entry: entry, state: 'active'),
      for (final entry in corpus.archive?.entries ?? const <CanonicalMemoryEntry>[]) (entry: entry, state: 'archived'),
    ];
    entries.sort((a, b) => b.entry.updated.compareTo(a.entry.updated));
    final q = query.trim();
    var selected = entries;
    var degraded = !health.isCurrent(selection.collectionRevision, selection.fingerprint);
    if (q.isNotEmpty) {
      final search = await _storage
          .searchBackendFor(context.principal)
          .search(
            q,
            limit: MemoryResourceLimits.searchResults,
            userId: context.principal,
            layers: const {SearchResultLayer.memory},
          );
      degraded = degraded || search.degradedLayers.isNotEmpty;
      final ids = search.results.map((hit) => hit.entryId).whereType<String>().toSet();
      selected = entries.where((entry) => ids.contains(entry.entry.id)).toList();
    }
    final offset = (page - 1) * pageSize;
    final visible = offset >= selected.length
        ? const <({CanonicalMemoryEntry entry, String state})>[]
        : selected.skip(offset).take(pageSize).toList();
    final currentRevision = (await context.corpus.manifest()).collectionRevision;
    if (currentRevision != selection.collectionRevision) {
      return {
        'selected': _identity(context, selector ?? 'owner'),
        'collectionRevision': currentRevision,
        'health': const {'state': 'unavailable'},
        'state': 'staleResult',
        'entries': const <Object>[],
        'query': q,
        'page': page,
        'hasNext': false,
        'sharedKnowledge': 'Separate from private agent memory',
      };
    }
    return {
      'selected': _identity(context, selector ?? 'owner'),
      'collectionRevision': selection.collectionRevision,
      'health': health.toJson(),
      'state': degraded
          ? 'degraded'
          : entries.isEmpty
          ? 'empty'
          : selected.isEmpty
          ? 'noMatch'
          : 'available',
      'entries': [for (final item in visible) _entry(item.entry, item.state, selection.collectionRevision)],
      'query': q,
      'page': page,
      'hasNext': offset + visible.length < selected.length,
      'sharedKnowledge': 'Separate from private agent memory',
    };
  }

  Future<Map<String, Object?>> detail({String? selector, required String id}) async {
    final context = _resolve(selector);
    final selection = await context.corpus.selectRecord(id);
    final manifest = await context.corpus.manifest();
    final health = await context.health.read(
      canonicalRevision: manifest.collectionRevision,
      canonicalFingerprint: manifest.fingerprint,
    );
    CanonicalMemoryEntry? entry;
    String? state;
    if (selection != null && selection.collectionRevision == manifest.collectionRevision) {
      for (final topic in selection.corpus.topics) {
        for (final candidate in topic.entries) {
          if (candidate.id == id) {
            entry = candidate;
            state = 'active';
          }
        }
      }
      for (final candidate in selection.corpus.archive?.entries ?? const <CanonicalMemoryEntry>[]) {
        if (candidate.id == id) {
          entry = candidate;
          state = 'archived';
        }
      }
    }
    return {
      'selected': _identity(context, selector ?? 'owner'),
      'collectionRevision': manifest.collectionRevision,
      'health': health.toJson(),
      'state': selection != null && selection.collectionRevision != manifest.collectionRevision
          ? 'staleResult'
          : entry == null
          ? 'notFound'
          : 'available',
      'entry': entry == null ? null : _entry(entry, state!, manifest.collectionRevision),
      'removalDisclosure': removalDisclosure,
    };
  }

  Future<Map<String, Object?>> apply({
    String? selector,
    required String id,
    required int expectedCollectionRevision,
    required int expectedEntryRevision,
    required String kind,
    String? topic,
    String? content,
    String? state,
    String? reason,
  }) async {
    if (selector == null || selector.isEmpty) throw const MemoryAdminUnavailable();
    final context = _resolve(selector);
    if (kind != 'revise' && kind != 'remove') throw ArgumentError('Invalid memory operation');
    final operation = kind == 'revise'
        ? {
            'kind': 'revise',
            'correlationId': 'admin',
            'targetId': id,
            'expectedEntryRevision': expectedEntryRevision,
            'topic': topic,
            'content': content,
            'state': state,
          }
        : {
            'kind': 'remove',
            'correlationId': 'admin',
            'targetId': id,
            'expectedEntryRevision': expectedEntryRevision,
            'reason': reason,
          };
    final service = MemoryApplyService(
      corpus: context.corpus,
      reconcileIndex: (_, _, _, _, _) async {
        final manifest = await context.corpus.manifest();
        final health = await context.health.read(
          canonicalRevision: manifest.collectionRevision,
          canonicalFingerprint: manifest.fingerprint,
        );
        if (!health.isCurrent(manifest.collectionRevision, manifest.fingerprint)) {
          throw StateError(health.reason ?? 'memory index projection is degraded');
        }
      },
    );
    final result = await service.apply(
      {
        'expectedRevision': expectedCollectionRevision,
        'operations': [operation],
      },
      userId: context.principal,
      provenance: MemorySourceRef(sourceLocator: 'memory-admin', caller: 'owner'),
    );
    final current = await detail(selector: selector, id: id);
    return {
      ...result,
      'selected': _identity(context, selector),
      'currentEntry': current['entry'],
      'removalDisclosure': removalDisclosure,
    };
  }

  Map<String, Object?> _identity(WorkspaceMemoryContext context, String selector) {
    final configured = _storage.memoryContexts.any((item) => item.principal == context.principal);
    return {
      'selector': selector,
      'label': context.workspace?.agentId ?? 'Default agent',
      'kind': context.principal == 'owner'
          ? 'default'
          : configured
          ? 'configured'
          : 'retained',
      'principal': context.principal,
    };
  }

  Map<String, Object?> _entry(CanonicalMemoryEntry entry, String state, int collectionRevision) => {
    'id': entry.id,
    'entryRevision': entry.revision,
    'collectionRevision': collectionRevision,
    'topic': entry.topic,
    'summary': entry.summary,
    'content': entry.content,
    'state': state,
    'created': entry.created.toIso8601String(),
    'updated': entry.updated.toIso8601String(),
    'provenance': entry.provenance.sourceLocator,
  };
}
