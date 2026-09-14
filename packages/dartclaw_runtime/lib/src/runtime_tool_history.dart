import 'package:dartclaw_core/dartclaw_core.dart';

final class RuntimeToolApprovalRequest {
  const new({
    required this.sessionId,
    required this.turnId,
    required this.requestId,
    required this.action,
    required this.target,
    required this.expiresAt,
  });

  final String sessionId;
  final String turnId;
  final String requestId;
  final String action;
  final Map<String, dynamic> target;
  final DateTime expiresAt;
}

typedef RuntimeToolApprovalRequested = Future<void> Function(RuntimeToolApprovalRequest request);
typedef RuntimeToolHistoryObserved = Future<void> Function(String sessionId, String turnId, BridgeEvent event);
typedef RuntimeToolApprovalClosed = Future<void> Function(
  String sessionId,
  String turnId,
  String requestId,
  bool approved,
  bool expired,
);
