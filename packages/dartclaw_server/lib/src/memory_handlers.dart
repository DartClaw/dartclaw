import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:logging/logging.dart';

final _log = Logger('MemoryHandlers');

/// Creates memory bridge handler closures for wiring into AgentHarness.
({
  Future<Map<String, dynamic>> Function(Map<String, dynamic>) onSave,
  Future<Map<String, dynamic>> Function(Map<String, dynamic>) onSearch,
  Future<Map<String, dynamic>> Function(Map<String, dynamic>) onRead,
})
createMemoryHandlers({required MemoryService memory, required MemoryFileService memoryFile}) {
  return (
    onSave: (Map<String, dynamic> params) async {
      final text = params['text'] as String;
      if (text.trim().isEmpty) {
        throw ArgumentError('text must not be empty');
      }
      final category = _sanitizeCategory((params['category'] as String?) ?? 'general');
      final stripped = MemoryFileService.stripMarkdown(text);
      final chunks = MemoryFileService.splitParagraphs(stripped);

      await memoryFile.appendMemory(text: text, category: category);

      for (final chunk in chunks) {
        try {
          memory.insertChunk(text: chunk, source: 'memory_save', category: category);
        } catch (e) {
          // SQLite index failure after file write — rebuild-index CLI is recovery path
          _log.warning('Failed to index memory chunk: $e');
        }
      }

      return {'ok': true, 'chunks_created': chunks.length};
    },
    onSearch: (Map<String, dynamic> params) async {
      final query = params['query'] as String;
      if (query.trim().isEmpty) return {'results': <Map<String, dynamic>>[]};

      final limit = (params['limit'] as num?)?.toInt() ?? 5;
      final sanitized = _sanitizeFts5Query(query);
      if (sanitized == '""') return {'results': <Map<String, dynamic>>[]};
      final results = memory.search(sanitized, limit: limit);

      return {
        'results':
            results.map((r) => {'text': r.text, 'source': r.source, 'score': r.score, 'category': r.category}).toList(),
      };
    },
    onRead: (Map<String, dynamic> params) async {
      final content = await memoryFile.readMemory();
      return {'content': content, 'size_bytes': utf8.encode(content).length};
    },
  );
}

/// Sanitizes category to lowercase alphanumeric + hyphens.
String _sanitizeCategory(String input) {
  final sanitized = input.toLowerCase().replaceAll(RegExp(r'[^a-z0-9-]'), '-').replaceAll(RegExp(r'-{2,}'), '-');
  final trimmed = sanitized.replaceAll(RegExp(r'^-+|-+$'), '');
  return trimmed.isEmpty ? 'general' : trimmed;
}

/// Sanitizes user input for FTS5 MATCH: strips operators and quotes each word
/// individually for implicit AND matching (safe against injection).
String _sanitizeFts5Query(String query) {
  var cleaned = query.replaceAll('"', '');
  cleaned = cleaned.replaceAll(RegExp(r'\b(AND|OR|NOT|NEAR)\b', caseSensitive: false), '');
  cleaned = cleaned.replaceAll(RegExp(r'[*^:+\-()]'), '');
  final words = cleaned.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return '""';
  return words.map((w) => '"$w"').join(' ');
}
