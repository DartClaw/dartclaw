import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart'
    show
        MessageService,
        OutputConfig,
        OutputFormat,
        OutputMode,
        Task,
        WorkflowStepExecutionRepository,
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
import 'workflow_task_config.dart';

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
  final WorkflowStepExecutionRepository? _workflowStepExecutionRepository;

  ContextExtractor({
    required WorkflowTaskService taskService,
    required MessageService messageService,
    required String dataDir,
    WorkflowStepExecutionRepository? workflowStepExecutionRepository,
    SchemaValidator? schemaValidator,
    StructuredOutputFallbackRecorder? structuredOutputFallbackRecorder,
  }) : _taskService = taskService,
       _messageService = messageService,
       _dataDir = dataDir,
       _workflowStepExecutionRepository = workflowStepExecutionRepository,
       _schemaValidator = schemaValidator ?? const SchemaValidator(),
       _structuredOutputFallbackRecorder = structuredOutputFallbackRecorder;

  /// Extracts context outputs for the given [step] from the completed [task].
  ///
  /// Returns a map of output key → extracted value.
  ///
  /// [effectiveOutputs] lets the caller supply a precomputed `outputs:` map
  /// (e.g. the step's explicit config shallow-merged over the skill's
  /// `workflow.default_outputs`). When null, the extractor falls back to
  /// `step.outputs`.
  Future<Map<String, dynamic>> extract(
    WorkflowStep step,
    Task task, {
    Map<String, OutputConfig>? effectiveOutputs,
  }) async {
    final outputs = <String, dynamic>{};
    final configs = effectiveOutputs ?? step.outputs;
    final workflowContextPayload = await _extractWorkflowContextPayload(task);
    final structuredOutputPayload = await _extractStructuredOutputPayload(task);

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
      final config = configs?[outputKey];

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
          final structuredValue = _normalizeJsonOutput(structuredOutputPayload[outputKey], config, step.id, outputKey);
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
              final normalizedValue = _normalizeJsonOutput(payloadValue, config, step.id, outputKey);
              _softValidate(normalizedValue, config, step.id, outputKey);
              outputs[outputKey] = normalizedValue;
            case OutputFormat.lines:
              outputs[outputKey] = switch (payloadValue) {
                final List<dynamic> values =>
                  values.map((value) => value.toString().trim()).where((s) => s.isNotEmpty).toList(),
                _ => extractLines(_stringifyWorkflowValue(payloadValue)),
              };
            case OutputFormat.text:
            case OutputFormat.path:
              outputs[outputKey] = _stringifyWorkflowValue(payloadValue);
          }
        }
        continue;
      }

      if (config != null && config.format != OutputFormat.text && config.format != OutputFormat.path) {
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
              Object? parsed = extractJson(rawContent);
              // Unwrap: if the parsed JSON is an envelope containing a key
              // matching this outputKey, extract just the nested value. This
              // handles Codex-style responses that emit a flat JSON with all
              // context keys at the top level.
              if (parsed is Map<String, dynamic> && parsed.containsKey(outputKey) && parsed[outputKey] is Map) {
                parsed = parsed[outputKey] as Object;
              }
              parsed = _normalizeJsonOutput(parsed, config, step.id, outputKey);
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
          case OutputFormat.path:
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

    // Path-existence validation for `format: path` outputs.
    //
    // Workflows routinely gate downstream steps on whether an upstream step
    // produced a file (e.g. `dartclaw-prd` sets `prd` to the path it wrote;
    // the next step's entryGate `prd == null` skips authoring when a PRD
    // already exists). LLMs occasionally emit the *intended* write path even
    // when they didn't (or couldn't) actually produce the file — poisoning
    // the gate into skipping a step that was supposed to author the file.
    //
    // Defensive policy: if `format: path` resolves to a non-empty string but
    // the file doesn't exist under any of the task's plausible roots, coerce
    // the value to an empty string and log a warning. An empty string is
    // treated as null by the gate evaluator, so the downstream authoring
    // step runs and can produce the file. Coercion is a narrow safety net;
    // skills should still emit correct values.
    final missingPathKeys = <String>{};
    for (final entry in configs?.entries ?? const <MapEntry<String, OutputConfig>>[]) {
      final outputKey = entry.key;
      final outputConfig = entry.value;
      if (outputConfig.format != OutputFormat.path) continue;
      final rawValue = outputs[outputKey];
      if (rawValue is! String || rawValue.isEmpty) continue;
      if (_pathResolvesToExistingFile(rawValue, task)) continue;
      missingPathKeys.add(outputKey);
      _log.warning(
        'Context key "$outputKey" from step "${step.id}" (task ${task.id}) '
        'resolved to path "$rawValue" which does not exist under any known root '
        '(worktree, project, dataDir, cwd). Coercing to empty string — '
        'downstream gates treat this as null. Skill should emit only paths to existing files.',
      );
    }
    final normalizedOutputs = _coercePhantomPaths(outputs, missingPathKeys);

    // Warn on large values.
    for (final entry in normalizedOutputs.entries) {
      final value = entry.value?.toString() ?? '';
      if (value.length > _contextSizeWarningThreshold) {
        _log.warning(
          'Context key "${entry.key}" from step "${step.id}" '
          'is ${value.length} characters (threshold: $_contextSizeWarningThreshold)',
        );
      }
    }

    return normalizedOutputs;
  }

  /// Returns `true` if [value] (possibly relative) resolves to an existing
  /// file under any plausible root for [task].
  ///
  /// Tries, in order: absolute path, task worktree path, project dir under
  /// dataDir (via `task.projectId`), and the process CWD. The check is
  /// read-only and tolerates missing roots.
  bool _pathResolvesToExistingFile(String value, Task task) {
    try {
      if (p.isAbsolute(value)) {
        return File(value).existsSync();
      }
      final roots = <String>[];
      final worktreePath = (task.worktreeJson?['path'] as String?)?.trim();
      if (worktreePath != null && worktreePath.isNotEmpty) roots.add(worktreePath);
      final projectId = task.projectId?.trim();
      if (projectId != null && projectId.isNotEmpty && projectId != '_local') {
        roots.add(p.join(_dataDir, 'projects', projectId));
      }
      roots.add(Directory.current.path);
      for (final root in roots) {
        if (File(p.join(root, value)).existsSync()) return true;
      }
      return false;
    } catch (error, st) {
      _log.fine('Path-existence probe failed for "$value" on task ${task.id}: $error\n$st');
      // On any filesystem error, preserve original value (fail-open).
      return true;
    }
  }

  /// Parses the last well-formed `<step-outcome>` payload from [task]'s
  /// assistant messages.
  Future<StepOutcomePayload?> extractStepOutcome(Task task) async {
    final sessionId = task.sessionId;
    if (sessionId == null || sessionId.isEmpty) return null;

    final messages = await _messageService.getMessages(sessionId);
    for (final message in messages.reversed) {
      if (message.role != 'assistant') continue;
      final parsed = parseStepOutcomePayload(message.content);
      if (parsed != null) return parsed;
    }
    return null;
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

  Future<Map<String, dynamic>> _extractStructuredOutputPayload(Task task) async {
    final repo = _workflowStepExecutionRepository;
    if (repo != null) {
      return await WorkflowTaskConfig.readStructuredOutputPayload(task, repo) ?? const <String, dynamic>{};
    }
    return const <String, dynamic>{};
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

  Object? _normalizeJsonOutput(Object? parsed, OutputConfig config, String stepId, String outputKey) {
    if (parsed == null || config.format != OutputFormat.json) return parsed;
    if (config.presetName == 'project-index') {
      return _sanitizeProjectIndex(parsed, stepId, outputKey);
    }
    return parsed;
  }

  Object _sanitizeProjectIndex(Object parsed, String stepId, String outputKey) {
    final projectIndex = _asStringKeyedMap(parsed);
    if (projectIndex == null) return parsed;

    final rawProjectRoot = projectIndex['project_root'];
    if (rawProjectRoot is! String || rawProjectRoot.trim().isEmpty) {
      return projectIndex;
    }
    final projectRoot = p.normalize(rawProjectRoot.trim());
    final sanitized = Map<String, dynamic>.from(projectIndex);

    final rawDocumentLocations = _asStringKeyedMap(projectIndex['document_locations']);
    if (rawDocumentLocations != null) {
      sanitized['document_locations'] = {
        for (final entry in rawDocumentLocations.entries)
          entry.key: _sanitizeProjectRelativePath(
            projectRoot,
            entry.value,
            stepId: stepId,
            outputKey: outputKey,
            fieldPath: 'document_locations.${entry.key}',
          ),
      };
    }

    final rawArtifactLocations = _asStringKeyedMap(projectIndex['artifact_locations']);
    if (rawArtifactLocations != null) {
      sanitized['artifact_locations'] = {
        for (final entry in rawArtifactLocations.entries)
          entry.key: _sanitizeProjectRelativePath(
            projectRoot,
            entry.value,
            stepId: stepId,
            outputKey: outputKey,
            fieldPath: 'artifact_locations.${entry.key}',
          ),
      };
    }

    for (final key in const ['active_prd', 'active_plan']) {
      if (!sanitized.containsKey(key)) continue;
      sanitized[key] = _sanitizeProjectRelativePath(
        projectRoot,
        sanitized[key],
        stepId: stepId,
        outputKey: outputKey,
        fieldPath: key,
      );
    }

    return sanitized;
  }

  Map<String, dynamic>? _asStringKeyedMap(Object? value) {
    return switch (value) {
      final Map<String, dynamic> typed => Map<String, dynamic>.from(typed),
      final Map<dynamic, dynamic> dynamicMap => dynamicMap.map((key, value) => MapEntry('$key', value)),
      _ => null,
    };
  }

  /// Path-string-based containment check — `..` and absolute escapes are
  /// cleared, but symlinks are not resolved. Threat model is LLM-emitted
  /// paths, not adversarial filesystems; a symlink inside project_root that
  /// targets outside would pass this check.
  Object? _sanitizeProjectRelativePath(
    String projectRoot,
    Object? value, {
    required String stepId,
    required String outputKey,
    required String fieldPath,
  }) {
    if (value == null || value is! String) return value;

    final trimmed = value.trim();
    if (trimmed.isEmpty) return trimmed;

    final normalizedRoot = p.normalize(projectRoot);
    final resolved = p.isAbsolute(trimmed) ? p.normalize(trimmed) : p.normalize(p.join(normalizedRoot, trimmed));
    final withinRoot = resolved == normalizedRoot || p.isWithin(normalizedRoot, resolved);
    if (!withinRoot) {
      _log.warning(
        'Schema normalization for "$outputKey" in step "$stepId": '
        '$fieldPath points outside project_root and will be cleared: $trimmed',
      );
      return null;
    }

    final relative = p.relative(resolved, from: normalizedRoot);
    return relative == '.' ? '' : relative;
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

  /// Parses the `<workflow-context>` payload from the most recent assistant
  /// message that contains one.
  ///
  /// Workflow one-shot execution may append a final bare-JSON extraction turn
  /// after an earlier assistant message already emitted the authoritative
  /// `<workflow-context>...</workflow-context>` block. Looking only at the last
  /// assistant message would silently drop mixed outputs such as text `prd`
  /// plus structured `stories`.
  Future<Map<String, dynamic>?> _extractWorkflowContextPayload(Task task) async {
    final sessionId = task.sessionId;
    if (sessionId == null || sessionId.isEmpty) return null;

    final messages = await _messageService.getMessages(sessionId);
    for (final message in messages.reversed) {
      if (message.role != 'assistant') continue;
      final match = workflowContextRegExp.firstMatch(message.content);
      if (match == null) continue;

      final rawJson = match.group(1)!;
      final decoded = jsonDecode(rawJson);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) {
        return decoded.map((key, value) => MapEntry(key.toString(), value));
      }
      throw const FormatException('workflow-context payload must decode to a JSON object');
    }

    return null;
  }

  String _stringifyWorkflowValue(Object? value) {
    if (value == null) return '';
    if (value is String) return value;
    return jsonEncode(value);
  }

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

Map<String, dynamic> _coercePhantomPaths(Map<String, dynamic> outputs, Set<String> missingPathKeys) {
  if (missingPathKeys.isEmpty) {
    return outputs;
  }
  return {
    for (final entry in outputs.entries)
      entry.key: missingPathKeys.contains(entry.key) ? '' : entry.value,
  };
}
