import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:test/test.dart';

void main() {
  group('Unified instance-directory config discovery', () {
    test('DARTCLAW_HOME resolves config and default data_dir under the same instance root', () {
      final config = DartclawConfig.load(
        fileReader: (path) {
          if (path == '/opt/myinstance/dartclaw.yaml') {
            return 'port: 5100\n';
          }
          return null;
        },
        env: {'HOME': '/home/user', 'DARTCLAW_HOME': '/opt/myinstance'},
      );

      expect(config.server.port, 5100);
      expect(config.server.dataDir, '/opt/myinstance');
      expect(config.workspaceDir, '/opt/myinstance/workspace');
    });

    test('deprecated CWD config only warns and does not override discovery', () {
      final config = DartclawConfig.load(
        fileReader: (path) {
          if (path == 'dartclaw.yaml') {
            return 'port: 6400\n';
          }
          if (path == '/home/user/.dartclaw/dartclaw.yaml') {
            return 'port: 6300\n';
          }
          return null;
        },
        env: {'HOME': '/home/user'},
      );

      expect(config.server.port, 6300);
      expect(config.warnings, anyElement(contains('CWD config discovery is deprecated')));
    });

    test('explicit config path still takes precedence over DARTCLAW_HOME', () {
      final config = DartclawConfig.load(
        configPath: '/explicit/config.yaml',
        fileReader: (path) {
          if (path == '/explicit/config.yaml') {
            return 'port: 7777\n';
          }
          if (path == '/opt/myinstance/dartclaw.yaml') {
            return 'port: 6200\n';
          }
          return null;
        },
        env: {'HOME': '/home/user', 'DARTCLAW_HOME': '/opt/myinstance'},
      );

      expect(config.server.port, 7777);
    });
  });
}
