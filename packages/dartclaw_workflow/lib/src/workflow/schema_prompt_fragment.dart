/// Renders a JSON Schema as prompt prose.
///
/// The one schema-to-prose renderer. Two prompts need it and must not diverge:
/// the step's required-output-format section, and the finalizer prompt — which
/// tells a model to "match the provided schema" even when the provider cannot
/// be given one, so the schema has to reach it as text or the model guesses the
/// types and the envelope fails host validation on fields it was never shown.
String describeSchemaForPrompt(Map<String, dynamic> schema, String outputKey) {
  final buf = StringBuffer();
  buf.writeln('Produce your output for "$outputKey" as JSON with this structure:');

  final type = schemaTypeNames(schema);
  if (type.contains('array')) {
    buf.writeln('A JSON array where each item has:');
    final items = schema['items'] as Map<String, dynamic>?;
    if (items != null) {
      _writeProperties(buf, items, indent: '  ');
    }
  } else if (type.contains('object')) {
    _writeProperties(buf, schema, indent: '');
  }

  buf.writeln();
  buf.write('Output the JSON directly – do not wrap in markdown code fences.');
  return buf.toString();
}

/// Declared type names of [schema], as a list because a schema may allow several.
List<String> schemaTypeNames(Map<String, dynamic> schema) {
  final rawType = schema['type'];
  return switch (rawType) {
    final String type => <String>[type],
    final List<dynamic> values => values.whereType<String>().toList(growable: false),
    _ => const <String>[],
  };
}

String _typeLabel(List<String> types) {
  if (types.isEmpty) return 'any';
  if (types.length == 1) return types.single;
  return types.join(' or ');
}

/// Writes property descriptions from a JSON Schema object definition.
void _writeProperties(StringBuffer buf, Map<String, dynamic> schema, {String indent = ''}) {
  final properties = schema['properties'] as Map<String, dynamic>?;
  if (properties == null) return;
  final required = (schema['required'] as List?)?.cast<String>().toSet() ?? <String>{};

  for (final entry in properties.entries) {
    final name = entry.key;
    final prop = entry.value as Map<String, dynamic>;
    final propType = schemaTypeNames(prop);
    final isRequired = required.contains(name);
    final enumValues = prop['enum'] as List?;
    final propDesc = (prop['description'] as String?)?.trim();

    var line = '$indent- $name (${_typeLabel(propType)}';
    if (!isRequired) line += ', optional';
    line += ')';
    if (enumValues != null) {
      line += ': ${enumValues.map((e) => '"$e"').join(', ')}';
    }
    if (propDesc != null && propDesc.isNotEmpty) {
      line += ': $propDesc';
    }
    buf.writeln(line);

    // Recurse into nested objects and arrays of objects. Depth is bounded
    // by schema nesting in current presets.
    if (propType.contains('array')) {
      final items = prop['items'] as Map<String, dynamic>?;
      if (items != null && items['properties'] != null) {
        buf.writeln('$indent  Each item has:');
        _writeProperties(buf, items, indent: '$indent    ');
      }
    } else if (propType.contains('object') && prop['properties'] != null) {
      buf.writeln('$indent  With fields:');
      _writeProperties(buf, prop, indent: '$indent    ');
    }
  }
}
