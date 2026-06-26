import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

import 'support/load_config.dart';

void main() {
  group('McpServersConfig', () {
    test('declared enabled server appears in the validated registry', () {
      final config = loadYaml(
        '''
credentials:
  linear:
    api_key: \${LINEAR_API_KEY}
mcp_servers:
  linear:
    command: linear-mcp
    enabled: true
    network_class: public
    credential: linear
''',
        env: {'HOME': defaultTestHome, 'LINEAR_API_KEY': 'linear-secret'},
      );

      final entry = config.mcpServers.enabledRegistry['linear'];
      expect(entry, isNotNull);
      expect(entry?.command, 'linear-mcp');
      expect(entry?.url, isNull);
      expect(entry?.enabled, isTrue);
      expect(entry?.networkClass, McpNetworkClass.public);
      expect(entry?.credential, 'linear');
      expect(entry.toString(), isNot(contains('linear-secret')));
    });

    test('defaults are empty and entries expose transport, enabled flag, network class, and credential reference', () {
      const defaults = McpServersConfig.defaults();
      const sameDefaults = McpServersConfig.defaults();
      const entry = McpServerEntry(
        url: 'https://mcp.example.test/mcp',
        enabled: true,
        networkClass: McpNetworkClass.public,
        credential: 'example',
      );

      expect(defaults.isEmpty, isTrue);
      expect(defaults, sameDefaults);
      expect(defaults.hashCode, sameDefaults.hashCode);
      expect(entry.command, isNull);
      expect(entry.url, 'https://mcp.example.test/mcp');
      expect(entry.enabled, isTrue);
      expect(entry.networkClass, McpNetworkClass.public);
      expect(entry.credential, 'example');
    });

    test('disabled server is excluded from the registry surface', () {
      final config = loadYaml('''
mcp_servers:
  linear:
    command: linear-mcp
    enabled: false
    network_class: public
    credential: linear
''');

      expect(config.mcpServers['linear'], isNotNull);
      expect(config.mcpServers.enabledRegistry, isNot(contains('linear')));
    });

    test('parses per-server governance, allow tools, and surface tools', () {
      final config = loadYaml(
        '''
credentials:
  linear:
    api_key: \${LINEAR_API_KEY}
mcp_servers:
  linear:
    command: linear-mcp
    network_class: public
    credential: linear
    rate_limit:
      calls: 2
      window_seconds: 30
    token_budget:
      tokens: 100
      window_seconds: 60
    allow_tools:
      - list_issues
      - delete_project
    surface_tools:
      - list_issues
''',
        env: {'HOME': defaultTestHome, 'LINEAR_API_KEY': 'linear-secret'},
      );

      final entry = config.mcpServers.enabledRegistry['linear']!;
      expect(entry.rateLimit.calls, 2);
      expect(entry.rateLimit.window, const Duration(seconds: 30));
      expect(entry.tokenBudget.tokens, 100);
      expect(entry.tokenBudget.window, const Duration(seconds: 60));
      expect(entry.allowTools, ['list_issues', 'delete_project']);
      expect(entry.surfaceTools, ['list_issues']);
    });

    test('negative rate limit and token budget fail config load', () {
      expect(
        () => loadYaml('''
mcp_servers:
  linear:
    command: linear-mcp
    network_class: public
    rate_limit:
      calls: -1
'''),
        throwsA(
          isA<FormatException>()
              .having((e) => e.message, 'message', contains('linear'))
              .having((e) => e.message, 'message', contains('non-negative')),
        ),
      );

      expect(
        () => loadYaml('''
mcp_servers:
  linear:
    command: linear-mcp
    network_class: public
    token_budget:
      tokens: -1
'''),
        throwsA(
          isA<FormatException>()
              .having((e) => e.message, 'message', contains('linear'))
              .having((e) => e.message, 'message', contains('non-negative')),
        ),
      );
    });

    test('unresolvable credential disables one server and is logged without exposing plaintext', () async {
      final records = <LogRecord>[];
      final previousLevel = Logger.root.level;
      Logger.root.level = Level.ALL;
      final subscription = Logger.root.onRecord.listen(records.add);
      addTearDown(() async {
        Logger.root.level = previousLevel;
        await subscription.cancel();
      });

      final config = loadYaml('''
credentials:
  linear:
    api_key: \${LINEAR_API_KEY}
mcp_servers:
  linear:
    command: linear-mcp
    enabled: true
    network_class: public
    credential: linear
''');
      await Future<void>.delayed(Duration.zero);

      expect(config.mcpServers['linear']?.enabled, isFalse);
      expect(config.mcpServers.enabledRegistry, isNot(contains('linear')));
      expect(config.warnings, anyElement(allOf(contains('linear'), contains('credential "linear"'))));
      expect(config.warnings.join('\n'), isNot(contains('LINEAR_API_KEY')));
      expect(records.any((record) => record.message.contains('mcp_servers.linear')), isTrue);
      expect(
        records.where((record) => record.loggerName == 'McpServersConfig').map((record) => record.message).join('\n'),
        isNot(contains('LINEAR_API_KEY')),
      );
    });

    test('malformed transport entry fails config load with an actionable message', () {
      expect(
        () => loadYaml('mcp_servers: nope\n'),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('mcp_servers'))),
      );

      expect(
        () => loadYaml('''
mcp_servers:
  linear:
    enabled: true
    network_class: public
    credential: linear
'''),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('mcp_servers.linear'))),
      );

      expect(
        () => loadYaml('''
mcp_servers:
  linear:
    command: linear-mcp
    url: https://mcp.example.test/mcp
    enabled: true
    network_class: public
    credential: linear
'''),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('exactly one transport'))),
      );
    });

    test('duplicate server name and unknown network class are rejected at load', () {
      expect(
        () => loadYaml('''
mcp_servers:
  linear:
    command: linear-mcp
    network_class: public
    credential: linear
  linear:
    command: other-mcp
    network_class: public
    credential: other
'''),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('duplicate server name "linear"'))),
      );

      expect(
        () => loadYaml('''
mcp_servers:
  linear:
    command: linear-mcp
    network_class: internet
    credential: linear
'''),
        throwsA(
          isA<FormatException>()
              .having((e) => e.message, 'message', contains('mcp_servers.linear'))
              .having((e) => e.message, 'message', contains('local, private, public')),
        ),
      );
    });

    test('duplicate server names are rejected for quoted and flow-style registry maps', () {
      expect(
        () => loadYaml(r'''
'mcp_servers':
  'linear':
    command: linear-mcp
    network_class: public
    credential: linear
  'linear':
    command: other-mcp
    network_class: public
    credential: other
'''),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('duplicate server name "linear"'))),
      );

      expect(
        () => loadYaml(
          'mcp_servers: {linear: {command: linear-mcp, network_class: public}, '
          'linear: {command: other-mcp, network_class: public}}\n',
        ),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('duplicate server name "linear"'))),
      );
    });

    test('duplicate server names are rejected when quoted keys use YAML escapes', () {
      expect(
        () => loadYaml(r'''
mcp_servers:
  'lin''ear':
    command: linear-mcp
    network_class: public
  "lin'ear":
    command: other-mcp
    network_class: public
'''),
        throwsA(
          isA<FormatException>().having((e) => e.message, 'message', contains('duplicate server name "lin\'ear"')),
        ),
      );

      expect(
        () => loadYaml(
          r'''mcp_servers: {"lin\"ear": {command: linear-mcp, network_class: public}, 'lin"ear': {command: other-mcp, network_class: public}}''',
        ),
        throwsA(
          isA<FormatException>().having((e) => e.message, 'message', contains('duplicate server name "lin"ear"')),
        ),
      );
    });

    test('duplicate server names are rejected when double-quoted keys use YAML hex escapes', () {
      expect(
        () => loadYaml(r'''
mcp_servers:
  linear:
    command: linear-mcp
    network_class: public
  "line\x61r":
    command: other-mcp
    network_class: public
'''),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('duplicate server name "linear"'))),
      );

      expect(
        () => loadYaml(
          r'''mcp_servers: {linear: {command: linear-mcp, network_class: public}, "line\x61r": {command: other-mcp, network_class: public}}''',
        ),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('duplicate server name "linear"'))),
      );
    });

    test('unrelated YAML duplicate keys are not mislabeled as mcp_servers errors', () {
      final config = loadYaml('''
mcp_servers: {}
providers:
  codex:
    executable: codex
  codex:
    executable: other
''');

      expect(config.mcpServers.isEmpty, isTrue);
      expect(config.warnings, anyElement(contains('YAML parse error')));
      expect(config.warnings.join('\n'), isNot(contains('mcp_servers contains duplicate')));
    });

    test('registry-shaped block scalar text is not scanned as mcp_servers config', () {
      final config = loadYaml('''
context:
  compact_instructions: |
    mcp_servers:
      linear:
        command: linear-mcp
      linear:
        command: other-mcp
''');

      expect(config.mcpServers.isEmpty, isTrue);
      expect(config.warnings.join('\n'), isNot(contains('duplicate server name')));
    });

    test('real duplicate registry is still rejected after registry-shaped block scalar text', () {
      expect(
        () => loadYaml('''
context:
  compact_instructions: |
    mcp_servers:
      linear:
        command: text-only
mcp_servers:
  linear:
    command: linear-mcp
    network_class: public
  linear:
    command: other-mcp
    network_class: public
'''),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('duplicate server name "linear"'))),
      );
    });

    test('root mcp_servers block scalar reports invalid registry shape, not duplicate names', () {
      expect(
        () => loadYaml('''
mcp_servers: |
  linear:
    command: linear-mcp
  linear:
    command: other-mcp
'''),
        throwsA(
          isA<FormatException>()
              .having((e) => e.message, 'message', contains('mcp_servers must be a map'))
              .having((e) => e.message, 'message', isNot(contains('duplicate server name'))),
        ),
      );
    });

    test('root mcp_servers chomped block scalars report invalid registry shape, not duplicate names', () {
      for (final indicator in ['|-', '|+', '>-', '>+']) {
        expect(
          () => loadYaml('''
mcp_servers: $indicator
  linear:
    command: linear-mcp
  linear:
    command: other-mcp
'''),
          throwsA(
            isA<FormatException>()
                .having((e) => e.message, 'message', contains('mcp_servers must be a map'))
                .having((e) => e.message, 'message', isNot(contains('duplicate server name'))),
          ),
          reason: indicator,
        );
      }
    });

    test('root mcp_servers sequence reports invalid registry shape, not duplicate names', () {
      expect(
        () => loadYaml('''
mcp_servers:
  - linear:
      command: linear-mcp
  - linear:
      command: other-mcp
'''),
        throwsA(
          isA<FormatException>()
              .having((e) => e.message, 'message', contains('mcp_servers must be a map'))
              .having((e) => e.message, 'message', isNot(contains('duplicate server name'))),
        ),
      );
    });

    test('duplicate root mcp_servers sections fail load with a registry error', () {
      expect(
        () => loadYaml('''
mcp_servers:
  linear:
    command: linear-mcp
    network_class: public
mcp_servers:
  other:
    command: other-mcp
    network_class: public
'''),
        throwsA(
          isA<FormatException>()
              .having((e) => e.message, 'message', contains('mcp_servers'))
              .having((e) => e.message, 'message', contains('duplicate registry section')),
        ),
      );
    });

    test('duplicate root section is rejected after scalar-shaped mcp_servers section', () {
      expect(
        () => loadYaml('''
mcp_servers: |
  linear:
    command: text-only
mcp_servers:
  linear:
    command: linear-mcp
    network_class: public
'''),
        throwsA(
          isA<FormatException>()
              .having((e) => e.message, 'message', contains('mcp_servers'))
              .having((e) => e.message, 'message', contains('duplicate registry section')),
        ),
      );
    });

    test('duplicate root section is rejected after sequence-shaped mcp_servers section', () {
      expect(
        () => loadYaml('''
mcp_servers:
  - linear:
      command: text-only
mcp_servers:
  linear:
    command: linear-mcp
    network_class: public
'''),
        throwsA(
          isA<FormatException>()
              .having((e) => e.message, 'message', contains('mcp_servers'))
              .having((e) => e.message, 'message', contains('duplicate registry section')),
        ),
      );
    });

    test('flow-style scalar value with colon reports map-entry shape error, not duplicate names', () {
      expect(
        () => loadYaml('mcp_servers: {linear: https://mcp.example.test/mcp}\n'),
        throwsA(
          isA<FormatException>()
              .having((e) => e.message, 'message', contains('mcp_servers.linear must be a map entry'))
              .having((e) => e.message, 'message', isNot(contains('duplicate server name'))),
        ),
      );
    });

    test('URL transport only accepts absolute http URLs without inline credentials', () {
      final invalidUrls = <String>[
        'not a url',
        '/mcp',
        'ftp://mcp.example.test/mcp',
        'https://user:secret@mcp.example.test/mcp',
        'https://mcp.example.test/mcp?token=secret',
        'https://mcp.example.test/mcp?api_key=secret',
        'https://mcp.example.test/mcp#secret',
      ];

      for (final url in invalidUrls) {
        expect(
          () => loadYaml('''
mcp_servers:
  linear:
    url: $url
    network_class: public
'''),
          throwsA(
            isA<FormatException>()
                .having((e) => e.message, 'message', contains('mcp_servers.linear'))
                .having((e) => e.message, 'message', contains('absolute http or https URL')),
          ),
          reason: url,
        );
      }

      final config = loadYaml(
        '''
credentials:
  linear:
    api_key: \${LINEAR_API_KEY}
mcp_servers:
  linear:
    url: https://mcp.example.test/mcp
    network_class: public
    credential: linear
''',
        env: {'HOME': defaultTestHome, 'LINEAR_API_KEY': 'linear-secret'},
      );

      expect(config.mcpServers.enabledRegistry['linear']?.url, 'https://mcp.example.test/mcp');
    });

    test('ConfigWriter rewrite preserves mcp_servers comments and key order', () async {
      final tempDir = await Directory.systemTemp.createTemp('mcp_servers_writer_test_');
      addTearDown(() async {
        await tempDir.delete(recursive: true);
      });
      final configPath = '${tempDir.path}/dartclaw.yaml';
      final writer = ConfigWriter(configPath: configPath);
      addTearDown(writer.dispose);
      final file = File(configPath);
      file.writeAsStringSync('''
# MCP registry
mcp_servers:
  # Linear server
  linear:
    command: linear-mcp
    enabled: true
    network_class: public
    credential: linear

port: 3000
''');

      await writer.updateFields({'port': 3001});

      final result = file.readAsStringSync();
      expect(result, contains('# MCP registry'));
      expect(result, contains('# Linear server'));
      expect(result.indexOf('mcp_servers:'), lessThan(result.indexOf('port: 3001')));
      expect(result, contains('command: linear-mcp'));
      expect(result, contains('credential: linear'));
    });
  });
}
