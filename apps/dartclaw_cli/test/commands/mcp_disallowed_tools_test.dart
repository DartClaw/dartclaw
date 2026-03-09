import 'package:dartclaw_cli/src/commands/serve_command.dart';
import 'package:test/test.dart';

void main() {
  group('mcpDisallowedTools', () {
    test('includes WebFetch when MCP enabled', () {
      final result = mcpDisallowedTools(
        mcpEnabled: true,
        searchEnabled: false,
        userDisallowed: [],
      );
      expect(result, contains('WebFetch'));
      expect(result, isNot(contains('WebSearch')));
    });

    test('includes WebSearch when MCP and search enabled', () {
      final result = mcpDisallowedTools(
        mcpEnabled: true,
        searchEnabled: true,
        userDisallowed: [],
      );
      expect(result, contains('WebFetch'));
      expect(result, contains('WebSearch'));
    });

    test('excludes both when MCP disabled', () {
      final result = mcpDisallowedTools(
        mcpEnabled: false,
        searchEnabled: true,
        userDisallowed: [],
      );
      expect(result, isNot(contains('WebFetch')));
      expect(result, isNot(contains('WebSearch')));
    });

    test('preserves user disallowedTools', () {
      final result = mcpDisallowedTools(
        mcpEnabled: true,
        searchEnabled: true,
        userDisallowed: ['Computer', 'Bash'],
      );
      expect(result, containsAll(['Computer', 'Bash', 'WebFetch', 'WebSearch']));
      // User items come first.
      expect(result.indexOf('Computer'), lessThan(result.indexOf('WebFetch')));
    });
  });
}
