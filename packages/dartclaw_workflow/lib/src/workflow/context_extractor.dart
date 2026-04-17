import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart'
    show
        MessageService,
        OutputConfig,
        OutputFormat,
        OutputMode,
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
import 'workflow_output_contract.dart';
import 'workflow_task_config_keys.dart';

typedef StructuredOutputFallbackRecorder =
    void Function(
      String taskId, {
      required String stepId,
      required String outputKey,
      required String failureReason,
      String? providerSubtype,
    });

/// Extracts context outputs from a completed task's artifacts and messages.
///
/// Four extraction strategies (in priority order for each output key):
/// 1. Explicit [ExtractionConfig] on the step (artifact lookup by name pattern).
/// 2. Workflow context tag: `<workflow-context>{...}</workflow-context>` in the last assistant message.
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
  final StructuredOutputFallbackRecorder? _structuredOutputFallbackRecorder;

  ContextExtractor({
    required WorkflowTaskService taskService,
    required MessageService messageService,
    required String dataDir,
    SchemaValidator? schemaValidator,
    StructuredOutputFallbackRecorder? structuredOutputFallbackRecorder,
  }) : _taskService = taskService,
       _messageService = messageService,
       _dataDir = dataDir,
       _schemaValidator = schemaValidator ?? const SchemaValidator(),
       _structuredOutputFallbackRecorder = structuredOutputFallbackRecorder;

  /// Extracts context outputs for the given [step] from the completed [task].
  ///
  /// Returns a map of output key → extracted value.
  Future<Map<String, dynamic>> extract(WorkflowStep step, Task task) async {
    final outputs = <String, dynamic>{};
    final workflowContextPayload = await _extractWorkflowContextPayload(task);
    final structuredOutputPayload = _extractStructuredOutputPayload(task);

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

      // Structured-mode primary: provider-enforced payload is authoritative.
      // On miss, record the fallback event and fall through to the heuristic chain.
      if (config != null && config.outputMode == OutputMode.structured) {
        if (structuredOutputPayload.containsKey(outputKey)) {
          final structuredValue = structuredOutputPayload[outputKey];
          _softValidate(structuredValue, config, step.id, outputKey);
          outputs[outputKey] = structuredValue;
          continue;
        }
        _structuredOutputFallbackRecorder?.call(
          task.id,
          stepId: step.id,
          outputKey: outputKey,
          failureReason: 'missing_payload',
        );
      }

      if (workflowContextPayload != null && workflowContextPayload.containsKey(outputKey)) {
        final payloadValue = workflowContextPayload[outputKey];
        if (config == null || config.format == OutputFormat.text) {
          outputs[outputKey] = _stringifyWorkflowValue(payloadValue);
        } else {
          switch (config.format) {
            case OutputFormat.json:
              _softValidate(payloadValue, config, step.id, outputKey);
              outputs[outputKey] = payloadValue;
            case OutputFormat.lines:
              outputs[outputKey] = switch (payloadValue) {
                final List<dynamic> values =>
                  values.map((value) => value.toString().trim()).where((s) => s.isNotEmpty).toList(),
                _ => extractLines(_stringifyWorkflowValue(payloadValue)),
              };
            case OutputFormat.text:
              outputs[outputKey] = _stringifyWorkflowValue(payloadValue);
          }
        }
        continue;
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
              var parsed = extractJson(rawContent);
              // Unwrap: if the parsed JSON is an envelope containing a key
              // matching this outputKey, extract just the nested value. This
              // handles Codex-style responses that emit a flat JSON with all
              // context keys at the top level.
              if (parsed is Map<String, dynamic> && parsed.containsKey(outputKey) && parsed[outputKey] is Map) {
                parsed = parsed[outputKey] as Object;
              }
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
    if (outputs.containsKey(outputKey)) {
      return outputs[outputKey];
    }

    final lastDot = outputKey.lastIndexOf('.');
    if (lastDot > 0) {
      final unscopedKey = outputKey.substring(lastDot + 1);
      if (outputs.containsKey(unscopedKey)) {
        return outputs[unscopedKey];
      }
    }

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

  Map<String, dynamic> _extractStructuredOutputPayload(Task task) {
    final payload = task.configJson[WorkflowTaskConfigKeys.structuredOutputPayload];
    return switch (payload) {
      final Map<String, dynamic> typed => typed,
      final Map<Object?, Object?> raw => raw.map((key, value) => MapEntry(key.toString(), value)),
      _ => const <String, dynamic>{},
    };
  }

  /// Extracts raw text content for format-aware processing.
  ///
  /// Priority: explicit extraction config → last assistant message → first .md artifact.
  Future<String?> _extractRawContent(WorkflowStep step, Task task, String outputKey) async {
    // 1. Explicit extraction config.
    if (step.extraction != null) {
      return _applyExtractionConfig(step.extraction!, task);
    }

    // 2. Last assistant message content (full text for JSON extraction).
    if (task.sessionId != null) {
      final messages = await _messageService.getMessagesTail(task.sessionId!, count: 5);
      final lastAssistant = messages.where((m) => m.role == 'assistant').lastOrNull;
      if (lastAssistant != null) return lastAssistant.content;
    }

    // 3. First .md artifact.
    return _extractFirstMdArtifact(task);
  }

  Future<String?> _extractLastAssistantContent(Task task) async {
    if (task.sessionId == null) return null;
    final messages = await _messageService.getMessagesTail(task.sessionId!, count: 50);
    final lastAssistant = messages.where((m) => m.role == 'assistant').lastOrNull;
    return lastAssistant?.content;
  }

  /// Soft-validates parsed JSON against the output config's schema.
  ///
  /// Logs warnings but never throws.
  void _softValidate(Object? parsed, OutputConfig config, String stepId, String outputKey) {
    if (parsed == null) return;

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

  /// Parses the `<workflow-context>` payload from the last assistant message.
  Future<Map<String, dynamic>?> _extractWorkflowContextPayload(Task task) async {
    final content = await _extractLastAssistantContent(task);
    if (content == null) return null;
    final match = workflowContextRegExp.firstMatch(content);
    if (match == null) return null;

    final rawJson = match.group(1)!;
    final decoded = jsonDecode(rawJson);
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) {
      return decoded.map((key, value) => MapEntry(key.toString(), value));
    }
    throw const FormatException('workflow-context payload must decode to a JSON object');
  }

  String _stringifyWorkflowValue(Object? value) {
    if (value == null) return '';
    if (value is String) return value;
    return jsonEncode(value);
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
