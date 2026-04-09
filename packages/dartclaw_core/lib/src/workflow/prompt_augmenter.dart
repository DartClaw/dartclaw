import 'package:dartclaw_models/dartclaw_models.dart' show OutputConfig, OutputFormat;

import 'schema_presets.dart';

/// Augments a step prompt with output format instructions from schema declarations.
class PromptAugmenter {
  const PromptAugmenter();

  /// Returns [prompt] with appended output format section if any output has a schema.
  ///
  /// When [evaluator] is true and the first json output has no schema,
  /// defaults to the 'verdict' preset.
  String augment(
    String prompt,
    Map<String, OutputConfig>? outputs, {
    bool evaluator = false,
  }) {
    if (outputs == null || outputs.isEmpty) return prompt;

    final fragments = <String>[];

    for (final entry in outputs.entries) {
      final config = entry.value;
      if (config.format != OutputFormat.json) continue;

      String? fragment;

      if (config.presetName != null) {
        // Preset schema.
        final preset = schemaPresets[config.presetName];
        if (preset != null) {
          fragment = preset.promptFragment;
        }
      } else if (config.inlineSchema != null) {
        // Inline JSON Schema — generate prompt from schema properties.
        fragment = _generateInlineFragment(config.inlineSchema!, entry.key);
      } else if (evaluator) {
        // Evaluator default: no explicit schema -> verdict preset.
        fragment = verdictPreset.promptFragment;
      }

      if (fragment != null) fragments.add(fragment);
    }

    if (fragments.isEmpty) return prompt;

    final section = fragments.join('\n\n');
    return '$prompt\n\n## Required Output Format\n\n$section';
  }

  /// Generates a prompt fragment from an inline JSON Schema by walking properties.
  String _generateInlineFragment(Map<String, dynamic> schema, String outputKey) {
    final buf = StringBuffer();
    buf.writeln('Produce your output for "$outputKey" as JSON with this structure:');

    final type = schema['type'] as String?;
    if (type == 'array') {
      buf.writeln('A JSON array where each item has:');
      final items = schema['items'] as Map<String, dynamic>?;
      if (items != null) {
        _writeProperties(buf, items, indent: '  ');
      }
    } else if (type == 'object') {
      _writeProperties(buf, schema, indent: '');
    }

    buf.writeln();
    buf.write('Output the JSON directly — do not wrap in markdown code fences.');
    return buf.toString();
  }

  /// Writes property descriptions from a JSON Schema object definition.
  void _writeProperties(
    StringBuffer buf,
    Map<String, dynamic> schema, {
    String indent = '',
  }) {
    final properties = schema['properties'] as Map<String, dynamic>?;
    if (properties == null) return;
    final required =
        (schema['required'] as List?)?.cast<String>().toSet() ?? <String>{};

    for (final entry in properties.entries) {
      final name = entry.key;
      final prop = entry.value as Map<String, dynamic>;
      final propType = prop['type'] as String? ?? 'any';
      final isRequired = required.contains(name);
      final enumValues = prop['enum'] as List?;

      var desc = '$indent- $name ($propType';
      if (!isRequired) desc += ', optional';
      desc += ')';
      if (enumValues != null) {
        desc += ': ${enumValues.map((e) => '"$e"').join(', ')}';
      }
      buf.writeln(desc);

      // Recurse into nested object/array items (one level only for inline).
      if (propType == 'array') {
        final items = prop['items'] as Map<String, dynamic>?;
        if (items != null && items['properties'] != null) {
          buf.writeln('$indent  Each item has:');
          _writeProperties(buf, items, indent: '$indent    ');
        }
      }
    }
  }
}
