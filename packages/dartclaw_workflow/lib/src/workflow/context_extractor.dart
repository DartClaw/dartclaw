import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart'
    show
        MessageService,
        OutputConfig,
        OutputFormat,
        Task,
        WorkflowStep,
        ExtractionConfig,
        ExtractionType,
        WorkflowTaskService;

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import 'json_extraction.dart';
import 'schema_presets.dart';
import 'schema_validator.dart';

/// Extracts context outputs from a completed task's artifacts and messages.
///
/// Four extraction strategies (in priority order for each output key):
/// 1. Explicit [ExtractionConfig] on the step (artifact lookup by name pattern).
/// 2. Agent convention: `## Context Output` section in last assistant message.
/// 3. First `.md` artifact file content.
/// 4. `diff.json` artifact for diff-related keys.
///
/// Automatic step metadata keys (`<stepId>.status`, `<stepId>.tokenCount`)
/// are set by [WorkflowExecutor] — not by this class.
class ContextExtractor {
  static const _contextSizeWarningThreshold = 10000;
  static final _log = Logger('ContextExtractor');

  final WorkflowTaskService _taskService;
  final MessageService _messageService;
  final String _dataDir;
  final SchemaValidator _schemaValidator;

  ContextExtractor({
    required WorkflowTaskService taskService,
    required MessageService messageService,
    required String dataDir,
    SchemaValidator? schemaValidator,
  }) : _taskService = taskService,
       _messageService = messageService,
       _dataDir = dataDir,
       _schemaValidator = schemaValidator ?? const SchemaValidator();

  /// Extracts context outputs for the given [step] from the completed [task].
  ///
  /// Returns a map of output key → extracted value.
  Future<Map<String, dynamic>> extract(WorkflowStep step, Task task) async {
    final outputs = <String, dynamic>{};

    // 1. Explicit ExtractionConfig takes priority for first output key (backward compat).
    if (step.extraction != null && step.contextOutputs.isNotEmpty) {
      final extracted = await _applyExtractionConfig(step.extraction!, task);
      if (extracted != null) {
        outputs[step.contextOutputs.first] = extracted;
      }
    }

    // 2. For each declared output key not yet extracted.
    for (final outputKey in step.contextOutputs) {
      if (outputs.containsKey(outputKey)) continue;

      // Determine output config for this key.
      final config = step.outputs?[outputKey];

      // source: worktree.* — read directly from persisted task.worktreeJson.
      if (config?.source != null) {
        final worktreeJson = task.worktreeJson;
        final value = switch (config!.source) {
          'worktree.branch' => (worktreeJson?['branch'] as String?) ?? '',
          'worktree.path' => (worktreeJson?['path'] as String?) ?? '',
          _ => null,
        };
        if (value != null) {
          outputs[outputKey] = value;
          if (value.isEmpty) {
            _log.warning(
              'worktree source "${config.source}" for "$outputKey" in step "${step.id}" '
              'returned empty: task ${task.id} has no worktree metadata',
            );
          }
          continue;
        }
        // Unknown source — fall through to normal extraction with a warning.
        _log.warning(
          'Unknown output source "${config.source}" for "$outputKey" in step "${step.id}"; '
          'falling back to normal extraction',
        );
      }

      if (config != null && config.format != OutputFormat.text) {
        // Format-aware extraction (json or lines).
        final rawContent = await _extractRawContent(step, task, outputKey);
        if (rawContent == null || rawContent.isEmpty) {
          _log.warning(
            'No raw content for format-aware extraction of "$outputKey" '
            'from step "${step.id}" (task ${task.id})',
          );
          outputs[outputKey] = '';
          continue;
        }

        switch (config.format) {
          case OutputFormat.json:
            try {
              final parsed = extractJson(rawContent);
              // Soft validation if schema is present.
              _softValidate(parsed, config, step.id, outputKey);
              outputs[outputKey] = parsed; // Store as Map/List, not String.
            } on FormatException catch (e) {
              _log.severe('JSON extraction failed for "$outputKey" from step "${step.id}": $e');
              rethrow;
            }
          case OutputFormat.lines:
            outputs[outputKey] = extractLines(rawContent);
          case OutputFormat.text:
            break; // Unreachable — guarded above.
        }
        continue;
      }

      final derivedValue = _deriveFromStructuredOutputs(outputs, outputKey);
      if (derivedValue != null) {
        outputs[outputKey] = derivedValue;
        continue;
      }

      // Fall through to convention-based extraction (text format or no config).

      // Try agent convention (## Context Output) first.
      final conventionValue = await _extractFromAgentConvention(task, outputKey);
      if (conventionValue != null) {
        outputs[outputKey] = conventionValue;
        continue;
      }

      // Try first .md artifact.
      final mdContent = await _extractFirstMdArtifact(task);
      if (mdContent != null) {
        outputs[outputKey] = mdContent;
        continue;
      }

      // Try diff.json for diff-related keys.
      if (outputKey.contains('diff') || outputKey.contains('changes')) {
        final diffContent = await _extractDiffArtifact(task);
        if (diffContent != null) {
          outputs[outputKey] = diffContent;
          continue;
        }
      }

      // Fallback: empty string with warning.
      _log.warning(
        'No content extracted for context key "$outputKey" '
        'from step "${step.id}" (task ${task.id})',
      );
      outputs[outputKey] = '';
    }

    // Warn on large values.
    for (final entry in outputs.entries) {
      final value = entry.value?.toString() ?? '';
      if (value.length > _contextSizeWarningThreshold) {
        _log.warning(
          'Context key "${entry.key}" from step "${step.id}" '
          'is ${value.length} characters (threshold: $_contextSizeWarningThreshold)',
        );
      }
    }

    return outputs;
  }

  dynamic _deriveFromStructuredOutputs(Map<String, dynamic> outputs, String outputKey) {
    for (final value in outputs.values) {
      if (value is Map<String, dynamic> && value.containsKey(outputKey)) {
        return value[outputKey];
      }
      if (value is Map && value.containsKey(outputKey)) {
        return value[outputKey];
      }
    }
    return null;
  }

  /// Extracts raw text content for format-aware processing.
  ///
  /// Priority: explicit extraction config → agent convention → last assistant message → first .md artifact.
  Future<String?> _extractRawContent(WorkflowStep step, Task task, String outputKey) async {
    // 1. Explicit extraction config.
    if (step.extraction != null) {
      return _applyExtractionConfig(step.extraction!, task);
    }

    // 2. Agent convention (## Context Output).
    final convention = await _extractFromAgentConvention(task, outputKey);
    if (convention != null) return convention;

    // 3. Last assistant message content (full text for JSON extraction).
    if (task.sessionId != null) {
      final messages = await _messageService.getMessagesTail(task.sessionId!, count: 5);
      final lastAssistant = messages.where((m) => m.role == 'assistant').lastOrNull;
      if (lastAssistant != null) return lastAssistant.content;
    }

    // 4. First .md artifact.
    return _extractFirstMdArtifact(task);
  }

  /// Soft-validates parsed JSON against the output config's schema.
  ///
  /// Logs warnings but never throws.
  void _softValidate(Object parsed, OutputConfig config, String stepId, String outputKey) {
    Map<String, dynamic>? schema;

    if (config.presetName != null) {
      schema = schemaPresets[config.presetName]?.schema;
    } else if (config.inlineSchema != null) {
      schema = config.inlineSchema;
    }

    if (schema == null) return;

    final warnings = _schemaValidator.validate(parsed, schema);
    for (final w in warnings) {
      _log.warning('Schema validation for "$outputKey" in step "$stepId": $w');
    }
  }

  /// Dispatches to the appropriate extraction handler based on [config.type].
  Future<String?> _applyExtractionConfig(ExtractionConfig config, Task task) async {
    switch (config.type) {
      case ExtractionType.artifact:
        return _extractArtifactByName(task, config.pattern);
      case ExtractionType.regex:
        _log.warning(
          'ExtractionType.regex not yet implemented for task ${task.id}; '
          'falling back to default extraction',
        );
        return null;
      case ExtractionType.jsonpath:
        _log.warning(
          'ExtractionType.jsonpath not yet implemented for task ${task.id}; '
          'falling back to default extraction',
        );
        return null;
    }
  }

  /// Finds an artifact whose name matches [pattern] and returns its content.
  Future<String?> _extractArtifactByName(Task task, String pattern) async {
    final artifacts = await _taskService.listArtifacts(task.id);
    for (final artifact in artifacts) {
      if (artifact.name.contains(pattern) || artifact.path.contains(pattern)) {
        return _readArtifactContent(task.id, artifact.path);
      }
    }
    return null;
  }

  /// Parses the `## Context Output` section from the last assistant message.
  Future<String?> _extractFromAgentConvention(Task task, String outputKey) async {
    if (task.sessionId == null) return null;

    final messages = await _messageService.getMessagesTail(task.sessionId!, count: 50);
    final assistants = messages.where((m) => m.role == 'assistant');
    if (assistants.isEmpty) return null;
    final lastAssistant = assistants.last;

    // Find ## Context Output section.
    final content = lastAssistant.content;
    final headerIndex = content.indexOf('## Context Output');
    if (headerIndex < 0) return null;

    final section = content.substring(headerIndex + '## Context Output'.length);

    // Try JSON fenced code block first.
    final fenceMatch = RegExp(r'```(?:json)?\s*\n([\s\S]*?)\n```').firstMatch(section);
    if (fenceMatch != null) {
      try {
        final decoded = jsonDecode(fenceMatch.group(1)!) as Map<String, dynamic>;
        return decoded[outputKey]?.toString();
      } catch (_) {
        // Not valid JSON; fall through to key-value parsing.
      }
    }

    // Parse key: value pairs (one per line).
    for (final line in section.split('\n')) {
      final colonIndex = line.indexOf(':');
      if (colonIndex < 0) continue;
      final key = line.substring(0, colonIndex).trim();
      if (key == outputKey) {
        return line.substring(colonIndex + 1).trim();
      }
    }

    return null;
  }

  /// Returns the content of the first `.md` artifact for [task].
  Future<String?> _extractFirstMdArtifact(Task task) async {
    final artifacts = await _taskService.listArtifacts(task.id);
    for (final artifact in artifacts) {
      if (artifact.path.endsWith('.md')) {
        return _readArtifactContent(task.id, artifact.path);
      }
    }
    return null;
  }

  /// Returns a summary string from the `diff.json` artifact, if present.
  Future<String?> _extractDiffArtifact(Task task) async {
    final artifacts = await _taskService.listArtifacts(task.id);
    for (final artifact in artifacts) {
      if (artifact.path.endsWith('diff.json')) {
        final raw = await _readArtifactContent(task.id, artifact.path);
        if (raw == null) return null;
        try {
          final json = jsonDecode(raw) as Map<String, dynamic>;
          final files = (json['files'] as int?) ?? 0;
          final additions = (json['additions'] as int?) ?? 0;
          final deletions = (json['deletions'] as int?) ?? 0;
          return '$files files changed, +$additions -$deletions';
        } catch (_) {
          return raw;
        }
      }
    }
    return null;
  }

  /// Reads the content of an artifact file.
  ///
  /// [path] may be absolute or relative to `<dataDir>/tasks/<taskId>/artifacts/`.
  Future<String?> _readArtifactContent(String taskId, String path) async {
    try {
      final file = File(p.isAbsolute(path) ? path : p.join(_dataDir, 'tasks', taskId, 'artifacts', path));
      if (!file.existsSync()) return null;
      return await file.readAsString();
    } catch (e) {
      _log.warning('Failed to read artifact at "$path" for task $taskId: $e');
      return null;
    }
  }
}
