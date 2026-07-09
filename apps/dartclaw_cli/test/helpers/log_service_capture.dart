import 'package:dartclaw_server/dartclaw_server.dart' show LogService;
import 'package:dartclaw_testing/dartclaw_testing.dart' show captureRootLogs;
import 'package:logging/logging.dart';
import 'package:test/test.dart';

Future<List<LogRecord>> captureLogServiceRecords(
  Future<void> Function() body, {
  Iterable<String> expectedSevereSubstrings = const [],
  bool failOnUnexpectedSevere = false,
}) async {
  final previousSuppression = LogService.suppressOutputForTests;
  final expectedSevere = expectedSevereSubstrings.toList();
  LogService.suppressOutputForTests = true;
  try {
    final records = await captureRootLogs(body);
    for (final expected in expectedSevere) {
      expect(
        records.any((record) => record.level >= Level.SEVERE && record.message.contains(expected)),
        isTrue,
        reason: 'Expected a SEVERE log containing "$expected".',
      );
    }
    if (failOnUnexpectedSevere) {
      final unexpectedSevere = records
          .where(
            (record) =>
                record.level >= Level.SEVERE && !expectedSevere.any((expected) => record.message.contains(expected)),
          )
          .toList();
      if (unexpectedSevere.isNotEmpty) {
        fail('Unexpected SEVERE logs: ${unexpectedSevere.map((record) => record.message).join(' | ')}');
      }
    }
    return records;
  } finally {
    LogService.suppressOutputForTests = previousSuppression;
  }
}
