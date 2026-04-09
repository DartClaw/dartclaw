/// Source location where a skill was discovered.
enum SkillSource {
  /// `<projectDir>/.claude/skills/` -- project-scoped, Claude Code harness.
  projectClaude,

  /// `<projectDir>/.agents/skills/` -- project-scoped, Codex harness.
  projectCodex,

  /// `<workspace>/skills/` -- workspace-scoped, DartClaw-managed.
  workspace,

  /// `~/.claude/skills/` -- user-scoped, Claude Code harness.
  userClaude,

  /// `<dataDir>/skills/` -- user-scoped, DartClaw-managed.
  userDartclaw,

  /// Plugin skill directories -- plugin-namespaced.
  plugin;

  String get displayName => switch (this) {
    projectClaude => 'project (.claude)',
    projectCodex => 'project (.agents)',
    workspace => 'workspace',
    userClaude => 'user (.claude)',
    userDartclaw => 'user (dartclaw)',
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

  const SkillInfo({
    required this.name,
    required this.description,
    required this.source,
    required this.path,
    this.nativeHarnesses = const {},
  });

  /// Creates a copy with merged harness sets (used during deduplication).
  SkillInfo mergeHarnesses(Set<String> additional) => SkillInfo(
    name: name,
    description: description,
    source: source,
    path: path,
    nativeHarnesses: {...nativeHarnesses, ...additional},
  );

  Map<String, dynamic> toJson() => {
    'name': name,
    'description': description,
    'source': source.name,
    'path': path,
    'nativeHarnesses': nativeHarnesses.toList()..sort(),
  };

  factory SkillInfo.fromJson(Map<String, dynamic> json) => SkillInfo(
    name: json['name'] as String,
    description: (json['description'] as String?) ?? '',
    source: SkillSource.values.byName(json['source'] as String),
    path: json['path'] as String,
    nativeHarnesses: (json['nativeHarnesses'] as List?)?.cast<String>().toSet() ?? const {},
  );
}
