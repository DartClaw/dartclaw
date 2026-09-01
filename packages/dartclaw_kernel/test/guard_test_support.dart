import 'package:dartclaw_kernel/dartclaw_kernel.dart';

GuardContext bashGuardContext(String command) => GuardContext(
  hookPoint: 'beforeToolCall',
  toolName: 'shell',
  toolInput: {'command': command},
  timestamp: DateTime.now(),
);
