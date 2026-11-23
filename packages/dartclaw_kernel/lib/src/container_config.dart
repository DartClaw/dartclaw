import 'package:collection/collection.dart';

import 'container_registries.dart';

/// Configuration for container isolation.
class ContainerConfig {
  /// Whether agent work runs in containers. Off unless the operator sets
  /// `container.enabled: true`; an absent section or key is `false`.
  final bool enabled;

  /// Container image used for isolated agent execution.
  final String image;

  /// The container CLI every runtime call goes through, chosen once at
  /// startup from the runtimes that answer. Not a YAML key.
  final String runtimeBinary;

  /// Every registry record in force, enabled or not: the built-ins overlaid by
  /// `container.registries` (ADR-062).
  final List<RegistryRecord> registries;

  /// Creates container isolation configuration.
  const new({
    this.enabled = false,
    this.image = 'dartclaw-agent:latest',
    this.runtimeBinary = 'docker',
    this.registries = builtInRegistryRecords,
  });

  /// Creates a configuration with container isolation off, the parsed default.
  const new disabled() : this(enabled: false);

  /// This configuration with [runtimeBinary] as the container CLI in use.
  ContainerConfig withRuntimeBinary(String runtimeBinary) =>
      ContainerConfig(enabled: enabled, image: image, runtimeBinary: runtimeBinary, registries: registries);

  /// Keys this parser reads; anything else is reported rather than ignored.
  static const knownKeys = {'enabled', 'image', 'registries'};

  /// Parses container configuration from YAML, appending warnings to [warns].
  ///
  /// Throws [FormatException] for an invalid `container.registries` record:
  /// it sets egress pins, so it is refused rather than defaulted.
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
      enabled: enabled is bool && enabled,
      image: image is String ? image : 'dartclaw-agent:latest',
      registries: parseRegistryRecords(yaml['registries']),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ContainerConfig &&
          enabled == other.enabled &&
          image == other.image &&
          runtimeBinary == other.runtimeBinary &&
          const ListEquality<RegistryRecord>().equals(registries, other.registries);

  @override
  int get hashCode => Object.hash(enabled, image, runtimeBinary, Object.hashAll(registries));
}
