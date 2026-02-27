import 'container_config.dart';

/// Validates Docker container configuration, rejecting dangerous options.
class DockerValidator {
  /// Returns a list of validation errors. Empty list means valid.
  static List<String> validate(ContainerConfig config) {
    final errors = <String>[];

    // Check extra args for dangerous patterns
    final allArgs = config.extraArgs.join(' ');

    if (allArgs.contains('--network host') || allArgs.contains('--network=host')) {
      errors.add('Dangerous: --network host defeats container isolation');
    }
    if (allArgs.contains('--network bridge') || allArgs.contains('--network=bridge')) {
      errors.add('Dangerous: --network bridge — use network:none with credential proxy');
    }
    if (allArgs.contains('--privileged')) {
      errors.add('Dangerous: --privileged disables all security restrictions');
    }
    if (allArgs.contains('seccomp=unconfined') || allArgs.contains('seccomp:unconfined')) {
      errors.add('Dangerous: seccomp=unconfined removes syscall filtering');
    }
    if (allArgs.contains('--pid=host') || allArgs.contains('--pid host')) {
      errors.add('Dangerous: --pid=host exposes host process namespace');
    }
    if (allArgs.contains('--ipc=host') || allArgs.contains('--ipc host')) {
      errors.add('Dangerous: --ipc=host shares host IPC namespace');
    }

    // Check mounts for sensitive paths
    for (final mount in config.extraMounts) {
      _validateMount(mount, errors);
    }

    return errors;
  }

  static void _validateMount(String mount, List<String> errors) {
    // Normalize: handle both -v and --mount formats
    final path = mount.split(':').first.trim();
    final normalized = path.replaceAll(r'\', '/');

    const sensitivePatterns = [
      '/etc',
      '/root',
      '/home',
      '/.ssh',
      '/.aws',
      '/.gnupg',
      '/.config/gcloud',
      '/var/run/docker.sock',
    ];

    for (final pattern in sensitivePatterns) {
      if (normalized == pattern || normalized.startsWith('$pattern/') || normalized.endsWith(pattern)) {
        errors.add('Dangerous mount: "$mount" exposes sensitive path "$pattern"');
        break;
      }
    }
  }
}
