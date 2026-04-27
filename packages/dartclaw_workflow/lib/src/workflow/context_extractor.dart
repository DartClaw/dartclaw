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

import 'context_output_defaults.dart';
import 'json_extraction.dart';
import 'missing_artifact_failure.dart';
import 'output_resolver.dart';
import 'schema_presets.dart';
import 'schema_validator.dart';
import 'workflow_git_port.dart';
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
/// Five extraction strategies (in priority order for each output key):
/// 1. Explicit `setValue:` literal on the step's [OutputConfig] — short-circuits
///    everything below; writes the configured literal (including `null`)
///    verbatim to context. See `WorkflowStep.outputs[key].setValue`.
/// 2. Explicit [ExtractionConfig] on the step (artifact lookup by name pattern).
///    Skipped for the first context-output key when that key has `setValue:`
///    configured so the legacy priority branch never beats `setValue`.
/// 3. Workflow context tag: `<workflow-context>{...}</workflow-context>` in the last assistant message.
/// 4. First `.md` artifact file content.
/// 5. `diff.json` artifact for diff-related keys.
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
  final WorkflowGitPort? _workflowGitPort;

  ContextExtractor({
    required WorkflowTaskService taskService,
    required MessageService messageService,
    required String dataDir,
    WorkflowStepExecutionRepository? workflowStepExecutionRepository,
    WorkflowGitPort? workflowGitPort,
    SchemaValidator? schemaValidator,
    StructuredOutputFallbackRecorder? structuredOutputFallbackRecorder,
  }) : _taskService = taskService,
       _messageService = messageService,
       _dataDir = dataDir,
       _workflowStepExecutionRepository = workflowStepExecutionRepository,
       _workflowGitPort = workflowGitPort,
       _schemaValidator = schemaValidator ?? const SchemaValidator(),
       _structuredOutputFallbackRecorder = structuredOutputFallbackRecorder;

  /// Extracts context outputs for the given [step] from the completed [task].
  ///
  /// Returns a map of output key → extracted value.
  ///
  /// [effectiveOutputs] lets callers supply precomputed output config; null
  /// falls back to `step.outputs`.
  Future<Map<String, dynamic>> extract(
    WorkflowStep step,
    Task task, {
    Map<String, OutputConfig>? effectiveOutputs,
  }) async {
    final outputs = <String, dynamic>{};
    final configs = effectiveOutputs ?? step.outputs;
    // Drive iteration off the canonical write-set: `outputs:` map keys are the
    // declaration of which context keys this step writes.
    final outputKeys = step.outputKeys;
    final workflowContextPayload = await _extractWorkflowContextPayload(task);
    final structuredOutputPayload = await _extractStructuredOutputPayload(task);

    // 1. Explicit ExtractionConfig takes priority for first output key (backward compat).
    //    Skipped when the first output key has `setValue` configured — `setValue`
    //    must win unconditionally over the legacy extraction-priority branch
    //    (otherwise `extraction:` would silently beat `setValue:` for the first key only).
    if (step.extraction != null && outputKeys.isNotEmpty) {
      final firstKey = outputKeys.first;
      final firstKeyHasSetValue = configs?[firstKey]?.hasSetValue ?? false;
      if (!firstKeyHasSetValue) {
        final extracted = await _applyExtractionConfig(step.extraction!, task);
        if (extracted != null) {
          outputs[firstKey] = extracted;
        }
      }
    }

    // 2. For each declared output key not yet extracted.
    for (final outputKey in outputKeys) {
      if (outputs.containsKey(outputKey)) continue;

      // Determine output config for this key.
      final config = configs?[outputKey];

      // setValue: explicit literal short-circuit — write the configured value
      // (including `null`) directly to context and skip all extraction paths.
      // Fires only on step success; the extract() entry-point itself is only
      // reached on success today, so failure/skip cases need no extra guard.
      if (config != null && config.hasSetValue) {
        outputs[outputKey] = config.setValue;
        continue;
      }

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

      if (_isDiscoverProjectCanonicalOutput(step, outputKey)) {
        outputs[outputKey] = defaultContextOutput(step, outputs, outputKey) ?? '';
        continue;
      }

      // discover-project's spec_path is load-bearing only when spec_source == 'existing';
      // tolerate non-existent claims otherwise (the spec step will synthesize).
      if (step.id == 'discover-project' && outputKey == 'spec_path') {
        final claimedSource = workflowContextPayload?['spec_source']?.toString().trim();
        if (claimedSource != 'existing') {
          outputs[outputKey] = '';
          continue;
        }
      }

      final resolver = outputResolverFor(outputKey, config);
      switch (resolver) {
        case FileSystemOutput():
          outputs[outputKey] = await _resolveFileSystemOutput(
            resolver,
            outputKey: outputKey,
            task: task,
            inlinePayload: workflowContextPayload?[outputKey],
          );
          continue;
        case InlineOutput():
          if (workflowContextPayload != null && workflowContextPayload.containsKey(outputKey)) {
            outputs[outputKey] = _normalizePayloadValue(workflowContextPayload[outputKey], config, step.id, outputKey);
            continue;
          }
          if (structuredOutputPayload.containsKey(outputKey)) {
            outputs[outputKey] = _normalizePayloadValue(structuredOutputPayload[outputKey], config, step.id, outputKey);
            continue;
          }
        case NarrativeOutput():
          if (workflowContextPayload != null && workflowContextPayload.containsKey(outputKey)) {
            outputs[outputKey] = _normalizePayloadValue(workflowContextPayload[outputKey], config, step.id, outputKey);
            continue;
          }
          if (structuredOutputPayload.containsKey(outputKey)) {
            outputs[outputKey] = _normalizePayloadValue(structuredOutputPayload[outputKey], config, step.id, outputKey);
            continue;
          }
      }

      final derivedValue = _deriveFromStructuredOutputs(step, outputs, outputKey);
      if (derivedValue != null) {
        outputs[outputKey] = derivedValue;
        continue;
      }

      if (config != null && config.outputMode == OutputMode.structured) {
        _structuredOutputFallbackRecorder?.call(
          task.id,
          stepId: step.id,
          outputKey: outputKey,
          failureReason: 'missing_payload',
        );
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

    applyContextOutputDefaults(step, outputs);

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

  bool _isDiscoverProjectCanonicalOutput(WorkflowStep step, String outputKey) {
    return step.id == 'discover-project' && const {'prd', 'plan', 'story_specs'}.contains(outputKey);
  }

  Future<Object?> _resolveFileSystemOutput(
    FileSystemOutput resolver, {
    required String outputKey,
    required Task task,
    required Object? inlinePayload,
  }) async {
    final claimedPaths = _claimedPaths(inlinePayload);
    final worktreePath = (task.worktreeJson?['path'] as String?)?.trim() ?? '';
    final git = _workflowGitPort;

    if (git == null || worktreePath.isEmpty) {
      final missingPaths = claimedPaths.where((path) => !_pathResolvesToExistingFile(path, task)).toList();
      if (missingPaths.isNotEmpty) {
        throw MissingArtifactFailure(
          claimedPaths: claimedPaths,
          missingPaths: missingPaths,
          worktreePath: worktreePath,
          fieldName: outputKey,
          reason: 'path claimed but not present in worktree diff',
        );
      }
      if (resolver.listMode) return claimedPaths;
      return claimedPaths.isEmpty ? '' : claimedPaths.single;
    }

    final changedPaths = await git.diffNameOnly(worktreePath);
    final matches = changedPaths.map(p.normalize).where(resolver.matches).toList()..sort();
    final existingClaims = claimedPaths.where((path) => _pathResolvesToExistingFile(path, task)).toList();
    final missingClaims = claimedPaths
        .where((path) => !matches.contains(p.normalize(path)) && !existingClaims.contains(path))
        .toList();
    if (missingClaims.isNotEmpty) {
      throw MissingArtifactFailure(
        claimedPaths: claimedPaths,
        missingPaths: missingClaims,
        worktreePath: worktreePath,
        fieldName: outputKey,
        reason: 'path claimed but not present in worktree diff',
      );
    }

    if (claimedPaths.isNotEmpty) {
      if (resolver.listMode) return claimedPaths.toList()..sort();
      if (claimedPaths.length == 1) return claimedPaths.single;
      throw StateError('Multiple filesystem artifacts were explicitly claimed for "$outputKey": $claimedPaths');
    }
    if (resolver.listMode) return matches;
    if (matches.isEmpty) return '';
    if (matches.length == 1) return matches.single;
    throw StateError('Multiple filesystem artifacts matched "$outputKey" in $worktreePath: $matches');
  }

  Object? _normalizePayloadValue(Object? payloadValue, OutputConfig? config, String stepId, String outputKey) {
    if (config == null || config.format == OutputFormat.text) {
      return _stringifyWorkflowValue(payloadValue);
    }
    switch (config.format) {
      case OutputFormat.json:
        final normalizedValue = _normalizeJsonOutput(payloadValue, config, stepId, outputKey);
        _softValidate(normalizedValue, config, stepId, outputKey);
        return normalizedValue;
      case OutputFormat.lines:
        return switch (payloadValue) {
          final List<dynamic> values =>
            values.map((value) => value.toString().trim()).where((s) => s.isNotEmpty).toList(),
          _ => extractLines(_stringifyWorkflowValue(payloadValue)),
        };
      case OutputFormat.text:
      case OutputFormat.path:
        return _stringifyWorkflowValue(payloadValue);
    }
  }

  List<String> _claimedPaths(Object? payloadValue) {
    if (payloadValue == null) return const <String>[];
    if (payloadValue is String) {
      final value = payloadValue.trim();
      return value.isEmpty || value == 'null' ? const <String>[] : <String>[p.normalize(value)];
    }
    if (payloadValue is Iterable) {
      return payloadValue
          .map((value) => value.toString().trim())
          .where((value) => value.isNotEmpty && value != 'null')
          .map(p.normalize)
          .toList();
    }
    return const <String>[];
  }

  /// Returns `true` if [value] (possibly relative) resolves to an existing
  /// file under any plausible root for [task].
  ///
  /// Tries, in order: absolute path, task worktree path, project dir under
  /// dataDir (via `task.projectId`). The check is
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

  dynamic _deriveFromStructuredOutputs(WorkflowStep step, Map<String, dynamic> outputs, String outputKey) {
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
    return defaultContextOutput(step, outputs, outputKey);
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

    final rawActiveStorySpecs = _asStringKeyedMap(projectIndex['active_story_specs']);
    if (rawActiveStorySpecs != null) {
      final rawItems = rawActiveStorySpecs['items'];
      if (rawItems is List) {
        sanitized['active_story_specs'] = {
          ...rawActiveStorySpecs,
          'items': [
            for (var index = 0; index < rawItems.length; index++)
              switch (_asStringKeyedMap(rawItems[index])) {
                final item? => {
                  ...item,
                  'spec_path': _sanitizeProjectRelativePath(
                    projectRoot,
                    item['spec_path'],
                    stepId: stepId,
                    outputKey: outputKey,
                    fieldPath: 'active_story_specs.items[$index].spec_path',
                  ),
                },
                _ => rawItems[index],
              },
          ],
        };
      }
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
