import 'package:dartclaw_core/dartclaw_core.dart' show MemorySearchResult;
import 'package:sqlite3/sqlite3.dart';

import 'known_systems.dart';

/// SQLite-backed service for time-bounded operational facts.
class TemporalKnowledgeGraphService {
  final Database _db;

  /// Creates the KG schema on [_db] and enables SQLite foreign-key checks.
  TemporalKnowledgeGraphService(this._db) {
    _db.execute('PRAGMA foreign_keys=ON');
    _initSchema();
  }

  void _initSchema() {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS kg_facts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        entity TEXT NOT NULL,
        predicate TEXT NOT NULL,
        value TEXT NOT NULL,
        valid_from TEXT NOT NULL,
        valid_to TEXT,
        source TEXT NOT NULL,
        owner TEXT,
        invalidated_at TEXT,
        invalidation_reason TEXT,
        created_at TEXT NOT NULL DEFAULT (datetime('now'))
      )
    ''');
    _migrateOwnerColumn();
    _db.execute('CREATE INDEX IF NOT EXISTS kg_facts_lookup ON kg_facts(entity, predicate, valid_from, valid_to)');
  }

  void _migrateOwnerColumn() {
    final columns = _db.select('PRAGMA table_info(kg_facts)').map((row) => row['name'] as String).toSet();
    if (!columns.contains('owner')) {
      _db.execute('ALTER TABLE kg_facts ADD COLUMN owner TEXT');
    }
  }

  /// Stores a source-linked temporal fact and returns its row id.
  int addFact({
    required String entity,
    required String predicate,
    required String value,
    required String validFrom,
    String? validTo,
    required String source,
    String? owner,
  }) {
    final normalizedEntity = normalizeKnowledgeEntity(entity);
    final normalizedPredicate = _required(predicate, 'predicate');
    final normalizedValue = _required(value, 'value');
    final normalizedSource = _required(source, 'source');
    final normalizedOwner = owner == null || owner.trim().isEmpty ? null : owner.trim();
    final from = _parseIso(validFrom, 'valid_from');
    final to = validTo == null || validTo.trim().isEmpty ? null : _parseIso(validTo, 'valid_to');
    if (to != null && to.isBefore(from)) {
      throw ArgumentError('valid_to must not be before valid_from');
    }

    _db.execute(
      '''
      INSERT INTO kg_facts(entity, predicate, value, valid_from, valid_to, source, owner)
      VALUES (?, ?, ?, ?, ?, ?, ?)
      ''',
      [
        normalizedEntity,
        normalizedPredicate,
        normalizedValue,
        _isoUtc(from),
        to == null ? null : _isoUtc(to),
        normalizedSource,
        normalizedOwner,
      ],
    );
    return _db.lastInsertRowId;
  }

  /// Returns facts for [entity] and optional [predicate] that are valid at [asOf].
  List<KnowledgeFact> query({
    required String entity,
    String? predicate,
    String? asOf,
    bool includeInvalidated = false,
  }) {
    final normalizedEntity = normalizeKnowledgeEntity(entity);
    final instant = asOf == null || asOf.trim().isEmpty ? null : _parseIso(asOf, 'as_of');
    final where = <String>['entity = ?'];
    final args = <Object?>[normalizedEntity];
    if (predicate != null && predicate.trim().isNotEmpty) {
      where.add('predicate = ?');
      args.add(predicate.trim());
    }
    if (instant == null && !includeInvalidated) {
      where.add('invalidated_at IS NULL');
    }
    final rows = _db.select('''
      SELECT id, entity, predicate, value, valid_from, valid_to, source, owner, invalidated_at, invalidation_reason
      FROM kg_facts
      WHERE ${where.join(' AND ')}
      ORDER BY valid_from DESC, id DESC
      ''', args);
    final facts = rows.map(KnowledgeFact.fromRow);
    if (instant == null) {
      return facts.toList();
    }
    return facts.where((fact) => _isValidAt(fact, instant, includeInvalidated: includeInvalidated)).toList();
  }

  /// Returns facts across every entity, optionally filtered by [asOf] and [search].
  List<KnowledgeFact> allFacts({String? asOf, String? search, int? limit}) {
    if (limit != null && limit < 1) {
      return const [];
    }
    final instant = asOf == null || asOf.trim().isEmpty ? null : parseAsOf(asOf);
    final where = <String>[];
    final args = <Object?>[];
    for (final term in _searchTerms(search ?? '')) {
      where.add("instr(lower(entity || ' ' || predicate || ' ' || value || ' ' || source), ?) > 0");
      args.add(term);
    }
    final sqlLimit = instant == null ? limit : null;
    if (sqlLimit != null) {
      args.add(sqlLimit);
    }
    final facts = _db
        .select('''
          SELECT id, entity, predicate, value, valid_from, valid_to, source, owner, invalidated_at, invalidation_reason
          FROM kg_facts
          ${where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}'}
          ORDER BY entity ASC, valid_from ASC, id ASC
          ${sqlLimit == null ? '' : 'LIMIT ?'}
          ''', args)
        .map(KnowledgeFact.fromRow)
        .toList();
    if (instant == null) {
      return facts;
    }
    final filtered = facts.where((fact) => _isValidAt(fact, instant, includeInvalidated: false));
    return limit == null ? filtered.toList() : filtered.take(limit).toList();
  }

  /// Parses an `as_of` date or timestamp using the graph's query semantics.
  DateTime parseAsOf(String asOf) => _parseIso(asOf, 'as_of');

  /// Returns all facts for [entity] in chronological order.
  List<KnowledgeFact> timeline({required String entity, String? predicate}) {
    final normalizedEntity = normalizeKnowledgeEntity(entity);
    final where = <String>['entity = ?'];
    final args = <Object?>[normalizedEntity];
    if (predicate != null && predicate.trim().isNotEmpty) {
      where.add('predicate = ?');
      args.add(predicate.trim());
    }
    return _db
        .select('''
          SELECT id, entity, predicate, value, valid_from, valid_to, source, owner, invalidated_at, invalidation_reason
          FROM kg_facts
          WHERE ${where.join(' AND ')}
          ORDER BY valid_from ASC, id ASC
          ''', args)
        .map(KnowledgeFact.fromRow)
        .toList();
  }

  /// Marks a fact invalidated while preserving the original row.
  bool invalidate({required int id, required String invalidatedAt, required String reason}) {
    final instant = _parseIso(invalidatedAt, 'invalidated_at');
    final normalizedReason = _required(reason, 'reason');
    final iso = _isoUtc(instant);
    final existing = _db.select('SELECT valid_from FROM kg_facts WHERE id = ?', [id]);
    if (existing.isEmpty) return false;
    final validFrom = _parseIso(existing.first['valid_from'] as String, 'valid_from');
    if (instant.isBefore(validFrom)) {
      throw ArgumentError('invalidated_at must not be before valid_from');
    }
    _db.execute(
      '''
      UPDATE kg_facts
      SET invalidated_at = ?,
          invalidation_reason = ?,
          valid_to = CASE WHEN valid_to IS NULL OR valid_to > ? THEN ? ELSE valid_to END
      WHERE id = ?
      ''',
      [iso, normalizedReason, iso, iso, id],
    );
    return _db.updatedRows > 0;
  }

  /// Returns the owner principal for [id], or `null` for legacy/system-owned rows.
  String? ownerForFact(int id) {
    final rows = _db.select('SELECT owner FROM kg_facts WHERE id = ?', [id]);
    if (rows.isEmpty) return null;
    return rows.first['owner'] as String?;
  }

  /// Whether a fact row with [id] exists.
  bool factExists(int id) => _db.select('SELECT 1 FROM kg_facts WHERE id = ? LIMIT 1', [id]).isNotEmpty;

  /// Whether the backing schema contains the additive owner column.
  bool get hasOwnerColumn => _db.select('PRAGMA table_info(kg_facts)').any((row) => row['name'] == 'owner');

  /// Finds open facts that disagree with an incoming value.
  List<KnowledgeContradiction> contradictions({
    required String entity,
    required String predicate,
    required String value,
  }) {
    final normalizedEntity = normalizeKnowledgeEntity(entity);
    final normalizedPredicate = _required(predicate, 'predicate');
    final normalizedValue = _required(value, 'value');
    return _db
        .select(
          '''
          SELECT id, entity, predicate, value, valid_from, valid_to, source, owner, invalidated_at, invalidation_reason
          FROM kg_facts
          WHERE entity = ?
            AND predicate = ?
            AND value <> ?
            AND invalidated_at IS NULL
            AND valid_to IS NULL
          ORDER BY id DESC
          ''',
          [normalizedEntity, normalizedPredicate, normalizedValue],
        )
        .map((row) => KnowledgeContradiction(existing: KnowledgeFact.fromRow(row), incomingValue: normalizedValue))
        .toList();
  }

  /// Finds open fact pairs with the same entity and predicate but different values.
  List<KnowledgeContradiction> openContradictions() {
    return _db
        .select('''
          SELECT a.id, a.entity, a.predicate, a.value, a.valid_from, a.valid_to, a.source, a.owner, a.invalidated_at,
                 a.invalidation_reason, b.value AS incoming_value
          FROM kg_facts a
          JOIN kg_facts b
            ON a.entity = b.entity
           AND a.predicate = b.predicate
           AND a.value <> b.value
           AND a.id < b.id
          WHERE a.invalidated_at IS NULL
            AND b.invalidated_at IS NULL
            AND a.valid_to IS NULL
            AND b.valid_to IS NULL
          ORDER BY a.entity, a.predicate, a.id
          ''')
        .map(
          (row) => KnowledgeContradiction(
            existing: KnowledgeFact.fromRow(row),
            incomingValue: row['incoming_value'] as String,
          ),
        )
        .toList();
  }

  static DateTime _parseIso(String value, String field) {
    final trimmed = value.trim();
    final match = RegExp(
      r'^(\d{4})-(\d{2})-(\d{2})(?:$|[T ](\d{2}):(\d{2})(?::(\d{2})(?:\.(\d{1,6}))?)?(Z|[+-]\d{2}:\d{2})$)',
    ).firstMatch(trimmed);
    if (match == null) {
      throw ArgumentError('$field must be an ISO-8601 date or timestamp');
    }
    final year = int.parse(match.group(1)!);
    final month = int.parse(match.group(2)!);
    final day = int.parse(match.group(3)!);
    if (!_isValidDate(year, month, day)) {
      throw ArgumentError('$field must be an ISO-8601 date or timestamp');
    }
    if (match.group(4) == null) {
      return DateTime.utc(year, month, day);
    }
    final hour = int.parse(match.group(4)!);
    final minute = int.parse(match.group(5)!);
    final second = int.parse(match.group(6) ?? '0');
    final offset = match.group(8)!;
    if (hour > 23 || minute > 59 || second > 59 || !_isValidOffset(offset)) {
      throw ArgumentError('$field must be an ISO-8601 date or timestamp');
    }
    return DateTime.parse(trimmed).toUtc();
  }

  static bool _isValidOffset(String offset) {
    if (offset == 'Z') return true;
    final hour = int.parse(offset.substring(1, 3));
    final minute = int.parse(offset.substring(4, 6));
    return hour <= 23 && minute <= 59;
  }

  static bool _isValidDate(int year, int month, int day) {
    if (month < 1 || month > 12 || day < 1) return false;
    final normalized = DateTime.utc(year, month, day);
    return normalized.year == year && normalized.month == month && normalized.day == day;
  }

  static String _isoUtc(DateTime value) => value.toUtc().toIso8601String();

  static List<String> _searchTerms(String search) => search
      .replaceAll('"', ' ')
      .split(RegExp(r'\s+'))
      .map((term) => term.trim().toLowerCase())
      .where((term) => term.isNotEmpty)
      .toList();

  static bool _isValidAt(KnowledgeFact fact, DateTime instant, {required bool includeInvalidated}) {
    final asOf = instant.toUtc();
    if (_parseIso(fact.validFrom, 'valid_from').isAfter(asOf)) {
      return false;
    }
    final validTo = fact.validTo;
    if (validTo != null && _parseIso(validTo, 'valid_to').isBefore(asOf)) {
      return false;
    }
    final invalidatedAt = fact.invalidatedAt;
    if (!includeInvalidated && invalidatedAt != null && !_parseIso(invalidatedAt, 'invalidated_at').isAfter(asOf)) {
      return false;
    }
    return true;
  }

  static String _required(String value, String field) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) throw ArgumentError('$field must not be empty');
    return trimmed;
  }
}

/// A time-bounded fact returned by the temporal knowledge graph.
class KnowledgeFact {
  /// Stable SQLite row id.
  final int id;

  /// Normalized entity name.
  final String entity;

  /// Predicate being asserted for [entity].
  final String predicate;

  /// Stored fact value.
  final String value;

  /// Inclusive ISO-8601 validity start.
  final String validFrom;

  /// Inclusive ISO-8601 validity end, or null for open-ended facts.
  final String? validTo;

  /// Source material that supports the fact.
  final String source;

  /// Principal that owns the fact, or null for legacy/system-owned facts.
  final String? owner;

  /// ISO-8601 invalidation timestamp, when invalidated.
  final String? invalidatedAt;

  /// Operator or agent-visible invalidation reason.
  final String? invalidationReason;

  /// Creates an immutable fact snapshot.
  const KnowledgeFact({
    required this.id,
    required this.entity,
    required this.predicate,
    required this.value,
    required this.validFrom,
    this.validTo,
    required this.source,
    this.owner,
    this.invalidatedAt,
    this.invalidationReason,
  });

  /// Hydrates a fact from a SQLite result row.
  factory KnowledgeFact.fromRow(Row row) => KnowledgeFact(
    id: row['id'] as int,
    entity: row['entity'] as String,
    predicate: row['predicate'] as String,
    value: row['value'] as String,
    validFrom: row['valid_from'] as String,
    validTo: row['valid_to'] as String?,
    source: row['source'] as String,
    owner: row['owner'] as String?,
    invalidatedAt: row['invalidated_at'] as String?,
    invalidationReason: row['invalidation_reason'] as String?,
  );

  /// Converts the fact to the MCP/tool JSON shape.
  Map<String, Object?> toJson() => {
    'id': id,
    'entity': entity,
    'predicate': predicate,
    'value': value,
    'valid_from': validFrom,
    if (validTo != null) 'valid_to': validTo,
    'source': source,
    if (owner != null) 'owner': owner,
    if (invalidatedAt != null) 'invalidated_at': invalidatedAt,
    if (invalidationReason != null) 'invalidation_reason': invalidationReason,
  };

  /// Converts the fact to a memory-search-compatible result.
  MemorySearchResult toSearchResult() =>
      MemorySearchResult(text: '$entity $predicate $value', source: source, category: 'knowledge graph', score: -500.0);
}

/// A conflicting open fact detected before inserting an incoming fact.
class KnowledgeContradiction {
  /// Existing fact that conflicts with [incomingValue].
  final KnowledgeFact existing;

  /// Incoming value that would conflict with [existing].
  final String incomingValue;

  /// Creates an immutable contradiction report.
  const KnowledgeContradiction({required this.existing, required this.incomingValue});

  /// Converts the contradiction to the MCP/tool JSON shape.
  Map<String, Object?> toJson() => {'incoming_value': incomingValue, 'existing': existing.toJson()};
}
