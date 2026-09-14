import 'package:dartclaw_kernel/dartclaw_kernel.dart';

/// Effective executable row used to offer a temporary conversation.
final class TemporaryConversationCapability {
  const new({required this.providerId, required this.policy, required this.available, required this.reason});

  final String providerId;
  final ExecutionPolicy policy;
  final bool available;
  final String reason;
}
