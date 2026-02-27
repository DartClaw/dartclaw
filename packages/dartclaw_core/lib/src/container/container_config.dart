/// Configuration for Docker container isolation.
class ContainerConfig {
  final bool enabled;
  final String image;
  final List<String> extraMounts;
  final List<String> extraArgs;

  const ContainerConfig({
    this.enabled = false,
    this.image = 'dartclaw-agent:latest',
    this.extraMounts = const [],
    this.extraArgs = const [],
  });

  const ContainerConfig.disabled() : this();

  factory ContainerConfig.fromYaml(Map<String, dynamic> yaml, List<String> warns) {
    final enabled = yaml['enabled'];
    if (enabled != null && enabled is! bool) {
      warns.add('Invalid type for container.enabled: "${enabled.runtimeType}" — using default');
    }
    final image = yaml['image'];
    if (image != null && image is! String) {
      warns.add('Invalid type for container.image: "${image.runtimeType}" — using default');
    }

    var mounts = <String>[];
    final mountsRaw = yaml['mounts'];
    if (mountsRaw is List) {
      mounts = mountsRaw.whereType<String>().toList();
    } else if (mountsRaw != null) {
      warns.add('Invalid type for container.mounts: "${mountsRaw.runtimeType}" — ignoring');
    }

    var args = <String>[];
    final argsRaw = yaml['extra_args'];
    if (argsRaw is List) {
      args = argsRaw.whereType<String>().toList();
    } else if (argsRaw != null) {
      warns.add('Invalid type for container.extra_args: "${argsRaw.runtimeType}" — ignoring');
    }

    return ContainerConfig(
      enabled: enabled is bool ? enabled : false,
      image: image is String ? image : 'dartclaw-agent:latest',
      extraMounts: mounts,
      extraArgs: args,
    );
  }
}
