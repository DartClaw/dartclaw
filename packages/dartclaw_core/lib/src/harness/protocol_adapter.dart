import 'canonical_tool.dart';
import 'protocol_message.dart';

/// Provider-agnostic protocol adapter boundary.
///
/// Implementations translate between a provider's wire protocol and DartClaw's
/// internal protocol message/control model.
abstract class ProtocolAdapter {
  /// Parses one provider stdout line into a provider-agnostic message.
  ///
  /// Returns `null` for malformed, unknown, or irrelevant lines.
  ProtocolMessage? parseLine(String line);

  /// Builds the JSON payload used to send a user turn to the provider.
  Map<String, dynamic> buildTurnRequest({
    required String message,
    String? systemPrompt,
    String? threadId,
    List<Map<String, dynamic>>? history,
    Map<String, dynamic>? settings,
    bool resume = false,
  });

  /// Builds the JSON payload used to answer a tool approval request.
  Map<String, dynamic> buildApprovalResponse(
    String requestId, {
    required bool allow,
    String? toolUseId,
    String? reason,
  });

  /// Maps a provider-native tool name to a canonical tool.
  ///
  /// Returns `null` when no mapping exists.
  CanonicalTool? mapToolName(String providerToolName, {String? kind});
}
