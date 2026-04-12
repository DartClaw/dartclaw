import 'package:dartclaw_server/src/container/docker_validator.dart';
import 'package:dartclaw_models/dartclaw_models.dart' show ContainerConfig;
import 'package:test/test.dart';

void main() {
  group('DockerValidator', () {
    test('accepts valid config', () {
      final errors = DockerValidator.validate(
        const ContainerConfig(enabled: true, extraMounts: ['/data/workspace:/workspace:rw']),
      );
      expect(errors, isEmpty);
    });

    test('rejects --network host', () {
      final errors = DockerValidator.validate(const ContainerConfig(enabled: true, extraArgs: ['--network', 'host']));
      expect(errors, isNotEmpty);
      expect(errors.first, contains('--network host'));
    });

    test('rejects --network=host', () {
      final errors = DockerValidator.validate(const ContainerConfig(enabled: true, extraArgs: ['--network=host']));
      expect(errors, isNotEmpty);
    });

    test('rejects --privileged', () {
      final errors = DockerValidator.validate(const ContainerConfig(enabled: true, extraArgs: ['--privileged']));
      expect(errors, isNotEmpty);
      expect(errors.first, contains('--privileged'));
    });

    test('rejects seccomp=unconfined', () {
      final errors = DockerValidator.validate(
        const ContainerConfig(enabled: true, extraArgs: ['--security-opt', 'seccomp=unconfined']),
      );
      expect(errors, isNotEmpty);
    });

    test('rejects --pid=host', () {
      final errors = DockerValidator.validate(const ContainerConfig(enabled: true, extraArgs: ['--pid=host']));
      expect(errors, isNotEmpty);
    });

    test('rejects --ipc=host', () {
      final errors = DockerValidator.validate(const ContainerConfig(enabled: true, extraArgs: ['--ipc=host']));
      expect(errors, isNotEmpty);
    });

    test('rejects sensitive mount: /etc', () {
      final errors = DockerValidator.validate(const ContainerConfig(enabled: true, extraMounts: ['/etc:/etc:ro']));
      expect(errors, isNotEmpty);
      expect(errors.first, contains('/etc'));
    });

    test('rejects sensitive mount: /.ssh', () {
      final errors = DockerValidator.validate(
        const ContainerConfig(enabled: true, extraMounts: ['/home/user/.ssh:/root/.ssh:ro']),
      );
      expect(errors, isNotEmpty);
      expect(errors.first, contains('.ssh'));
    });

    test('rejects docker socket mount', () {
      final errors = DockerValidator.validate(
        const ContainerConfig(enabled: true, extraMounts: ['/var/run/docker.sock:/var/run/docker.sock']),
      );
      expect(errors, isNotEmpty);
    });

    test('multiple errors are all reported', () {
      final errors = DockerValidator.validate(
        const ContainerConfig(
          enabled: true,
          extraArgs: ['--privileged', '--network', 'host'],
          extraMounts: ['/etc:/etc:ro'],
        ),
      );
      expect(errors.length, greaterThanOrEqualTo(3));
    });
  });
}
