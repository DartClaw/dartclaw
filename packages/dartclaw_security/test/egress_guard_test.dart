import 'package:dartclaw_security/dartclaw_security.dart';
import 'package:test/test.dart';

void main() {
  group('EgressGuard', () {
    test('S01 allowlisted server and tool passes', () async {
      final guard = EgressGuard(
        allowlist: {
          'linear': ['list_issues'],
        },
      );

      final verdict = await guard.evaluate(_context(server: 'linear', tool: 'list_issues'));

      expect(verdict.isPass, isTrue);
    });

    test('S02 non-allowlisted tool and server are denied by default', () async {
      final guard = EgressGuard(
        allowlist: {
          'linear': ['list_issues'],
        },
      );

      final unknownTool = await guard.evaluate(_context(server: 'linear', tool: 'delete_project'));
      final unknownServer = await guard.evaluate(_context(server: 'unregistered', tool: 'list_issues'));

      expect(unknownTool.isBlock, isTrue);
      expect(unknownTool.message, contains('not allowlisted'));
      expect(unknownServer.isBlock, isTrue);
      expect(unknownServer.message, contains('not allowlisted'));
    });
  });
}

GuardContext _context({required String server, required String tool}) => GuardContext(
  hookPoint: 'outboundMcpToolsCall',
  toolName: 'tools/call',
  toolInput: {'server': server, 'tool': tool},
  sessionId: 'session-1',
  timestamp: DateTime.utc(2026),
);
