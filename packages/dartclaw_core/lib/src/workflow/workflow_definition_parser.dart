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
        throw FormatException(
          'Workflow YAML must be a mapping${_at(sourcePath)}.',
        );
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
      throw FormatException(
        'Missing required field "$key"${_at(sourcePath)}.',
      );
    }
    if (value is! String) {
      throw FormatException(
        'Field "$key" must be a string${_at(sourcePath)}.',
      );
    }
    if (value.isEmpty) {
      throw FormatException(
        'Field "$key" must not be empty${_at(sourcePath)}.',
      );
    }
    return value;
  }

  Map<String, WorkflowVariable> _parseVariables(Object? raw) {
    if (raw == null) return const {};
    if (raw is! YamlMap) return const {};
    return {
      for (final entry in raw.entries)
        entry.key as String: _parseVariable(entry.value),
    };
  }

  WorkflowVariable _parseVariable(Object? raw) {
    if (raw == null) return const WorkflowVariable();
    if (raw is! YamlMap) return const WorkflowVariable();
    return WorkflowVariable(
      required: (raw['required'] as bool?) ?? true,
      description: (raw['description'] as String?) ?? '',
      defaultValue: raw['default'] as String?,
    );
  }

  List<WorkflowStep> _parseSteps(Object? raw, String? sourcePath) {
    if (raw == null) {
      throw FormatException(
        'Missing required field "steps"${_at(sourcePath)}.',
      );
    }
    if (raw is! YamlList) {
      throw FormatException(
        'Field "steps" must be a list${_at(sourcePath)}.',
      );
    }
    if (raw.isEmpty) {
      throw FormatException(
        'Field "steps" must not be empty${_at(sourcePath)}.',
      );
    }
    return raw.map((s) => _parseStep(s as YamlMap, sourcePath)).toList(growable: false);
  }

  WorkflowStep _parseStep(YamlMap raw, String? sourcePath) {
    final id = raw['id'];
    if (id == null || id is! String || id.isEmpty) {
      throw FormatException(
        'Each step must have a non-empty "id" field${_at(sourcePath)}.',
      );
    }
    final name = raw['name'];
    if (name == null || name is! String || name.isEmpty) {
      throw FormatException(
        'Step "$id" must have a non-empty "name" field${_at(sourcePath)}.',
      );
    }
    final prompt = raw['prompt'];
    if (prompt == null || prompt is! String || prompt.isEmpty) {
      throw FormatException(
        'Step "$id" must have a non-empty "prompt" field${_at(sourcePath)}.',
      );
    }

    final reviewRaw = raw['review'] as String?;
    final review = reviewRaw != null
        ? (StepReviewMode.fromYaml(reviewRaw) ??
            (throw FormatException(
              'Step "$id": unknown review mode "$reviewRaw"${_at(sourcePath)}.',
            )))
        : StepReviewMode.codingOnly;

    final timeoutRaw = raw['timeout'];
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

    return WorkflowStep(
      id: id,
      name: name,
      prompt: prompt,
      type: (raw['type'] as String?) ?? 'research',
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
      maxTokens: raw['maxTokens'] as int?,
      maxRetries: raw['maxRetries'] as int?,
      allowedTools: _parseOptionalStringList(raw['allowedTools']),
    );
  }

  List<WorkflowLoop> _parseLoops(Object? raw) {
    if (raw == null) return const [];
    if (raw is! YamlList) return const [];
    return raw.map((l) => _parseLoop(l as YamlMap)).toList(growable: false);
  }

  WorkflowLoop _parseLoop(YamlMap raw) {
    return WorkflowLoop(
      id: raw['id'] as String,
      steps: _parseStringList(raw['steps']),
      maxIterations: raw['maxIterations'] as int,
      exitGate: (raw['exitGate'] as String?) ?? '',
    );
  }

  List<String> _parseStringList(Object? raw) {
    if (raw == null) return const [];
    if (raw is! YamlList) return const [];
    return raw.cast<String>().toList(growable: false);
  }

  List<String>? _parseOptionalStringList(Object? raw) {
    if (raw == null) return null;
    if (raw is! YamlList) return null;
    return raw.cast<String>().toList(growable: false);
  }

  String _at(String? sourcePath) =>
      sourcePath != null ? ' in "$sourcePath"' : '';
}
