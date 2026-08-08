import 'package:dartclaw_security/dartclaw_security.dart';

GuardContext bashGuardContext(String command) => GuardContext(
  hookPoint: 'beforeToolCall',
  toolName: 'shell',
  toolInput: {'command': command},
  timestamp: DateTime.now(),
);
