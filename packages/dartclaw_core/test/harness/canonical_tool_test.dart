import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  group('CanonicalTool', () {
    test('exposes stable names for the canonical taxonomy', () {
      expect(CanonicalTool.shell.stableName, 'shell');
      expect(CanonicalTool.fileRead.stableName, 'file_read');
      expect(CanonicalTool.fileWrite.stableName, 'file_write');
      expect(CanonicalTool.fileEdit.stableName, 'file_edit');
      expect(CanonicalTool.webFetch.stableName, 'web_fetch');
      expect(CanonicalTool.sessionsSpawn.stableName, 'sessions_spawn');
      expect(CanonicalTool.sessionsSend.stableName, 'sessions_send');
      expect(CanonicalTool.mcpCall.stableName, 'mcp_call');
    });

    test('fromName resolves known names and rejects unknown values', () {
      expect(CanonicalTool.fromName('shell'), CanonicalTool.shell);
      expect(CanonicalTool.fromName('file_read'), CanonicalTool.fileRead);
      expect(CanonicalTool.fromName('file_write'), CanonicalTool.fileWrite);
      expect(CanonicalTool.fromName('file_edit'), CanonicalTool.fileEdit);
      expect(CanonicalTool.fromName('web_fetch'), CanonicalTool.webFetch);
      expect(CanonicalTool.fromName('sessions_spawn'), CanonicalTool.sessionsSpawn);
      expect(CanonicalTool.fromName('sessions_send'), CanonicalTool.sessionsSend);
      expect(CanonicalTool.fromName('mcp_call'), CanonicalTool.mcpCall);
      expect(CanonicalTool.fromName('Bash'), isNull);
      expect(CanonicalTool.fromName(''), isNull);
    });
  });
}
