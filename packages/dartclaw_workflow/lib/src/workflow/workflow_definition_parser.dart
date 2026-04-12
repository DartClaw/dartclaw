import 'dart:io';

import 'package:dartclaw_models/dartclaw_models.dart';
import 'package:yaml/yaml.dart';

import 'duration_parser.dart';

/// Parses workflow definition YAML files into [WorkflowDefinition] objects.
class WorkflowDefinitionParser {
  /// Parses the YAML string [source] into a [WorkflowDefinition].
  ///
  /// Throws [FormatException] if the YAML is structurally invalid.
  /// Does not perform semantic validation — use [WorkflowDefinitionValidator]
  /// for that.
  WorkflowDefinition parse(String source, {String? sourcePath}) {
    final YamlMap yaml;
    try {
      final raw = loadYaml(source);
      if (raw is! YamlMap) {
        throw FormatException('Workflow YAML must be a mapping${_at(sourcePath)}.');
      }
      yaml = raw;
    } on YamlException catch (e) {
      throw FormatException('Invalid YAML${_at(sourcePath)}: ${e.message}');
    }

    return WorkflowDefinition(
      name: _requireString(yaml, 'name', sourcePath),
      description: _requireString(yaml, 'description', sourcePath),
      variables: _parseVariables(yaml['variables']),
      steps: _parseSteps(yaml['steps'], sourcePath),
      loops: _parseLoops(yaml['loops']),
      maxTokens: yaml['maxTokens'] as int?,
      stepDefaults: _parseStepDefaults(yaml['stepDefaults'], sourcePath),
    );
  }

  /// Parses a YAML file at [path] into a [WorkflowDefinition].
  Future<WorkflowDefinition> parseFile(String path) async {
    final content = await File(path).readAsString();
    return parse(content, sourcePath: path);
  }

  String _requireString(YamlMap yaml, String key, String? sourcePath) {
    final value = yaml[key];
    if (value == null) {
      throw FormatException('Missing required field "$key"${_at(sourcePath)}.');
    }
    if (value is! String) {
      throw FormatException('Field "$key" must be a string${_at(sourcePath)}.');
    }
    if (value.isEmpty) {
      throw FormatException('Field "$key" must not be empty${_at(sourcePath)}.');
    }
    return value;
  }

  Map<String, WorkflowVariable> _parseVariables(Object? raw) {
    if (raw is! YamlMap) return const {};
    return {for (final entry in raw.entries) entry.key as String: _parseVariable(entry.value)};
  }

  WorkflowVariable _parseVariable(Object? raw) {
    if (raw is! YamlMap) return const WorkflowVariable();
    return WorkflowVariable(
      required: (raw['required'] as bool?) ?? true,
      description: (raw['description'] as String?) ?? '',
      defaultValue: raw['default'] as String?,
    );
  }

  List<WorkflowStep> _parseSteps(Object? raw, String? sourcePath) {
    if (raw == null) {
      throw FormatException('Missing required field "steps"${_at(sourcePath)}.');
    }
    if (raw is! YamlList) {
      throw FormatException('Field "steps" must be a list${_at(sourcePath)}.');
    }
    if (raw.isEmpty) {
      throw FormatException('Field "steps" must not be empty${_at(sourcePath)}.');
    }
    return raw.map((s) => _parseStep(s as YamlMap, sourcePath)).toList(growable: false);
  }

  WorkflowStep _parseStep(YamlMap raw, String? sourcePath) {
    final id = raw['id'];
    if (id == null || id is! String || id.isEmpty) {
      throw FormatException('Each step must have a non-empty "id" field${_at(sourcePath)}.');
    }
    final name = raw['name'];
    if (name == null || name is! String || name.isEmpty) {
      throw FormatException('Step "$id" must have a non-empty "name" field${_at(sourcePath)}.');
    }
    // Parse skill field (optional — skill-aware steps may omit prompt).
    final skill = raw['skill'] as String?;

    // Parse prompt — optional when skill is present.
    // Accepts: List<String> (S02 canonical), String (legacy, normalized to
    // single-element list), or null (when skill is present).
    final promptRaw = raw['prompt'];
    final List<String>? prompts;
    if (promptRaw == null) {
      prompts = null;
    } else if (promptRaw is String) {
      if (promptRaw.isEmpty) {
        throw FormatException('Step "$id" must have a non-empty "prompt" field${_at(sourcePath)}.');
      }
      prompts = [promptRaw];
    } else if (promptRaw is YamlList) {
      if (promptRaw.isEmpty) {
        throw FormatException('Step "$id": "prompt" list must not be empty${_at(sourcePath)}.');
      }
      final castedPrompts = <String>[];
      for (final item in promptRaw) {
        if (item is! String || item.isEmpty) {
          throw FormatException('Step "$id": each prompt in the list must be a non-empty string${_at(sourcePath)}.');
        }
        castedPrompts.add(item);
      }
      prompts = castedPrompts;
    } else {
      throw FormatException('Step "$id": "prompt" must be a string or list of strings${_at(sourcePath)}.');
    }

    // Infer step type early so we can relax prompt requirements for hybrid types.
    final stepType = (raw['type'] as String?) ?? 'research';

    // Reject no-skill + no-prompt at parse time, except for bash/approval steps
    // which do not need an agent prompt (S02/S03 own their execution semantics).
    if (skill == null && (prompts == null || prompts.isEmpty)) {
      if (stepType != 'bash' && stepType != 'approval') {
        throw FormatException('Step "$id" must have either "prompt" or "skill" (or both)${_at(sourcePath)}.');
      }
    }

    final reviewRaw = raw['review'] as String?;
    final review = reviewRaw != null
        ? (StepReviewMode.fromYaml(reviewRaw) ??
              (throw FormatException('Step "$id": unknown review mode "$reviewRaw"${_at(sourcePath)}.')))
        : StepReviewMode.codingOnly;

    final timeoutRaw = raw['timeout'] ?? raw['timeoutSeconds'];
    int? timeoutSeconds;
    if (timeoutRaw != null) {
      if (timeoutRaw is String) {
        timeoutSeconds = parseDuration(timeoutRaw).inSeconds;
      } else if (timeoutRaw is int) {
        timeoutSeconds = timeoutRaw;
      }
    }

    final extractionRaw = raw['extraction'];
    ExtractionConfig? extraction;
    if (extractionRaw is YamlMap) {
      extraction = ExtractionConfig(
        type: ExtractionType.values.byName(extractionRaw['type'] as String),
        pattern: extractionRaw['pattern'] as String,
      );
    }

    // Parse outputs map (new 0.15.1 syntax).
    final outputsRaw = raw['outputs'];
    Map<String, OutputConfig>? outputs;
    if (outputsRaw is YamlMap) {
      outputs = {};
      for (final entry in outputsRaw.entries) {
        final key = entry.key as String;
        final value = entry.value;
        if (value is YamlMap) {
          final formatRaw = value['format'] as String?;
          final format = formatRaw != null
              ? (OutputFormat.fromYaml(formatRaw) ??
                    (throw FormatException('Step "$id" output "$key": unknown format "$formatRaw"${_at(sourcePath)}.')))
              : OutputFormat.text;
          final schema = _parseSchema(value['schema']);
          final outputSource = value['source'] as String?;
          outputs[key] = OutputConfig(format: format, schema: schema, source: outputSource);
        } else {
          // Shorthand: `key: json` or `key: lines`
          final format = OutputFormat.fromYaml(value.toString());
          outputs[key] = OutputConfig(format: format ?? OutputFormat.text);
        }
      }
    }

    // Parse map step fields. Accept both snake_case (primary) and camelCase (alias).
    final mapOver = (raw['map_over'] ?? raw['mapOver']) as String?;
    final maxParallel = _parseMaxParallel(raw['max_parallel'] ?? raw['maxParallel'], id, sourcePath);
    final maxItems = (raw['max_items'] ?? raw['maxItems']) as int? ?? 20;

    return WorkflowStep(
      id: id,
      name: name,
      skill: skill,
      prompts: prompts,
      type: stepType,
      project: raw['project'] as String?,
      provider: raw['provider'] as String?,
      model: raw['model'] as String?,
      timeoutSeconds: timeoutSeconds,
      review: review,
      parallel: (raw['parallel'] as bool?) ?? false,
      gate: raw['gate'] as String?,
      contextInputs: _parseStringList(raw['contextInputs']),
      contextOutputs: _parseStringList(raw['contextOutputs']),
      extraction: extraction,
      outputs: outputs,
      maxTokens: raw['maxTokens'] as int?,
      maxCostUsd: _parseDouble(raw['maxCostUsd']),
      maxRetries: raw['maxRetries'] as int?,
      allowedTools: _parseOptionalStringList(raw['allowedTools']),
      mapOver: mapOver,
      maxParallel: maxParallel,
      maxItems: maxItems,
      continueSession: _parseContinueSession(raw['continueSession'] ?? raw['continue_session'], id, sourcePath),
      onError: (raw['onError'] ?? raw['on_error']) as String?,
      workdir: raw['workdir'] as String?,
    );
  }

  String? _parseContinueSession(Object? raw, String stepId, String? sourcePath) {
    if (raw == null || raw == false) return null;
    if (raw == true) return '@previous';
    if (raw is String && raw.trim().isNotEmpty) return raw.trim();
    throw FormatException(
      'Step "$stepId": "continueSession" must be true or a non-empty step ID string${_at(sourcePath)}.',
    );
  }

  /// Parses the `max_parallel` value from YAML.
  ///
  /// Accepts int (concurrency limit), String "unlimited", or String template.
  /// Returns null if absent.
  Object? _parseMaxParallel(Object? raw, String stepId, String? sourcePath) {
    if (raw == null) return null;
    if (raw is int) return raw;
    if (raw is String) return raw;
    throw FormatException(
      'Step "$stepId": "max_parallel" must be an integer or string '
      '(e.g., 3, "unlimited", or a template like "{{MAX_PARALLEL}}")${_at(sourcePath)}.',
    );
  }

  /// Parses a schema value: String (preset name), Map (inline schema), or null.
  Object? _parseSchema(Object? raw) {
    if (raw == null) return null;
    if (raw is String) return raw; // Preset name.
    if (raw is YamlMap) return _yamlToMap(raw); // Inline JSON Schema.
    return null;
  }

  /// Deep-converts a [YamlMap] to a plain `Map<String, dynamic>`.
  Map<String, dynamic> _yamlToMap(YamlMap yaml) {
    return {for (final entry in yaml.entries) entry.key.toString(): _yamlToValue(entry.value)};
  }

  dynamic _yamlToValue(Object? value) {
    if (value is YamlMap) return _yamlToMap(value);
    if (value is YamlList) return value.map(_yamlToValue).toList();
    return value;
  }

  List<WorkflowLoop> _parseLoops(Object? raw) {
    if (raw is! YamlList) return const [];
    return raw.map((l) => _parseLoop(l as YamlMap)).toList(growable: false);
  }

  WorkflowLoop _parseLoop(YamlMap raw) {
    return WorkflowLoop(
      id: raw['id'] as String,
      steps: _parseStringList(raw['steps']),
      maxIterations: raw['maxIterations'] as int,
      exitGate: (raw['exitGate'] as String?) ?? '',
      finally_: raw['finally'] as String?,
    );
  }

  List<StepConfigDefault>? _parseStepDefaults(Object? raw, String? sourcePath) {
    if (raw is! YamlList) return null;
    return raw
        .map((entry) {
          if (entry is! YamlMap) {
            throw FormatException('Each stepDefaults entry must be a mapping${_at(sourcePath)}.');
          }
          final match = entry['match'];
          if (match == null || match is! String || match.isEmpty) {
            throw FormatException('Each stepDefaults entry must have a non-empty "match" field${_at(sourcePath)}.');
          }
          return StepConfigDefault(
            match: match,
            provider: entry['provider'] as String?,
            model: entry['model'] as String?,
            maxTokens: entry['maxTokens'] as int?,
            maxCostUsd: _parseDouble(entry['maxCostUsd']),
            maxRetries: entry['maxRetries'] as int?,
            allowedTools: _parseOptionalStringList(entry['allowedTools']),
          );
        })
        .toList(growable: false);
  }

  List<String> _parseStringList(Object? raw) {
    if (raw is! YamlList) return const [];
    return raw.cast<String>().toList(growable: false);
  }

  List<String>? _parseOptionalStringList(Object? raw) {
    if (raw is! YamlList) return null;
    return raw.cast<String>().toList(growable: false);
  }

  /// Parses a numeric value as [double], accepting both int and double YAML values.
  ///
  /// YAML parses bare numbers like `2` as int, not double. This normalizes them.
  double? _parseDouble(Object? raw) {
    if (raw == null) return null;
    if (raw is double) return raw;
    if (raw is int) return raw.toDouble();
    return null;
  }

  String _at(String? sourcePath) => sourcePath != null ? ' in "$sourcePath"' : '';
}
