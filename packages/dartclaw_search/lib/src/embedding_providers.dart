import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:llamadart/llamadart.dart';

part 'http_embedding_provider.dart';
part 'native_embedding_provider.dart';

/// Checks whether one explicit embedding request may access [uri].
typedef NetworkAccessCheck = Future<void> Function(Uri uri);

const _nativeQueryPrefix = 'task: search result | query: ';
const _nativeDocumentPrefix = 'title: none | text: ';
const _nativeConvention = 'embeddinggemma-input-v1';
const _httpConvention = 'openai-compatible-raw-input-v1';

String _fingerprint(Map<String, String> fields) => sha256.convert(utf8.encode(jsonEncode(fields))).toString();

List<double> _validateVector(Object? value, String operation) {
  if (value is! List || value.isEmpty) {
    throw _EmbeddingFailure('$operation returned an invalid embedding');
  }
  final vector = <double>[];
  for (final component in value) {
    if (component is! num || !component.isFinite) {
      throw _EmbeddingFailure('$operation returned an invalid embedding');
    }
    vector.add(component.toDouble());
  }
  return List.unmodifiable(vector);
}

int _validateDimension(int? expected, List<double> vector, String operation) {
  if (expected != null && vector.length != expected) {
    throw _EmbeddingFailure('$operation returned inconsistent embedding dimensions');
  }
  return expected ?? vector.length;
}

Duration _remaining(Duration timeout, Stopwatch elapsed, String operation) {
  final remaining = timeout - elapsed.elapsed;
  if (remaining <= Duration.zero) throw _EmbeddingFailure('$operation timed out');
  return remaining;
}

final class _EmbeddingFailure implements Exception {
  final String message;

  const new(this.message);

  @override
  String toString() => message;
}
