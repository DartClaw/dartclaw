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
          hostDisallowedTools: const ['WebFetch', 'WebSearch'],
          userDisallowedTools: const [],
        ),
        ['WebFetch', 'WebSearch'],
      );
    });

    test('every container profile loses provider-native web, whatever its bridge serves', () {
      // The tools run at the provider, outside `network:none`, so the host
      // gateway 403s any request declaring one — keeping them would only move
      // the failure to the agent's first call.
      for (final profile in ['workspace', 'restricted']) {
        expect(
          workerDisallowedTools(
            containerProfile: profile,
            hostDisallowedTools: const [],
            userDisallowedTools: const [],
          ),
          containsAll(['WebFetch', 'WebSearch']),
          reason: 'profile "$profile" must not declare a native web tool the gateway refuses',
        );
      }
    });

    test('user-configured denials survive into a container', () {
      expect(
        workerDisallowedTools(
          containerProfile: 'workspace',
          hostDisallowedTools: const [],
          userDisallowedTools: const ['Computer'],
        ),
        contains('Computer'),
      );
    });
  });
}
