import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:test/test.dart';

void main() {
  group('retired andthen config', () {
    setUp(DartclawConfig.clearExtensionParsers);
    tearDown(DartclawConfig.clearExtensionParsers);

    test('legacy keys emit warnings only', () {
      final config = DartclawConfig.load(
        configPath: 'dartclaw.yaml',
        fileReader: (path) {
          if (path != 'dartclaw.yaml') return null;
          return '''
andthen:
  git_url: https://example.com/forks/andthen
  ref: v0.15.2
  network: required
  source_cache_dir: /var/cache/dartclaw/andthen-src
''';
        },
        env: const {'HOME': '/home/user'},
      );

      expect(config.warnings, hasLength(4));
      expect(config.warnings, everyElement(contains('DartClaw no longer provisions AndThen skills')));
    });

    test('retired keys are not advertised as active config metadata', () {
      for (final key in const ['andthen.git_url', 'andthen.ref', 'andthen.network', 'andthen.source_cache_dir']) {
        expect(ConfigMeta.fields.containsKey(key), isFalse);
      }
    });
  });
}
