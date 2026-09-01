/// Configuration for container isolation.
class ContainerConfig {
  /// The posture the operator declared, or `null` when the config declares
  /// none — which startup resolution settles by probing for a runtime.
  ///
  /// The requested-vs-inferred asymmetry keys off this: an explicit `true`
  /// keeps every fail-closed refusal, an inferred posture downgrades.
  final bool? declaredEnabled;

  /// The posture in force. Before startup resolution this is
  /// [declaredEnabled] or `false`; resolution replaces it with the settled
  /// answer, so every downstream reader sees a plain boolean.
  final bool enabled;

  /// Container image used for isolated agent execution.
  final String image;

  /// The container CLI every runtime call goes through, chosen once by the
  /// startup probe. Resolution output rather than a YAML key.
  final String runtimeBinary;

  /// Creates container isolation configuration; [enabled] omitted means unset.
  const new({bool? enabled, this.image = 'dartclaw-agent:latest', this.runtimeBinary = 'docker'})
    : declaredEnabled = enabled,
      enabled = enabled ?? false;

  const new _({required this.declaredEnabled, required this.enabled, required this.image, required this.runtimeBinary});

  /// Creates a configuration that declares isolation off.
  const new disabled() : this(enabled: false);

  /// The posture startup resolution settled on, and the runtime that answered.
  ContainerConfig resolved({required bool enabled, String? runtimeBinary}) => ContainerConfig._(
    declaredEnabled: declaredEnabled,
    enabled: enabled,
    image: image,
    runtimeBinary: runtimeBinary ?? this.runtimeBinary,
  );

  /// Keys this parser reads; anything else is reported rather than ignored.
  static const knownKeys = {'enabled', 'image'};

  /// Parses container configuration from YAML, appending warnings to [warns].
  factory fromYaml(Map<String, dynamic> yaml, List<String> warns) {
    for (final key in yaml.keys) {
      if (!knownKeys.contains(key)) warns.add('Unknown config key: container.$key');
    }
    final enabled = yaml['enabled'];
    if (enabled != null && enabled is! bool) {
      warns.add('Invalid type for container.enabled: "${enabled.runtimeType}" — using default');
    }
    final image = yaml['image'];
    if (image != null && image is! String) {
      warns.add('Invalid type for container.image: "${image.runtimeType}" — using default');
    }

    return ContainerConfig(
      enabled: enabled is bool ? enabled : null,
      image: image is String ? image : 'dartclaw-agent:latest',
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ContainerConfig &&
          declaredEnabled == other.declaredEnabled &&
          enabled == other.enabled &&
          image == other.image &&
          runtimeBinary == other.runtimeBinary;

  @override
  int get hashCode => Object.hash(declaredEnabled, enabled, image, runtimeBinary);
}
