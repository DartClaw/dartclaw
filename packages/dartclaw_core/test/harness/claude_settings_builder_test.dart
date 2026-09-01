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

  group('ClaudeSettingsBuilder declared-tool allow rules', () {
    // A step's declared tools are the policy the guard chain enforces. Until
    // 2026-08-28 they were never stated to the provider, so the CLI enforced
    // its own: on a host whose operator allowed `Bash(python:*)` but no
    // `Write`, a review step ran 107 shell commands and had all 17 of its
    // writes refused. These rules close that gap from the same list.
    List<String> rulesFor(List<String> tools, {List<String> roots = const ['/work', '/artifacts']}) =>
        ClaudeSettingsBuilder.allowRulesForCanonicalTools(tools, writableRoots: roots);

    test('shell maps to Bash', () => expect(rulesFor(['shell']), ['Bash']));

    test('file_read maps to Read', () => expect(rulesFor(['file_read']), ['Read']));

    test('web_fetch and web_search map to their native names', () {
      expect(rulesFor(['web_fetch', 'web_search']), ['WebFetch', 'WebSearch']);
    });

    test('mcp_call maps to the bridged MCP prefix', () => expect(rulesFor(['mcp_call']), ['mcp__dartclaw']));

    test('file_write emits an Edit rule per root, absolutely anchored', () {
      // Verified live 2026-08-28: the CLI consults Edit(path) and Read(path)
      // rules only, and a single leading slash anchors at the settings source
      // rather than the filesystem root. Write(/abs/**), Write(//abs/**) and
      // Edit(/abs/**) were all refused; only this form writes. The exact
      // string is the contract with the CLI, so it is pinned.
      expect(rulesFor(['file_write']), ['Edit(//work/**)', 'Edit(//artifacts/**)']);
    });

    test('file_edit emits the same rule, since the CLI enforces one capability', () {
      expect(rulesFor(['file_edit']), ['Edit(//work/**)', 'Edit(//artifacts/**)']);
    });

    test('declaring both file_write and file_edit does not duplicate the rule', () {
      expect(rulesFor(['file_write', 'file_edit']), ['Edit(//work/**)', 'Edit(//artifacts/**)']);
    });

    test('a relative root yields no rule rather than one anchored at the settings source', () {
      expect(rulesFor(['file_write'], roots: ['relative/work']), isEmpty);
    });

    test('an unrecognised canonical name yields no rule', () {
      // The CLI must never be widened by a name this mapping does not know;
      // the guard chain stays the inner boundary for it either way.
      expect(rulesFor(['shell', 'teleport']), ['Bash']);
    });

    test('a step declaring nothing gets an empty allow list, not a wildcard', () {
      expect(rulesFor(const []), isEmpty);
    });

    test('blank roots are dropped rather than producing a rule rooted at ""', () {
      expect(rulesFor(['file_write'], roots: ['/work', '  ']), ['Edit(//work/**)']);
    });

    test('derived rules merge with operator-supplied allow rules instead of replacing them', () {
      final raw = ClaudeSettingsBuilder.buildSettings(
        {
          'permissions': {
            'allow': ['Bash(ls:*)'],
          },
        },
        declaredToolRules: const ['Read'],
        containerManager: null,
        hostWorkingDirectory: '/work',
      );
      final settings = jsonDecode(raw!) as Map<String, dynamic>;
      expect((settings['permissions'] as Map<String, dynamic>)['allow'], ['Bash(ls:*)', 'Read']);
    });

    test('a path-valued settings option is refused for a step rather than dropping its rules', () {
      // Returning the path would run the step on the operator's policy with
      // none of its declared rules — the defect this derivation closes.
      expect(
        () => ClaudeSettingsBuilder.buildSettings(
          {'settings': '/etc/claude-settings.json'},
          declaredToolRules: const ['Read'],
          containerManager: null,
          hostWorkingDirectory: '/work',
        ),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('declared tool policy'))),
      );
    });

    test('a path-valued settings option is still honoured when no step policy is derived', () {
      final raw = ClaudeSettingsBuilder.buildSettings(
        {'settings': '/etc/claude-settings.json'},
        containerManager: null,
        hostWorkingDirectory: '/work',
      );
      expect(raw, '/etc/claude-settings.json');
    });

    test('an empty declared rule list still produces a permissions block', () {
      // Fail-closed: a step that declared no tools must reach the CLI as "allow
      // nothing", never as "no opinion", which would restore inherited rules.
      final raw = ClaudeSettingsBuilder.buildSettings(
        const {},
        declaredToolRules: const [],
        containerManager: null,
        hostWorkingDirectory: '/work',
      );
      final settings = jsonDecode(raw!) as Map<String, dynamic>;
      expect((settings['permissions'] as Map<String, dynamic>)['allow'], isEmpty);
    });
  });
}
