import 'dart:async';

import 'package:logging/logging.dart';

/// Captures root logger records emitted while [body] runs.
///
/// This helper is capture-only: existing root listeners still receive records.
/// Tests that need to suppress a package-owned printing listener should do that
/// through that package's own test seam.
Future<List<LogRecord>> captureRootLogs(Future<void> Function() body, {Level level = Level.ALL}) async {
  final previousLevel = Logger.root.level;
  Logger.root.level = level;
  final records = <LogRecord>[];
  final subscription = Logger.root.onRecord.listen(records.add);
  try {
    await body();
    return List<LogRecord>.unmodifiable(records);
  } finally {
    await subscription.cancel();
    Logger.root.level = previousLevel;
  }
}
