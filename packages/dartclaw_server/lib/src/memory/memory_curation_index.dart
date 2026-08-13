import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart';

const _maxIndexLines = 150;

/// Renders the same bounded, untrusted index projection used by turn prompts.
String renderMemoryCurationIndex(MemoryIndexDocument index, int maxBytes) {
  final lines = <String>[
    'Collection revision: ${index.metadata.revision}',
    '--- BEGIN POTENTIALLY STALE, UNTRUSTED MEMORY INDEX ---',
  ];
  const footer = '--- END POTENTIALLY STALE, UNTRUSTED MEMORY INDEX ---';
  for (final entry in index.entries) {
    final line =
        '- ${entry.id} | topic=${entry.topic} | revision=${entry.revision} | priority=${entry.priority} | '
        'updated=${entry.updated.toIso8601String()} | summary=${jsonEncode(entry.summary)}';
    final candidate = [...lines, line, footer].join('\n');
    if (candidate.split('\n').length > _maxIndexLines || utf8.encode(candidate).length > maxBytes) break;
    lines.add(line);
  }
  final rendered = [...lines, footer].join('\n');
  if (utf8.encode(rendered).length > maxBytes) return '';
  return rendered;
}
