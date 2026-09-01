import 'dart:convert';
import 'dart:io';

const _beginMarker = '<!-- BEGIN GENERATED CONFIG REFERENCE -->';
const _endMarker = '<!-- END GENERATED CONFIG REFERENCE -->';
const _legacyHeading = '### Full Config Reference';
const _regenerationCommand = 'dart run dev/tools/render_config_reference.dart';

void main(List<String> arguments) {
  if (arguments.any((argument) => argument != '--check') ||
      arguments.where((argument) => argument == '--check').length > 1) {
    stderr.writeln('Usage: $_regenerationCommand [--check]');
    exitCode = 64;
    return;
  }

  final root = _repoRoot();
  final schemaFile = File('${root.path}/schemas/dartclaw.schema.json');
  final coreFile = File('${root.path}/dev/tools/config_reference_core_keys.txt');
  final guideFile = File('${root.path}/docs/guide/configuration.md');
  final schema = jsonDecode(schemaFile.readAsStringSync()) as Map<String, Object?>;
  final fields = <String, Map<String, Object?>>{};
  _collectFields(schema, const [], fields);
  final coreKeys = _readCoreKeys(coreFile, fields);
  final generated = _render(fields, coreKeys);
  final current = guideFile.readAsStringSync();
  final expected = _replaceGeneratedRegion(current, generated);

  if (arguments.contains('--check')) {
    if (current != expected) {
      stderr.writeln('${guideFile.path} is out of date. Regenerate it with: $_regenerationCommand');
      exitCode = 1;
    }
    return;
  }
  if (current != expected) guideFile.writeAsStringSync(expected);
}

Directory _repoRoot() {
  final script = File.fromUri(Platform.script).resolveSymbolicLinksSync();
  return File(script).parent.parent.parent;
}

/// Schema to dotted leaf keys, with no config instance in hand.
///
/// Stops at an array rather than descending `items`: the reference documents
/// the key an operator writes and describes the element shape in prose.
/// `packages/dartclaw_kernel/test/support/json_schema_walker.dart` descends the
/// same schema for a different question — validating an instance — and must
/// descend `items`, because array indices exist only in the instance. The two
/// are deliberately separate; see that file for the full reasoning.
void _collectFields(Map<String, Object?> schema, List<String> segments, Map<String, Map<String, Object?>> fields) {
  final properties = schema['properties'];
  if (properties is Map<String, dynamic>) {
    for (final entry in properties.entries) {
      _collectFields(entry.value as Map<String, Object?>, [...segments, entry.key], fields);
    }
  }

  final additional = schema['additionalProperties'];
  if (additional is Map<String, dynamic>) {
    final entryPath = [...segments, '<name>'];
    final entrySchema = additional.cast<String, Object?>();
    final entryProperties = entrySchema['properties'];
    if (entryProperties is Map && entryProperties.isNotEmpty) {
      _collectFields(entrySchema, entryPath, fields);
    } else if (segments.isNotEmpty) {
      fields[entryPath.join('.')] = _withFallbackDescription(entrySchema, schema);
    }
  } else if (additional == true && segments.isNotEmpty) {
    fields[segments.join('.')] = schema;
  }

  if (segments.isNotEmpty && properties is! Map && additional is! Map && additional != true) {
    fields[segments.join('.')] = schema;
  }
}

Map<String, Object?> _withFallbackDescription(Map<String, Object?> entry, Map<String, Object?> container) {
  if (entry['description'] != null || container['description'] == null) return entry;
  return {...entry, 'description': container['description']};
}

List<String> _readCoreKeys(File file, Map<String, Map<String, Object?>> fields) {
  final keys = <String>[];
  final seen = <String>{};
  for (final rawLine in file.readAsLinesSync()) {
    final line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final separator = line.indexOf('  # ');
    if (separator < 0 || line.substring(separator + 4).trim().isEmpty) {
      _fail('Malformed core config key entry: $line (expected <yaml path>  # <rationale>)');
    }
    final key = line.substring(0, separator).trim();
    if (!seen.add(key)) _fail('Duplicate core config key: $key');
    if (!fields.containsKey(key)) _fail('Unknown core config key: $key');
    keys.add(key);
  }
  if (keys.length > 90) _fail('Core config key count ${keys.length} exceeds the limit of 90.');
  return keys;
}

Never _fail(String message) {
  stderr.writeln(message);
  exit(1);
}

String _render(Map<String, Map<String, Object?>> fields, List<String> coreKeys) {
  final sortedKeys = fields.keys.toList()..sort();
  final buffer = StringBuffer()
    ..writeln(_beginMarker)
    ..writeln('### Core Config')
    ..writeln()
    ..writeln(
      'These are the settings most operators need first. The exhaustive reference below documents every accepted key.',
    )
    ..writeln()
    ..writeln('| Key | Type | Constraints | Description |')
    ..writeln('| --- | --- | --- | --- |');
  for (final key in coreKeys) {
    _writeRow(buffer, key, fields[key]!);
  }
  buffer
    ..writeln()
    ..writeln(_legacyHeading)
    ..writeln()
    ..writeln('This table is generated from `schemas/dartclaw.schema.json`. Named map entries use `<name>`.')
    ..writeln()
    ..writeln('| Key | Type | Constraints | Description |')
    ..writeln('| --- | --- | --- | --- |');
  String? section;
  for (final key in sortedKeys) {
    final nextSection = key.split('.').first;
    if (section != null && nextSection != section) {
      buffer.writeln('| **${_escape(nextSection)}** |  |  |  |');
    } else if (section == null) {
      buffer.writeln('| **${_escape(nextSection)}** |  |  |  |');
    }
    section = nextSection;
    _writeRow(buffer, key, fields[key]!);
  }
  buffer.writeln(_endMarker);
  return buffer.toString().trimRight();
}

void _writeRow(StringBuffer buffer, String key, Map<String, Object?> schema) {
  buffer.writeln(
    '| `${_escape(key)}` | ${_escape(_type(schema))} | ${_escape(_constraints(schema))} | ${_escape(schema['description'] as String? ?? '')} |',
  );
}

String _type(Map<String, Object?> schema) {
  final type = schema['type'];
  if (type is List) return type.join(' or ');
  if (type is String) return type;
  return 'free-form object';
}

String _constraints(Map<String, Object?> schema) {
  final constraints = <String>[];
  final values = schema['enum'];
  if (values is List) constraints.add('one of ${values.map(jsonEncode).join(', ')}');
  final minimum = schema['minimum'];
  final maximum = schema['maximum'];
  if (minimum != null && maximum != null) {
    constraints.add('$minimum–$maximum');
  } else if (minimum != null) {
    constraints.add('minimum $minimum');
  } else if (maximum != null) {
    constraints.add('maximum $maximum');
  }
  return constraints.join('; ');
}

String _escape(String value) =>
    value.replaceAll('\\', '\\\\').replaceAll('|', '\\|').replaceAll(RegExp(r'\s+'), ' ').trim();

String _replaceGeneratedRegion(String guide, String generated) {
  final begin = guide.indexOf(_beginMarker);
  if (begin >= 0) {
    final end = guide.indexOf(_endMarker, begin);
    if (end < 0) _fail('Missing $_endMarker in docs/guide/configuration.md.');
    return guide.replaceRange(begin, end + _endMarker.length, generated);
  }

  final heading = guide.indexOf(_legacyHeading);
  if (heading < 0) _fail('Missing $_legacyHeading in docs/guide/configuration.md.');
  final fenceStart = guide.indexOf('```yaml', heading);
  if (fenceStart < 0) _fail('Missing legacy YAML reference fence in docs/guide/configuration.md.');
  final fenceEnd = guide.indexOf('\n```', fenceStart + 7);
  if (fenceEnd < 0) _fail('Missing closing legacy YAML reference fence in docs/guide/configuration.md.');
  return guide.replaceRange(heading, fenceEnd + 4, generated);
}
