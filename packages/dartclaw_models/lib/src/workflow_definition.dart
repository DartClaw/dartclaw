const _workflowDefinitionFieldUnset = Object();

/// Output format for context extraction.
enum OutputFormat {
  /// Raw string extraction (default, current behavior).
  text,

  /// Multi-strategy JSON extraction with fallback chain.
  json,

  /// Split output into list of trimmed non-empty lines.
  lines,

  /// Workspace-relative file path produced on disk by an artifact-producing
  /// step (`dartclaw-prd`, `dartclaw-plan`, `dartclaw-spec`). Treated as text
  /// at runtime; the distinct format surfaces intent in the workflow contract
  /// and lets the engine recognise artifact-producing outputs.
  path;

  static OutputFormat? fromYaml(String value) => switch (value) {
    'text' => text,
    'json' => json,
    'lines' => lines,
    'path' => path,
    _ => null,
  };
}

/// Output extraction mode for JSON workflow outputs.
enum OutputMode {
  /// Prompt-guided extraction using the existing heuristic parser.
  prompt,

  /// Native provider-structured output via a dedicated extraction turn.
  structured;

  static OutputMode? fromYaml(String value) => switch (value) {
    'prompt' => prompt,
    'structured' => structured,
    _ => null,
  };
}

/// Configuration for a single output key's extraction and validation.
class OutputConfig {
  /// Output format determining extraction strategy.
  final OutputFormat format;

  /// Schema for validation and prompt augmentation.
  ///
  /// Can be:
  /// - A [String] preset name (e.g. 'verdict', 'story-plan')
  /// - A [Map<String, dynamic>] inline JSON Schema
  /// - null (no schema constraint)
  final Object? schema;

  /// Explicit output source override.
  ///
  /// When set, extraction is driven by this source rather than by agent-authored
  /// context text. Supported values:
  /// - `"worktree.branch"` — reads the coding-task branch from persisted worktree metadata
  /// - `"worktree.path"` — reads the worktree filesystem path from persisted worktree metadata
  final String? source;

  /// Extraction mode for JSON outputs.
  final OutputMode outputMode;

  /// Optional human-readable description of the semantic meaning of this output.
  ///
  /// Included verbatim in the prompt augmentation sections (Workflow Output Contract
  /// and Required Output Format) so the agent understands *what* a field represents,
  /// not just its name and JSON shape. Keep to one concise sentence.
  final String? description;

  const OutputConfig({
    this.format = OutputFormat.text,
    this.schema,
    this.source,
    this.outputMode = OutputMode.prompt,
    this.description,
  });

  /// Whether this config has a schema (preset name or inline).
  bool get hasSchema => schema != null;

  /// Returns the schema preset name if [schema] is a String, else null.
  String? get presetName => schema is String ? schema as String : null;

  /// Returns the inline schema if [schema] is a Map, else null.
  Map<String, dynamic>? get inlineSchema => schema is Map<String, dynamic> ? schema as Map<String, dynamic> : null;

  Map<String, dynamic> toJson() => {
    'format': format.name,
    if (schema != null) 'schema': schema,
    if (source != null) 'source': source,
    if (outputMode != OutputMode.prompt) 'outputMode': outputMode.name,
    if (description != null) 'description': description,
  };

  factory OutputConfig.fromJson(Map<String, dynamic> json) => OutputConfig(
    format: json['format'] != null ? OutputFormat.values.byName(json['format'] as String) : OutputFormat.text,
    schema: json['schema'],
    source: json['source'] as String?,
    outputMode: json['outputMode'] != null ? OutputMode.values.byName(json['outputMode'] as String) : OutputMode.prompt,
    description: json['description'] as String?,
  );
}

/// Review mode for workflow steps.
enum StepReviewMode {
  /// Step always enters review status.
  always,

  /// Workflow-authored default. The generic meaning is "review coding work",
  /// but the workflow executor now maps omitted/codingOnly steps to
  /// auto-accept unless the YAML explicitly opts into `always`.
  codingOnly,

  /// Step auto-accepts on completion.
  never;

  /// Parses a YAML review mode string, supporting hyphenated form.
  static StepReviewMode? fromYaml(String value) => switch (value) {
    'always' => always,
    'coding-only' => codingOnly,
    'never' => never,
    _ => null,
  };
}

/// Policy applied when a workflow step reports an explicit failed outcome.
enum OnFailurePolicy {
  fail('fail'),
  continueWorkflow('continue'),
  retry('retry'),
  pause('pause');

  final String yamlName;

  const OnFailurePolicy(this.yamlName);

  static OnFailurePolicy? fromYaml(String value) => switch (value) {
    'fail' => fail,
    'continue' => continueWorkflow,
    'retry' => retry,
    'pause' => pause,
    _ => null,
  };
}

/// Extraction strategy for context output values.
enum ExtractionType {
  /// Extract using a regular expression.
  regex,

  /// Extract using a JSON path expression.
  jsonpath,

  /// Extract from a named artifact.
  artifact,
}

/// Configuration for custom context output extraction.
class ExtractionConfig {
  final ExtractionType type;
  final String pattern;

  const ExtractionConfig({required this.type, required this.pattern});

  Map<String, dynamic> toJson() => {'type': type.name, 'pattern': pattern};

  factory ExtractionConfig.fromJson(Map<String, dynamic> json) =>
      ExtractionConfig(type: ExtractionType.values.byName(json['type'] as String), pattern: json['pattern'] as String);
}

/// A variable declaration in a workflow definition.
class WorkflowVariable {
  /// Whether this variable must be provided at workflow start.
  final bool required;

  /// Human-readable description for UI display.
  final String description;

  /// Optional default value used when not provided.
  final String? defaultValue;

  const WorkflowVariable({this.required = true, this.description = '', this.defaultValue});

  Map<String, dynamic> toJson() => {
    'required': required,
    'description': description,
    if (defaultValue != null) 'defaultValue': defaultValue,
  };

  factory WorkflowVariable.fromJson(Map<String, dynamic> json) => WorkflowVariable(
    required: (json['required'] as bool?) ?? true,
    description: (json['description'] as String?) ?? '',
    defaultValue: json['defaultValue'] as String?,
  );
}

/// Pattern-based step config default entry.
///
/// Each entry has a glob [match] pattern and optional config overrides.
/// Applied in order — first match wins. Per-step explicit config takes precedence.
class StepConfigDefault {
  /// Glob pattern matched against step IDs (e.g. "review*", "*").
  final String match;

  /// Optional provider override.
  final String? provider;

  /// Optional model override.
  final String? model;

  /// Optional reasoning effort level (e.g. "low", "medium", "high").
  final String? effort;

  /// Optional per-step token budget.
  final int? maxTokens;

  /// Optional per-step cost ceiling in USD.
  final double? maxCostUsd;

  /// Optional per-step retry limit.
  final int? maxRetries;

  /// Optional per-step tool allowlist.
  final List<String>? allowedTools;

  const StepConfigDefault({
    required this.match,
    this.provider,
    this.model,
    this.effort,
    this.maxTokens,
    this.maxCostUsd,
    this.maxRetries,
    this.allowedTools,
  });

  Map<String, dynamic> toJson() => {
    'match': match,
    if (provider != null) 'provider': provider,
    if (model != null) 'model': model,
    if (effort != null) 'effort': effort,
    if (maxTokens != null) 'maxTokens': maxTokens,
    if (maxCostUsd != null) 'maxCostUsd': maxCostUsd,
    if (maxRetries != null) 'maxRetries': maxRetries,
    if (allowedTools != null) 'allowedTools': allowedTools!.toList(),
  };

  factory StepConfigDefault.fromJson(Map<String, dynamic> json) => StepConfigDefault(
    match: json['match'] as String,
    provider: json['provider'] as String?,
    model: json['model'] as String?,
    effort: json['effort'] as String?,
    maxTokens: json['maxTokens'] as int?,
    maxCostUsd: (json['maxCostUsd'] as num?)?.toDouble(),
    maxRetries: json['maxRetries'] as int?,
    allowedTools: (json['allowedTools'] as List?)?.cast<String>(),
  );
}

/// A loop construct over a set of workflow steps.
class WorkflowLoop {
  /// Unique identifier for this loop.
  final String id;

  /// Ordered list of step IDs to iterate.
  final List<String> steps;

  /// Maximum number of iterations (circuit breaker, required).
  final int maxIterations;

  /// Optional condition expression for entering the loop body.
  final String? entryGate;

  /// Condition expression for early termination.
  final String exitGate;

  /// Optional step ID to execute after loop terminates (regardless of exit reason).
  ///
  /// Must reference a step in the workflow's [WorkflowDefinition.steps] that is
  /// NOT in this loop's [steps] list. Named `finally_` in Dart because `finally`
  /// is a reserved keyword; serialized as `finally` in JSON/YAML.
  final String? finally_;

  const WorkflowLoop({
    required this.id,
    required this.steps,
    required this.maxIterations,
    this.entryGate,
    required this.exitGate,
    this.finally_,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'steps': steps.toList(),
    'maxIterations': maxIterations,
    if (entryGate != null) 'entryGate': entryGate,
    'exitGate': exitGate,
    if (finally_ != null) 'finally': finally_,
  };

  factory WorkflowLoop.fromJson(Map<String, dynamic> json) => WorkflowLoop(
    id: json['id'] as String,
    steps: (json['steps'] as List).cast<String>(),
    maxIterations: json['maxIterations'] as int,
    entryGate: json['entryGate'] as String?,
    exitGate: json['exitGate'] as String,
    finally_: json['finally'] as String?,
  );
}

/// A normalized execution node within a workflow definition.
sealed class WorkflowNode {
  const WorkflowNode();

  /// Discriminator used for serialization.
  String get type;

  /// Step IDs referenced by this node in execution order.
  List<String> get stepIds;

  Map<String, dynamic> toJson();

  factory WorkflowNode.fromJson(Map<String, dynamic> json) {
    final type = json['type'] as String?;
    return switch (type) {
      'action' => ActionNode(stepId: json['stepId'] as String),
      'map' => MapNode(stepId: json['stepId'] as String),
      'parallelGroup' => ParallelGroupNode(stepIds: (json['stepIds'] as List).cast<String>()),
      'loop' => LoopNode(
        loopId: json['loopId'] as String,
        stepIds: (json['stepIds'] as List).cast<String>(),
        finallyStepId: json['finallyStepId'] as String?,
      ),
      'foreach' => ForeachNode(
        stepId: json['stepId'] as String,
        childStepIds: (json['childStepIds'] as List).cast<String>(),
      ),
      _ => throw FormatException('Unknown workflow node type: $type'),
    };
  }
}

/// A normalized action node for an ordinary workflow step.
final class ActionNode extends WorkflowNode {
  final String stepId;

  const ActionNode({required this.stepId});

  @override
  String get type => 'action';

  @override
  List<String> get stepIds => [stepId];

  @override
  Map<String, dynamic> toJson() => {'type': type, 'stepId': stepId};
}

/// A normalized map/fan-out node.
final class MapNode extends WorkflowNode {
  final String stepId;

  const MapNode({required this.stepId});

  @override
  String get type => 'map';

  @override
  List<String> get stepIds => [stepId];

  @override
  Map<String, dynamic> toJson() => {'type': type, 'stepId': stepId};
}

/// A normalized contiguous parallel group.
final class ParallelGroupNode extends WorkflowNode {
  @override
  final List<String> stepIds;

  const ParallelGroupNode({required this.stepIds});

  @override
  String get type => 'parallelGroup';

  @override
  Map<String, dynamic> toJson() => {'type': type, 'stepIds': stepIds.toList(growable: false)};
}

/// A normalized loop node with ordered body steps and optional finalizer.
final class LoopNode extends WorkflowNode {
  final String loopId;

  @override
  final List<String> stepIds;

  final String? finallyStepId;

  const LoopNode({required this.loopId, required this.stepIds, this.finallyStepId});

  @override
  String get type => 'loop';

  @override
  Map<String, dynamic> toJson() => {
    'type': type,
    'loopId': loopId,
    'stepIds': stepIds.toList(growable: false),
    if (finallyStepId != null) 'finallyStepId': finallyStepId,
  };
}

/// A normalized foreach/sub-pipeline node.
///
/// Represents "for each item in a collection, run this ordered sequence of steps".
/// The [stepId] refers to the controller step (which declares [mapOver] and
/// [foreachSteps]). [childStepIds] are the ordered substep IDs that execute
/// per item. Child steps are "foreach-owned" and are not emitted as top-level
/// nodes during normalization.
final class ForeachNode extends WorkflowNode {
  /// The controller step that drives the iteration.
  final String stepId;

  /// Ordered sub-pipeline step IDs executed sequentially per item.
  final List<String> childStepIds;

  const ForeachNode({required this.stepId, required this.childStepIds});

  @override
  String get type => 'foreach';

  @override
  List<String> get stepIds => [stepId, ...childStepIds];

  @override
  Map<String, dynamic> toJson() => {
    'type': type,
    'stepId': stepId,
    'childStepIds': childStepIds.toList(growable: false),
  };
}

/// A single step within a workflow definition.
class WorkflowStep {
  /// Unique identifier within the workflow.
  final String id;

  /// Human-readable step name.
  final String name;

  /// Optional skill reference for skill-aware steps.
  ///
  /// When present, the engine constructs the agent prompt as:
  /// `"Use the '<skill>' skill. <resolved prompt or context>"`
  final String? skill;

  /// Ordered list of prompt templates for this step.
  ///
  /// Required when [skill] is null. Optional when [skill] is present
  /// (context from [contextInputs] used when absent).
  /// Each entry uses `{{variable}}` and `{{context.key}}` references.
  /// Single-prompt steps have exactly one element; multi-prompt steps have two or more,
  /// which execute as sequential turns in the same conversation session.
  final List<String>? prompts;

  /// Task type string (research, analysis, writing, coding, automation, custom).
  /// Stored as string to avoid cross-package dependency on dartclaw_core's TaskType.
  final String type;

  /// Whether `type:` was authored explicitly in the source definition.
  final bool typeAuthored;

  /// Optional project reference (supports `{{variable}}` references).
  final String? project;

  /// Optional provider override (e.g., "claude", "codex").
  final String? provider;

  /// Optional model override for the provider.
  final String? model;

  /// Optional reasoning effort level (e.g. "low", "medium", "high").
  final String? effort;

  /// Step timeout in seconds (null means no timeout).
  final int? timeoutSeconds;

  /// Review mode for this step.
  final StepReviewMode review;

  /// Whether this step executes in parallel with adjacent parallel steps.
  final bool parallel;

  /// Optional gate expression that must be satisfied before this step runs.
  ///
  /// When the gate evaluates false the executor pauses the run awaiting operator
  /// review. Use [entryGate] instead when the desired behavior is to skip the
  /// step and continue.
  final String? gate;

  /// Optional entry-gate expression evaluated before [gate].
  ///
  /// When [entryGate] evaluates false the step is skipped (a `StepSkippedEvent`
  /// fires, the cursor advances, and the run continues). Mirrors the loop-level
  /// [WorkflowLoop.entryGate] semantic. `null` means "no entry gate — proceed to
  /// [gate] check".
  final String? entryGate;

  /// Context keys this step reads from.
  final List<String> contextInputs;

  /// Context keys this step writes to.
  final List<String> contextOutputs;

  /// Optional custom extraction configuration.
  final ExtractionConfig? extraction;

  /// Per-output extraction and format configuration.
  ///
  /// Keys correspond to entries in [contextOutputs].
  /// When null, all outputs use default text extraction.
  final Map<String, OutputConfig>? outputs;

  /// Optional per-step token budget.
  final int? maxTokens;

  /// Optional per-step cost ceiling in USD.
  final double? maxCostUsd;

  /// Optional per-step retry limit.
  final int? maxRetries;

  /// Optional per-step tool allowlist.
  final List<String>? allowedTools;

  /// Context key referencing a JSON array produced by a prior step.
  ///
  /// When set, this step is a map/fan-out step that iterates over the
  /// collection at this key. The collection is resolved from workflow context
  /// at execution time (S07). Template engine can access `{{map.item}}`,
  /// `{{map.index}}`, `{{map.length}}`, and `{{map.item.field}}` references.
  final String? mapOver;

  /// Maximum number of parallel map iterations.
  ///
  /// Stored as [Object?] because the value may be:
  /// - `int`: explicit concurrency limit
  /// - `String` `"unlimited"`: no concurrency cap
  /// - `String` template: e.g. `"{{MAX_PARALLEL}}"`, resolved at runtime (S07)
  /// - `null`: default (S07 determines the default)
  final Object? maxParallel;

  /// Maximum number of items to process from the map collection (default 20).
  ///
  /// Acts as a safety cap to prevent runaway fan-out.
  final int maxItems;

  /// Ordered child step IDs for a per-item sub-pipeline (foreach).
  ///
  /// When set alongside [mapOver], this step becomes a "foreach controller"
  /// that iterates [mapOver] and runs these child steps in authored order for
  /// each item before moving to the next phase. The controller step itself does
  /// not create an agent task — it is a pure orchestration container.
  final List<String>? foreachSteps;

  /// Optional author-supplied loop variable name for this map/foreach controller.
  ///
  /// When set, templates in this step (or its foreach children) can reference
  /// the iteration as `{{<alias>.item}}`, `{{<alias>.item.field}}`,
  /// `{{<alias>.index}}`, `{{<alias>.display_index}}`, `{{<alias>.length}}`,
  /// and `{{context.key[<alias>.index]}}`. Legacy `{{map.*}}` continues to
  /// resolve against the same iteration so existing workflows keep working.
  ///
  /// Must be a plain identifier (`[a-zA-Z_][a-zA-Z0-9_]*`). Reserved names
  /// `map` and `context` are rejected by the validator.
  ///
  /// YAML spelling: `as:` (primary) or `mapAlias:` / `map_alias:` (aliases).
  final String? mapAlias;

  /// Optional step reference whose root agent session should be continued.
  ///
  /// The value is normally a step ID. The legacy boolean form
  /// `continueSession: true` is still accepted and is normalized internally to
  /// the immediately preceding step via the private sentinel `@previous`.
  /// Only valid for provider/harness combinations that support session
  /// continuity (e.g. Claude Code). S04 owns runtime execution semantics.
  final String? continueSession;

  /// Error handling policy for this step.
  ///
  /// Accepted values: `"pause"` (default — abort the workflow), `"continue"`
  /// (log the error and continue to the next step), and legacy `"fail"`
  /// (treated the same as `"pause"` for backward compatibility).
  /// S02 owns runtime execution semantics for this field.
  final String? onError;

  /// Working directory override for bash steps.
  ///
  /// When set, the bash executor uses this path as the working directory.
  /// Supports `{{variable}}` references. Ignored for non-bash steps.
  /// S02 owns runtime execution semantics for this field.
  final String? workdir;

  /// Policy applied when this step reports an explicit failed outcome.
  ///
  /// Defaults to [OnFailurePolicy.fail].
  final OnFailurePolicy onFailure;

  /// Whether this step or its referenced skill emits its own `<step-outcome>`
  /// marker and should skip prompt augmentation for the outcome protocol.
  final bool emitsOwnOutcome;

  /// Whether the engine auto-frames unreferenced `contextInputs` and declared
  /// [workflowVariables] onto the step prompt as `<key>...</key>` blocks.
  /// Defaults to `true`; set to `false` (YAML: `auto_frame_context: false`) when
  /// the step's prompt body intentionally omits some declared context.
  final bool autoFrameContext;

  /// Workflow-level variable names this step opts in to receive via auto-framing.
  ///
  /// Only variables listed here are appended as `<NAME>{value}</NAME>` blocks
  /// by the engine. Undeclared workflow variables never reach the prompt, even
  /// if declared on the workflow, preventing leakage across unrelated steps
  /// (e.g. `REQUIREMENTS` must not land on `discover-project`).
  ///
  /// Each entry must be a key in the workflow's top-level `variables:` block;
  /// the validator rejects unknown names at load time. Empty by default.
  final List<String> workflowVariables;

  /// Convenience getter returning the first (or only) prompt.
  ///
  /// Returns null when this is a skill-only step with no prompt.
  /// Use [prompts] directly when iterating all prompts in a multi-prompt step.
  String? get prompt => prompts?.firstOrNull;

  /// Whether this step sends more than one turn in the same session.
  bool get isMultiPrompt => (prompts?.length ?? 0) > 1;

  /// Whether this step is a map/fan-out step.
  bool get isMapStep => mapOver != null;

  /// Whether this step is a foreach controller (per-item ordered sub-pipeline).
  bool get isForeachController => mapOver != null && foreachSteps != null && foreachSteps!.isNotEmpty;

  const WorkflowStep({
    required this.id,
    required this.name,
    this.prompts,
    this.skill,
    this.type = 'research',
    this.typeAuthored = false,
    this.project,
    this.provider,
    this.model,
    this.effort,
    this.timeoutSeconds,
    this.review = StepReviewMode.codingOnly,
    this.parallel = false,
    this.gate,
    this.entryGate,
    this.contextInputs = const [],
    this.contextOutputs = const [],
    this.extraction,
    this.outputs,
    this.maxTokens,
    this.maxCostUsd,
    this.maxRetries,
    this.allowedTools,
    this.mapOver,
    this.maxParallel,
    this.maxItems = 20,
    this.foreachSteps,
    this.mapAlias,
    this.continueSession,
    this.onError,
    this.workdir,
    this.onFailure = OnFailurePolicy.fail,
    this.emitsOwnOutcome = false,
    this.autoFrameContext = true,
    this.workflowVariables = const [],
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    if (skill != null) 'skill': skill,
    if (prompts != null) 'prompts': prompts!.toList(),
    if (typeAuthored || type != 'research') 'type': type,
    'review': review.name,
    'parallel': parallel,
    if (project != null) 'project': project,
    if (provider != null) 'provider': provider,
    if (model != null) 'model': model,
    if (effort != null) 'effort': effort,
    if (timeoutSeconds != null) 'timeout': timeoutSeconds,
    if (gate != null) 'gate': gate,
    if (entryGate != null) 'entryGate': entryGate,
    'contextInputs': contextInputs.toList(),
    'contextOutputs': contextOutputs.toList(),
    if (extraction != null) 'extraction': extraction!.toJson(),
    if (outputs != null) 'outputs': outputs!.map((k, v) => MapEntry(k, v.toJson())),
    if (maxTokens != null) 'maxTokens': maxTokens,
    if (maxCostUsd != null) 'maxCostUsd': maxCostUsd,
    if (maxRetries != null) 'maxRetries': maxRetries,
    if (allowedTools != null) 'allowedTools': allowedTools!.toList(),
    if (mapOver != null) 'mapOver': mapOver,
    if (maxParallel != null) 'maxParallel': maxParallel,
    if (maxItems != 20) 'maxItems': maxItems,
    if (foreachSteps != null) 'foreachSteps': foreachSteps!.toList(growable: false),
    if (mapAlias != null) 'mapAlias': mapAlias,
    if (continueSession != null) 'continueSession': continueSession == '@previous' ? true : continueSession,
    if (onError != null) 'onError': onError,
    if (workdir != null) 'workdir': workdir,
    if (onFailure != OnFailurePolicy.fail) 'onFailure': onFailure.yamlName,
    if (emitsOwnOutcome) 'emitsOwnOutcome': true,
    if (!autoFrameContext) 'autoFrameContext': false,
    if (workflowVariables.isNotEmpty) 'workflowVariables': workflowVariables.toList(growable: false),
  };

  factory WorkflowStep.fromJson(Map<String, dynamic> json) {
    // Accept both legacy String and new List<String> for 'prompts'/'prompt'.
    // Null is valid when 'skill' is present.
    final List<String>? prompts;
    final rawPrompts = json['prompts'] ?? json['prompt'];
    if (rawPrompts is String) {
      prompts = [rawPrompts];
    } else if (rawPrompts is List) {
      prompts = rawPrompts.cast<String>();
    } else {
      prompts = null;
    }
    return WorkflowStep(
      id: json['id'] as String,
      name: json['name'] as String,
      skill: json['skill'] as String?,
      prompts: prompts,
      type: (json['type'] as String?) ?? 'research',
      typeAuthored: (json['typeAuthored'] as bool?) ?? json.containsKey('type'),
      project: json['project'] as String?,
      provider: json['provider'] as String?,
      model: json['model'] as String?,
      timeoutSeconds: (json['timeout'] ?? json['timeoutSeconds']) as int?,
      review: json['review'] != null
          ? StepReviewMode.values.byName(json['review'] as String)
          : StepReviewMode.codingOnly,
      parallel: (json['parallel'] as bool?) ?? false,
      gate: json['gate'] as String?,
      entryGate: json['entryGate'] as String?,
      contextInputs: (json['contextInputs'] as List?)?.cast<String>() ?? const [],
      contextOutputs: (json['contextOutputs'] as List?)?.cast<String>() ?? const [],
      extraction: json['extraction'] != null
          ? ExtractionConfig.fromJson(json['extraction'] as Map<String, dynamic>)
          : null,
      outputs: (json['outputs'] as Map<String, dynamic>?)?.map(
        (k, v) => MapEntry(k, OutputConfig.fromJson(v as Map<String, dynamic>)),
      ),
      maxTokens: json['maxTokens'] as int?,
      maxCostUsd: (json['maxCostUsd'] as num?)?.toDouble(),
      maxRetries: json['maxRetries'] as int?,
      allowedTools: (json['allowedTools'] as List?)?.cast<String>(),
      mapOver: json['mapOver'] as String?,
      maxParallel: json['maxParallel'],
      maxItems: (json['maxItems'] as int?) ?? 20,
      foreachSteps: (json['foreachSteps'] as List?)?.cast<String>(),
      mapAlias: json['mapAlias'] as String?,
      continueSession: switch (json['continueSession']) {
        true => '@previous',
        String value when value.isNotEmpty => value,
        _ => null,
      },
      onError: json['onError'] as String?,
      workdir: json['workdir'] as String?,
      onFailure: json['onFailure'] is String
          ? (OnFailurePolicy.fromYaml(json['onFailure'] as String) ?? OnFailurePolicy.fail)
          : OnFailurePolicy.fail,
      emitsOwnOutcome: (json['emitsOwnOutcome'] as bool?) ?? false,
      autoFrameContext: (json['autoFrameContext'] as bool?) ?? true,
      workflowVariables: (json['workflowVariables'] as List?)?.cast<String>() ?? const [],
    );
  }
}

/// Artifact auto-commit configuration nested under [WorkflowGitStrategy].
///
/// When [commit] is true the workflow engine commits any files produced by
/// artifact-producing steps (`dartclaw-prd`, `dartclaw-plan`, `dartclaw-spec`,
/// or any step writing under `context.docs_project_index.artifact_locations.*`)
/// to the workflow branch before per-map-item worktrees are dispatched, so the
/// worktrees inherit the committed files via standard `git checkout`.
class WorkflowGitArtifactsStrategy {
  /// Whether artifact auto-commit is enabled for this workflow.
  ///
  /// `null` triggers default resolution at validate/execute time:
  /// defaults to `true` iff the workflow declares ≥1 artifact-producing step,
  /// else `false`.
  final bool? commit;

  /// Commit message template applied when the hook fires.
  ///
  /// Supports `{{runId}}` and workflow-level variable substitution.
  final String? commitMessage;

  /// Project identifier whose working tree receives the commits.
  ///
  /// Supports `{{VARIABLE}}` templating. When null the workflow's primary
  /// project (`{{PROJECT}}`) is used.
  final String? project;

  const WorkflowGitArtifactsStrategy({this.commit, this.commitMessage, this.project});

  Map<String, dynamic> toJson() => {
    if (commit != null) 'commit': commit,
    if (commitMessage != null) 'commitMessage': commitMessage,
    if (project != null) 'project': project,
  };

  factory WorkflowGitArtifactsStrategy.fromJson(Map<String, dynamic> json) => WorkflowGitArtifactsStrategy(
    commit: json['commit'] as bool?,
    commitMessage: json['commitMessage'] as String?,
    project: json['project'] as String?,
  );
}

/// Cross-clone external artifact mount configuration nested under
/// [WorkflowGitStrategy].worktree.
///
/// Two modes:
/// - `per-story-copy` (default, least-privilege): on per-map-item worktree
///   creation the engine resolves [source] against the current `map.item.*`
///   fields, copies exactly that file from [fromProject]'s working tree into
///   the worktree at the same relative path. Each worktree receives only the
///   file its story owns.
/// - `bind-mount` (opt-in): the engine bind-mounts the directory
///   `<dataDir>/projects/<fromProject>/<fromPath>` read-only into every
///   per-story worktree at [toPath]. Intended for debugging / cross-story
///   reference scenarios and must be justified in the profile README.
class WorkflowGitExternalArtifactMount {
  /// Mount mode — `per-story-copy` (default) or `bind-mount`.
  final String mode;

  /// External project id to pull artifacts from.
  final String fromProject;

  /// (`per-story-copy` only) Template resolved against the current map item to
  /// a workspace-relative path inside [fromProject]. Example:
  /// `"{{map.item.spec_path}}"`.
  final String? source;

  /// (`bind-mount` only) Directory to mount (relative to [fromProject] root).
  final String? fromPath;

  /// (`bind-mount` only) Mount target path inside the per-story worktree.
  final String? toPath;

  /// (`bind-mount` only) Whether the mount is read-only. Defaults to true.
  final bool? readonly;

  const WorkflowGitExternalArtifactMount({
    this.mode = 'per-story-copy',
    required this.fromProject,
    this.source,
    this.fromPath,
    this.toPath,
    this.readonly,
  });

  Map<String, dynamic> toJson() => {
    'mode': mode,
    'fromProject': fromProject,
    if (source != null) 'source': source,
    if (fromPath != null) 'fromPath': fromPath,
    if (toPath != null) 'toPath': toPath,
    if (readonly != null) 'readonly': readonly,
  };

  factory WorkflowGitExternalArtifactMount.fromJson(Map<String, dynamic> json) => WorkflowGitExternalArtifactMount(
    mode: (json['mode'] as String?) ?? 'per-story-copy',
    fromProject: json['fromProject'] as String,
    source: json['source'] as String?,
    fromPath: json['fromPath'] as String?,
    toPath: json['toPath'] as String?,
    readonly: json['readonly'] as bool?,
  );
}

/// Publish strategy configuration nested under [WorkflowGitStrategy].
class WorkflowGitPublishStrategy {
  /// Whether publish behavior is enabled for the workflow.
  final bool? enabled;

  const WorkflowGitPublishStrategy({this.enabled});

  Map<String, dynamic> toJson() => {if (enabled != null) 'enabled': enabled};

  factory WorkflowGitPublishStrategy.fromJson(Map<String, dynamic> json) =>
      WorkflowGitPublishStrategy(enabled: json['enabled'] as bool?);
}

/// Escalation policy when all merge-resolve attempts are exhausted.
///
/// YAML string → enum mapping:
/// - `serialize-remaining` → [serializeRemaining]
/// - `fail` → [fail]
///
/// The string `pause` is intentionally NOT mapped here — it is reserved for
/// a future release and surfaced as a validator error via
/// [MergeResolveConfig.rawEscalation].
enum MergeResolveEscalation {
  serializeRemaining,
  fail;

  static MergeResolveEscalation? tryParse(String? value) => switch (value) {
    'serialize-remaining' => serializeRemaining,
    'fail' => fail,
    _ => null,
  };

  String toYamlString() => switch (this) {
    serializeRemaining => 'serialize-remaining',
    fail => 'fail',
  };
}

/// Verification command configuration nested under [MergeResolveConfig].
///
/// All fields are optional — absent/empty block means markers + `git diff
/// --check` only (BPC-19). Unknown keys are captured in [unknownFields] so
/// the validator can emit a BPC-17 error without making [fromJson] throwing.
class MergeResolveVerificationConfig {
  /// Shell command to run for format verification (e.g. `dart format --set-exit-if-changed .`).
  final String? format;

  /// Shell command to run for static analysis (e.g. `dart analyze`).
  final String? analyze;

  /// Shell command to run for tests (e.g. `dart test`).
  final String? test;

  /// Unknown keys captured at parse time for validator surfacing.
  final List<String> unknownFields;

  const MergeResolveVerificationConfig({this.format, this.analyze, this.test, this.unknownFields = const []});

  Map<String, dynamic> toJson() => {
    if (format != null) 'format': format,
    if (analyze != null) 'analyze': analyze,
    if (test != null) 'test': test,
  };

  factory MergeResolveVerificationConfig.fromJson(Object? raw) {
    final json = switch (raw) {
      Map<String, dynamic> m => m,
      Map<Object?, Object?> m => Map<String, dynamic>.from(m),
      _ => <String, dynamic>{},
    };
    const knownKeys = {'format', 'analyze', 'test'};
    final unknown = json.keys.where((k) => !knownKeys.contains(k)).toList();
    return MergeResolveVerificationConfig(
      format: json['format'] as String?,
      analyze: json['analyze'] as String?,
      test: json['test'] as String?,
      unknownFields: unknown,
    );
  }
}

/// Typed configuration for the `merge_resolve:` block under `gitStrategy:`.
///
/// BPC-18 defaults apply when the block is absent or fields are omitted:
/// `enabled: false`, `maxAttempts: 2`, `tokenCeiling: 100000`,
/// `escalation: serialize-remaining`, `verification: {}`.
///
/// [rawEscalation] preserves the authored string when it does not map to a
/// known [MergeResolveEscalation] value (e.g. the reserved `pause`) so the
/// validator can emit the correct BPC-17 message without `fromJson` throwing.
///
/// Unknown top-level keys are captured in [unknownFields] for the same reason.
class MergeResolveConfig {
  final bool enabled;
  final int maxAttempts;
  final int tokenCeiling;

  /// Parsed escalation value. `null` when the authored string is unrecognised.
  final MergeResolveEscalation? escalation;

  /// Raw escalation string from YAML — `null` when the key was absent.
  final String? rawEscalation;

  final MergeResolveVerificationConfig verification;

  /// Unknown top-level keys captured at parse time for validator surfacing.
  final List<String> unknownFields;

  const MergeResolveConfig({
    this.enabled = false,
    this.maxAttempts = 2,
    this.tokenCeiling = 100000,
    this.escalation = MergeResolveEscalation.serializeRemaining,
    this.rawEscalation,
    this.verification = const MergeResolveVerificationConfig(),
    this.unknownFields = const [],
  });

  Map<String, dynamic> toJson() => {
    if (enabled) 'enabled': enabled,
    if (maxAttempts != 2) 'max_attempts': maxAttempts,
    if (tokenCeiling != 100000) 'token_ceiling': tokenCeiling,
    if (escalation != null && escalation != MergeResolveEscalation.serializeRemaining)
      'escalation': escalation!.toYamlString()
    else if (rawEscalation != null)
      'escalation': rawEscalation,
    if (verification.format != null || verification.analyze != null || verification.test != null)
      'verification': verification.toJson(),
  };

  factory MergeResolveConfig.fromJson(Object? raw) {
    final json = switch (raw) {
      Map<String, dynamic> m => m,
      Map<Object?, Object?> m => Map<String, dynamic>.from(m),
      _ => <String, dynamic>{},
    };
    const knownKeys = {'enabled', 'max_attempts', 'token_ceiling', 'escalation', 'verification'};
    final unknown = json.keys.where((k) => !knownKeys.contains(k)).toList();
    final rawEsc = json['escalation'] as String?;
    return MergeResolveConfig(
      enabled: (json['enabled'] as bool?) ?? false,
      maxAttempts: (json['max_attempts'] as int?) ?? 2,
      tokenCeiling: (json['token_ceiling'] as int?) ?? 100000,
      escalation: rawEsc == null
          ? MergeResolveEscalation.serializeRemaining
          : MergeResolveEscalation.tryParse(rawEsc),
      rawEscalation: rawEsc,
      verification: MergeResolveVerificationConfig.fromJson(json['verification']),
      unknownFields: unknown,
    );
  }
}

/// Worktree strategy configuration nested under [WorkflowGitStrategy].
class WorkflowGitWorktreeStrategy {
  /// Worktree mode (`shared`, `per-task`, `per-map-item`, `inline`, `auto`).
  final String? mode;

  /// Optional cross-clone external artifact mount (two-repo profiles).
  final WorkflowGitExternalArtifactMount? externalArtifactMount;

  const WorkflowGitWorktreeStrategy({this.mode, this.externalArtifactMount});

  Object? toJsonValue() {
    if (mode != null && externalArtifactMount == null) return mode;
    if (mode == null && externalArtifactMount == null) return null;
    return {
      if (mode != null) 'mode': mode,
      if (externalArtifactMount != null) 'externalArtifactMount': externalArtifactMount!.toJson(),
    };
  }

  factory WorkflowGitWorktreeStrategy.fromJson(Object? json) => switch (json) {
    String mode => WorkflowGitWorktreeStrategy(mode: mode),
    Map<String, dynamic> map => WorkflowGitWorktreeStrategy(
      mode: map['mode'] as String?,
      externalArtifactMount: switch (map['externalArtifactMount']) {
        Map<String, dynamic> mount => WorkflowGitExternalArtifactMount.fromJson(mount),
        Map<Object?, Object?> mount => WorkflowGitExternalArtifactMount.fromJson(Map<String, dynamic>.from(mount)),
        _ => null,
      },
    ),
    Map<Object?, Object?> map => WorkflowGitWorktreeStrategy.fromJson(Map<String, dynamic>.from(map)),
    _ => const WorkflowGitWorktreeStrategy(),
  };
}

/// Reusable workflow-level git behavior strategy surface.
///
/// This shape is intentionally declarative for S16b. Runtime enforcement is
/// owned by later milestones.
class WorkflowGitStrategy {
  /// Whether workflow startup should bootstrap a workflow-owned feature branch.
  final bool? bootstrap;

  /// Worktree strategy (`shared`, `per-task`, `per-map-item`, `inline`,
  /// `auto`) plus nested worktree-only settings.
  final WorkflowGitWorktreeStrategy? worktree;

  /// Promotion strategy (`merge`, `rebase`, `none`).
  final String? promotion;

  /// Publish behavior configuration.
  final WorkflowGitPublishStrategy? publish;

  /// Artifact auto-commit configuration (null = default truth-table resolution).
  final WorkflowGitArtifactsStrategy? artifacts;

  /// True when the definition authored `gitStrategy.externalArtifactMount`
  /// at the deprecated flat level. Parser-only metadata so the validator can
  /// emit a migration hint while still hydrating the nested runtime surface.
  final bool legacyExternalArtifactMountLocation;

  /// Nullable backing field — null when `merge_resolve:` is absent from YAML
  /// so [toJson] omits the key for pre-feature definitions.
  final MergeResolveConfig? _mergeResolve;

  /// Typed agent-resolved-merge configuration.
  ///
  /// Returns a default [MergeResolveConfig] (BPC-18 defaults) when the
  /// `merge_resolve:` block was absent from the YAML, so callers never need a
  /// null check.
  MergeResolveConfig get mergeResolve => _mergeResolve ?? const MergeResolveConfig();

  /// Convenience projection of the configured worktree mode.
  String? get worktreeMode => worktree?.mode;

  /// Convenience projection of the nested external artifact mount.
  WorkflowGitExternalArtifactMount? get externalArtifactMount => worktree?.externalArtifactMount;

  /// Resolves the authored worktree mode to the runtime mode for a specific
  /// scope. Omitted worktree config is treated as `auto`.
  ///
  /// `auto` resolves to `per-map-item` only for map/foreach scopes whose
  /// effective `maxParallel` is greater than 1. Runtime callers also pass
  /// `null` for the `"unlimited"` path, which is treated as parallel fan-out.
  /// All other `auto` cases resolve to `inline`.
  String effectiveWorktreeMode({required int? maxParallel, required bool isMap}) {
    final authored = worktreeMode?.trim();
    if (authored == null || authored.isEmpty || authored == 'auto') {
      if (isMap && maxParallel == null) {
        return 'per-map-item';
      }
      final effectiveMaxParallel = maxParallel ?? 1;
      return isMap && effectiveMaxParallel > 1 ? 'per-map-item' : 'inline';
    }
    return authored;
  }

  const WorkflowGitStrategy({
    this.bootstrap,
    this.worktree,
    this.promotion,
    this.publish,
    this.artifacts,
    this.legacyExternalArtifactMountLocation = false,
    MergeResolveConfig? mergeResolve,
  }) : _mergeResolve = mergeResolve;

  Map<String, dynamic> toJson() => {
    if (bootstrap != null) 'bootstrap': bootstrap,
    if (worktree != null) 'worktree': worktree!.toJsonValue(),
    if (promotion != null) 'promotion': promotion,
    if (publish != null) 'publish': publish!.toJson(),
    if (artifacts != null) 'artifacts': artifacts!.toJson(),
    if (_mergeResolve != null) 'merge_resolve': _mergeResolve.toJson(),
  };

  factory WorkflowGitStrategy.fromJson(Map<String, dynamic> json) => WorkflowGitStrategy(
    bootstrap: json['bootstrap'] as bool?,
    worktree: switch (json['worktree']) {
      null => null,
      final value => WorkflowGitWorktreeStrategy.fromJson(value),
    },
    promotion: json['promotion'] as String?,
    publish: switch (json['publish']) {
      Map<String, dynamic> publish => WorkflowGitPublishStrategy.fromJson(publish),
      Map<Object?, Object?> publish => WorkflowGitPublishStrategy.fromJson(Map<String, dynamic>.from(publish)),
      _ => null,
    },
    artifacts: switch (json['artifacts']) {
      Map<String, dynamic> artifacts => WorkflowGitArtifactsStrategy.fromJson(artifacts),
      Map<Object?, Object?> artifacts => WorkflowGitArtifactsStrategy.fromJson(Map<String, dynamic>.from(artifacts)),
      _ => null,
    },
    legacyExternalArtifactMountLocation: json['legacyExternalArtifactMountLocation'] == true,
    mergeResolve: switch (json['merge_resolve']) {
      null => null,
      final value => MergeResolveConfig.fromJson(value),
    },
  );
}

/// A workflow definition parsed from a YAML file.
///
/// Immutable value object describing a multi-step agent pipeline.
/// Contains step definitions, variable declarations, loop constructs,
/// and optional budget limits. Loaded at startup, never modified at runtime.
class WorkflowDefinition {
  /// Unique name used as identifier (derived from YAML `name` field).
  final String name;

  /// Human-readable description of the workflow's purpose.
  final String description;

  /// Variable declarations: name -> variable definition.
  final Map<String, WorkflowVariable> variables;

  /// Ordered list of workflow steps.
  final List<WorkflowStep> steps;

  /// Loop definitions referencing step IDs.
  final List<WorkflowLoop> loops;

  /// Explicit normalized execution graph.
  ///
  /// Older snapshots may omit this field; in that case it is rebuilt from
  /// [steps] and [loops] on demand for backward compatibility.
  final List<WorkflowNode>? _nodes;

  /// Optional workflow-level token budget ceiling.
  final int? maxTokens;

  /// Optional workflow-level project binding inherited by eligible steps.
  final String? project;

  /// Optional pattern-based step config defaults applied in order (first match wins).
  final List<StepConfigDefault>? stepDefaults;

  /// Optional workflow-level git strategy configuration.
  final WorkflowGitStrategy? gitStrategy;

  const WorkflowDefinition({
    required this.name,
    required this.description,
    this.variables = const {},
    required this.steps,
    this.loops = const [],
    List<WorkflowNode>? nodes,
    this.maxTokens,
    this.project,
    this.stepDefaults,
    this.gitStrategy,
  }) : _nodes = nodes;

  /// Normalized authored-order execution graph for this definition.
  List<WorkflowNode> get nodes => _nodes ?? normalizeNodes(steps, loops);

  WorkflowDefinition copyWith({
    String? name,
    String? description,
    Map<String, WorkflowVariable>? variables,
    List<WorkflowStep>? steps,
    List<WorkflowLoop>? loops,
    Object? nodes = _workflowDefinitionFieldUnset,
    int? maxTokens,
    Object? project = _workflowDefinitionFieldUnset,
    Object? stepDefaults = _workflowDefinitionFieldUnset,
    Object? gitStrategy = _workflowDefinitionFieldUnset,
  }) => WorkflowDefinition(
    name: name ?? this.name,
    description: description ?? this.description,
    variables: variables ?? this.variables,
    steps: steps ?? this.steps,
    loops: loops ?? this.loops,
    nodes: identical(nodes, _workflowDefinitionFieldUnset) ? _nodes : nodes as List<WorkflowNode>?,
    maxTokens: maxTokens ?? this.maxTokens,
    project: identical(project, _workflowDefinitionFieldUnset) ? this.project : project as String?,
    stepDefaults: identical(stepDefaults, _workflowDefinitionFieldUnset)
        ? this.stepDefaults
        : stepDefaults as List<StepConfigDefault>?,
    gitStrategy: identical(gitStrategy, _workflowDefinitionFieldUnset)
        ? this.gitStrategy
        : gitStrategy as WorkflowGitStrategy?,
  );

  Map<String, dynamic> toJson() => {
    'name': name,
    'description': description,
    'variables': variables.map((k, v) => MapEntry(k, v.toJson())),
    'steps': steps.map((s) => s.toJson()).toList(),
    'loops': loops.map((l) => l.toJson()).toList(),
    'nodes': nodes.map((n) => n.toJson()).toList(growable: false),
    if (maxTokens != null) 'maxTokens': maxTokens,
    if (project != null) 'project': project,
    if (stepDefaults != null) 'stepDefaults': stepDefaults!.map((d) => d.toJson()).toList(),
    if (gitStrategy != null) 'gitStrategy': gitStrategy!.toJson(),
  };

  factory WorkflowDefinition.fromJson(Map<String, dynamic> json) => WorkflowDefinition(
    name: json['name'] as String,
    description: json['description'] as String,
    variables:
        (json['variables'] as Map<String, dynamic>?)?.map(
          (k, v) => MapEntry(k, WorkflowVariable.fromJson(v as Map<String, dynamic>)),
        ) ??
        const {},
    steps: (json['steps'] as List).map((s) => WorkflowStep.fromJson(s as Map<String, dynamic>)).toList(growable: false),
    loops:
        (json['loops'] as List?)
            ?.map((l) => WorkflowLoop.fromJson(l as Map<String, dynamic>))
            .toList(growable: false) ??
        const [],
    nodes: (json['nodes'] as List?)
        ?.map((node) => WorkflowNode.fromJson(node as Map<String, dynamic>))
        .toList(growable: false),
    maxTokens: json['maxTokens'] as int?,
    project: json['project'] as String?,
    stepDefaults: (json['stepDefaults'] as List?)
        ?.map((d) => StepConfigDefault.fromJson(d as Map<String, dynamic>))
        .toList(growable: false),
    gitStrategy: switch (json['gitStrategy']) {
      Map<String, dynamic> strategy => WorkflowGitStrategy.fromJson(strategy),
      Map<Object?, Object?> strategy => WorkflowGitStrategy.fromJson(Map<String, dynamic>.from(strategy)),
      _ => null,
    },
  );

  /// Builds the authored-order execution graph used by validation and runtime.
  static List<WorkflowNode> normalizeNodes(List<WorkflowStep> steps, List<WorkflowLoop> loops) {
    final loopByFirstStepId = <String, WorkflowLoop>{
      for (final loop in loops)
        if (loop.steps.isNotEmpty) loop.steps.first: loop,
    };
    final loopOwnedStepIds = {
      ...loops.expand((loop) => loop.steps),
      ...loops.map((loop) => loop.finally_).whereType<String>(),
    };
    // Foreach-owned steps are child steps of foreach controllers; they are
    // not emitted as top-level nodes.
    final foreachOwnedStepIds = {
      for (final step in steps)
        if (step.isForeachController) ...step.foreachSteps!,
    };

    final nodes = <WorkflowNode>[];
    final emittedLoopIds = <String>{};

    for (var index = 0; index < steps.length; index++) {
      final step = steps[index];
      final loopAtStep = loopByFirstStepId[step.id];
      if (loopAtStep != null && emittedLoopIds.add(loopAtStep.id)) {
        nodes.add(
          LoopNode(
            loopId: loopAtStep.id,
            stepIds: loopAtStep.steps.toList(growable: false),
            finallyStepId: loopAtStep.finally_,
          ),
        );
        continue;
      }

      if (loopOwnedStepIds.contains(step.id)) {
        continue;
      }

      if (foreachOwnedStepIds.contains(step.id)) {
        continue;
      }

      if (step.isForeachController) {
        nodes.add(ForeachNode(stepId: step.id, childStepIds: step.foreachSteps!.toList(growable: false)));
        continue;
      }

      if (step.isMapStep) {
        nodes.add(MapNode(stepId: step.id));
        continue;
      }

      if (step.parallel) {
        final parallelStepIds = <String>[step.id];
        while (index + 1 < steps.length) {
          final next = steps[index + 1];
          if (loopOwnedStepIds.contains(next.id) ||
              foreachOwnedStepIds.contains(next.id) ||
              loopByFirstStepId.containsKey(next.id) ||
              next.isMapStep ||
              next.isForeachController ||
              !next.parallel) {
            break;
          }
          parallelStepIds.add(next.id);
          index++;
        }
        nodes.add(ParallelGroupNode(stepIds: parallelStepIds));
        continue;
      }

      nodes.add(ActionNode(stepId: step.id));
    }

    return nodes;
  }
}
