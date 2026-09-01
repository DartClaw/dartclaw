import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart' show MessageService, Task, WorkflowTaskService;

import 'workflow_definition.dart' show OutputConfig, OutputMode, WorkflowStep;

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import 'diff_artifact_reader.dart';
import 'filesystem_output_resolver.dart' as fs;
import 'output_normalization.dart' as on_;
import 'output_resolver.dart';
import 'path_safety_policy.dart' show validateArgumentSafePath;
import 'schema_presets.dart' show outputResolverFor;
import 'schema_validator.dart';
import 'workflow_output_contract.dart';
import 'workflow_run_paths.dart' show workflowStepArtifactsDir;
import 'workflow_task_config.dart';

typedef StructuredOutputFallbackRecorder = void Function(
  String taskId, {
  required String stepId,
  required String outputKey,
  required String failureReason,
  String? providerSubtype,
});

/// Extracts context outputs for a completed task from the sources the host
/// controls. Assistant prose is never one of them.
///
/// A declared output resolves from exactly one of:
/// 1. `OutputConfig.source` (`worktree.*`) – read from persisted task metadata.
/// 2. The validated execution envelope's `outputs` – every model-derived claim.
/// 3. The host-owned step artifacts dir, for a `format: path` output with no
///    usable claim (see `filesystem_output_resolver.dart`).
/// 4. The `diff.json` artifact, for the canonical `diff_summary` key.
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

  new({
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
    final envelopeOutputs = await _extractEnvelopeOutputs(task);
    // A `null` envelope path value means "no claim" (the schema declares path
    // keys required+nullable so no-claim survives strict mode); it must NOT
    // short-circuit the host-owned step-artifacts capture, so drop
    // null-valued entries from the claim view.
    final claimPayload = <String, dynamic>{
      for (final entry in envelopeOutputs.entries)
        if (entry.value != null) entry.key: entry.value,
    };

    // 1. For each declared output key not yet extracted.
    for (final outputKey in outputKeys) {
      if (outputs.containsKey(outputKey)) continue;

      // Determine output config for this key.
      final config = configs?[outputKey];

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
            claimedValue: claimKey == null ? null : claimPayload[claimKey],
            hasClaim: claimKey != null,
            claimPayload: claimPayload,
          );
          _assertArgumentSafeFileSystemOutput(resolvedFsOutput, outputKey);
          outputs[outputKey] = resolvedFsOutput;
          continue;
        case InlineOutput():
          if (envelopeOutputs.containsKey(outputKey)) {
            outputs[outputKey] = on_.normalizePayloadValue(
              envelopeOutputs[outputKey],
              config,
              _schemaValidator,
              step.id,
              outputKey,
            );
            continue;
          }
      }

      final derivedValue = on_.deriveFromStructuredOutputs(outputs, outputKey);
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

      // Try diff.json for the canonical diff summary key.
      if (outputKey == 'diff_summary') {
        final diffContent = await readDiffArtifactSummary(_taskService, _dataDir, task);
        if (diffContent != null) {
          outputs[outputKey] = diffContent;
          continue;
        }
      }

      // No value: leave the key absent rather than inventing one. An empty
      // string here is a host-fabricated stand-in for something the step never
      // produced, and downstream it is indistinguishable from a real value —
      // a stalled review's `gating_findings_count` read as a clean 0 and let a
      // gate pass (live, 2026-08-28). The executor records which declared keys
      // a terminally failed step left unproduced, and the gate evaluator
      // refuses to coerce those.
      _log.warning(
        'No content extracted for context key "$outputKey" '
        'from step "${step.id}" (task ${task.id})',
      );
    }

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

  Future<Object?> _resolveFileSystemOutput(
    FileSystemOutput resolver, {
    required String outputKey,
    required WorkflowStep step,
    required Task task,
    required Object? claimedValue,
    required bool hasClaim,
    required Map<String, dynamic> claimPayload,
  }) async {
    final claimedPaths = _claimedPaths(claimedValue);
    final claimsExplicitlyEmpty = hasClaim && _isExplicitlyEmptyPathClaim(claimedValue);
    final stepArtifactsDir = await _stepArtifactsDirFor(step, task);
    return fs.resolveFileSystemOutput(
      resolver,
      outputKey: outputKey,
      step: step,
      task: task,
      claimedPaths: claimedPaths,
      existingClaims: _existingSafeFileClaims(claimedPaths, task, stepArtifactsDir),
      stepArtifactsDir: stepArtifactsDir,
      claimPayload: claimPayload,
      claimsExplicitlyEmpty: claimsExplicitlyEmpty,
    );
  }

  /// The host-owned artifacts dir for this step occurrence, empty when the task
  /// carries no workflow run.
  Future<String> _stepArtifactsDirFor(WorkflowStep step, Task task) async {
    final runId = task.workflowRunId?.trim();
    if (runId == null || runId.isEmpty) return '';
    return workflowStepArtifactsDir(
      dataDir: _dataDir,
      runId: runId,
      stepId: step.id,
      mapIterationIndex: await _mapIterationIndexFor(task),
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
  // values are resolved under an engine-owned root (step artifacts dir,
  // runtime-artifacts — trusted, may contain spaces) and list outputs are
  // host-collected, so both are exempt. Restores the check the removed
  // discovery-spec validator ran on `spec_path`.
  void _assertArgumentSafeFileSystemOutput(Object? value, String outputKey) {
    if (value is! String || value.isEmpty || p.isAbsolute(value)) return;
    validateArgumentSafePath(value, fieldName: outputKey, rawPath: value);
  }

  /// Distinguishes an explicit "no path" claim (agent emitted `""` or JSON
  /// `null` for a payload key) from "no claim at all" (the key was absent from
  /// the payload). The caller is responsible for checking `Map.containsKey`
  /// first – this helper assumes the key was present and only inspects the
  /// value shape. Explicit-empty claims must NOT trigger the step-artifacts
  /// capture in [fs.resolveFileSystemOutput]. The literal string `"null"` is an
  /// ordinary path claim: it resolves or fails on containment and existence
  /// like any other.
  bool _isExplicitlyEmptyPathClaim(Object? payloadValue) {
    if (payloadValue == null) return true;
    if (payloadValue is String) return payloadValue.trim().isEmpty;
    if (payloadValue is Iterable) {
      if (payloadValue.isEmpty) return true;
      return payloadValue.every((value) => value == null || value.toString().trim().isEmpty);
    }
    return false;
  }

  /// Resolves which payload key carries the inline filesystem claim for
  /// [outputKey], accepting a bare-suffix alias for a namespaced output.
  ///
  /// Prefers the exact key; when the output is namespaced as `<stepId>.<suffix>`
  /// and the exact key is absent, falls back to the bare `<suffix>` the skill's
  /// output contract emits. Returns null when neither form is present.
  String? _fileSystemClaimKey(String outputKey, WorkflowStep step, Map<String, dynamic> payload) {
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
      return value.isEmpty ? const <String>[] : <String>[p.normalize(value)];
    }
    if (payloadValue is Iterable) {
      return payloadValue
          .map((value) => value.toString().trim())
          .where((value) => value.isNotEmpty)
          .map(p.normalize)
          .toList();
    }
    return const <String>[];
  }

  Map<String, String> _existingSafeFileClaims(List<String> values, Task task, String stepArtifactsDir) {
    return fs.existingSafeFileClaims(
      values,
      roots: fs.fileSystemOutputRoots(
        stepArtifactsDir: stepArtifactsDir,
        worktreeJson: task.worktreeJson,
        workflowRunId: task.workflowRunId,
        projectId: task.projectId,
        dataDir: _dataDir,
      ),
      taskId: task.id,
    );
  }

  /// The declared model-derived outputs the persisted execution envelope
  /// carries, unwrapped from its `outputs` object. Engine-owned `step_outcome`
  /// stays out of the map.
  ///
  /// Empty when the task has no persisted structured payload — the
  /// missing-envelope path the finalizer's own re-ask already charged. Throws
  /// [StateError] for a payload written before the envelope existed: those
  /// outputs travelled a channel this release no longer reads, so a resumed run
  /// must fail loudly rather than resolve a partial context.
  Future<Map<String, dynamic>> _extractEnvelopeOutputs(Task task) async {
    final repo = _workflowStepExecutionRepository;
    if (repo == null) return const <String, dynamic>{};
    final payload = await WorkflowTaskConfig.readStructuredOutputPayload(task, repo);
    if (payload == null) return const <String, dynamic>{};
    if (!isExecutionEnvelope(payload)) {
      throw StateError(
        'Task ${task.id} carries a pre-0.25 structured output payload. DartClaw 0.25 removed the legacy '
        'inline output channel, so this run cannot be resumed — re-run the workflow under 0.25.',
      );
    }
    final outputs = payload[executionEnvelopeOutputsKey];
    return outputs is Map ? outputs.map((key, value) => MapEntry(key.toString(), value)) : const <String, dynamic>{};
  }

  /// Resolves the semantic step outcome for [task].
  ///
  /// Reads the finalizer envelope's `step_outcome`. Only an [emitsOwnOutcome]
  /// step — which declares no envelope — resolves from the inline
  /// `<step-outcome>` tag, its designed channel. Returns null when neither
  /// source supplies a valid outcome, leaving lifecycle-status fallback (and
  /// its counter) to the caller.
  Future<StepOutcomePayload?> extractStepOutcome(Task task, {required bool emitsOwnOutcome}) async {
    final envelopeOutcome = await _extractEnvelopeStepOutcome(task);
    if (envelopeOutcome != null) return envelopeOutcome;
    if (!emitsOwnOutcome) return null;

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
