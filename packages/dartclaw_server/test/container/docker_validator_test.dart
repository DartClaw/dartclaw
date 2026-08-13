import 'package:dartclaw_server/src/container/docker_validator.dart';
import 'package:dartclaw_models/dartclaw_models.dart' show ContainerConfig;
import 'package:test/test.dart';

void main() {
  group('DockerValidator', () {
    test('accepts valid config', () {
      final errors = DockerValidator.validate(const ContainerConfig(enabled: true));
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

    test('rejects every raw Docker argument, including unenumerated overrides', () {
      for (final args in const [
        ['--net=host'],
        ['--cap-add', 'SYS_ADMIN'],
        ['--device', '/dev/kvm'],
        ['--userns=host'],
        ['--security-opt', 'apparmor=unconfined'],
      ]) {
        expect(
          DockerValidator.validate(ContainerConfig(enabled: true, extraArgs: args)),
          anyElement(contains('raw Docker arguments')),
          reason: '$args must not bypass mandatory container hardening',
        );
      }
    });

    test('rejects every arbitrary host mount', () {
      for (final mount in const [
        '/tmp/shared:/shared:ro',
        '/:/project/subdir:rw',
        '/tmp/shared:/etc:rw',
        '/var/run/docker.sock:/var/run/docker.sock',
      ]) {
        expect(
          DockerValidator.validate(ContainerConfig(enabled: true, extraMounts: [mount])),
          anyElement(contains('container.mounts is unsupported')),
          reason: '$mount must not bypass the execution boundary',
        );
      }
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
