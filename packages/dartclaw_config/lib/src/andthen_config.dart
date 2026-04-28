/// Where AndThen-derived skills are installed at `dartclaw serve` startup.
enum AndthenInstallScope {
  /// Install into `<dataDir>/.agents/skills`, `<dataDir>/.claude/skills`,
  /// `<dataDir>/.claude/agents`. Discoverable by spawned agents whose CWD is a
  /// descendant of `<dataDir>` via CWD-walk-up + Codex defaults.
  dataDir,

  /// Install into the user-tier defaults (`~/.claude/skills`, `~/.claude/agents`,
  /// `~/.agents/skills`) via `install-skills.sh --claude-user`. Picked up by
  /// Claude Code / Codex regardless of agent CWD.
  user,

  /// Run both passes — one for `<dataDir>` and one for user-tier — each with
  /// its own marker file and completeness check.
  both,
}

/// Network-acquisition policy for the AndThen source clone.
enum AndthenNetworkPolicy {
  /// Try network first, fall back to the cached source on failure.
  auto,

  /// Fail startup if the network clone/pull cannot complete.
  required,

  /// Skip clone/pull entirely; require a pre-staged `<dataDir>/andthen-src/`.
  disabled,
}

/// Configuration for the AndThen-skills runtime provisioning subsystem.
///
/// At `dartclaw serve` startup, [SkillProvisioner] (in `dartclaw_workflow`)
/// uses this config to clone AndThen, run AndThen's own `install-skills.sh
/// --prefix dartclaw-`, and copy the DC-native skills into the same scope(s).
///
/// All four fields require a server restart to change — see
/// `ConfigNotifier.nonReloadableKeys`.
class AndthenConfig {
  /// Upstream git URL to clone.
  final String gitUrl;

  /// Ref to check out. `latest` means "fetch + fast-forward `main`"; any other
  /// value is treated as a tag, branch, or 40-character SHA passed to
  /// `git checkout`.
  final String ref;

  /// Where AndThen-derived skills are installed.
  final AndthenInstallScope installScope;

  /// How the source clone is acquired/refreshed at startup.
  final AndthenNetworkPolicy network;

  const AndthenConfig({
    this.gitUrl = 'https://github.com/IT-HUSET/andthen',
    this.ref = 'latest',
    this.installScope = AndthenInstallScope.dataDir,
    this.network = AndthenNetworkPolicy.auto,
  });

  /// All defaults.
  const AndthenConfig.defaults() : this();

  AndthenConfig copyWith({
    String? gitUrl,
    String? ref,
    AndthenInstallScope? installScope,
    AndthenNetworkPolicy? network,
  }) => AndthenConfig(
    gitUrl: gitUrl ?? this.gitUrl,
    ref: ref ?? this.ref,
    installScope: installScope ?? this.installScope,
    network: network ?? this.network,
  );

  Map<String, Object?> toJson() => {
    'git_url': gitUrl,
    'ref': ref,
    'install_scope': installScope.yamlValue,
    'network': network.yamlValue,
  };

  factory AndthenConfig.fromJson(Map<String, Object?> json) => AndthenConfig(
    gitUrl: (json['git_url'] as String?) ?? const AndthenConfig().gitUrl,
    ref: (json['ref'] as String?) ?? const AndthenConfig().ref,
    installScope: parseAndthenInstallScope(json['install_scope']) ?? AndthenInstallScope.dataDir,
    network: parseAndthenNetworkPolicy(json['network']) ?? AndthenNetworkPolicy.auto,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AndthenConfig &&
          gitUrl == other.gitUrl &&
          ref == other.ref &&
          installScope == other.installScope &&
          network == other.network;

  @override
  int get hashCode => Object.hash(gitUrl, ref, installScope, network);
}

/// YAML keys for the `install_scope` enum.
extension AndthenInstallScopeYaml on AndthenInstallScope {
  String get yamlValue => switch (this) {
    AndthenInstallScope.dataDir => 'data_dir',
    AndthenInstallScope.user => 'user',
    AndthenInstallScope.both => 'both',
  };
}

/// YAML keys for the `network` enum.
extension AndthenNetworkPolicyYaml on AndthenNetworkPolicy {
  String get yamlValue => switch (this) {
    AndthenNetworkPolicy.auto => 'auto',
    AndthenNetworkPolicy.required => 'required',
    AndthenNetworkPolicy.disabled => 'disabled',
  };
}

/// Parses [value] into an [AndthenInstallScope]. Returns `null` if [value] is
/// not a recognized YAML token.
AndthenInstallScope? parseAndthenInstallScope(Object? value) {
  if (value is! String) return null;
  return switch (value) {
    'data_dir' => AndthenInstallScope.dataDir,
    'user' => AndthenInstallScope.user,
    'both' => AndthenInstallScope.both,
    _ => null,
  };
}

/// Parses [value] into an [AndthenNetworkPolicy]. Returns `null` if [value] is
/// not a recognized YAML token.
AndthenNetworkPolicy? parseAndthenNetworkPolicy(Object? value) {
  if (value is! String) return null;
  return switch (value) {
    'auto' => AndthenNetworkPolicy.auto,
    'required' => AndthenNetworkPolicy.required,
    'disabled' => AndthenNetworkPolicy.disabled,
    _ => null,
  };
}
