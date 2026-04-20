import 'package:dartclaw_models/dartclaw_models.dart' show OutputConfig, OutputFormat, OutputMode;

import 'schema_presets.dart';
import 'workflow_output_contract.dart';

/// Augments a step prompt with output format instructions from schema declarations.
class PromptAugmenter {
  const PromptAugmenter();

  /// Returns [prompt] with appended output format and workflow-context instructions.
  String augment(
    String prompt, {
    Map<String, OutputConfig>? outputs,
    List<String> contextOutputs = const [],
    bool emitStepOutcomeProtocol = false,
  }) {
    final sections = <String>[];

    final workflowContextSection = _buildWorkflowContextSection(outputs, contextOutputs);
    if (workflowContextSection != null) sections.add(workflowContextSection);

    final schemaSection = _buildSchemaSection(outputs, contextOutputs);
    if (schemaSection != null) sections.add(schemaSection);

    if (emitStepOutcomeProtocol) {
      sections.add(_buildStepOutcomeSection());
    }

    if (sections.isEmpty) return prompt;

    return '$prompt\n\n${sections.join('\n\n')}';
  }

  String _buildStepOutcomeSection() {
    final buf = StringBuffer();
    buf.writeln('## Step Outcome Protocol');
    buf.writeln();
    buf.writeln(
      'End your final response with '
      '`$kStepOutcomeOpen{"outcome":"succeeded|failed|needsInput","reason":"..." }$kStepOutcomeClose`.',
    );
    buf.writeln('Do not use markdown code fences inside `$kStepOutcomeOpen`.');
    buf.writeln('Allowed outcome values are exactly: `succeeded`, `failed`, `needsInput`.');
    buf.writeln('Use `needsInput` when a human decision or missing requirement blocks safe progress.');
    buf.writeln();
    buf.writeln('Example:');
    buf.writeln(kStepOutcomeOpen);
    buf.writeln('{"outcome":"succeeded","reason":"completed as requested"}');
    buf.writeln(kStepOutcomeClose);
    return buf.toString().trimRight();
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
        // Preset schema — use explicit promptFragment when set, otherwise
        // derive the fragment from the schema itself (single source of truth
        // via per-property `description` fields).
        final preset = schemaPresets[config.presetName];
        if (preset != null) {
          fragment = preset.promptFragment ?? _generateInlineFragment(preset.schema, entry.key);
        }
      } else if (config.inlineSchema != null) {
        // Inline JSON Schema — generate prompt from schema properties.
        fragment = _generateInlineFragment(config.inlineSchema!, entry.key);
      }

      if (fragment != null) {
        final desc = effectiveDescription(config);
        if (desc != null) {
          fragment = '"${entry.key}" — $desc\n\n$fragment';
        }
        fragments.add(fragment);
      }
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
    buf.writeln('End your final response with `$kWorkflowContextOpen` containing a single JSON object.');
    buf.writeln('Do not use markdown code fences inside `$kWorkflowContextOpen`.');
    buf.writeln('Include exactly these keys:');

    for (final key in contextOutputs) {
      final config = outputs?[key];
      _writeWorkflowContextField(buf, key, config);
    }

    buf.writeln();
    buf.writeln('Example:');
    buf.writeln(kWorkflowContextOpen);
    buf.writeln('{"key":"value"}');
    buf.writeln(kWorkflowContextClose);
    return buf.toString().trimRight();
  }

  void _writeWorkflowContextField(StringBuffer buf, String key, OutputConfig? config) {
    final effectiveDesc = config == null ? null : effectiveDescription(config);
    final descSuffix = effectiveDesc != null ? ' — $effectiveDesc' : '';

    if (config == null || config.format == OutputFormat.text) {
      buf.writeln('- "$key": JSON string$descSuffix');
      return;
    }

    if (config.format == OutputFormat.path) {
      buf.writeln('- "$key": workspace-relative file path string$descSuffix');
      return;
    }

    if (config.format == OutputFormat.lines) {
      buf.writeln('- "$key": JSON array of strings$descSuffix');
      return;
    }

    final schema = config.presetName != null ? schemaPresets[config.presetName]?.schema : config.inlineSchema;

    if (schema == null) {
      buf.writeln('- "$key": JSON value$descSuffix');
      return;
    }

    final type = _schemaTypes(schema);
    if (type.contains('array')) {
      buf.writeln('- "$key": JSON array$descSuffix');
      final items = schema['items'] as Map<String, dynamic>?;
      if (items != null) {
        buf.writeln('  Each item has:');
        _writeProperties(buf, items, indent: '    ');
      }
      return;
    }

    if (type.contains('object')) {
      buf.writeln('- "$key": JSON object$descSuffix${descSuffix.isEmpty ? " with:" : ", with:"}');
      _writeProperties(buf, schema, indent: '  ');
      return;
    }

    buf.writeln('- "$key": JSON ${_typeLabel(type)}$descSuffix');
  }

  /// Generates a prompt fragment from an inline JSON Schema by walking properties.
  String _generateInlineFragment(Map<String, dynamic> schema, String outputKey) {
    final buf = StringBuffer();
    buf.writeln('Produce your output for "$outputKey" as JSON with this structure:');

    final type = _schemaTypes(schema);
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
      final propType = _schemaTypes(prop);
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
      // by schema nesting — current presets reach two levels (project-index).
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

  /// Returns the description to render for [config], falling back to the
  /// preset's canonical description when the output declares a known preset
  /// and no inline `description:` override. Returns null when neither source
  /// provides a non-empty value.
  ///
  /// Exposed as a public static so peer renderers (e.g. `SkillPromptBuilder`'s
  /// auto-framed context sections) share a single description-resolution
  /// strategy. Keeping this in one place prevents drift between the
  /// output-contract rendering here and the context-input rendering there.
  static String? effectiveDescription(OutputConfig config) {
    final inline = config.description?.trim();
    if (inline != null && inline.isNotEmpty) return inline;
    final presetName = config.presetName;
    if (presetName == null) return null;
    final presetDesc = schemaPresets[presetName]?.description?.trim();
    if (presetDesc == null || presetDesc.isEmpty) return null;
    return presetDesc;
  }

  List<String> _schemaTypes(Map<String, dynamic> schema) {
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
}
