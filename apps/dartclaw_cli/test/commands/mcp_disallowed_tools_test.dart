import 'package:dartclaw_cli/src/commands/serve_command.dart';
import 'package:dartclaw_cli/src/commands/wiring/harness_wiring.dart' show workerDisallowedTools;
import 'package:test/test.dart';

void main() {
  group('mcpDisallowedTools', () {
    test('includes WebFetch when MCP enabled', () {
      final result = mcpDisallowedTools(mcpEnabled: true, searchEnabled: false, userDisallowed: []);
      expect(result, contains('WebFetch'));
      expect(result, isNot(contains('WebSearch')));
    });

    test('includes WebSearch when MCP and search enabled', () {
      final result = mcpDisallowedTools(mcpEnabled: true, searchEnabled: true, userDisallowed: []);
      expect(result, contains('WebFetch'));
      expect(result, contains('WebSearch'));
    });

    test('excludes both when MCP disabled', () {
      final result = mcpDisallowedTools(mcpEnabled: false, searchEnabled: true, userDisallowed: []);
      expect(result, isNot(contains('WebFetch')));
      expect(result, isNot(contains('WebSearch')));
    });

    test('preserves user disallowedTools', () {
      final result = mcpDisallowedTools(mcpEnabled: true, searchEnabled: true, userDisallowed: ['Computer', 'Bash']);
      expect(result, containsAll(['Computer', 'Bash', 'WebFetch', 'WebSearch']));
      // User items come first.
      expect(result.indexOf('Computer'), lessThan(result.indexOf('WebFetch')));
    });
  });

  group('workerDisallowedTools', () {
    test('host workers keep the deployment-derived suppression unchanged', () {
      expect(
        workerDisallowedTools(
          containerProfile: null,
          bridgedMcpTools: const {},
          hostDisallowedTools: const ['WebFetch', 'WebSearch'],
          userDisallowedTools: const [],
        ),
        ['WebFetch', 'WebSearch'],
      );
    });

    test('a container granted no bridged tools keeps its provider-native web', () {
      // Otherwise the container has neither a bridged nor a native web tool:
      // the silent capability loss the no-fallback rule forbids.
      expect(
        workerDisallowedTools(
          containerProfile: 'workspace',
          bridgedMcpTools: const {},
          hostDisallowedTools: const ['WebFetch', 'WebSearch'],
          userDisallowedTools: const [],
        ),
        isEmpty,
      );
    });

    test('a container suppresses only the native tools its bridge actually replaces', () {
      expect(
        workerDisallowedTools(
          containerProfile: 'restricted',
          bridgedMcpTools: const {'web_fetch'},
          hostDisallowedTools: const [],
          userDisallowedTools: const [],
        ),
        ['WebFetch'],
      );
      expect(
        workerDisallowedTools(
          containerProfile: 'restricted',
          bridgedMcpTools: const {'web_fetch', 'web_search'},
          hostDisallowedTools: const [],
          userDisallowedTools: const [],
        ),
        ['WebFetch', 'WebSearch'],
      );
    });

    test('user-configured denials survive into a container', () {
      expect(
        workerDisallowedTools(
          containerProfile: 'workspace',
          bridgedMcpTools: const {},
          hostDisallowedTools: const [],
          userDisallowedTools: const ['Computer'],
        ),
        contains('Computer'),
      );
    });
  });
}
