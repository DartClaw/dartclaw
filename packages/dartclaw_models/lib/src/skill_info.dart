import 'workflow_definition.dart' show OutputConfig;

/// Source location where a skill was discovered.
enum SkillSource {
  /// `<projectDir>/.claude/skills/` -- project-scoped, Claude Code harness.
  projectClaude,

  /// `<projectDir>/.agents/skills/` -- project-scoped, non-Claude harnesses.
  projectAgents,

  /// `<workspace>/skills/` -- workspace-scoped, DartClaw-managed.
  workspace,

  /// `<dataDir>/.claude/skills/` / `<dataDir>/.agents/skills/` -- data-dir scoped native harness roots.
  dataDirNative,

  /// `~/.claude/skills/` -- user-scoped, Claude Code harness.
  userClaude,

  /// `~/.agents/skills/` -- user-scoped, non-Claude harnesses.
  userAgents,

  /// `<dataDir>/skills/` -- user-scoped, DartClaw-managed.
  userDartclaw,

  /// `<repo>/packages/dartclaw_workflow/skills/` -- repo-managed built-ins.
  dartclaw,

  /// Plugin skill directories -- plugin-namespaced.
  plugin;

  String get displayName => switch (this) {
    projectClaude => 'project (.claude)',
    projectAgents => 'project (.agents)',
    workspace => 'workspace',
    dataDirNative => 'data dir native',
    userClaude => 'user (.claude)',
    userAgents => 'user (.agents)',
    userDartclaw => 'user (dartclaw)',
    dartclaw => 'DartClaw Built-in',
    plugin => 'plugin',
  };
}

/// Metadata for a discovered Agent Skills-compatible skill definition.
///
/// Immutable value object. DartClaw never reads full skill content --
/// only name, description, and source metadata from YAML frontmatter.
class SkillInfo {
  /// Skill name (from frontmatter or directory name).
  final String name;

  /// Human-readable description (from YAML frontmatter).
  final String description;

  /// Where the skill was discovered.
  final SkillSource source;

  /// Filesystem path to the skill directory.
  final String path;

  /// Set of provider identifiers where the skill is natively installed
  /// (e.g. `{'claude'}`, `{'claude', 'codex'}`).
  final Set<String> nativeHarnesses;

  /// Default workflow-step prompt declared in the skill's `workflow:` frontmatter block.
  ///
  /// Used by `SkillPromptBuilder` as the base prompt when a workflow step references
  /// this skill and declares no `prompt:` of its own. Null when the frontmatter omits
  /// the `workflow.default_prompt` key.
  final String? defaultPrompt;

  /// Default per-output configurations declared in the skill's `workflow:` frontmatter block.
  ///
  /// Used by the step-config resolution path to fill in `outputs:` when a workflow step
  /// references this skill and declares no `outputs:` of its own. Null when the frontmatter
  /// omits the `workflow.default_outputs` key.
  final Map<String, OutputConfig>? defaultOutputs;

  /// Whether this skill emits its own `<step-outcome>` marker.
  ///
  /// When true the workflow prompt augmenter suppresses the built-in outcome
  /// protocol instructions and lets the skill produce the marker itself.
  final bool emitsOwnOutcome;

  const SkillInfo({
    required this.name,
    required this.description,
    required this.source,
    required this.path,
    this.nativeHarnesses = const {},
    this.defaultPrompt,
    this.defaultOutputs,
    this.emitsOwnOutcome = false,
  });

  /// Creates a copy with merged harness sets (used during deduplication).
  SkillInfo mergeHarnesses(Set<String> additional) => SkillInfo(
    name: name,
    description: description,
    source: source,
    path: path,
    nativeHarnesses: {...nativeHarnesses, ...additional},
    defaultPrompt: defaultPrompt,
    defaultOutputs: defaultOutputs,
    emitsOwnOutcome: emitsOwnOutcome,
  );

  Map<String, dynamic> toJson() => {
    'name': name,
    'description': description,
    'source': source.name,
    'path': path,
    'nativeHarnesses': nativeHarnesses.toList()..sort(),
    if (defaultPrompt != null) 'defaultPrompt': defaultPrompt,
    if (defaultOutputs != null) 'defaultOutputs': defaultOutputs!.map((k, v) => MapEntry(k, v.toJson())),
    if (emitsOwnOutcome) 'emitsOwnOutcome': true,
  };

  factory SkillInfo.fromJson(Map<String, dynamic> json) => SkillInfo(
    name: json['name'] as String,
    description: (json['description'] as String?) ?? '',
    source: SkillSource.values.byName(json['source'] as String),
    path: json['path'] as String,
    nativeHarnesses: (json['nativeHarnesses'] as List?)?.cast<String>().toSet() ?? const {},
    defaultPrompt: json['defaultPrompt'] as String?,
    defaultOutputs: (json['defaultOutputs'] as Map<String, dynamic>?)?.map(
      (k, v) => MapEntry(k, OutputConfig.fromJson(v as Map<String, dynamic>)),
    ),
    emitsOwnOutcome: (json['emitsOwnOutcome'] as bool?) ?? false,
  );
}
