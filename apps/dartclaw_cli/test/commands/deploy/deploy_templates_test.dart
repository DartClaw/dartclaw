import 'package:dartclaw_cli/src/commands/deploy_templates/launchdaemon_plist.dart';
import 'package:dartclaw_cli/src/commands/deploy_templates/nftables_rules.dart';
import 'package:dartclaw_cli/src/commands/deploy_templates/pf_rules.dart';
import 'package:dartclaw_cli/src/commands/deploy_templates/systemd_unit.dart';
import 'package:test/test.dart';

void main() {
  group('generatePlist', () {
    late String plist;

    setUp(() {
      plist = generatePlist(
        binPath: '/usr/local/bin/dartclaw',
        host: '0.0.0.0',
        port: 3000,
        dataDir: '/home/dc/.dartclaw',
        user: 'dc',
      );
    });

    test('contains XML plist header', () {
      expect(plist, contains('<?xml version="1.0"'));
      expect(plist, contains('<!DOCTYPE plist'));
    });

    test('contains label', () {
      expect(plist, contains('com.dartclaw.agent'));
    });

    test('contains interpolated binPath and port', () {
      expect(plist, contains('/usr/local/bin/dartclaw'));
      expect(plist, contains('<string>3000</string>'));
    });

    test('contains API key placeholder', () {
      expect(plist, contains('__ANTHROPIC_API_KEY__'));
    });

    test('contains auto-restart directives', () {
      expect(plist, contains('<key>KeepAlive</key>'));
      expect(plist, contains('<true/>'));
    });

    test('contains log paths', () {
      expect(plist, contains('/home/dc/.dartclaw/logs/dartclaw.log'));
      expect(plist, contains('/home/dc/.dartclaw/logs/dartclaw.err.log'));
    });

    test('contains user', () {
      expect(plist, contains('<key>UserName</key>'));
      expect(plist, contains('<string>dc</string>'));
    });
  });

  group('generateUnit', () {
    late String unit;

    setUp(() {
      unit = generateUnit(
        binPath: '/usr/local/bin/dartclaw',
        host: '0.0.0.0',
        port: 3000,
        dataDir: '/home/dc/.dartclaw',
        user: 'dc',
      );
    });

    test('contains systemd sections', () {
      expect(unit, contains('[Unit]'));
      expect(unit, contains('[Service]'));
      expect(unit, contains('[Install]'));
    });

    test('contains ExecStart with interpolated values', () {
      expect(
        unit,
        contains('ExecStart=/usr/local/bin/dartclaw serve --host 0.0.0.0 --port 3000'),
      );
    });

    test('contains API key placeholder', () {
      expect(unit, contains('Environment=ANTHROPIC_API_KEY=__ANTHROPIC_API_KEY__'));
    });

    test('contains auto-restart', () {
      expect(unit, contains('Restart=always'));
    });

    test('contains security hardening', () {
      expect(unit, contains('NoNewPrivileges=true'));
      expect(unit, contains('ProtectSystem=strict'));
      expect(unit, contains('PrivateTmp=true'));
    });

    test('contains log paths', () {
      expect(unit, contains('/home/dc/.dartclaw/logs/dartclaw.log'));
    });

    test('contains user', () {
      expect(unit, contains('User=dc'));
    });
  });

  group('generatePfRules', () {
    test('contains default allowed host', () {
      final rules = generatePfRules();
      expect(rules, contains('api.anthropic.com'));
      expect(rules, contains('port 443'));
    });

    test('contains DNS rules', () {
      final rules = generatePfRules();
      expect(rules, contains('1.1.1.1'));
      expect(rules, contains('8.8.8.8'));
      expect(rules, contains('port 53'));
    });

    test('contains anchor block', () {
      final rules = generatePfRules();
      expect(rules, contains('anchor "dartclaw"'));
      expect(rules, contains('block out all'));
    });

    test('includes custom hosts', () {
      final rules = generatePfRules(
        allowedHosts: ['api.anthropic.com', 'custom.example.com'],
      );
      expect(rules, contains('custom.example.com'));
    });
  });

  group('generateNftablesRules', () {
    test('contains default allowed host', () {
      final rules = generateNftablesRules();
      expect(rules, contains('api.anthropic.com'));
      expect(rules, contains('tcp dport 443'));
    });

    test('contains DNS rules', () {
      final rules = generateNftablesRules();
      expect(rules, contains('1.1.1.1'));
      expect(rules, contains('8.8.8.8'));
      expect(rules, contains('dport 53'));
    });

    test('contains table and chain', () {
      final rules = generateNftablesRules();
      expect(rules, contains('table inet dartclaw'));
      expect(rules, contains('chain output'));
      expect(rules, contains('policy drop'));
    });

    test('includes custom hosts', () {
      final rules = generateNftablesRules(
        allowedHosts: ['api.anthropic.com', 'custom.example.com'],
      );
      expect(rules, contains('custom.example.com'));
    });
  });
}
