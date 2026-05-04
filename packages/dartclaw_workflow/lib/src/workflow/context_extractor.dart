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
import 'workflow_run_paths.dart';
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
      if (_isSpecPathDiscoveryStep(step, outputKey)) {
        final claimedSource = workflowContextPayload?['spec_source']?.toString().trim();
        if (claimedSource != 'existing') {
          outputs[outputKey] = '';
          continue;
        }
      }

      final resolver = outputResolverFor(outputKey, config);
      switch (resolver) {
        case FileSystemOutput():
          try {
            outputs[outputKey] = await _resolveFileSystemOutput(
              resolver,
              outputKey: outputKey,
              step: step,
              task: task,
              inlinePayload: workflowContextPayload?[outputKey],
              workflowContextPayload: workflowContextPayload,
            );
          } on MissingArtifactFailure catch (error) {
            if (_isSpecPathDiscoveryStep(step, outputKey)) {
              _log.warning(
                '$_discoverProjectStepId claimed an existing spec path that is not present; '
                'treating it as synthesized so the spec step can author one. $error',
              );
              outputs[outputKey] = '';
              continue;
            }
            rethrow;
          }
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

      final derivedValue = _deriveFromStructuredOutputs(
        step,
        outputs,
        outputKey,
        workflowContextPayload: workflowContextPayload,
        structuredOutputPayload: structuredOutputPayload,
      );
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
              _validateSchema(parsed, config, step.id, outputKey);
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

  // Single source of truth for the discover-project workflow step id. All
  // step-specific behavior in this file (canonical-output handling, spec_path
  // tolerance) routes through one of the predicates below — grep this constant
  // if the workflow YAML ever renames the step.
  static const _discoverProjectStepId = 'discover-project';

  bool _isDiscoverProjectStep(WorkflowStep step) => step.id == _discoverProjectStepId;

  bool _isDiscoverProjectCanonicalOutput(WorkflowStep step, String outputKey) {
    return _isDiscoverProjectStep(step) && const {'prd', 'plan', 'story_specs'}.contains(outputKey);
  }

  // The discover-project step may legitimately claim a spec_path that is not
  // yet on disk when spec_source != 'existing' (the downstream spec step will
  // synthesize the file). Centralizing the predicate keeps the two callers
  // (early-skip + MissingArtifactFailure recovery) aligned.
  bool _isSpecPathDiscoveryStep(WorkflowStep step, String outputKey) {
    return _isDiscoverProjectStep(step) && outputKey == 'spec_path';
  }

  Future<Object?> _resolveFileSystemOutput(
    FileSystemOutput resolver, {
    required String outputKey,
    required WorkflowStep step,
    required Task task,
    required Object? inlinePayload,
    required Map<String, dynamic>? workflowContextPayload,
  }) async {
    final claimedPaths = _claimedPaths(inlinePayload);
    final worktreePath = (task.worktreeJson?['path'] as String?)?.trim() ?? '';
    final git = _workflowGitPort;
    final preservesRuntimeArtifactsRoot = _preservesRuntimeArtifactsRoot(
      outputKey,
      step,
      resolver,
      workflowContextPayload,
    );

    if (git == null || worktreePath.isEmpty) {
      final existingClaims = _existingSafeFileClaims(
        claimedPaths,
        task,
        resolver,
        preserveRuntimeArtifactsRoot: preservesRuntimeArtifactsRoot,
      );
      final missingPaths = claimedPaths.where((path) => !existingClaims.containsKey(path)).toList();
      if (missingPaths.isNotEmpty) {
        if (_allowsMissingCleanReviewArtifact(outputKey, step, resolver, workflowContextPayload)) {
          final fallback = _materializeMissingCleanReviewArtifact(
            outputKey: outputKey,
            step: step,
            task: task,
            resolver: resolver,
            missingClaims: missingPaths,
            workflowContextPayload: workflowContextPayload,
          );
          if (fallback != null) return resolver.listMode ? <String>[fallback] : fallback;
          _log.warning(
            'Ignoring missing clean review artifact claim(s) for "$outputKey" on task ${task.id}: $missingPaths',
          );
          return resolver.listMode ? const <String>[] : '';
        }
        throw MissingArtifactFailure(
          claimedPaths: claimedPaths,
          missingPaths: missingPaths,
          worktreePath: worktreePath,
          fieldName: outputKey,
          reason: 'path claimed but not present in worktree diff',
        );
      }
      final safeClaims = existingClaims.values.toList()..sort();
      if (resolver.listMode) return safeClaims;
      return safeClaims.isEmpty ? '' : safeClaims.single;
    }

    final changedPaths = await git.diffNameOnly(worktreePath);
    final matches = _safeChangedFileSystemMatches(
      changedPaths.map(p.normalize).where(resolver.matches),
      task,
      resolver,
    );
    final existingClaims = _existingSafeFileClaims(
      claimedPaths,
      task,
      resolver,
      preserveRuntimeArtifactsRoot: preservesRuntimeArtifactsRoot,
    );
    final missingClaims = claimedPaths
        .where(
          (path) => !matches.contains(existingClaims[path] ?? p.normalize(path)) && !existingClaims.containsKey(path),
        )
        .toList();
    if (missingClaims.isNotEmpty) {
      if (matches.isNotEmpty) {
        _log.warning(
          'Ignoring stale claimed path(s) for "$outputKey" on task ${task.id}: '
          '$missingClaims; using changed file(s): $matches',
        );
        if (resolver.listMode) return matches;
        if (matches.length == 1) return matches.single;
        throw StateError(
          'Multiple filesystem artifacts matched "$outputKey" in $worktreePath '
          'after stale claims $missingClaims: $matches',
        );
      }
      if (_allowsMissingCleanReviewArtifact(outputKey, step, resolver, workflowContextPayload)) {
        final fallback = _materializeMissingCleanReviewArtifact(
          outputKey: outputKey,
          step: step,
          task: task,
          resolver: resolver,
          missingClaims: missingClaims,
          workflowContextPayload: workflowContextPayload,
        );
        if (fallback != null) return resolver.listMode ? <String>[fallback] : fallback;
        _log.warning(
          'Ignoring missing clean review artifact claim(s) for "$outputKey" on task ${task.id}: $missingClaims',
        );
        return resolver.listMode ? const <String>[] : '';
      }
      throw MissingArtifactFailure(
        claimedPaths: claimedPaths,
        missingPaths: missingClaims,
        worktreePath: worktreePath,
        fieldName: outputKey,
        reason: 'path claimed but not present in worktree diff',
      );
    }

    if (claimedPaths.isNotEmpty) {
      final matchingClaims = _changedFileSystemOutputClaims(claimedPaths, existingClaims, matches);
      final runtimeClaims = preservesRuntimeArtifactsRoot
          ? _runtimeArtifactsOutputClaims(existingClaims.values, task)
          : const <String>[];
      if (runtimeClaims.isNotEmpty) {
        if (resolver.listMode) return runtimeClaims;
        if (runtimeClaims.length == 1) return runtimeClaims.single;
        throw StateError('Multiple runtime artifacts were explicitly claimed for "$outputKey": $runtimeClaims');
      }
      if (matchingClaims.isNotEmpty &&
          (_prefersChangedFileSystemMatches(outputKey, step, resolver, workflowContextPayload) || !resolver.listMode)) {
        if (resolver.listMode) return matchingClaims;
        if (matchingClaims.length == 1) return matchingClaims.single;
        throw StateError('Multiple filesystem artifacts were explicitly claimed for "$outputKey": $matchingClaims');
      }
      if (_prefersChangedFileSystemMatches(outputKey, step, resolver, workflowContextPayload) && matches.isNotEmpty) {
        if (resolver.listMode) return matches;
        if (matches.length == 1) return matches.single;
        throw StateError('Multiple filesystem artifacts matched "$outputKey" in $worktreePath: $matches');
      }
      final safeClaims = _safeFileSystemOutputClaims(claimedPaths, existingClaims, matches);
      if (resolver.listMode) return safeClaims;
      if (safeClaims.length == 1) return safeClaims.single;
      throw StateError('Multiple filesystem artifacts were explicitly claimed for "$outputKey": $safeClaims');
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
        _validateSchema(normalizedValue, config, stepId, outputKey);
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

  bool _prefersChangedFileSystemMatches(
    String outputKey,
    WorkflowStep step,
    FileSystemOutput resolver,
    Map<String, dynamic>? workflowContextPayload,
  ) {
    return _isReviewArtifactPathOutput(outputKey, step, resolver, workflowContextPayload);
  }

  bool _preservesRuntimeArtifactsRoot(
    String outputKey,
    WorkflowStep step,
    FileSystemOutput resolver,
    Map<String, dynamic>? workflowContextPayload,
  ) {
    return _isReviewArtifactPathOutput(outputKey, step, resolver, workflowContextPayload);
  }

  bool _allowsMissingCleanReviewArtifact(
    String outputKey,
    WorkflowStep step,
    FileSystemOutput resolver,
    Map<String, dynamic>? workflowContextPayload,
  ) {
    if (!_isReviewArtifactPathOutput(outputKey, step, resolver, workflowContextPayload) ||
        workflowContextPayload == null) {
      return false;
    }
    final findingsCount = _firstInteger(workflowContextPayload, _findingsCountKeys(step));
    final gatingCount = _firstInteger(workflowContextPayload, _gatingFindingsCountKeys(step));
    if (findingsCount == null) return false;
    return findingsCount == 0 && (gatingCount == null || gatingCount == 0);
  }

  String? _materializeMissingCleanReviewArtifact({
    required String outputKey,
    required WorkflowStep step,
    required Task task,
    required FileSystemOutput resolver,
    required List<String> missingClaims,
    required Map<String, dynamic>? workflowContextPayload,
  }) {
    final runId = task.workflowRunId?.trim();
    if (runId == null || runId.isEmpty) return null;

    final runtimeArtifactsDir = _runtimeArtifactsDir(runId);
    for (final claim in missingClaims.map(p.normalize)) {
      // TOCTOU note: the containment check in _runtimeArtifactsRelativeClaim resolves
      // symlinks at validation time, but the createSync/writeAsStringSync below run
      // separately. A racing process with write access to runtimeArtifactsDir could
      // swap a path component for a symlink in between, redirecting the write outside
      // the run dir. The threat model is bounded: any agent that can win this race
      // already has write access to the run dir (a confused-deputy scenario rather
      // than privilege escalation), and the materialized body is a diagnostic stub —
      // no secrets are leaked. Tightening to O_CREAT|O_EXCL or temp-then-rename is
      // tracked as a hardening item if the threat model widens.
      final relative = _runtimeArtifactsRelativeClaim(claim, runtimeArtifactsDir);
      if (relative == null) continue;
      if (!resolver.matches(relative)) continue;

      try {
        final file = File(claim)..createSync(recursive: true);
        file.writeAsStringSync(_missingCleanReviewArtifactBody(outputKey, step, task, workflowContextPayload));
        _log.warning(
          'Materialized diagnostic clean review artifact for "$outputKey" on task ${task.id} '
          'after the agent claimed a missing zero-finding report: $claim',
        );
        return claim;
      } catch (error, st) {
        _log.warning(
          'Failed to materialize diagnostic clean review artifact for "$outputKey" on task ${task.id}: $claim',
          error,
          st,
        );
        return null;
      }
    }
    return null;
  }

  String? _runtimeArtifactsRelativeClaim(String claim, String runtimeArtifactsDir) {
    final normalizedClaim = p.normalize(claim);
    if (!p.isAbsolute(normalizedClaim)) return null;

    final roots = <String>{p.normalize(runtimeArtifactsDir)};
    try {
      if (Directory(runtimeArtifactsDir).existsSync()) {
        roots.add(p.normalize(Directory(runtimeArtifactsDir).resolveSymbolicLinksSync()));
      }
    } catch (_) {
      // The unresolved string root still protects the common non-symlink case.
    }

    for (final root in roots) {
      if (p.isWithin(root, normalizedClaim)) {
        final relative = p.normalize(p.relative(normalizedClaim, from: root));
        if (!_runtimeArtifactsClaimStaysInside(runtimeArtifactsDir, normalizedClaim)) return null;
        return relative;
      }
    }
    return null;
  }

  bool _runtimeArtifactsClaimStaysInside(String runtimeArtifactsDir, String claim) {
    try {
      final resolvedRoot = Directory(runtimeArtifactsDir).resolveSymbolicLinksSync();
      final resolvedClaim = _resolveExistingPathOrParent(claim);
      if (resolvedClaim == null) return false;
      return resolvedClaim == resolvedRoot || p.isWithin(resolvedRoot, resolvedClaim);
    } on FileSystemException {
      // runtimeArtifactsDir doesn't exist yet (first claim in a brand-new run).
      // String containment was already established by the caller; no symlinks
      // can exist inside a non-existent dir, so string-level check suffices.
      return p.isWithin(p.normalize(runtimeArtifactsDir), claim);
    }
  }

  String? _resolveExistingPathOrParent(String path) {
    if (File(path).existsSync()) return File(path).resolveSymbolicLinksSync();
    if (Directory(path).existsSync()) return Directory(path).resolveSymbolicLinksSync();
    final parent = Directory(p.dirname(path));
    if (!parent.existsSync()) return null;
    return p.normalize(p.join(parent.resolveSymbolicLinksSync(), p.basename(path)));
  }

  String _missingCleanReviewArtifactBody(
    String outputKey,
    WorkflowStep step,
    Task task,
    Map<String, dynamic>? workflowContextPayload,
  ) {
    final findingsCount = _firstInteger(workflowContextPayload ?? const <String, dynamic>{}, _findingsCountKeys(step));
    final gatingCount = _firstInteger(
      workflowContextPayload ?? const <String, dynamic>{},
      _gatingFindingsCountKeys(step),
    );
    return [
      '# Clean Review Artifact',
      '',
      'The agent reported a clean review but did not leave the claimed markdown report on disk.',
      'DartClaw materialized this diagnostic artifact so downstream steps have a durable review path.',
      '',
      '- Step: ${step.id}',
      '- Task: ${task.id}',
      '- Output: $outputKey',
      '- Findings count: ${findingsCount ?? 0}',
      '- Gating findings count: ${gatingCount ?? 0}',
      '',
    ].join('\n');
  }

  bool _isReviewArtifactPathOutput(
    String outputKey,
    WorkflowStep step,
    FileSystemOutput resolver,
    Map<String, dynamic>? workflowContextPayload,
  ) {
    if (step.outputs?[outputKey]?.format != OutputFormat.path) return false;
    return _declaresReviewCounts(step) ||
        _payloadHasReviewCounts(step, workflowContextPayload) ||
        _hasReviewArtifactPattern(resolver);
  }

  bool _hasReviewArtifactPattern(FileSystemOutput resolver) {
    final pattern = resolver.pathPattern.toLowerCase();
    return pattern.contains('review') || pattern.contains('architecture');
  }

  bool _declaresReviewCounts(WorkflowStep step) {
    final outputKeys = step.outputKeys.toSet();
    return outputKeys.contains('${step.id}.findings_count') ||
        outputKeys.contains('${step.id}.gating_findings_count') ||
        outputKeys.contains('findings_count') ||
        outputKeys.contains('gating_findings_count');
  }

  bool _payloadHasReviewCounts(WorkflowStep step, Map<String, dynamic>? workflowContextPayload) {
    if (workflowContextPayload == null) return false;
    return _firstInteger(workflowContextPayload, _findingsCountKeys(step)) != null ||
        _firstInteger(workflowContextPayload, _gatingFindingsCountKeys(step)) != null;
  }

  List<String> _findingsCountKeys(WorkflowStep step) => ['${step.id}.findings_count', 'findings_count'];

  List<String> _gatingFindingsCountKeys(WorkflowStep step) => [
    '${step.id}.gating_findings_count',
    'gating_findings_count',
  ];

  int? _firstInteger(Map<String, dynamic> values, Iterable<String> keys) {
    for (final key in keys) {
      final value = values[key];
      if (value is int) return value;
      if (value is num && value.isFinite && value.roundToDouble() == value) {
        return value.toInt();
      }
      if (value is String) {
        final parsed = int.tryParse(value.trim());
        if (parsed != null) return parsed;
      }
    }
    return null;
  }

  List<String> _changedFileSystemOutputClaims(
    List<String> claimedPaths,
    Map<String, String> existingClaims,
    List<String> changedMatches,
  ) {
    return claimedPaths
        .map((path) => existingClaims[path] ?? p.normalize(path))
        .where(changedMatches.contains)
        .toSet()
        .toList()
      ..sort();
  }

  List<String> _safeChangedFileSystemMatches(Iterable<String> values, Task task, FileSystemOutput resolver) {
    return values
        .map(
          (value) => _safeRelativeExistingFileClaim(value, task, resolver, roots: _worktreeFileSystemOutputRoots(task)),
        )
        .whereType<String>()
        .toSet()
        .toList()
      ..sort();
  }

  List<String> _safeFileSystemOutputClaims(
    List<String> claimedPaths,
    Map<String, String> existingClaims,
    List<String> changedMatches,
  ) {
    return claimedPaths
        .map((path) => existingClaims[path] ?? p.normalize(path))
        .where(changedMatches.contains)
        .followedBy(existingClaims.values)
        .toSet()
        .toList()
      ..sort();
  }

  List<String> _runtimeArtifactsOutputClaims(Iterable<String> claims, Task task) {
    final runId = task.workflowRunId?.trim();
    if (runId == null || runId.isEmpty) return const <String>[];
    final runtimeArtifactsDir = _runtimeArtifactsDir(runId);
    return claims
        .map(p.normalize)
        .where((claim) => _runtimeArtifactsRelativeClaim(claim, runtimeArtifactsDir) != null)
        .toSet()
        .toList()
      ..sort();
  }

  Map<String, String> _existingSafeFileClaims(
    List<String> values,
    Task task,
    FileSystemOutput resolver, {
    required bool preserveRuntimeArtifactsRoot,
  }) {
    final claims = <String, String>{};
    for (final value in values) {
      final safeClaim = _safeRelativeExistingFileClaim(
        value,
        task,
        resolver,
        preserveRuntimeArtifactsRoot: preserveRuntimeArtifactsRoot,
      );
      if (safeClaim != null) claims[value] = safeClaim;
    }
    return claims;
  }

  String? _safeRelativeExistingFileClaim(
    String value,
    Task task,
    FileSystemOutput resolver, {
    bool preserveRuntimeArtifactsRoot = false,
    List<String>? roots,
  }) {
    for (final root in roots ?? _fileSystemOutputRoots(task)) {
      try {
        final normalizedRoot = p.normalize(root);
        if (!Directory(normalizedRoot).existsSync()) continue;
        final candidates = _relativeClaimCandidates(value, normalizedRoot, projectId: task.projectId);
        for (var i = 0; i < candidates.length; i++) {
          final claim = candidates[i];
          final candidate = p.normalize(p.isAbsolute(claim) ? claim : p.join(normalizedRoot, claim));
          if (!p.isWithin(normalizedRoot, candidate) || !File(candidate).existsSync()) continue;
          final resolvedRoot = p.normalize(Directory(normalizedRoot).resolveSymbolicLinksSync());
          final resolvedCandidate = p.normalize(File(candidate).resolveSymbolicLinksSync());
          if (!p.isWithin(resolvedRoot, resolvedCandidate)) continue;
          final relative = p.normalize(p.relative(candidate, from: normalizedRoot));
          if (!resolver.matches(relative)) continue;
          if (preserveRuntimeArtifactsRoot && _isRuntimeArtifactsRoot(normalizedRoot, task)) {
            return candidate;
          }
          if (i > 0) {
            _log.fine(
              'Path-existence probe stripped prefix from "$value" → "$relative" under "$normalizedRoot" for task ${task.id}',
            );
          }
          return relative;
        }
      } catch (error, st) {
        _log.fine('Path-existence probe failed for "$value" on task ${task.id}: $error\n$st');
      }
    }
    return null;
  }

  // Order is load-bearing: the un-stripped form must be tried first so that a
  // worktree containing both `<root>/<projectId>/foo.md` and `<root>/foo.md`
  // resolves to the agent's literal claim rather than the stripped fallback.
  List<String> _relativeClaimCandidates(String value, String root, {String? projectId}) {
    final normalized = p.normalize(value);
    if (p.isAbsolute(normalized)) return [normalized];
    final candidates = <String>[normalized];
    final parts = p.split(normalized);
    final removablePrefixes = {p.basename(root), if (projectId?.trim().isNotEmpty ?? false) projectId!.trim()};
    if (parts.length > 1 && removablePrefixes.contains(parts.first)) {
      candidates.add(p.joinAll(parts.skip(1)));
    }
    return candidates;
  }

  List<String> _fileSystemOutputRoots(Task task) {
    final roots = _worktreeFileSystemOutputRoots(task);
    final runId = task.workflowRunId?.trim();
    if (runId != null && runId.isNotEmpty) {
      roots.add(_runtimeArtifactsDir(runId));
    }
    final projectId = task.projectId?.trim();
    if (projectId != null && projectId.isNotEmpty && projectId != '_local') {
      roots.add(p.join(_dataDir, 'projects', projectId));
    }
    return roots;
  }

  List<String> _worktreeFileSystemOutputRoots(Task task) {
    final worktreePath = (task.worktreeJson?['path'] as String?)?.trim();
    return worktreePath == null || worktreePath.isEmpty ? <String>[] : <String>[worktreePath];
  }

  bool _isRuntimeArtifactsRoot(String root, Task task) {
    final runId = task.workflowRunId?.trim();
    if (runId == null || runId.isEmpty) return false;
    return p.normalize(root) == _runtimeArtifactsDir(runId);
  }

  String _runtimeArtifactsDir(String runId) => workflowRuntimeArtifactsDir(dataDir: _dataDir, runId: runId);

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

  dynamic _deriveFromStructuredOutputs(
    WorkflowStep step,
    Map<String, dynamic> outputs,
    String outputKey, {
    required Map<String, dynamic>? workflowContextPayload,
    required Map<String, dynamic> structuredOutputPayload,
  }) {
    if (outputs.containsKey(outputKey)) {
      return outputs[outputKey];
    }
    final reviewCount = _deriveReviewFindingCount(outputKey, outputs, workflowContextPayload, structuredOutputPayload);
    if (reviewCount != null) return reviewCount;

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

  int? _deriveReviewFindingCount(
    String outputKey,
    Map<String, dynamic> outputs,
    Map<String, dynamic>? workflowContextPayload,
    Map<String, dynamic> structuredOutputPayload,
  ) {
    if (!outputKey.endsWith('.findings_count') && !outputKey.endsWith('.gating_findings_count')) {
      return null;
    }
    for (final source in [outputs, workflowContextPayload, structuredOutputPayload]) {
      final count = _deriveReviewFindingCountFromMap(outputKey, source);
      if (count != null) return count;
    }
    if (outputKey.endsWith('.findings_count')) {
      for (final source in [outputs, workflowContextPayload, structuredOutputPayload]) {
        final totalCount = _findIntegerValue(source, 'findings_count');
        if (totalCount != null) return totalCount;
      }
    }
    if (outputKey.endsWith('.gating_findings_count')) {
      final totalKey = outputKey.replaceFirst('.gating_findings_count', '.findings_count');
      for (final source in [workflowContextPayload, structuredOutputPayload]) {
        final totalCount = _findIntegerValue(source, totalKey);
        if (totalCount != null) return totalCount;
      }
      for (final source in [outputs, workflowContextPayload, structuredOutputPayload]) {
        final gatingCount = _findIntegerValue(source, 'gating_findings_count');
        if (gatingCount != null) return gatingCount;
      }
      for (final source in [outputs, workflowContextPayload, structuredOutputPayload]) {
        final totalCount = _findIntegerValue(source, 'findings_count');
        if (totalCount != null) return totalCount;
      }
    }
    return null;
  }

  int? _findIntegerValue(Map<String, dynamic>? source, String key) {
    if (source == null) return null;
    final directValue = _asInteger(source[key]);
    if (directValue != null) return directValue;
    for (final value in source.values) {
      final map = _asStringKeyedMap(value);
      final nestedValue = _asInteger(map?[key]);
      if (nestedValue != null) return nestedValue;
    }
    return null;
  }

  int? _asInteger(Object? value) {
    if (value is int) return value;
    if (value is num && value.isFinite && value.roundToDouble() == value) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  int? _deriveReviewFindingCountFromMap(String outputKey, Map<String, dynamic>? source) {
    if (source == null) return null;
    final directCount = _deriveReviewFindingCountFromVerdict(outputKey, source);
    if (directCount != null) return directCount;

    for (final value in source.values) {
      final verdict = _asVerdictMap(value);
      if (verdict == null) continue;
      final count = _deriveReviewFindingCountFromVerdict(outputKey, verdict);
      if (count != null) return count;
    }
    return null;
  }

  int? _deriveReviewFindingCountFromVerdict(String outputKey, Map<String, dynamic> verdict) {
    if (!verdict.containsKey('findings')) return null;
    if (outputKey.endsWith('.findings_count')) {
      final findingsCount = verdict['findings_count'];
      if (findingsCount is int) return findingsCount;
      if (findingsCount is num) return findingsCount.toInt();
    }
    if (outputKey.endsWith('.gating_findings_count')) {
      final findings = verdict['findings'];
      if (findings is! Iterable) return null;
      return findings.where(_isGatingFinding).length;
    }
    return null;
  }

  Map<String, dynamic>? _asVerdictMap(Object? value) {
    final map = _asStringKeyedMap(value);
    if (map != null) return map;
    if (value is String) {
      try {
        final decoded = jsonDecode(value);
        return _asStringKeyedMap(decoded);
      } on FormatException {
        return null;
      }
    }
    return null;
  }

  bool _isGatingFinding(Object? finding) {
    final findingMap = _asStringKeyedMap(finding);
    final severity = findingMap?['severity']?.toString().trim().toLowerCase();
    return severity == null || severity != 'low';
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

  void _validateSchema(Object? parsed, OutputConfig config, String stepId, String outputKey) {
    if (parsed == null) return;

    Map<String, dynamic>? schema;

    if (config.presetName != null) {
      schema = schemaPresets[config.presetName]?.schema;
    } else if (config.inlineSchema != null) {
      schema = config.inlineSchema;
    }

    if (schema == null) return;

    final warnings = _schemaValidator.validate(parsed, schema);
    if (warnings.isNotEmpty && _requiresStrictSchema(config, outputKey)) {
      throw FormatException(
        'Structured output "$outputKey" from step "$stepId" failed schema validation: ${warnings.join('; ')}',
      );
    }
    for (final w in warnings) {
      _log.warning('Schema validation for "$outputKey" in step "$stepId": $w');
    }
  }

  bool _requiresStrictSchema(OutputConfig config, String outputKey) {
    if (config.outputMode != OutputMode.structured) return false;
    return config.presetName == 'non-negative-integer' ||
        outputKey.endsWith('.findings_count') ||
        outputKey.endsWith('.gating_findings_count') ||
        outputKey == 'findings_count' ||
        outputKey == 'gating_findings_count';
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
      const canonicalDocumentLocationKeys = {
        'product',
        'backlog',
        'roadmap',
        'prd',
        'plan',
        'spec',
        'state',
        'readme',
        'agent_rules',
        'architecture',
        'guide',
      };
      sanitized['document_locations'] = {
        for (final entry in rawDocumentLocations.entries)
          if (canonicalDocumentLocationKeys.contains(entry.key))
            entry.key: _sanitizeProjectDocumentLocation(
              projectRoot,
              entry.key,
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

    final rawStateProtocol = _asStringKeyedMap(projectIndex['state_protocol']);
    if (rawStateProtocol != null) {
      const canonicalStateProtocolKeys = {'type', 'state_file', 'format'};
      final stateProtocol = <String, Object?>{};
      for (final entry in rawStateProtocol.entries) {
        if (!canonicalStateProtocolKeys.contains(entry.key)) continue;
        // type/format are agent-supplied scalars echoed back as context.
        // Coerce to a trimmed String (or drop) so downstream prompts can't be
        // surprised by Maps/Lists/null leaking through; we don't restrict to
        // a known enum because the schema is intentionally open.
        final value = entry.key == 'state_file'
            ? _sanitizeProjectRelativePath(
                projectRoot,
                entry.value,
                stepId: stepId,
                outputKey: outputKey,
                fieldPath: 'state_protocol.state_file',
              )
            : _coerceStateProtocolScalar(
                entry.value,
                stepId: stepId,
                outputKey: outputKey,
                fieldPath: 'state_protocol.${entry.key}',
              );
        if (value != null) stateProtocol[entry.key] = value;
      }
      sanitized['state_protocol'] = stateProtocol;
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

  Object? _sanitizeProjectDocumentLocation(
    String projectRoot,
    String key,
    Object? value, {
    required String stepId,
    required String outputKey,
    required String fieldPath,
  }) {
    final sanitized = _sanitizeProjectRelativePath(
      projectRoot,
      value,
      stepId: stepId,
      outputKey: outputKey,
      fieldPath: fieldPath,
    );
    if (key != 'agent_rules') return sanitized;
    return _repairAgentRulesLocation(projectRoot, sanitized);
  }

  Object? _repairAgentRulesLocation(String projectRoot, Object? sanitized) {
    if (sanitized is String && sanitized.trim().isNotEmpty) {
      final resolved = p.normalize(p.join(projectRoot, sanitized.trim()));
      if (File(resolved).existsSync()) return sanitized;
    }
    for (final candidate in const ['AGENTS.md', 'CLAUDE.md']) {
      if (File(p.join(projectRoot, candidate)).existsSync()) return candidate;
    }
    if (sanitized is String && sanitized.trim().isNotEmpty) {
      _log.warning(
        'agent_rules path does not exist and no AGENTS.md/CLAUDE.md found in $projectRoot; '
        'returning unverified path: $sanitized',
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

  String? _coerceStateProtocolScalar(
    Object? value, {
    required String stepId,
    required String outputKey,
    required String fieldPath,
  }) {
    if (value is String) {
      final trimmed = value.trim();
      return trimmed.isEmpty ? null : trimmed;
    }
    if (value == null) return null;
    _log.warning(
      'Dropping non-string $fieldPath ("${value.runtimeType}") from "$outputKey" '
      'in step "$stepId"; only string scalars are accepted',
    );
    return null;
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
