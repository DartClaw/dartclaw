import 'guard.dart';
import 'guard_verdict.dart';

/// Guard that restricts tool usage to a task-specific allowlist.
///
/// When [allowedTools] is null or empty, all tools are permitted.
/// When set, any tool not in the list is blocked.
class TaskToolFilterGuard extends Guard {
  @override
  String get name => 'task_tool_filter';

  @override
  String get category => 'tool';

  /// Mutable allowlist — set before each turn via [TaskExecutor].
  /// Null/empty means unrestricted.
  List<String>? allowedTools;

  @override
  Future<GuardVerdict> evaluate(GuardContext context) async {
    if (context.hookPoint != 'beforeToolCall') return GuardVerdict.pass();
    final tools = allowedTools;
    if (tools == null || tools.isEmpty) return GuardVerdict.pass();
    final toolName = context.toolName;
    if (toolName == null) return GuardVerdict.pass();
    if (tools.contains(toolName)) return GuardVerdict.pass();
    return GuardVerdict.block(
      'Tool "$toolName" is not in this task\'s allowed tools: ${tools.join(', ')}',
    );
  }
}
