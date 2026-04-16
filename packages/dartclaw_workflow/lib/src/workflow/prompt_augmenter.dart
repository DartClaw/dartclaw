import 'package:dartclaw_models/dartclaw_models.dart' show OutputConfig, OutputFormat, OutputMode;

import 'schema_presets.dart';

/// Augments a step prompt with output format instructions from schema declarations.
class PromptAugmenter {
  const PromptAugmenter();

  /// Returns [prompt] with appended output format and workflow-context instructions.
  String augment(String prompt, {Map<String, OutputConfig>? outputs, List<String> contextOutputs = const []}) {
    final sections = <String>[];

    final workflowContextSection = _buildWorkflowContextSection(outputs, contextOutputs);
    if (workflowContextSection != null) sections.add(workflowContextSection);

    final schemaSection = _buildSchemaSection(outputs, contextOutputs);
    if (schemaSection != null) sections.add(schemaSection);

    if (sections.isEmpty) return prompt;

    return '$prompt\n\n${sections.join('\n\n')}';
  }

  String? _buildSchemaSection(Map<String, OutputConfig>? outputs, List<String> contextOutputs) {
    if (outputs == null || outputs.isEmpty) return null;

    final fragments = <String>[];

    for (final entry in outputs.entries) {
      if (contextOutputs.contains(entry.key)) continue;
      final config = entry.value;
      if (config.format != OutputFormat.json) continue;
      if (config.outputMode == OutputMode.structured) continue;

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
      }

      if (fragment != null) fragments.add(fragment);
    }

    if (fragments.isEmpty) return null;

    final section = fragments.join('\n\n');
    return '## Required Output Format\n\n$section';
  }

  String? _buildWorkflowContextSection(Map<String, OutputConfig>? outputs, List<String> contextOutputs) {
    if (contextOutputs.isEmpty) return null;

    final buf = StringBuffer();
    buf.writeln('## Workflow Output Contract');
    buf.writeln();
    buf.writeln('End your final response with `<workflow-context>` containing a single JSON object.');
    buf.writeln('Do not use markdown code fences inside `<workflow-context>`.');
    buf.writeln('Include exactly these keys:');

    for (final key in contextOutputs) {
      final config = outputs?[key];
      _writeWorkflowContextField(buf, key, config);
    }

    buf.writeln();
    buf.writeln('Example:');
    buf.writeln('<workflow-context>');
    buf.writeln('{"key":"value"}');
    buf.writeln('</workflow-context>');
    return buf.toString().trimRight();
  }

  void _writeWorkflowContextField(StringBuffer buf, String key, OutputConfig? config) {
    if (config == null || config.format == OutputFormat.text) {
      buf.writeln('- "$key": JSON string');
      return;
    }

    if (config.format == OutputFormat.lines) {
      buf.writeln('- "$key": JSON array of strings');
      return;
    }

    final schema = config.presetName != null ? schemaPresets[config.presetName]?.schema : config.inlineSchema;

    if (schema == null) {
      buf.writeln('- "$key": JSON value');
      return;
    }

    final type = schema['type'] as String?;
    if (type == 'array') {
      buf.writeln('- "$key": JSON array');
      final items = schema['items'] as Map<String, dynamic>?;
      if (items != null) {
        buf.writeln('  Each item has:');
        _writeProperties(buf, items, indent: '    ');
      }
      return;
    }

    if (type == 'object') {
      buf.writeln('- "$key": JSON object with:');
      _writeProperties(buf, schema, indent: '  ');
      return;
    }

    buf.writeln('- "$key": JSON $type');
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
  void _writeProperties(StringBuffer buf, Map<String, dynamic> schema, {String indent = ''}) {
    final properties = schema['properties'] as Map<String, dynamic>?;
    if (properties == null) return;
    final required = (schema['required'] as List?)?.cast<String>().toSet() ?? <String>{};

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
