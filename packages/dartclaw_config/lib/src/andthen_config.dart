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
/// --prefix dartclaw- --claude-user`, and copy the DC-native skills into the
/// same user-tier native skill roots.
///
/// All three fields require a server restart to change — see
/// `ConfigNotifier.nonReloadableKeys`.
class AndthenConfig {
  /// Upstream git URL to clone.
  final String gitUrl;

  /// Ref to check out. `latest` means "fetch + fast-forward `main`"; any other
  /// value is treated as a tag, branch, or 40-character SHA passed to
  /// `git checkout`.
  final String ref;

  /// How the source clone is acquired/refreshed at startup.
  final AndthenNetworkPolicy network;

  const AndthenConfig({
    this.gitUrl = 'https://github.com/IT-HUSET/andthen',
    this.ref = 'latest',
    this.network = AndthenNetworkPolicy.auto,
  });

  /// All defaults.
  const AndthenConfig.defaults() : this();

  AndthenConfig copyWith({String? gitUrl, String? ref, AndthenNetworkPolicy? network}) =>
      AndthenConfig(gitUrl: gitUrl ?? this.gitUrl, ref: ref ?? this.ref, network: network ?? this.network);

  Map<String, Object?> toJson() => {'git_url': gitUrl, 'ref': ref, 'network': network.yamlValue};

  factory AndthenConfig.fromJson(Map<String, Object?> json) => AndthenConfig(
    gitUrl: (json['git_url'] as String?) ?? const AndthenConfig().gitUrl,
    ref: (json['ref'] as String?) ?? const AndthenConfig().ref,
    network: parseAndthenNetworkPolicy(json['network']) ?? AndthenNetworkPolicy.auto,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AndthenConfig && gitUrl == other.gitUrl && ref == other.ref && network == other.network;

  @override
  int get hashCode => Object.hash(gitUrl, ref, network);
}

/// YAML keys for the `network` enum.
extension AndthenNetworkPolicyYaml on AndthenNetworkPolicy {
  String get yamlValue => switch (this) {
    AndthenNetworkPolicy.auto => 'auto',
    AndthenNetworkPolicy.required => 'required',
    AndthenNetworkPolicy.disabled => 'disabled',
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
