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

  Map<String, dynamic> toJson() => {
    'type': type.name,
    'pattern': pattern,
  };

  factory ExtractionConfig.fromJson(Map<String, dynamic> json) =>
      ExtractionConfig(
        type: ExtractionType.values.byName(json['type'] as String),
        pattern: json['pattern'] as String,
      );
}

/// A variable declaration in a workflow definition.
class WorkflowVariable {
  /// Whether this variable must be provided at workflow start.
  final bool required;

  /// Human-readable description for UI display.
  final String description;

  /// Optional default value used when not provided.
  final String? defaultValue;

  const WorkflowVariable({
    this.required = true,
    this.description = '',
    this.defaultValue,
  });

  Map<String, dynamic> toJson() => {
    'required': required,
    'description': description,
    if (defaultValue != null) 'defaultValue': defaultValue,
  };

  factory WorkflowVariable.fromJson(Map<String, dynamic> json) =>
      WorkflowVariable(
        required: (json['required'] as bool?) ?? true,
        description: (json['description'] as String?) ?? '',
        defaultValue: json['defaultValue'] as String?,
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

  /// Condition expression for early termination.
  final String exitGate;

  const WorkflowLoop({
    required this.id,
    required this.steps,
    required this.maxIterations,
    required this.exitGate,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'steps': List<String>.from(steps),
    'maxIterations': maxIterations,
    'exitGate': exitGate,
  };

  factory WorkflowLoop.fromJson(Map<String, dynamic> json) =>
      WorkflowLoop(
        id: json['id'] as String,
        steps: (json['steps'] as List).cast<String>(),
        maxIterations: json['maxIterations'] as int,
        exitGate: json['exitGate'] as String,
      );
}

/// A single step within a workflow definition.
class WorkflowStep {
  /// Unique identifier within the workflow.
  final String id;

  /// Human-readable step name.
  final String name;

  /// Prompt template with `{{variable}}` and `{{context.key}}` references.
  final String prompt;

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

  /// Optional per-step token budget.
  final int? maxTokens;

  /// Optional per-step retry limit.
  final int? maxRetries;

  /// Optional per-step tool allowlist.
  final List<String>? allowedTools;

  const WorkflowStep({
    required this.id,
    required this.name,
    required this.prompt,
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
    this.maxTokens,
    this.maxRetries,
    this.allowedTools,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'prompt': prompt,
    'type': type,
    'review': review.name,
    'parallel': parallel,
    if (project != null) 'project': project,
    if (provider != null) 'provider': provider,
    if (model != null) 'model': model,
    if (timeoutSeconds != null) 'timeout': timeoutSeconds,
    if (gate != null) 'gate': gate,
    'contextInputs': List<String>.from(contextInputs),
    'contextOutputs': List<String>.from(contextOutputs),
    if (extraction != null) 'extraction': extraction!.toJson(),
    if (maxTokens != null) 'maxTokens': maxTokens,
    if (maxRetries != null) 'maxRetries': maxRetries,
    if (allowedTools != null) 'allowedTools': List<String>.from(allowedTools!),
  };

  factory WorkflowStep.fromJson(Map<String, dynamic> json) => WorkflowStep(
    id: json['id'] as String,
    name: json['name'] as String,
    prompt: json['prompt'] as String,
    type: (json['type'] as String?) ?? 'research',
    project: json['project'] as String?,
    provider: json['provider'] as String?,
    model: json['model'] as String?,
    timeoutSeconds: json['timeout'] as int?,
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
    maxTokens: json['maxTokens'] as int?,
    maxRetries: json['maxRetries'] as int?,
    allowedTools: (json['allowedTools'] as List?)?.cast<String>(),
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

  /// Optional workflow-level token budget ceiling.
  final int? maxTokens;

  const WorkflowDefinition({
    required this.name,
    required this.description,
    this.variables = const {},
    required this.steps,
    this.loops = const [],
    this.maxTokens,
  });

  Map<String, dynamic> toJson() => {
    'name': name,
    'description': description,
    'variables': variables.map((k, v) => MapEntry(k, v.toJson())),
    'steps': steps.map((s) => s.toJson()).toList(),
    'loops': loops.map((l) => l.toJson()).toList(),
    if (maxTokens != null) 'maxTokens': maxTokens,
  };

  factory WorkflowDefinition.fromJson(Map<String, dynamic> json) =>
      WorkflowDefinition(
        name: json['name'] as String,
        description: json['description'] as String,
        variables: (json['variables'] as Map<String, dynamic>?)?.map(
              (k, v) => MapEntry(k, WorkflowVariable.fromJson(v as Map<String, dynamic>)),
            ) ??
            const {},
        steps: (json['steps'] as List)
            .map((s) => WorkflowStep.fromJson(s as Map<String, dynamic>))
            .toList(growable: false),
        loops: (json['loops'] as List?)
                ?.map((l) => WorkflowLoop.fromJson(l as Map<String, dynamic>))
                .toList(growable: false) ??
            const [],
        maxTokens: json['maxTokens'] as int?,
      );
}
