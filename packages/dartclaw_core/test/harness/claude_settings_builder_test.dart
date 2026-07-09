import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

Map<String, dynamic>? _settingsJson(Map<String, dynamic> options) {
  final raw = ClaudeSettingsBuilder.buildSettings(options, containerManager: null, hostWorkingDirectory: '/work');
  if (raw == null) return null;
  return jsonDecode(raw) as Map<String, dynamic>;
}

void main() {
  group('ClaudeSettingsBuilder coarse sandbox translation', () {
    test('workspace-write enables the sandbox without denying writes', () {
      final settings = _settingsJson({'sandbox': 'workspace-write'})!;
      expect(settings['sandbox'], {'enabled': true});
    });

    test('read-only enables the sandbox and denies all writes', () {
      final settings = _settingsJson({'sandbox': 'read-only'})!;
      expect(settings['sandbox'], {
        'enabled': true,
        'allowUnsandboxedCommands': false,
        'filesystem': {
          'denyWrite': ['/'],
        },
      });
    });

    test('danger-full-access disables OS isolation', () {
      final settings = _settingsJson({'sandbox': 'danger-full-access'})!;
      expect(settings['sandbox'], {'enabled': false});
    });

    test('coarse sandbox deep-merges over a raw settings sandbox block', () {
      final settings = _settingsJson({
        'settings': jsonEncode({
          'sandbox': {
            'network': {
              'allowedDomains': ['example.com'],
            },
          },
        }),
        'sandbox': 'workspace-write',
      })!;
      final sandbox = settings['sandbox'] as Map<String, dynamic>;
      // The coarse value adds enabled:true; the raw block's network rules survive.
      expect(sandbox['enabled'], isTrue);
      expect(sandbox['network'], {
        'allowedDomains': ['example.com'],
      });
    });

    test('a map-valued sandbox still passes through as a raw native block', () {
      final settings = _settingsJson({
        'sandbox': {
          'enabled': true,
          'filesystem': {
            'allowWrite': ['/tmp/build'],
          },
        },
      })!;
      expect(settings['sandbox'], {
        'enabled': true,
        'filesystem': {
          'allowWrite': ['/tmp/build'],
        },
      });
    });

    test('an unrecognised coarse sandbox string is ignored', () {
      final settings = _settingsJson({'sandbox': 'totally-open'});
      expect(settings, isNull);
    });
  });
}
