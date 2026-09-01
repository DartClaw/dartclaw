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
      expect(CanonicalTool.memoryApply.stableName, 'memory_apply');
      expect(CanonicalTool.memoryObserve.stableName, 'memory_observe');
      expect(CanonicalTool.memorySearch.stableName, 'memory_search');
      expect(CanonicalTool.memoryRead.stableName, 'memory_read');
      expect(CanonicalTool.sessionsSpawn.stableName, 'sessions_spawn');
      expect(CanonicalTool.sessionsSend.stableName, 'sessions_send');
      expect(CanonicalTool.taskCreate.stableName, 'task_create');
      expect(CanonicalTool.taskReview.stableName, 'task_review');
      expect(CanonicalTool.taskList.stableName, 'task_list');
      expect(CanonicalTool.reviewList.stableName, 'review_list');
      expect(CanonicalTool.taskBind.stableName, 'task_bind');
      expect(CanonicalTool.taskUnbind.stableName, 'task_unbind');
      expect(CanonicalTool.mcpCall.stableName, 'mcp_call');
    });

    test('fromName resolves known names and rejects unknown values', () {
      expect(CanonicalTool.fromName('shell'), CanonicalTool.shell);
      expect(CanonicalTool.fromName('file_read'), CanonicalTool.fileRead);
      expect(CanonicalTool.fromName('file_write'), CanonicalTool.fileWrite);
      expect(CanonicalTool.fromName('file_edit'), CanonicalTool.fileEdit);
      expect(CanonicalTool.fromName('web_fetch'), CanonicalTool.webFetch);
      expect(CanonicalTool.fromName('memory_apply'), CanonicalTool.memoryApply);
      expect(CanonicalTool.fromName('memory_observe'), CanonicalTool.memoryObserve);
      expect(CanonicalTool.fromName('memory_search'), CanonicalTool.memorySearch);
      expect(CanonicalTool.fromName('memory_read'), CanonicalTool.memoryRead);
      expect(CanonicalTool.fromName('sessions_spawn'), CanonicalTool.sessionsSpawn);
      expect(CanonicalTool.fromName('sessions_send'), CanonicalTool.sessionsSend);
      // A registered MCP tool with no canonical entry is unreachable from every
      // container, so each of the six must resolve by its registered name.
      expect(CanonicalTool.fromName('task_create'), CanonicalTool.taskCreate);
      expect(CanonicalTool.fromName('task_review'), CanonicalTool.taskReview);
      expect(CanonicalTool.fromName('task_list'), CanonicalTool.taskList);
      expect(CanonicalTool.fromName('review_list'), CanonicalTool.reviewList);
      expect(CanonicalTool.fromName('task_bind'), CanonicalTool.taskBind);
      expect(CanonicalTool.fromName('task_unbind'), CanonicalTool.taskUnbind);
      expect(CanonicalTool.fromName('mcp_call'), CanonicalTool.mcpCall);
      expect(CanonicalTool.fromName('Bash'), isNull);
      expect(CanonicalTool.fromName(''), isNull);
    });
  });
}
