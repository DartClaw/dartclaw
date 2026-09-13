import 'schema_presets.dart';
import 'step_config_resolver.dart';
import 'workflow_definition.dart';

enum WorkflowValueKind { string, boolean, integer, number, stringList, mapping, list, nullValue }

class WorkflowFieldRule {
  final List<String> names;
  final List<WorkflowValueKind> kinds;
  final List<WorkflowValueKind> coercedKinds;
  final List<WorkflowValueKind> ignoredKinds;
  final List<Object?> ignoredValues;
  final Map<WorkflowValueKind, List<WorkflowTaskType>> kindApplicableTypes;
  final bool required;
  final List<WorkflowTaskType> requiredForTypes;
  final List<String> alternatives;
  final Iterable<Object> enumValues;
  final List<WorkflowTaskType> applicableTypes;
  final List<String> mutuallyExclusiveWith;
  final int? maxOutputs;

  const new(
    this.names,
    this.kinds, {
    this.coercedKinds = const [],
    this.ignoredKinds = const [],
    this.ignoredValues = const [],
    this.kindApplicableTypes = const {},
    this.required = false,
    this.requiredForTypes = const [],
    this.alternatives = const [],
    this.enumValues = const [],
    this.applicableTypes = const [],
    this.mutuallyExclusiveWith = const [],
    this.maxOutputs,
  });

  // Optional YAML fields normalize explicit null as omission.
  Iterable<WorkflowValueKind> get acceptedKinds => {
    ...kinds,
    ...coercedKinds,
    ...ignoredKinds,
    if (!required) WorkflowValueKind.nullValue,
  };

  bool appliesTo(WorkflowTaskType type) => applicableTypes.isEmpty || applicableTypes.contains(type);

  bool acceptsKindForType(WorkflowValueKind kind, WorkflowTaskType type) {
    if (!acceptedKinds.contains(kind)) return false;
    final types = kindApplicableTypes[kind] ?? applicableTypes;
    return types.isEmpty || types.contains(type);
  }

  bool requiresValueFor(WorkflowTaskType type) => required || requiredForTypes.contains(type);
}

class WorkflowBlockRule {
  final String name;
  final List<WorkflowFieldRule> fields;

  const new(this.name, this.fields);

  Iterable<String> get keys => fields.expand((field) => field.names);

  WorkflowFieldRule field(String name) => fields.firstWhere((field) => field.names.contains(name));
}

class WorkflowRequiredOutputRule {
  final String key;
  final OutputFormat format;
  final String preset;

  const new(this.key, this.format, this.preset);
}

abstract final class WorkflowDslRules {
  static const _ignoredYamlKinds = [
    WorkflowValueKind.boolean,
    WorkflowValueKind.number,
    WorkflowValueKind.mapping,
    WorkflowValueKind.list,
  ];

  static const workflow = WorkflowBlockRule('workflow', [
    WorkflowFieldRule(['name'], [WorkflowValueKind.string], required: true),
    WorkflowFieldRule(['description'], [WorkflowValueKind.string], required: true),
    WorkflowFieldRule(['variables'], [WorkflowValueKind.mapping]),
    WorkflowFieldRule(['steps'], [WorkflowValueKind.list], required: true),
    WorkflowFieldRule(['maxTokens'], [WorkflowValueKind.integer]),
    WorkflowFieldRule(['project'], [WorkflowValueKind.string]),
    WorkflowFieldRule(['stepDefaults'], [WorkflowValueKind.list]),
    WorkflowFieldRule(['gitStrategy'], [WorkflowValueKind.mapping]),
  ]);

  static const variable = WorkflowBlockRule('variable', [
    WorkflowFieldRule(['required'], [WorkflowValueKind.boolean]),
    WorkflowFieldRule(['description'], [WorkflowValueKind.string]),
    WorkflowFieldRule(['default'], [WorkflowValueKind.string]),
  ]);

  static const step = WorkflowBlockRule('step', [
    WorkflowFieldRule(['id'], [WorkflowValueKind.string], required: true),
    WorkflowFieldRule(['name'], [WorkflowValueKind.string], required: true),
    WorkflowFieldRule(['skill'], [WorkflowValueKind.string]),
    WorkflowFieldRule(['type'], [WorkflowValueKind.string], enumValues: WorkflowTaskType.values),
    WorkflowFieldRule(
      ['prompt'],
      [WorkflowValueKind.stringList],
      coercedKinds: [WorkflowValueKind.string],
      kindApplicableTypes: {
        WorkflowValueKind.stringList: [
          WorkflowTaskType.agent,
          WorkflowTaskType.foreach,
          WorkflowTaskType.loop,
          WorkflowTaskType.aggregateReviews,
        ],
      },
      requiredForTypes: [WorkflowTaskType.agent],
      alternatives: ['skill'],
      mutuallyExclusiveWith: ['script'],
    ),
    WorkflowFieldRule(['script'], [WorkflowValueKind.string], applicableTypes: [WorkflowTaskType.bash]),
    WorkflowFieldRule(['provider'], [WorkflowValueKind.string]),
    WorkflowFieldRule(['model'], [WorkflowValueKind.string]),
    WorkflowFieldRule(['effort'], [WorkflowValueKind.string]),
    WorkflowFieldRule(
      ['timeout', 'timeoutSeconds', 'timeout_seconds'],
      [WorkflowValueKind.integer],
      coercedKinds: [WorkflowValueKind.string],
      ignoredKinds: _ignoredYamlKinds,
      applicableTypes: [
        WorkflowTaskType.bash,
        WorkflowTaskType.approval,
        WorkflowTaskType.foreach,
        WorkflowTaskType.loop,
        WorkflowTaskType.aggregateReviews,
      ],

      kindApplicableTypes: {WorkflowValueKind.nullValue: WorkflowTaskType.values},
    ),
    WorkflowFieldRule(
      ['turn_timeout'],
      [WorkflowValueKind.integer],
      coercedKinds: [WorkflowValueKind.string],
      applicableTypes: [WorkflowTaskType.agent],

      kindApplicableTypes: {WorkflowValueKind.nullValue: WorkflowTaskType.values},
    ),
    WorkflowFieldRule(
      ['parallel'],
      [WorkflowValueKind.boolean],
      applicableTypes: [
        WorkflowTaskType.agent,
        WorkflowTaskType.bash,
        WorkflowTaskType.foreach,
        WorkflowTaskType.loop,
        WorkflowTaskType.aggregateReviews,
      ],
      mutuallyExclusiveWith: ['continueSession', 'continue_session'],

      kindApplicableTypes: {WorkflowValueKind.nullValue: WorkflowTaskType.values},
      ignoredValues: [false, null],
    ),
    WorkflowFieldRule(['entryGate'], [WorkflowValueKind.string]),
    WorkflowFieldRule(['inputs'], [WorkflowValueKind.stringList]),
    WorkflowFieldRule(['outputs'], [WorkflowValueKind.mapping]),
    WorkflowFieldRule(['maxRetries'], [WorkflowValueKind.integer]),
    WorkflowFieldRule(['allowedTools'], [WorkflowValueKind.stringList]),
    WorkflowFieldRule(['aggregateReviews'], [WorkflowValueKind.stringList]),
    WorkflowFieldRule(
      ['map_over', 'mapOver'],
      [WorkflowValueKind.string],
      mutuallyExclusiveWith: ['parallel'],
      ignoredValues: [null],
      maxOutputs: 1,
    ),
    WorkflowFieldRule(['max_parallel', 'maxParallel'], [WorkflowValueKind.integer, WorkflowValueKind.string]),
    WorkflowFieldRule(
      ['foreach_steps', 'foreachSteps'],
      [WorkflowValueKind.stringList],
      ignoredKinds: [
        WorkflowValueKind.string,
        WorkflowValueKind.boolean,
        WorkflowValueKind.integer,
        WorkflowValueKind.number,
        WorkflowValueKind.mapping,
      ],
    ),
    WorkflowFieldRule(
      ['continueSession', 'continue_session'],
      [WorkflowValueKind.string, WorkflowValueKind.boolean],
      applicableTypes: [
        WorkflowTaskType.agent,
        WorkflowTaskType.foreach,
        WorkflowTaskType.loop,
        WorkflowTaskType.aggregateReviews,
      ],

      kindApplicableTypes: {WorkflowValueKind.nullValue: WorkflowTaskType.values},
      ignoredValues: [false, null],
    ),
    WorkflowFieldRule(['onError', 'on_error'], [WorkflowValueKind.string], enumValues: OnErrorPolicy.yamlValues),
    WorkflowFieldRule(['workdir'], [WorkflowValueKind.string]),
    WorkflowFieldRule(['onFailure', 'on_failure'], [WorkflowValueKind.string], enumValues: OnFailurePolicy.yamlValues),
    WorkflowFieldRule(['emitsOwnOutcome', 'emits_own_outcome'], [WorkflowValueKind.boolean]),
    WorkflowFieldRule(['auto_frame_context', 'autoFrameContext'], [WorkflowValueKind.boolean]),
    WorkflowFieldRule(['workflow_variables', 'workflowVariables'], [WorkflowValueKind.stringList]),
  ]);

  static const inlineForeach = WorkflowBlockRule('inlineForeach', [
    WorkflowFieldRule(['id'], [WorkflowValueKind.string], required: true),
    WorkflowFieldRule(['name'], [WorkflowValueKind.string], required: true),
    WorkflowFieldRule(['type'], [WorkflowValueKind.string], required: true, enumValues: [WorkflowTaskType.foreach]),
    WorkflowFieldRule(['map_over', 'mapOver'], [WorkflowValueKind.string], required: true),
    WorkflowFieldRule(['max_parallel', 'maxParallel'], [WorkflowValueKind.integer, WorkflowValueKind.string]),
    WorkflowFieldRule(['entryGate'], [WorkflowValueKind.string]),
    WorkflowFieldRule(['inputs'], [WorkflowValueKind.stringList]),
    WorkflowFieldRule(['outputs'], [WorkflowValueKind.mapping]),
    WorkflowFieldRule(['steps'], [WorkflowValueKind.list], required: true),
    WorkflowFieldRule(['onFailure', 'on_failure'], [WorkflowValueKind.string], enumValues: OnFailurePolicy.yamlValues),
    WorkflowFieldRule(['workflow_variables', 'workflowVariables'], [WorkflowValueKind.stringList]),
  ]);

  static const inlineLoop = WorkflowBlockRule('inlineLoop', [
    WorkflowFieldRule(['id'], [WorkflowValueKind.string], required: true),
    WorkflowFieldRule(['name'], [WorkflowValueKind.string], required: true),
    WorkflowFieldRule(['type'], [WorkflowValueKind.string], required: true, enumValues: [WorkflowTaskType.loop]),
    WorkflowFieldRule(['maxIterations'], [WorkflowValueKind.integer], required: true),
    WorkflowFieldRule(['entryGate'], [WorkflowValueKind.string]),
    WorkflowFieldRule(['exitGate'], [WorkflowValueKind.string], required: true),
    WorkflowFieldRule(['steps'], [WorkflowValueKind.list], required: true),
    WorkflowFieldRule(['onMaxIterations'], [WorkflowValueKind.string], enumValues: loopMaxIterationsPolicies),
  ]);

  static const output = WorkflowBlockRule('output', [
    WorkflowFieldRule(['format'], [WorkflowValueKind.string], enumValues: OutputFormat.values),
    WorkflowFieldRule(
      ['schema'],
      [WorkflowValueKind.string],
      coercedKinds: [WorkflowValueKind.mapping],
      ignoredKinds: [
        WorkflowValueKind.boolean,
        WorkflowValueKind.integer,
        WorkflowValueKind.number,
        WorkflowValueKind.list,
      ],
    ),
    WorkflowFieldRule(['source'], [WorkflowValueKind.string]),
    WorkflowFieldRule(['description'], [WorkflowValueKind.string]),
    WorkflowFieldRule(['pathPattern', 'path_pattern'], [WorkflowValueKind.string]),
    WorkflowFieldRule(['preferPatterns', 'prefer_patterns'], [WorkflowValueKind.stringList]),
  ]);

  static const stepDefault = WorkflowBlockRule('stepDefault', [
    WorkflowFieldRule(['match'], [WorkflowValueKind.string], required: true),
    WorkflowFieldRule(['provider'], [WorkflowValueKind.string]),
    WorkflowFieldRule(['model'], [WorkflowValueKind.string]),
    WorkflowFieldRule(['effort'], [WorkflowValueKind.string]),
    WorkflowFieldRule(['maxRetries'], [WorkflowValueKind.integer]),
    WorkflowFieldRule(['timeout', 'timeout_seconds', 'timeoutSeconds'], [WorkflowValueKind.integer]),
    WorkflowFieldRule(['turn_timeout'], [WorkflowValueKind.integer], coercedKinds: [WorkflowValueKind.string]),
    WorkflowFieldRule(['allowedTools'], [WorkflowValueKind.stringList]),
  ]);

  static const gitStrategy = WorkflowBlockRule('gitStrategy', [
    WorkflowFieldRule(['integrationBranch', 'integration_branch'], [WorkflowValueKind.boolean]),
    WorkflowFieldRule(['bootstrap'], [WorkflowValueKind.boolean]),
    WorkflowFieldRule(['worktree'], [WorkflowValueKind.string, WorkflowValueKind.mapping]),
    WorkflowFieldRule(['promotion'], [WorkflowValueKind.string], enumValues: ['merge', 'rebase', 'none']),
    WorkflowFieldRule(['publish'], [WorkflowValueKind.mapping]),
    WorkflowFieldRule(['cleanup'], [WorkflowValueKind.mapping]),
    WorkflowFieldRule(['artifacts'], [WorkflowValueKind.mapping]),
    WorkflowFieldRule(
      ['merge_resolve', 'mergeResolve'],
      [WorkflowValueKind.mapping],
      ignoredKinds: [
        WorkflowValueKind.string,
        WorkflowValueKind.boolean,
        WorkflowValueKind.integer,
        WorkflowValueKind.number,
        WorkflowValueKind.list,
      ],
    ),
  ]);

  static const gitPublish = WorkflowBlockRule('gitPublish', [
    WorkflowFieldRule(['enabled'], [WorkflowValueKind.boolean]),
  ]);
  static const gitCleanup = WorkflowBlockRule('gitCleanup', [
    WorkflowFieldRule(['enabled'], [WorkflowValueKind.boolean]),
  ]);
  static const gitArtifacts = WorkflowBlockRule('gitArtifacts', [
    WorkflowFieldRule(['commit'], [WorkflowValueKind.boolean]),
    WorkflowFieldRule(['commitMessage', 'commit_message'], [WorkflowValueKind.string]),
    WorkflowFieldRule(['project'], [WorkflowValueKind.string]),
  ]);
  static const gitWorktree = WorkflowBlockRule('gitWorktree', [
    WorkflowFieldRule(['mode'], [WorkflowValueKind.string], enumValues: WorkflowGitWorktreeMode.values),
  ]);
  static const mergeResolve = WorkflowBlockRule('mergeResolve', [
    WorkflowFieldRule(['enabled'], [WorkflowValueKind.boolean]),
    WorkflowFieldRule(['max_attempts'], [WorkflowValueKind.integer]),
    WorkflowFieldRule(['token_ceiling'], [WorkflowValueKind.integer]),
    WorkflowFieldRule(['escalation'], [WorkflowValueKind.string], enumValues: MergeResolveEscalation.values),
  ]);

  static const blocks = [
    workflow,
    variable,
    step,
    inlineForeach,
    inlineLoop,
    output,
    stepDefault,
    gitStrategy,
    gitPublish,
    gitCleanup,
    gitArtifacts,
    gitWorktree,
    mergeResolve,
  ];

  static const roleAliases = workflowRoleDefaultAliases;
  static const warnsInLoopTypes = [WorkflowTaskType.approval];

  static const loopMaxIterationsPolicies = [
    WorkflowLoop.onMaxIterationsFail,
    WorkflowLoop.onMaxIterationsContinue,
    WorkflowLoop.onMaxIterationsEscalate,
  ];

  static const aggregateReviewOutputs = [
    WorkflowRequiredOutputRule('review_report_path', OutputFormat.path, 'review_report_path'),
    WorkflowRequiredOutputRule('findings_count', OutputFormat.json, 'findings_count'),
    WorkflowRequiredOutputRule('gating_findings_count', OutputFormat.json, 'gating_findings_count'),
  ];

  static const outputShorthandValues = [...OutputFormat.values, ...schemaPresetValues];
}
