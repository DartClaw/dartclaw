import 'package:dartclaw_kernel/dartclaw_kernel.dart';

String displaySessionTitle(String? title, SessionType? type, {String emptyTitle = 'Untitled draft'}) {
  if (type == SessionType.main) return 'Agent';
  final trimmed = title?.trim() ?? '';
  return trimmed.isEmpty ? emptyTitle : trimmed;
}
