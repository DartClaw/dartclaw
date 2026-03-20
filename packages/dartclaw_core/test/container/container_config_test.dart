import 'package:dartclaw_core/src/container/container_config.dart';
import 'package:test/test.dart';

void main() {
  group('ContainerConfig', () {
    test('defaults are disabled', () {
      const config = ContainerConfig();
      expect(config.enabled, isFalse);
      expect(config.image, 'dartclaw-agent:latest');
      expect(config.extraMounts, isEmpty);
      expect(config.extraArgs, isEmpty);
    });

    test('fromYaml parses enabled flag', () {
      final warns = <String>[];
      final config = ContainerConfig.fromYaml({'enabled': true, 'image': 'my-image:v1'}, warns);
      expect(config.enabled, isTrue);
      expect(config.image, 'my-image:v1');
      expect(warns, isEmpty);
    });

    test('fromYaml parses mounts', () {
      final warns = <String>[];
      final config = ContainerConfig.fromYaml({
        'enabled': true,
        'mounts': ['/data:/data:ro'],
      }, warns);
      expect(config.extraMounts, ['/data:/data:ro']);
    });

    test('fromYaml handles invalid types gracefully', () {
      final warns = <String>[];
      final config = ContainerConfig.fromYaml({'enabled': 'yes', 'image': 123, 'mounts': 'not-a-list'}, warns);
      expect(config.enabled, isFalse);
      expect(config.image, 'dartclaw-agent:latest');
      expect(config.extraMounts, isEmpty);
      expect(warns, hasLength(3));
    });
  });
}
