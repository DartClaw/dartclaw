import 'dart:io';

import 'package:dartclaw_storage/dartclaw_storage.dart';

/// Fake [QmdManager] that simulates running/not-running states and can return
/// canned query results or throw to exercise fallback paths.
///
/// Union of the former per-file fakes: defaults to a running manager returning
/// an empty result set; set [fakeRunning], [nextQueryResult], or [shouldThrow]
/// to vary behavior.
class FakeQmdManager extends QmdManager {
  bool fakeRunning;
  List<Map<String, dynamic>>? nextQueryResult;
  bool shouldThrow = false;

  FakeQmdManager({this.fakeRunning = true})
    : super(
        commandRunner: (exe, args, {workingDirectory}) async {
          return ProcessResult(0, 0, '', '');
        },
      );

  @override
  bool get isRunning => fakeRunning;

  @override
  Future<List<Map<String, dynamic>>> query(String queryText, {String depth = 'standard', int limit = 10}) async {
    if (shouldThrow) throw Exception('QMD unreachable');
    return nextQueryResult ?? [];
  }

  @override
  Future<void> triggerIndex() async {
    if (shouldThrow) throw Exception('Index failed');
  }
}
