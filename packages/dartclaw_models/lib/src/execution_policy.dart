/// Where an agent process runs.
///
/// Execution mode is independent of the container security profile: a profile
/// describes a container's filesystem and capability posture and is meaningful
/// only for [ExecutionMode.container].
enum ExecutionMode {
  /// The harness process runs directly on the host.
  host,

  /// The harness process runs inside a container.
  container;

  /// Parses a YAML scalar, returning `null` for unrecognized values.
  static ExecutionMode? fromYaml(String value) => switch (value.trim().toLowerCase()) {
    'host' => ExecutionMode.host,
    'container' => ExecutionMode.container,
    _ => null,
  };

  /// The canonical YAML spelling.
  String toYaml() => name;

  /// Accepted YAML values, for diagnostics.
  static const acceptedYamlValues = ['host', 'container'];
}

/// A complete, validated execution placement decision.
///
/// Carries both policy axes so no consumer has to infer placement from the
/// presence of a container manager or from a profile label. The invariant
/// `containerProfile != null` iff `mode == ExecutionMode.container` is enforced
/// by the constructors.
final class ExecutionPolicy {
  /// Host execution. Carries no container profile.
  const ExecutionPolicy.host() : mode = ExecutionMode.host, containerProfile = null;

  /// Container execution within [containerProfile].
  const ExecutionPolicy.container(String this.containerProfile) : mode = ExecutionMode.container;

  /// Where the harness process runs.
  final ExecutionMode mode;

  /// Container filesystem/capability profile, or `null` for host execution.
  final String? containerProfile;

  /// Whether this policy places the harness inside a container.
  bool get isContainer => mode == ExecutionMode.container;

  /// Serializes to a JSON-safe map, omitting the profile for host execution.
  Map<String, dynamic> toJson() => {
    'mode': mode.name,
    if (containerProfile != null) 'containerProfile': containerProfile,
  };

  /// Reconstructs a policy from [toJson] output.
  ///
  /// Throws [FormatException] when the mode is unknown or the profile
  /// contradicts the mode.
  factory ExecutionPolicy.fromJson(Map<String, dynamic> json) {
    final rawMode = json['mode'];
    final mode = rawMode is String ? ExecutionMode.fromYaml(rawMode) : null;
    if (mode == null) throw FormatException('Unknown execution mode: $rawMode');
    final profile = json['containerProfile'] as String?;
    return ExecutionPolicy.of(mode, profile);
  }

  /// Builds a policy from its two axes, enforcing the mode/profile invariant.
  ///
  /// Throws [FormatException] when a profile is supplied for host execution or
  /// omitted for container execution.
  factory ExecutionPolicy.of(ExecutionMode mode, String? containerProfile) {
    switch (mode) {
      case ExecutionMode.host:
        if (containerProfile != null) {
          throw FormatException('Host execution cannot carry container profile "$containerProfile"');
        }
        return const ExecutionPolicy.host();
      case ExecutionMode.container:
        if (containerProfile == null) {
          throw const FormatException('Container execution requires a container profile');
        }
        return ExecutionPolicy.container(containerProfile);
    }
  }

  /// Operator-facing rendering of both axes, e.g. `container/restricted`.
  String describe() => containerProfile == null ? mode.name : '${mode.name}/$containerProfile';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ExecutionPolicy && mode == other.mode && containerProfile == other.containerProfile;

  @override
  int get hashCode => Object.hash(mode, containerProfile);

  @override
  String toString() => 'ExecutionPolicy(${describe()})';
}
