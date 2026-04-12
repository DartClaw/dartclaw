import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:test/test.dart';

DartclawConfig _loadYaml(String yaml) {
  return DartclawConfig.load(
    fileReader: (path) => path == '/tmp/.dartclaw/dartclaw.yaml' ? yaml : null,
    env: {'HOME': '/tmp'},
  );
}

void main() {
  group('CanvasConfig', () {
    test('defaults are applied when canvas section is absent', () {
      final config = _loadYaml('port: 3000\n');

      expect(config.server.baseUrl, isNull);
      expect(config.canvas.enabled, isTrue);
      expect(config.canvas.share.defaultPermission, 'interact');
      expect(config.canvas.share.defaultTtlMinutes, 480);
      expect(config.canvas.share.maxConnections, 50);
      expect(config.canvas.share.autoShare, isTrue);
      expect(config.canvas.share.showQr, isTrue);
      expect(config.canvas.workshopMode.taskBoard, isTrue);
      expect(config.canvas.workshopMode.showContributorStats, isTrue);
      expect(config.canvas.workshopMode.showBudgetBar, isTrue);
    });

    test('full canvas section parses correctly', () {
      final config = _loadYaml('''
base_url: https://workshop.example.com
canvas:
  enabled: false
  share:
    default_permission: view
    default_ttl: 2h
    max_connections: 12
    auto_share: false
    show_qr: false
  workshop_mode:
    task_board: false
    show_contributor_stats: false
    show_budget_bar: true
''');

      expect(config.server.baseUrl, 'https://workshop.example.com');
      expect(config.canvas.enabled, isFalse);
      expect(config.canvas.share.defaultPermission, 'view');
      expect(config.canvas.share.defaultTtlMinutes, 120);
      expect(config.canvas.share.maxConnections, 12);
      expect(config.canvas.share.autoShare, isFalse);
      expect(config.canvas.share.showQr, isFalse);
      expect(config.canvas.workshopMode.taskBoard, isFalse);
      expect(config.canvas.workshopMode.showContributorStats, isFalse);
      expect(config.canvas.workshopMode.showBudgetBar, isTrue);
    });

    test('partial section falls back to defaults', () {
      final config = _loadYaml('''
canvas:
  share:
    max_connections: 8
''');

      expect(config.canvas.enabled, isTrue);
      expect(config.canvas.share.defaultPermission, 'interact');
      expect(config.canvas.share.defaultTtlMinutes, 480);
      expect(config.canvas.share.maxConnections, 8);
    });

    test('duration shorthand parses to minutes', () {
      final config = _loadYaml('''
canvas:
  share:
    default_ttl: 30m
''');

      expect(config.canvas.share.defaultTtlMinutes, 30);
    });
  });
}
