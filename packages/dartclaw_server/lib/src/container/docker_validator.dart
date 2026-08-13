import 'package:dartclaw_models/dartclaw_models.dart' show ContainerConfig;

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
    if (config.extraArgs.isNotEmpty) {
      errors.add('container.extra_args is unsupported because raw Docker arguments can override mandatory hardening');
    }

    if (config.extraMounts.isNotEmpty) {
      errors.add('container.mounts is unsupported because arbitrary host mounts bypass the execution boundary');
    }

    return errors;
  }
}
