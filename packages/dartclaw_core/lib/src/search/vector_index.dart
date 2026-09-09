import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';

/// Selects one fixed vector corpus prepared by the storage schema gate.
final class VectorTable {
  /// Memory-chunk vector projection.
  static final memoryChunks = VectorTable._('memory_vectors');

  /// Conversation-chunk vector projection.
  static final conversationChunks = VectorTable._('conversation_vectors');

  const new _(this.tableName);

  /// Fixed database table name selected by this descriptor.
  final String tableName;
}

/// SQLite implementation of [VectorIndex].
final class SqliteVectorIndex implements VectorIndex {
  /// Creates an index over one fixed vector corpus.
  new(DatabaseBackend backend, {required VectorTable table}) : _backend = backend, _table = table;

  final DatabaseBackend _backend;
  final VectorTable _table;

  @override
  Future<List<VectorMatch>> search(
    List<double> queryVector, {
    required String userId,
    required String modelFingerprint,
    int limit = 20,
  }) async {
    final query = _validatedQuery(queryVector, modelFingerprint: modelFingerprint, limit: limit);
    final queryNorm = _norm(query);
    if (queryNorm == 0) return const [];
    final rows = await _backend.query(
      '''
        SELECT document_id, chunk_index, content_hash, model_fingerprint, dimension, embedding
        FROM ${_table.tableName}
        WHERE user_id = ? AND model_fingerprint = ? AND dimension = ?
      ''',
      [userId, modelFingerprint, query.length],
    );
    final matches = <VectorMatch>[];
    for (final row in rows) {
      final record = _sqliteRecord(row, _table);
      final candidateNorm = _norm(record.vector);
      if (candidateNorm == 0) continue;
      var dot = 0.0;
      for (var index = 0; index < query.length; index++) {
        dot += query[index] * record.vector[index];
      }
      final score = dot / (queryNorm * candidateNorm);
      if (!score.isFinite) throw _corruptProjection(_table, 'non-finite cosine score');
      matches.add(
        VectorMatch(
          documentId: record.documentId,
          chunkIndex: record.chunkIndex,
          contentHash: record.contentHash,
          score: score,
        ),
      );
    }
    matches.sort(_compareMatches);
    return List.unmodifiable(matches.take(limit));
  }

  @override
  Future<List<VectorRecord>> list({required String userId}) async {
    final rows = await _backend.query(
      '''
        SELECT document_id, chunk_index, content_hash, model_fingerprint, dimension, embedding
        FROM ${_table.tableName}
        WHERE user_id = ?
        ORDER BY document_id, chunk_index
      ''',
      [userId],
    );
    return List.unmodifiable(rows.map((row) => _sqliteRecord(row, _table)));
  }

  @override
  Future<void> upsert(
    Iterable<VectorRecord> records, {
    required String userId,
    Set<VectorIdentity> retire = const {},
  }) async {
    final replacements = _storedRecords(records);
    if (replacements.isEmpty && retire.isEmpty) return;
    await _backend.transaction((tx) async {
      await _deleteIdentities(tx, {...retire, ...replacements.keys}, userId);
      await _insert(tx, replacements.values, userId);
    });
  }

  @override
  Future<void> delete(Iterable<VectorIdentity> identities, {required String userId}) async {
    final selected = identities.toSet();
    if (selected.isEmpty) return;
    await _backend.transaction((tx) => _deleteIdentities(tx, selected, userId));
  }

  @override
  Future<void> replaceAll(Iterable<VectorRecord> records, {required String userId}) async {
    final replacements = _storedRecords(records);
    await _backend.transaction((tx) async {
      await tx.execute('DELETE FROM ${_table.tableName} WHERE user_id = ?', [userId]);
      await _insert(tx, replacements.values, userId);
    });
  }

  Future<void> _deleteIdentities(DatabaseBackend backend, Set<VectorIdentity> identities, String userId) async {
    final selected = _sortedIdentities(identities);
    if (selected.isEmpty) return;
    final clauses = List.filled(selected.length, '(document_id = ? AND chunk_index = ?)').join(' OR ');
    await backend.execute('DELETE FROM ${_table.tableName} WHERE user_id = ? AND ($clauses)', [
      userId,
      for (final identity in selected) ...[identity.documentId, identity.chunkIndex],
    ]);
  }

  Future<void> _insert(DatabaseBackend backend, Iterable<_StoredVector> records, String userId) async {
    final statement = await backend.prepare('''INSERT INTO ${_table.tableName}
         (user_id, document_id, chunk_index, content_hash, model_fingerprint, dimension, embedding)
         VALUES (?, ?, ?, ?, ?, ?, ?)''');
    try {
      for (final stored in records) {
        final record = stored.record;
        await statement.execute([
          userId,
          record.documentId,
          record.chunkIndex,
          record.contentHash,
          record.modelFingerprint,
          stored.values.length,
          stored.bytes,
        ]);
      }
    } finally {
      await statement.close();
    }
  }
}

/// PostgreSQL pgvector implementation of [VectorIndex].
final class PostgresVectorIndex implements VectorIndex {
  /// Creates an index over one fixed vector corpus.
  new(DatabaseBackend backend, {required VectorTable table}) : _backend = backend, _table = table;

  final DatabaseBackend _backend;
  final VectorTable _table;

  @override
  Future<List<VectorMatch>> search(
    List<double> queryVector, {
    required String userId,
    required String modelFingerprint,
    int limit = 20,
  }) async {
    final query = _validatedQuery(queryVector, modelFingerprint: modelFingerprint, limit: limit);
    if (_norm(query) == 0) return const [];
    final literal = _vectorLiteral(query);
    final rows = await _backend.query(
      '''
        WITH query_vector AS MATERIALIZED (
          SELECT CAST(? AS public.vector) AS embedding
        ), candidates AS MATERIALIZED (
          SELECT document_id, chunk_index, content_hash, embedding
          FROM ${_table.tableName}
          WHERE user_id = ? AND model_fingerprint = ? AND dimension = ?
            AND public.vector_dims(embedding) = ? AND public.vector_norm(embedding) > 0
        )
        SELECT document_id, chunk_index, content_hash,
               1 - (candidates.embedding OPERATOR(public.<=>) query_vector.embedding) AS score
        FROM candidates CROSS JOIN query_vector
        ORDER BY score DESC, document_id, chunk_index
        LIMIT ?
      ''',
      [literal, userId, modelFingerprint, query.length, query.length, limit],
    );
    return List.unmodifiable(rows.map((row) => _postgresMatch(row, _table)));
  }

  @override
  Future<List<VectorRecord>> list({required String userId}) async {
    final rows = await _backend.query(
      '''
        SELECT document_id, chunk_index, content_hash, model_fingerprint, dimension,
               CAST(embedding AS text) AS embedding
        FROM ${_table.tableName}
        WHERE user_id = ?
        ORDER BY document_id, chunk_index
      ''',
      [userId],
    );
    return List.unmodifiable(rows.map((row) => _postgresRecord(row, _table)));
  }

  @override
  Future<void> upsert(
    Iterable<VectorRecord> records, {
    required String userId,
    Set<VectorIdentity> retire = const {},
  }) async {
    final replacements = _storedRecords(records);
    if (replacements.isEmpty && retire.isEmpty) return;
    await _backend.transaction((tx) async {
      await _deleteIdentities(tx, {...retire, ...replacements.keys}, userId);
      await _insert(tx, replacements.values, userId);
    });
  }

  @override
  Future<void> delete(Iterable<VectorIdentity> identities, {required String userId}) async {
    final selected = identities.toSet();
    if (selected.isEmpty) return;
    await _backend.transaction((tx) => _deleteIdentities(tx, selected, userId));
  }

  @override
  Future<void> replaceAll(Iterable<VectorRecord> records, {required String userId}) async {
    final replacements = _storedRecords(records);
    await _backend.transaction((tx) async {
      await tx.execute('DELETE FROM ${_table.tableName} WHERE user_id = ?', [userId]);
      await _insert(tx, replacements.values, userId);
    });
  }

  Future<void> _deleteIdentities(DatabaseBackend backend, Set<VectorIdentity> identities, String userId) async {
    final selected = _sortedIdentities(identities);
    if (selected.isEmpty) return;
    final clauses = List.filled(selected.length, '(document_id = ? AND chunk_index = ?)').join(' OR ');
    await backend.execute('DELETE FROM ${_table.tableName} WHERE user_id = ? AND ($clauses)', [
      userId,
      for (final identity in selected) ...[identity.documentId, identity.chunkIndex],
    ]);
  }

  Future<void> _insert(DatabaseBackend backend, Iterable<_StoredVector> records, String userId) async {
    final statement = await backend.prepare('''INSERT INTO ${_table.tableName}
         (user_id, document_id, chunk_index, content_hash, model_fingerprint, dimension, embedding)
         VALUES (?, ?, ?, ?, ?, ?, CAST(? AS public.vector))''');
    try {
      for (final stored in records) {
        final record = stored.record;
        await statement.execute([
          userId,
          record.documentId,
          record.chunkIndex,
          record.contentHash,
          record.modelFingerprint,
          stored.values.length,
          _vectorLiteral(stored.values),
        ]);
      }
    } finally {
      await statement.close();
    }
  }
}

final class _StoredVector {
  const new _(this.record, this.values, this.bytes);

  final VectorRecord record;
  final List<double> values;
  final Uint8List bytes;
}

Map<VectorIdentity, _StoredVector> _storedRecords(Iterable<VectorRecord> records) {
  final replacements = <VectorIdentity, _StoredVector>{};
  for (final record in records) {
    final values = _float32Values(record.vector, 'record.vector');
    final identity = VectorIdentity(documentId: record.documentId, chunkIndex: record.chunkIndex);
    replacements.remove(identity);
    replacements[identity] = _StoredVector._(record, values, _encodeFloat32(values));
  }
  return replacements;
}

List<VectorIdentity> _sortedIdentities(Iterable<VectorIdentity> identities) {
  final selected = identities.toSet().toList(growable: false);
  selected.sort((left, right) {
    final documentOrder = left.documentId.compareTo(right.documentId);
    return documentOrder != 0 ? documentOrder : left.chunkIndex.compareTo(right.chunkIndex);
  });
  return selected;
}

List<double> _validatedQuery(List<double> query, {required String modelFingerprint, required int limit}) {
  if (query.isEmpty) throw ArgumentError.value(query, 'queryVector', 'must not be empty');
  if (modelFingerprint.isEmpty) {
    throw ArgumentError.value(modelFingerprint, 'modelFingerprint', 'must not be empty');
  }
  if (limit <= 0) throw ArgumentError.value(limit, 'limit', 'must be positive');
  return _float32Values(query, 'queryVector');
}

List<double> _float32Values(List<double> values, String name) {
  final bytes = ByteData(values.length * Float32List.bytesPerElement);
  final result = List<double>.filled(values.length, 0, growable: false);
  for (var index = 0; index < values.length; index++) {
    final value = values[index];
    if (!value.isFinite) throw ArgumentError.value(value, '$name[$index]', 'must be finite');
    bytes.setFloat32(index * Float32List.bytesPerElement, value, Endian.little);
    final stored = bytes.getFloat32(index * Float32List.bytesPerElement, Endian.little);
    if (!stored.isFinite) throw ArgumentError.value(value, '$name[$index]', 'must fit finite float32');
    result[index] = stored;
  }
  return result;
}

Uint8List _encodeFloat32(List<double> values) {
  final bytes = ByteData(values.length * Float32List.bytesPerElement);
  for (var index = 0; index < values.length; index++) {
    bytes.setFloat32(index * Float32List.bytesPerElement, values[index], Endian.little);
  }
  return bytes.buffer.asUint8List();
}

List<double> _decodeFloat32(Object? value, Object? dimension) {
  if (value is! Uint8List || dimension is! int || dimension <= 0 || value.length != dimension * 4) {
    throw const FormatException('invalid float32 vector representation');
  }
  final data = ByteData.sublistView(value);
  return List<double>.generate(dimension, (index) {
    final component = data.getFloat32(index * Float32List.bytesPerElement, Endian.little);
    if (!component.isFinite) throw const FormatException('non-finite float32 vector component');
    return component;
  }, growable: false);
}

VectorRecord _sqliteRecord(Map<String, Object?> row, VectorTable table) {
  try {
    return VectorRecord(
      documentId: _storedString(row, 'document_id'),
      chunkIndex: _storedNonNegativeInt(row, 'chunk_index'),
      contentHash: _storedString(row, 'content_hash'),
      modelFingerprint: _storedString(row, 'model_fingerprint'),
      vector: _decodeFloat32(row['embedding'], _storedPositiveInt(row, 'dimension')),
    );
  } on FormatException {
    throw _corruptProjection(table, 'invalid SQLite float32 record');
  }
}

VectorRecord _postgresRecord(Map<String, Object?> row, VectorTable table) {
  try {
    final dimension = _storedPositiveInt(row, 'dimension');
    final vector = _parseVector(_storedString(row, 'embedding'));
    if (vector.length != dimension) throw const FormatException('dimension mismatch');
    return VectorRecord(
      documentId: _storedString(row, 'document_id'),
      chunkIndex: _storedNonNegativeInt(row, 'chunk_index'),
      contentHash: _storedString(row, 'content_hash'),
      modelFingerprint: _storedString(row, 'model_fingerprint'),
      vector: vector,
    );
  } on FormatException {
    throw _corruptProjection(table, 'invalid PostgreSQL vector record');
  }
}

VectorMatch _postgresMatch(Map<String, Object?> row, VectorTable table) {
  try {
    return VectorMatch(
      documentId: _storedString(row, 'document_id'),
      chunkIndex: _storedNonNegativeInt(row, 'chunk_index'),
      contentHash: _storedString(row, 'content_hash'),
      score: _storedFiniteDouble(row, 'score'),
    );
  } on FormatException {
    throw _corruptProjection(table, 'invalid PostgreSQL vector match');
  }
}

String _storedString(Map<String, Object?> row, String name) {
  final value = row[name];
  if (value is! String || value.isEmpty) throw FormatException('invalid $name');
  return value;
}

int _storedNonNegativeInt(Map<String, Object?> row, String name) {
  final value = row[name];
  if (value is! int || value < 0) throw FormatException('invalid $name');
  return value;
}

int _storedPositiveInt(Map<String, Object?> row, String name) {
  final value = row[name];
  if (value is! int || value <= 0) throw FormatException('invalid $name');
  return value;
}

double _storedFiniteDouble(Map<String, Object?> row, String name) {
  final value = row[name];
  if (value is! num) throw FormatException('invalid $name');
  final result = value.toDouble();
  if (!result.isFinite) throw FormatException('invalid $name');
  return result;
}

List<double> _parseVector(String encoded) {
  if (!encoded.startsWith('[') || !encoded.endsWith(']')) throw const FormatException('invalid vector text');
  final body = encoded.substring(1, encoded.length - 1);
  if (body.isEmpty) throw const FormatException('empty vector text');
  final values = body.split(',').map(double.parse).toList(growable: false);
  if (values.any((value) => !value.isFinite)) throw const FormatException('non-finite vector text');
  return values;
}

String _vectorLiteral(List<double> values) => '[${values.join(',')}]';

double _norm(List<double> values) {
  var sum = 0.0;
  for (final value in values) {
    sum += value * value;
  }
  return math.sqrt(sum);
}

int _compareMatches(VectorMatch left, VectorMatch right) {
  final scoreOrder = right.score.compareTo(left.score);
  if (scoreOrder != 0) return scoreOrder;
  final documentOrder = left.documentId.compareTo(right.documentId);
  return documentOrder != 0 ? documentOrder : left.chunkIndex.compareTo(right.chunkIndex);
}

SchemaIncompatibleException _corruptProjection(VectorTable table, String difference) => SchemaIncompatibleException(
  storeName: table.tableName,
  foundEpoch: 'current',
  differences: [difference],
  action: 'Reset and rebuild only the derived vector projection.',
);
