import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:test/test.dart';

void main() {
  group('ContainerConfig', () {
    test('defaults are disabled', () {
      const config = ContainerConfig();
      expect(config.enabled, isFalse);
      expect(config.image, 'dartclaw-agent:latest');
    });

    test('fromYaml parses enabled flag', () {
      final warns = <String>[];
      final config = ContainerConfig.fromYaml({'enabled': true, 'image': 'my-image:v1'}, warns);
      expect(config.enabled, isTrue);
      expect(config.image, 'my-image:v1');
      expect(warns, isEmpty);
    });

    test('fromYaml reports a removed mount or argument key instead of reading it', () {
      // The container never took host mounts or raw Docker arguments from
      // config; the keys that claimed otherwise are gone, so the parser reports
      // them like any other key it does not read.
      final warns = <String>[];
      final config = ContainerConfig.fromYaml({
        'enabled': true,
        'mounts': ['/data:/data:ro'],
        'extra_args': ['--privileged'],
        'mount_allowlist': ['~/projects'],
      }, warns);
      expect(config.enabled, isTrue);
      expect(
        warns,
        containsAll(<String>[
          'Unknown config key: container.mounts',
          'Unknown config key: container.extra_args',
          'Unknown config key: container.mount_allowlist',
        ]),
      );
    });

    test('fromYaml handles invalid types gracefully', () {
      final warns = <String>[];
      final config = ContainerConfig.fromYaml({'enabled': 'yes', 'image': 123}, warns);
      expect(config.enabled, isFalse);
      expect(config.image, 'dartclaw-agent:latest');
      expect(warns, hasLength(2));
    });
  });
}
