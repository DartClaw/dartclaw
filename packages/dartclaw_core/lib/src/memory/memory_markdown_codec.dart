import 'dart:convert';

import 'canonical_memory.dart';
import 'memory_documents.dart';

/// Parses and renders deterministic, LF-terminated canonical memory Markdown.
final class MemoryMarkdownCodec {
  const MemoryMarkdownCodec();

  /// Renders [document] in stable field and record order with one final LF.
  String render(CanonicalMemoryDocument document) {
    final lines = <String>[
      '# DartClaw Canonical Memory',
      'Format-Version: $canonicalMemoryFormatVersion',
      'Role: ${document.role.wireName}',
    ];
    switch (document) {
      case MemoryIndexDocument():
        lines.addAll([
          'Collection-ID: ${document.metadata.collectionId}',
          'Collection-Revision: ${document.metadata.revision}',
          ..._renderRecords(document.entries.map(_indexFields)),
        ]);
      case MemoryTopicDocument():
        lines.addAll(['Topic: ${jsonEncode(document.topic)}', ..._renderRecords(document.entries.map(_entryFields))]);
      case MemoryArchiveDocument():
        lines.addAll(_renderRecords(document.entries.map(_entryFields)));
      case MemoryObservationDocument():
        lines.addAll(['Date: ${document.date}', ..._renderRecords(document.observations.map(_observationFields))]);
      case MemoryLearningDocument():
        lines.addAll(_renderRecords(document.entries.map(_learningFields)));
      case MemoryAuditDocument():
        lines.addAll(_renderRecords(document.records.map(_auditFields)));
    }
    return '${lines.join('\n')}\n';
  }

  /// Parses supported canonical Markdown or throws [FormatException].
  CanonicalMemoryDocument parse(String markdown) {
    if (!markdown.endsWith('\n')) throw const FormatException('Canonical Markdown must end with LF');
    if (markdown.contains('\r')) throw const FormatException('Canonical Markdown must use LF line endings');
    final lines = markdown.substring(0, markdown.length - 1).split('\n');
    if (lines.length < 3 || lines[0] != '# DartClaw Canonical Memory') {
      throw const FormatException('Not canonical memory Markdown');
    }
    final formatVersion = _integer(_field(lines[1], 'Format-Version'), 'Format-Version');
    if (formatVersion != canonicalMemoryFormatVersion) {
      throw FormatException('Unsupported format version: $formatVersion');
    }
    final role = MemoryRole.parse(_field(lines[2], 'Role'));
    var cursor = 3;
    String take(String name) {
      if (cursor >= lines.length) throw FormatException('Missing $name');
      return _field(lines[cursor++], name);
    }

    try {
      switch (role) {
        case MemoryRole.indexDocument:
          final metadata = MemoryCollectionMetadata(
            formatVersion: formatVersion,
            collectionId: take('Collection-ID'),
            revision: _integer(take('Collection-Revision'), 'Collection-Revision'),
          );
          return MemoryIndexDocument(metadata: metadata, entries: _records(lines, cursor).map(_parseIndex));
        case MemoryRole.topic:
          final topic = _string(take('Topic'), 'Topic');
          return MemoryTopicDocument(topic: topic, entries: _records(lines, cursor).map(_parseEntry));
        case MemoryRole.archive:
          return MemoryArchiveDocument(entries: _records(lines, cursor).map(_parseEntry));
        case MemoryRole.observation:
          return MemoryObservationDocument(
            date: take('Date'),
            observations: _records(lines, cursor).map(_parseObservation),
          );
        case MemoryRole.learning:
          return MemoryLearningDocument(entries: _records(lines, cursor).map(_parseLearning));
        case MemoryRole.audit:
          return MemoryAuditDocument(records: _records(lines, cursor).map(_parseAudit));
        case MemoryRole.wiki:
        case MemoryRole.kg:
          throw FormatException('Role ${role.wireName} is not a canonical memory document');
      }
    } on ArgumentError catch (error) {
      throw FormatException('Invalid ${error.name ?? 'value'}: ${error.invalidValue}');
    }
  }

  List<String> _renderRecords(Iterable<Map<String, String>> records) {
    final result = <String>[];
    for (final record in records) {
      result.add('');
      result.add('## Record');
      for (final entry in record.entries) {
        result.add('${entry.key}: ${entry.value}');
      }
    }
    return result;
  }

  List<Map<String, String>> _records(List<String> lines, int start) {
    if (start == lines.length) return const [];
    final records = <Map<String, String>>[];
    var cursor = start;
    while (cursor < lines.length) {
      if (lines[cursor++] != '') throw FormatException('Expected blank line before record at line $cursor');
      if (cursor >= lines.length || lines[cursor++] != '## Record') {
        throw FormatException('Expected record at line $cursor');
      }
      final fields = <String, String>{};
      while (cursor < lines.length && lines[cursor].isNotEmpty) {
        final separator = lines[cursor].indexOf(': ');
        if (separator < 1) throw FormatException('Invalid field at line ${cursor + 1}');
        final name = lines[cursor].substring(0, separator);
        if (fields.containsKey(name)) throw FormatException('Duplicate field: $name');
        fields[name] = lines[cursor].substring(separator + 2);
        cursor++;
      }
      records.add(fields);
    }
    return records;
  }

  Map<String, String> _indexFields(MemoryIndexEntry entry) => {
    'ID': entry.id,
    'Revision': '${entry.revision}',
    'Topic': jsonEncode(entry.topic),
    'Summary': jsonEncode(entry.summary),
    'Updated': entry.updated.toIso8601String(),
    'Priority': '${entry.priority}',
    'Locator': entry.locator,
  };

  Map<String, String> _entryFields(CanonicalMemoryEntry entry) => {
    'ID': entry.id,
    'Revision': '${entry.revision}',
    'Topic': jsonEncode(entry.topic),
    'Summary': jsonEncode(entry.summary),
    'Content': jsonEncode(entry.content),
    'Created': entry.created.toIso8601String(),
    'Updated': entry.updated.toIso8601String(),
    ..._sourceFields(entry.provenance),
  };

  Map<String, String> _learningFields(CanonicalMemoryLearning entry) => {
    'ID': entry.id,
    'Revision': '${entry.revision}',
    'Summary': jsonEncode(entry.summary),
    'Content': jsonEncode(entry.content),
    'Created': entry.created.toIso8601String(),
    'Updated': entry.updated.toIso8601String(),
    ..._sourceFields(entry.provenance),
  };

  Map<String, String> _observationFields(MemoryObservation observation) => {
    'ID': observation.id,
    'Recorded': observation.recorded.toIso8601String(),
    'Content': jsonEncode(observation.content),
    'Trust-Label': jsonEncode(observation.trustLabel),
    'Truncated': '${observation.isTruncated}',
    'Resulting-Entry-IDs': jsonEncode(observation.resultingEntryIds),
    ..._sourceFields(observation.provenance),
  };

  Map<String, String> _auditFields(MemoryDeletionAudit audit) => {
    'Entry-ID': audit.entryId,
    'Deleted-At': audit.deletedAt.toIso8601String(),
    'Reason': jsonEncode(audit.reason),
    ..._sourceFields(audit.provenance),
  };

  Map<String, String> _sourceFields(MemorySourceRef source) => {
    'Origin-Kind': source.originKind?.name ?? '-',
    'Source-Locator': jsonEncode(source.sourceLocator),
    'Source-Event': source.sourceEvent == null ? '-' : jsonEncode(source.sourceEvent),
    'Caller': source.caller == null ? '-' : jsonEncode(source.caller),
    'Session-Ref': source.sessionRef == null ? '-' : jsonEncode(source.sessionRef),
  };
}

MemoryIndexEntry _parseIndex(Map<String, String> fields) {
  _requireExactFields(fields, const {'ID', 'Revision', 'Topic', 'Summary', 'Updated', 'Priority', 'Locator'});
  return MemoryIndexEntry(
    id: _required(fields, 'ID'),
    revision: _integer(_required(fields, 'Revision'), 'Revision'),
    topic: _string(_required(fields, 'Topic'), 'Topic'),
    summary: _string(_required(fields, 'Summary'), 'Summary'),
    updated: _timestamp(_required(fields, 'Updated'), 'Updated'),
    priority: _nonNegativeInteger(_required(fields, 'Priority'), 'Priority'),
    locator: _required(fields, 'Locator'),
  );
}

CanonicalMemoryEntry _parseEntry(Map<String, String> fields) {
  _requireExactFields(fields, {
    ..._sourceFieldNames,
    'ID',
    'Revision',
    'Topic',
    'Summary',
    'Content',
    'Created',
    'Updated',
  });
  return CanonicalMemoryEntry(
    id: _required(fields, 'ID'),
    revision: _integer(_required(fields, 'Revision'), 'Revision'),
    topic: _string(_required(fields, 'Topic'), 'Topic'),
    summary: _string(_required(fields, 'Summary'), 'Summary'),
    content: _string(_required(fields, 'Content'), 'Content'),
    created: _timestamp(_required(fields, 'Created'), 'Created'),
    updated: _timestamp(_required(fields, 'Updated'), 'Updated'),
    provenance: _parseSource(fields),
  );
}

CanonicalMemoryLearning _parseLearning(Map<String, String> fields) {
  _requireExactFields(fields, {..._sourceFieldNames, 'ID', 'Revision', 'Summary', 'Content', 'Created', 'Updated'});
  return CanonicalMemoryLearning(
    id: _required(fields, 'ID'),
    revision: _integer(_required(fields, 'Revision'), 'Revision'),
    summary: _string(_required(fields, 'Summary'), 'Summary'),
    content: _string(_required(fields, 'Content'), 'Content'),
    created: _timestamp(_required(fields, 'Created'), 'Created'),
    updated: _timestamp(_required(fields, 'Updated'), 'Updated'),
    provenance: _parseSource(fields),
  );
}

MemoryObservation _parseObservation(Map<String, String> fields) {
  _requireExactFields(fields, {
    ..._sourceFieldNames,
    'ID',
    'Recorded',
    'Content',
    'Trust-Label',
    'Truncated',
    'Resulting-Entry-IDs',
  });
  return MemoryObservation(
    id: _required(fields, 'ID'),
    recorded: _timestamp(_required(fields, 'Recorded'), 'Recorded'),
    content: _string(_required(fields, 'Content'), 'Content'),
    trustLabel: _string(_required(fields, 'Trust-Label'), 'Trust-Label'),
    isTruncated: _boolean(_required(fields, 'Truncated'), 'Truncated'),
    resultingEntryIds: _stringList(_required(fields, 'Resulting-Entry-IDs'), 'Resulting-Entry-IDs'),
    provenance: _parseSource(fields),
  );
}

MemoryDeletionAudit _parseAudit(Map<String, String> fields) {
  _requireExactFields(fields, {..._sourceFieldNames, 'Entry-ID', 'Deleted-At', 'Reason'});
  return MemoryDeletionAudit(
    entryId: _required(fields, 'Entry-ID'),
    deletedAt: _timestamp(_required(fields, 'Deleted-At'), 'Deleted-At'),
    reason: _string(_required(fields, 'Reason'), 'Reason'),
    provenance: _parseSource(fields),
  );
}

MemorySourceRef _parseSource(Map<String, String> fields) {
  final origin = _required(fields, 'Origin-Kind');
  return MemorySourceRef(
    originKind: origin == '-' ? null : MemoryOriginKind.parse(origin),
    sourceLocator: _string(_required(fields, 'Source-Locator'), 'Source-Locator'),
    sourceEvent: _optionalString(_required(fields, 'Source-Event'), 'Source-Event'),
    caller: _optionalString(_required(fields, 'Caller'), 'Caller'),
    sessionRef: _optionalString(_required(fields, 'Session-Ref'), 'Session-Ref'),
  );
}

const _sourceFieldNames = {'Origin-Kind', 'Source-Locator', 'Source-Event', 'Caller', 'Session-Ref'};

void _requireExactFields(Map<String, String> fields, Set<String> allowed) {
  for (final field in fields.keys) {
    if (!allowed.contains(field)) throw FormatException('Unknown field: $field');
  }
}

String _field(String line, String name) {
  final prefix = '$name: ';
  if (!line.startsWith(prefix)) throw FormatException('Missing or misplaced $name');
  return line.substring(prefix.length);
}

String _required(Map<String, String> fields, String name) => fields[name] ?? (throw FormatException('Missing $name'));

int _integer(String value, String name) => int.tryParse(value) ?? (throw FormatException('Invalid $name: $value'));

int _nonNegativeInteger(String value, String name) {
  final parsed = _integer(value, name);
  if (parsed < 0) throw FormatException('Invalid $name: $value');
  return parsed;
}

String _string(String value, String name) {
  try {
    final decoded = jsonDecode(value);
    if (decoded is! String) throw FormatException('Invalid $name');
    return decoded;
  } on JsonUnsupportedObjectError {
    throw FormatException('Invalid $name');
  } on FormatException {
    throw FormatException('Invalid $name');
  }
}

String? _optionalString(String value, String name) {
  if (value == '-') return null;
  final decoded = _string(value, name);
  if (decoded.trim().isEmpty) throw FormatException('Invalid $name: $decoded');
  return decoded;
}

bool _boolean(String value, String name) => switch (value) {
  'true' => true,
  'false' => false,
  _ => throw FormatException('Invalid $name: $value'),
};

List<String> _stringList(String value, String name) {
  try {
    final decoded = jsonDecode(value);
    if (decoded is! List || decoded.any((item) => item is! String)) throw FormatException('Invalid $name');
    return decoded.cast<String>();
  } on JsonUnsupportedObjectError {
    throw FormatException('Invalid $name');
  } on FormatException {
    throw FormatException('Invalid $name');
  }
}

DateTime _timestamp(String value, String name) {
  final parsed = DateTime.tryParse(value);
  if (parsed == null || !value.endsWith('Z') || parsed.toIso8601String() != value) {
    throw FormatException('Invalid $name: $value');
  }
  return parsed;
}
