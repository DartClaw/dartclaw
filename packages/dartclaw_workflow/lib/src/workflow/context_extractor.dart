import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart'
    show MessageService, Task, WorkflowStepExecutionRepository, WorkflowTaskService;
import 'workflow_definition.dart' show OutputConfig, OutputFormat, OutputMode, WorkflowStep;

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import 'context_output_defaults.dart';
import 'diff_artifact_reader.dart';
import 'filesystem_output_resolver.dart' as fs;
import 'json_extraction.dart';
import 'output_normalization.dart' as on_;
import 'output_resolver.dart';
import 'path_safety_policy.dart' show validateArgumentSafePath;
import 'review_artifact_policy.dart' as rap;
import 'schema_presets.dart' show outputResolverFor;
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
/// Four extraction strategies (in priority order for each output key):
/// 1. Explicit `setValue:` literal on the step's [OutputConfig] – short-circuits
///    everything below; writes the configured literal (including `null`)
///    verbatim to context. See `WorkflowStep.outputs[key].setValue`.
/// 2. Workflow context tag: `<workflow-context>{...}</workflow-context>` in the last assistant message.
/// 3. First `.md` artifact file content.
/// 4. `diff.json` artifact when explicitly requested by the `diff_summary` output key.
///
/// Automatic step metadata keys (`<stepId>.status`, `<stepId>.tokenCount`)
/// are set by [WorkflowExecutor] – not by this class.
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

  /// Extracts context outputs for [step] from the completed [task].
  ///
  /// [effectiveOutputs] overrides `step.outputs` when supplied.
  Future<Map<String, dynamic>> extract(
    WorkflowStep step,
    Task task, {
    Map<String, OutputConfig>? effectiveOutputs,
  }) async {
    final outputs = <String, dynamic>{};
    final configs = effectiveOutputs ?? step.outputs;
    // Drive iteration off the canonical write-set: `outputs:` map keys are the
    // declaration of which context keys this step writes.
    final outputKeys = configs?.keys.toList(growable: false) ?? step.outputKeys;
    final workflowContextPayload = await _extractWorkflowContextPayload(task);
    final (outputs: structuredOutputPayload, isEnvelope: structuredIsEnvelope) = await _extractStructuredOutputPayload(
      task,
    );
    // Filesystem path/artifact claims arrive in the finalizer envelope's
    // `outputs`; legacy transcripts still carry them inline. Prefer the
    // structured (envelope) claim, falling back to the inline block. A `null`
    // envelope path value means "no claim" (the schema declares path keys
    // required+nullable so no-claim survives strict mode); it must NOT mask an
    // inline claim or short-circuit the glob / reviews-dir backstop, so drop
    // null-valued structured entries from the claim view.
    final structuredClaims = <String, dynamic>{
      for (final entry in structuredOutputPayload.entries)
        if (entry.value != null) entry.key: entry.value,
    };
    final claimPayload = structuredClaims.isEmpty
        ? workflowContextPayload
        : <String, dynamic>{...?workflowContextPayload, ...structuredClaims};

    // 1. For each declared output key not yet extracted.
    for (final outputKey in outputKeys) {
      if (outputs.containsKey(outputKey)) continue;

      // Determine output config for this key.
      final config = configs?[outputKey];

      // setValue: explicit literal short-circuit – write the configured value
      // (including `null`) directly to context and skip all extraction paths.
      // Fires only on step success; the extract() entry-point itself is only
      // reached on success today, so failure/skip cases need no extra guard.
      if (config != null && config.hasSetValue) {
        outputs[outputKey] = config.setValue;
        continue;
      }

      // source: worktree.* – read directly from persisted task.worktreeJson.
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
        // Unknown source – fall through to normal extraction with a warning.
        _log.warning(
          'Unknown output source "${config.source}" for "$outputKey" in step "${step.id}"; '
          'falling back to normal extraction',
        );
      }

      final resolver = outputResolverFor(outputKey, config);
      final derivedReviewCount = on_.deriveReviewCountFromStructuredOutputs(
        step,
        outputs,
        outputKey,
        workflowContextPayload: workflowContextPayload,
        structuredOutputPayload: structuredOutputPayload,
      );
      if (derivedReviewCount != null) {
        outputs[outputKey] = derivedReviewCount;
        continue;
      }
      switch (resolver) {
        case FileSystemOutput():
          // A step may declare a namespaced output key
          // (`<stepId>.review_report_path`, required when parallel steps would
          // collide on a shared context key) while the invoking skill emits the
          // bare canonical key (`review_report_path`). Honor the agent's claim
          // under either form, mirroring the dual-key acceptance already used
          // for review counts (see findingsCountKeys). Each step extracts from
          // its own session payload, so the bare alias cannot cross-contaminate
          // a sibling step.
          final claimKey = _fileSystemClaimKey(outputKey, step, claimPayload);
          final resolvedFsOutput = await _resolveFileSystemOutput(
            resolver,
            outputKey: outputKey,
            step: step,
            task: task,
            inlinePayload: claimKey == null ? null : claimPayload?[claimKey],
            hasInlineClaim: claimKey != null,
            workflowContextPayload: claimPayload,
          );
          _assertArgumentSafeFileSystemOutput(resolvedFsOutput, outputKey);
          outputs[outputKey] = resolvedFsOutput;
          continue;
        case InlineOutput():
          if (_extractInlineOutput(
            outputs,
            outputKey,
            config,
            step,
            workflowContextPayload: workflowContextPayload,
            structuredOutputPayload: structuredOutputPayload,
            structuredIsEnvelope: structuredIsEnvelope,
          )) {
            continue;
          }
      }

      final derivedValue = on_.deriveFromStructuredOutputs(
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
        final rawContent = await _extractRawContent(task);
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
              on_.validateSchema(parsed, config, _schemaValidator, step.id, outputKey);
              outputs[outputKey] = parsed; // Store as Map/List, not String.
            } on FormatException catch (e) {
              _log.severe('JSON extraction failed for "$outputKey" from step "${step.id}": $e');
              rethrow;
            }
          case OutputFormat.lines:
            outputs[outputKey] = extractLines(rawContent);
          case OutputFormat.text:
          case OutputFormat.path:
            break; // Unreachable – guarded above.
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

      // Try diff.json for the canonical diff summary key.
      if (outputKey == 'diff_summary') {
        final diffContent = await readDiffArtifactSummary(_taskService, _dataDir, task);
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

  /// Resolves an [InlineOutput] key from the structured
  /// payload and the legacy inline block, writing into [outputs] and returning
  /// whether a value was found.
  ///
  /// When the structured payload is a finalizer envelope it is primary
  /// (envelope-first); for legacy flat payloads the historical inline-first
  /// ordering is preserved so old transcripts still resolve.
  bool _extractInlineOutput(
    Map<String, dynamic> outputs,
    String outputKey,
    OutputConfig? config,
    WorkflowStep step, {
    required Map<String, dynamic>? workflowContextPayload,
    required Map<String, dynamic> structuredOutputPayload,
    required bool structuredIsEnvelope,
  }) {
    Object? normalize(Object? value) => on_.normalizePayloadValue(value, config, _schemaValidator, step.id, outputKey);
    final inlineHasKey = workflowContextPayload != null && workflowContextPayload.containsKey(outputKey);
    final structuredHasKey = structuredOutputPayload.containsKey(outputKey);
    if (structuredIsEnvelope && structuredHasKey) {
      outputs[outputKey] = normalize(structuredOutputPayload[outputKey]);
      return true;
    }
    if (inlineHasKey) {
      outputs[outputKey] = normalize(workflowContextPayload[outputKey]);
      return true;
    }
    if (structuredHasKey) {
      outputs[outputKey] = normalize(structuredOutputPayload[outputKey]);
      return true;
    }
    return false;
  }

  Future<Object?> _resolveFileSystemOutput(
    FileSystemOutput resolver, {
    required String outputKey,
    required WorkflowStep step,
    required Task task,
    required Object? inlinePayload,
    required bool hasInlineClaim,
    required Map<String, dynamic>? workflowContextPayload,
  }) async {
    // Review artifacts are captured deterministically from the host-owned step
    // artifacts dir — model-claimed paths and the worktree diff never apply.
    if (rap.isReviewArtifactPathOutput(outputKey, step, resolver, workflowContextPayload)) {
      return rap.resolveReviewArtifactFromStepDir(
        outputKey: outputKey,
        step: step,
        task: task,
        resolver: resolver,
        workflowContextPayload: workflowContextPayload,
        dataDir: _dataDir,
        mapIterationIndex: await _mapIterationIndexFor(task),
      );
    }
    final claimedPaths = _claimedPaths(inlinePayload);
    final claimsExplicitlyEmpty = hasInlineClaim && _isExplicitlyEmptyPathClaim(inlinePayload);
    final git = _workflowGitPort;
    final worktreePath = (task.worktreeJson?['path'] as String?)?.trim() ?? '';
    final existingClaims = _existingSafeFileClaims(claimedPaths, task);
    List<String> changedMatches = const [];
    if (git != null && worktreePath.isNotEmpty) {
      final changedPaths = await git.diffNameOnly(worktreePath);
      // `pathPattern` selects which diff entries are discovery candidates; the
      // containment + existence boundary is applied in the helper.
      changedMatches = _safeChangedFileSystemMatches(changedPaths.map(p.normalize).where(resolver.matches), task);
    }
    return fs.resolveFileSystemOutput(
      claimsExplicitlyEmpty: claimsExplicitlyEmpty,
      resolver,
      outputKey: outputKey,
      task: task,
      claimedPaths: claimedPaths,
      changedMatches: changedMatches,
      existingClaims: existingClaims,
      git: git,
    );
  }

  /// The map-iteration index for a map-dispatched task, read from the
  /// hydrated [WorkflowStepExecution] row (falling back to the repository),
  /// so parallel iterations resolve their own disjoint step artifacts dirs.
  Future<int?> _mapIterationIndexFor(Task task) async {
    final hydrated = task.workflowStepExecution;
    if (hydrated != null) return hydrated.mapIterationIndex;
    final repo = _workflowStepExecutionRepository;
    if (repo == null) return null;
    return (await repo.getByTaskId(task.id))?.mapIterationIndex;
  }

  // Single-value relative `format: path` outputs are interpolated straight into
  // skill command arguments (e.g. `--auto {{context.spec_path}}`), so they must
  // pass the argument-safety axis (control chars, parent traversal, flag-shaped
  // segments) of the generic `format: path` trust boundary (ADR-041). Absolute
  // values are engine-produced runtime-artifacts claims (trusted, may contain
  // spaces) and list outputs are diff-derived, so both are exempt. Restores the
  // check the removed discovery-spec validator ran on `spec_path`.
  void _assertArgumentSafeFileSystemOutput(Object? value, String outputKey) {
    if (value is! String || value.isEmpty || p.isAbsolute(value)) return;
    validateArgumentSafePath(value, fieldName: outputKey, rawPath: value);
  }

  /// Distinguishes an explicit "no path" claim (agent emitted `""`, `"null"`,
  /// or JSON `null` for a payload key) from "no claim at all" (the key was
  /// absent from the payload). The caller is responsible for checking
  /// `Map.containsKey` first – this helper assumes the key was present and
  /// only inspects the value shape. Explicit-empty claims must NOT trigger
  /// changed-file fallback in [fs.resolveFileSystemOutput].
  bool _isExplicitlyEmptyPathClaim(Object? payloadValue) {
    if (payloadValue == null) return true;
    if (payloadValue is String) {
      final value = payloadValue.trim();
      return value.isEmpty || value == 'null';
    }
    if (payloadValue is Iterable) {
      if (payloadValue.isEmpty) return true;
      return payloadValue.every((value) {
        if (value == null) return true;
        final v = value.toString().trim();
        return v.isEmpty || v == 'null';
      });
    }
    return false;
  }

  /// Resolves which payload key carries the inline filesystem claim for
  /// [outputKey], accepting a bare-suffix alias for a namespaced output.
  ///
  /// Prefers the exact key; when the output is namespaced as `<stepId>.<suffix>`
  /// and the exact key is absent, falls back to the bare `<suffix>` the skill's
  /// output contract emits. Returns null when neither form is present.
  String? _fileSystemClaimKey(String outputKey, WorkflowStep step, Map<String, dynamic>? payload) {
    if (payload == null) return null;
    if (payload.containsKey(outputKey)) return outputKey;
    final prefix = '${step.id}.';
    if (outputKey.startsWith(prefix)) {
      final bare = outputKey.substring(prefix.length);
      if (bare.isNotEmpty && payload.containsKey(bare)) return bare;
    }
    return null;
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

  List<String> _safeChangedFileSystemMatches(Iterable<String> values, Task task) {
    return fs.safeChangedFileSystemMatches(
      values,
      worktreeRoots: fs.worktreeFileSystemOutputRoots(task.worktreeJson),
      taskId: task.id,
      projectId: task.projectId,
      workflowRunId: task.workflowRunId,
      dataDir: _dataDir,
    );
  }

  Map<String, String> _existingSafeFileClaims(List<String> values, Task task) {
    return fs.existingSafeFileClaims(
      values,
      roots: fs.fileSystemOutputRoots(
        worktreeJson: task.worktreeJson,
        workflowRunId: task.workflowRunId,
        projectId: task.projectId,
        dataDir: _dataDir,
      ),
      taskId: task.id,
      projectId: task.projectId,
      workflowRunId: task.workflowRunId,
      dataDir: _dataDir,
    );
  }

  /// The primary structured payload of declared domain outputs, and
  /// whether it came from a finalizer envelope.
  ///
  /// For a finalizer envelope (marker-discriminated), returns the unwrapped
  /// `outputs` object so downstream extraction reads declared model-derived
  /// outputs directly; engine-owned `step_outcome` stays out of the output
  /// map. Legacy flat payloads (pre-envelope rows, opt-out steps) pass through
  /// unchanged as the compatibility fallback. [isEnvelope] lets extraction make
  /// the envelope the primary source (envelope-first) while keeping the
  /// historical inline-first ordering for legacy flat payloads.
  Future<({Map<String, dynamic> outputs, bool isEnvelope})> _extractStructuredOutputPayload(Task task) async {
    final repo = _workflowStepExecutionRepository;
    if (repo == null) return (outputs: const <String, dynamic>{}, isEnvelope: false);
    final payload = await WorkflowTaskConfig.readStructuredOutputPayload(task, repo);
    if (payload == null) return (outputs: const <String, dynamic>{}, isEnvelope: false);
    if (isExecutionEnvelope(payload)) {
      final outputs = payload[executionEnvelopeOutputsKey];
      return (
        outputs: outputs is Map
            ? outputs.map((key, value) => MapEntry(key.toString(), value))
            : const <String, dynamic>{},
        isEnvelope: true,
      );
    }
    return (outputs: payload, isEnvelope: false);
  }

  /// Extracts raw text content for format-aware processing.
  Future<String?> _extractRawContent(Task task) async {
    if (task.sessionId != null) {
      final messages = await _messageService.getMessagesTail(task.sessionId!, count: 5);
      final lastAssistant = messages.where((m) => m.role == 'assistant').lastOrNull;
      if (lastAssistant != null) return lastAssistant.content;
    }

    return _extractFirstMdArtifact(task);
  }

  /// Parses the `<workflow-context>` payload from the most recent assistant
  /// message that contains one.
  ///
  /// Workflow one-shot execution may append a final bare-JSON extraction turn
  /// after an earlier assistant message already emitted the primary
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

  Future<String?> _extractFirstMdArtifact(Task task) async {
    final artifacts = await _taskService.listArtifacts(task.id);
    for (final artifact in artifacts) {
      if (artifact.path.endsWith('.md')) {
        return _readArtifactContent(task.id, artifact.path);
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

  /// Resolves the semantic step outcome for [task].
  ///
  /// Reads the finalizer envelope's `step_outcome` first (the standard path);
  /// falls back to parsing the last well-formed `<step-outcome>` tag from the
  /// task's assistant messages for legacy transcripts and `emitsOwnOutcome`
  /// steps. Returns null when neither source supplies a valid outcome, leaving
  /// lifecycle-status fallback (and its counter) to the caller.
  Future<StepOutcomePayload?> extractStepOutcome(Task task) async {
    final envelopeOutcome = await _extractEnvelopeStepOutcome(task);
    if (envelopeOutcome != null) return envelopeOutcome;

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

  /// Reads `step_outcome` from the persisted finalizer envelope, when present
  /// and carrying a valid protocol outcome.
  Future<StepOutcomePayload?> _extractEnvelopeStepOutcome(Task task) async {
    final repo = _workflowStepExecutionRepository;
    if (repo == null) return null;
    final payload = await WorkflowTaskConfig.readStructuredOutputPayload(task, repo);
    if (!isExecutionEnvelope(payload)) return null;
    final stepOutcome = payload![executionEnvelopeStepOutcomeKey];
    if (stepOutcome is! Map) return null;
    final outcome = stepOutcome['outcome']?.toString();
    if (outcome != 'succeeded' && outcome != 'failed' && outcome != 'needsInput') return null;
    return StepOutcomePayload(outcome: outcome!, reason: stepOutcome['reason']?.toString() ?? '');
  }
}
