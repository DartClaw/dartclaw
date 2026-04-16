/// Output format for context extraction.
enum OutputFormat {
  /// Raw string extraction (default, current behavior).
  text,

  /// Multi-strategy JSON extraction with fallback chain.
  json,

  /// Split output into list of trimmed non-empty lines.
  lines;

  static OutputFormat? fromYaml(String value) => switch (value) {
    'text' => text,
    'json' => json,
    'lines' => lines,
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

  const OutputConfig({this.format = OutputFormat.text, this.schema, this.source});

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
  };

  factory OutputConfig.fromJson(Map<String, dynamic> json) => OutputConfig(
    format: json['format'] != null ? OutputFormat.values.byName(json['format'] as String) : OutputFormat.text,
    schema: json['schema'],
    source: json['source'] as String?,
  );
}

/// Review mode for workflow steps.
enum StepReviewMode {
  /// Step always enters review status.
  always,

  /// Only coding steps enter review (default).
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
    this.maxTokens,
    this.maxCostUsd,
    this.maxRetries,
    this.allowedTools,
  });

  Map<String, dynamic> toJson() => {
    'match': match,
    if (provider != null) 'provider': provider,
    if (model != null) 'model': model,
    if (maxTokens != null) 'maxTokens': maxTokens,
    if (maxCostUsd != null) 'maxCostUsd': maxCostUsd,
    if (maxRetries != null) 'maxRetries': maxRetries,
    if (allowedTools != null) 'allowedTools': allowedTools!.toList(),
  };

  factory StepConfigDefault.fromJson(Map<String, dynamic> json) => StepConfigDefault(
    match: json['match'] as String,
    provider: json['provider'] as String?,
    model: json['model'] as String?,
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

  /// Optional project reference (supports `{{variable}}` references).
  final String? project;

  /// Optional provider override (e.g., "claude", "codex").
  final String? provider;

  /// Optional model override for the provider.
  final String? model;

  /// Step timeout in seconds (null means no timeout).
  final int? timeoutSeconds;

  /// Review mode for this step.
  final StepReviewMode review;

  /// Whether this step executes in parallel with adjacent parallel steps.
  final bool parallel;

  /// Optional gate expression that must be satisfied before this step runs.
  final String? gate;

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
    this.project,
    this.provider,
    this.model,
    this.timeoutSeconds,
    this.review = StepReviewMode.codingOnly,
    this.parallel = false,
    this.gate,
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
    this.continueSession,
    this.onError,
    this.workdir,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    if (skill != null) 'skill': skill,
    if (prompts != null) 'prompts': prompts!.toList(),
    'type': type,
    'review': review.name,
    'parallel': parallel,
    if (project != null) 'project': project,
    if (provider != null) 'provider': provider,
    if (model != null) 'model': model,
    if (timeoutSeconds != null) 'timeout': timeoutSeconds,
    if (gate != null) 'gate': gate,
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
    if (continueSession != null) 'continueSession': continueSession == '@previous' ? true : continueSession,
    if (onError != null) 'onError': onError,
    if (workdir != null) 'workdir': workdir,
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
      project: json['project'] as String?,
      provider: json['provider'] as String?,
      model: json['model'] as String?,
      timeoutSeconds: (json['timeout'] ?? json['timeoutSeconds']) as int?,
      review: json['review'] != null
          ? StepReviewMode.values.byName(json['review'] as String)
          : StepReviewMode.codingOnly,
      parallel: (json['parallel'] as bool?) ?? false,
      gate: json['gate'] as String?,
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
      continueSession: switch (json['continueSession']) {
        true => '@previous',
        String value when value.isNotEmpty => value,
        _ => null,
      },
      onError: json['onError'] as String?,
      workdir: json['workdir'] as String?,
    );
  }
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

/// Reusable workflow-level git behavior strategy surface.
///
/// This shape is intentionally declarative for S16b. Runtime enforcement is
/// owned by later milestones.
class WorkflowGitStrategy {
  /// Whether workflow startup should bootstrap a workflow-owned feature branch.
  final bool? bootstrap;

  /// Worktree strategy (`shared`, `per-task`, `per-map-item`).
  final String? worktree;

  /// Promotion strategy (`merge`, `rebase`, `none`).
  final String? promotion;

  /// Whether a final integrated review is required.
  final bool? finalReview;

  /// Publish behavior configuration.
  final WorkflowGitPublishStrategy? publish;

  /// Cleanup behavior (`always`, `preserve-on-failure`, `never`).
  final String? cleanup;

  const WorkflowGitStrategy({
    this.bootstrap,
    this.worktree,
    this.promotion,
    this.finalReview,
    this.publish,
    this.cleanup,
  });

  Map<String, dynamic> toJson() => {
    if (bootstrap != null) 'bootstrap': bootstrap,
    if (worktree != null) 'worktree': worktree,
    if (promotion != null) 'promotion': promotion,
    if (finalReview != null) 'finalReview': finalReview,
    if (publish != null) 'publish': publish!.toJson(),
    if (cleanup != null) 'cleanup': cleanup,
  };

  factory WorkflowGitStrategy.fromJson(Map<String, dynamic> json) => WorkflowGitStrategy(
    bootstrap: json['bootstrap'] as bool?,
    worktree: json['worktree'] as String?,
    promotion: json['promotion'] as String?,
    finalReview: json['finalReview'] as bool?,
    publish: switch (json['publish']) {
      Map<String, dynamic> publish => WorkflowGitPublishStrategy.fromJson(publish),
      Map<Object?, Object?> publish => WorkflowGitPublishStrategy.fromJson(Map<String, dynamic>.from(publish)),
      _ => null,
    },
    cleanup: json['cleanup'] as String?,
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
    this.stepDefaults,
    this.gitStrategy,
  }) : _nodes = nodes;

  /// Normalized authored-order execution graph for this definition.
  List<WorkflowNode> get nodes => _nodes ?? normalizeNodes(steps, loops);

  Map<String, dynamic> toJson() => {
    'name': name,
    'description': description,
    'variables': variables.map((k, v) => MapEntry(k, v.toJson())),
    'steps': steps.map((s) => s.toJson()).toList(),
    'loops': loops.map((l) => l.toJson()).toList(),
    'nodes': nodes.map((n) => n.toJson()).toList(growable: false),
    if (maxTokens != null) 'maxTokens': maxTokens,
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
        if (step.isForeachController)
          ...step.foreachSteps!,
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
        nodes.add(
          ForeachNode(
            stepId: step.id,
            childStepIds: step.foreachSteps!.toList(growable: false),
          ),
        );
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
