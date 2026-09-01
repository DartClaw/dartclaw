import 'package:dartclaw_core/dartclaw_core.dart';

import '../scheduling/delivery.dart';
import '../workspace/workspace_path_guard.dart';
import 'tool_schema.dart';

/// MCP tool that sends a workspace file to the owner's active DM sessions.
///
/// Takes no recipient: targets are resolved host-side from active channel
/// sessions, exactly as scheduled-job announce delivery resolves them. A
/// model-supplied destination would make this an exfiltration primitive the
/// guard chain would have to catch after the fact.
class AttachMediaTool implements McpTool {
  new({required WorkspacePathGuard workspace, required DeliveryService delivery})
    : _workspace = workspace,
      _delivery = delivery;

  final WorkspacePathGuard _workspace;
  final DeliveryService _delivery;

  @override
  String get name => 'attach_media';

  @override
  String get description =>
      'Send a file from the workspace to the owner as a media attachment. The path must resolve inside the '
      'workspace; the recipient is the owner\'s active direct-message sessions and cannot be chosen here.';

  @override
  Map<String, dynamic> get inputSchema => toolSchema(
    {
      'path': {'type': 'string', 'description': 'Workspace-relative path to the file to send.'},
      'caption': {'type': 'string', 'description': 'Message text sent alongside the file.'},
    },
    const ['path'],
  );

  @override
  McpToolAccess get access => McpToolAccess.write;

  @override
  Future<ToolResult> call(Map<String, dynamic> args) async {
    final invalid = validateToolArguments(inputSchema, args);
    if (invalid != null) return invalid;

    final path = args['path'] as String;
    final verdict = _workspace.resolveFile(path);
    final file = verdict.file;
    if (file == null) {
      return toolError('containment_refused', verdict.refusal!, {'path': path});
    }

    final report = await _delivery.deliverMedia(mediaPath: file.path, caption: args['caption'] as String? ?? '');
    if (report.attempted == 0) {
      return toolError('no_recipient', 'No active direct-message session to send to; nothing was delivered', {
        'path': path,
      });
    }
    // Distinct from having no recipient: the owner is reachable and the send
    // itself failed, which is a different thing for the model to report.
    if (report.delivered.isEmpty) {
      return toolError('delivery_failed', 'Every send to the owner\'s direct-message sessions failed', {
        'path': path,
        'attempted': report.attempted,
      });
    }
    return toolJson({'path': path, 'delivered_to': report.delivered});
  }
}
