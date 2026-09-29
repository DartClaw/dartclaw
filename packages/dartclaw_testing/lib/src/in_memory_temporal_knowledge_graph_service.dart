import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';

/// In-memory temporal knowledge graph for tests that do not exercise storage.
final class InMemoryTemporalKnowledgeGraphService extends TemporalKnowledgeGraphService {
  new() : super(_UnusedDatabaseBackend());

  final Map<int, KnowledgeFact> _facts = {};
  var _nextId = 1;

  @override
  Future<int> addFact({
    required String entity,
    required String predicate,
    required String value,
    required String validFrom,
    String? validTo,
    required String source,
    String? owner,
  }) async {
    final from = _parse(validFrom, 'valid_from');
    final to = validTo == null || validTo.trim().isEmpty ? null : _parse(validTo, 'valid_to');
    if (to != null && to.isBefore(from)) throw ArgumentError('valid_to must not be before valid_from');
    final id = _nextId++;
    _facts[id] = KnowledgeFact(
      id: id,
      entity: normalizeKnowledgeEntity(entity),
      predicate: _required(predicate, 'predicate'),
      value: _required(value, 'value'),
      validFrom: from.toUtc().toIso8601String(),
      validTo: to?.toUtc().toIso8601String(),
      source: _required(source, 'source'),
      owner: owner == null || owner.trim().isEmpty ? null : owner.trim(),
    );
    return id;
  }

  @override
  Future<List<KnowledgeFact>> query({
    required String entity,
    String? predicate,
    String? asOf,
    bool includeInvalidated = false,
  }) async {
    final instant = asOf == null || asOf.trim().isEmpty ? null : _parse(asOf, 'as_of');
    final normalizedEntity = normalizeKnowledgeEntity(entity);
    final normalizedPredicate = predicate?.trim();
    final facts = _facts.values.where((fact) {
      if (fact.entity != normalizedEntity) return false;
      if (normalizedPredicate != null && normalizedPredicate.isNotEmpty && fact.predicate != normalizedPredicate) {
        return false;
      }
      if (instant != null) return _isValidAt(fact, instant, includeInvalidated: includeInvalidated);
      return includeInvalidated || fact.invalidatedAt == null;
    }).toList();
    facts.sort((left, right) {
      final byStart = right.validFrom.compareTo(left.validFrom);
      return byStart != 0 ? byStart : right.id.compareTo(left.id);
    });
    return facts;
  }

  @override
  Future<List<KnowledgeFact>> allFacts({String? asOf, String? search, int? limit}) async {
    if (limit != null && limit < 1) return const [];
    final instant = asOf == null || asOf.trim().isEmpty ? null : _parse(asOf, 'as_of');
    final terms = search
        ?.replaceAll('"', ' ')
        .split(RegExp(r'\s+'))
        .map((term) => term.trim().toLowerCase())
        .where((term) => term.isNotEmpty)
        .toList();
    final facts = _facts.values.where((fact) {
      if (instant != null && !_isValidAt(fact, instant, includeInvalidated: false)) return false;
      if (terms == null || terms.isEmpty) return true;
      final searchable = '${fact.entity} ${fact.predicate} ${fact.value} ${fact.source}'.toLowerCase();
      return terms.every(searchable.contains);
    }).toList();
    facts.sort((left, right) {
      final byEntity = left.entity.compareTo(right.entity);
      if (byEntity != 0) return byEntity;
      final byStart = left.validFrom.compareTo(right.validFrom);
      return byStart != 0 ? byStart : left.id.compareTo(right.id);
    });
    return limit == null ? facts : facts.take(limit).toList();
  }

  @override
  DateTime parseAsOf(String asOf) => _parse(asOf, 'as_of');

  @override
  Future<List<KnowledgeFact>> timeline({required String entity, String? predicate}) async {
    final normalizedEntity = normalizeKnowledgeEntity(entity);
    final normalizedPredicate = predicate?.trim();
    final facts = _facts.values
        .where(
          (fact) =>
              fact.entity == normalizedEntity &&
              (normalizedPredicate == null || normalizedPredicate.isEmpty || fact.predicate == normalizedPredicate),
        )
        .toList();
    facts.sort((left, right) {
      final byStart = left.validFrom.compareTo(right.validFrom);
      return byStart != 0 ? byStart : left.id.compareTo(right.id);
    });
    return facts;
  }

  @override
  Future<bool> invalidate({required int id, required String invalidatedAt, required String reason}) async {
    final existing = _facts[id];
    if (existing == null) return false;
    final instant = _parse(invalidatedAt, 'invalidated_at');
    if (instant.isBefore(_parse(existing.validFrom, 'valid_from'))) {
      throw ArgumentError('invalidated_at must not be before valid_from');
    }
    final iso = instant.toUtc().toIso8601String();
    final existingTo = existing.validTo;
    _facts[id] = KnowledgeFact(
      id: existing.id,
      entity: existing.entity,
      predicate: existing.predicate,
      value: existing.value,
      validFrom: existing.validFrom,
      validTo: existingTo == null || existingTo.compareTo(iso) > 0 ? iso : existingTo,
      source: existing.source,
      owner: existing.owner,
      invalidatedAt: iso,
      invalidationReason: _required(reason, 'reason'),
    );
    return true;
  }

  @override
  Future<String?> ownerForFact(int id) async => _facts[id]?.owner;

  @override
  Future<KnowledgeFact?> factById(int id) async => _facts[id];

  @override
  Future<bool> factExists(int id) async => _facts.containsKey(id);

  @override
  Future<List<KnowledgeContradiction>> contradictions({
    required String entity,
    required String predicate,
    required String value,
  }) async {
    final normalizedEntity = normalizeKnowledgeEntity(entity);
    final normalizedPredicate = _required(predicate, 'predicate');
    final normalizedValue = _required(value, 'value');
    final facts =
        _facts.values
            .where(
              (fact) =>
                  fact.entity == normalizedEntity &&
                  fact.predicate == normalizedPredicate &&
                  fact.value != normalizedValue &&
                  fact.invalidatedAt == null &&
                  fact.validTo == null,
            )
            .toList()
          ..sort((left, right) => right.id.compareTo(left.id));
    return facts.map((fact) => KnowledgeContradiction(existing: fact, incomingValue: normalizedValue)).toList();
  }

  @override
  Future<List<KnowledgeContradiction>> openContradictions() async {
    final facts = _facts.values.where((fact) => fact.invalidatedAt == null && fact.validTo == null).toList()
      ..sort((left, right) {
        final byEntity = left.entity.compareTo(right.entity);
        if (byEntity != 0) return byEntity;
        final byPredicate = left.predicate.compareTo(right.predicate);
        return byPredicate != 0 ? byPredicate : left.id.compareTo(right.id);
      });
    final contradictions = <KnowledgeContradiction>[];
    for (var left = 0; left < facts.length; left++) {
      for (var right = left + 1; right < facts.length; right++) {
        final existing = facts[left];
        final incoming = facts[right];
        if (existing.entity == incoming.entity &&
            existing.predicate == incoming.predicate &&
            existing.value != incoming.value) {
          contradictions.add(KnowledgeContradiction(existing: existing, incomingValue: incoming.value));
        }
      }
    }
    return contradictions;
  }

  static DateTime _parse(String value, String field) =>
      tryParseIsoInstant(value) ?? (throw ArgumentError('$field must be an ISO-8601 date or timestamp'));

  static String _required(String value, String field) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) throw ArgumentError('$field must not be empty');
    return trimmed;
  }

  static bool _isValidAt(KnowledgeFact fact, DateTime instant, {required bool includeInvalidated}) {
    final asOf = instant.toUtc();
    if (_parse(fact.validFrom, 'valid_from').isAfter(asOf)) return false;
    if (fact.validTo case final validTo?) {
      if (_parse(validTo, 'valid_to').isBefore(asOf)) return false;
    }
    final invalidatedAt = fact.invalidatedAt;
    if (!includeInvalidated && invalidatedAt != null) {
      if (!_parse(invalidatedAt, 'invalidated_at').isAfter(asOf)) return false;
    }
    return true;
  }
}

final class _UnusedDatabaseBackend implements DatabaseBackend {
  @override
  Future<void> close() async {}

  @override
  Future<int> execute(String sql, [List<Object?> parameters = const []]) =>
      throw UnsupportedError('The in-memory knowledge graph does not use SQL');

  @override
  Future<DatabaseStatement> prepare(String sql) =>
      throw UnsupportedError('The in-memory knowledge graph does not use SQL');

  @override
  Future<List<Map<String, Object?>>> query(String sql, [List<Object?> parameters = const []]) =>
      throw UnsupportedError('The in-memory knowledge graph does not use SQL');

  @override
  Future<T> transaction<T>(Future<T> Function(DatabaseBackend tx) body) => body(this);
}
