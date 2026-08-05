import 'package:dartclaw_core/dartclaw_core.dart' show SessionType;

String displaySessionTitle(String? title, SessionType? type, {String emptyTitle = 'Untitled draft'}) {
  if (type == SessionType.main) return 'Agent';
  final trimmed = title?.trim() ?? '';
  return trimmed.isEmpty ? emptyTitle : trimmed;
}
